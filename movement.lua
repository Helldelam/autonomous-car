local util = require("util")
local config = require("config")
local _utils = require("_utils")

-- Driving. Each tick, for a moving car, movement.update_mode picks the driving
-- mode (fast, normal or slow), then movement.drive_tick sets the acceleration
-- and the steering, or movement.maneuver_tick does while a maneuver is under way.
local movement = {}

local pi, sin, cos = math.pi, math.sin, math.cos
local riding = defines.riding

-- How far around the car the slow measurements look (gates, moving neighbours):
-- the longest look-ahead of drive_tick plus the distance covered while braking
-- from a fast speed.
local SENSOR_REACH = config.lookahead.start + config.lookahead.length + config.lookahead.speed_bonus
	+ config.car_size.length + config.speed.fast * config.braking_duration

-- ============================================================
-- Helpers
-- ============================================================

-- Unit vector of an orientation (0 = north, 0.25 = east, as LuaEntity.orientation).
local function compute_heading_vector(orientation)
	return sin(2 * pi * orientation), -cos(2 * pi * orientation)
end

-- Angle from orientation `from` to orientation `to`, in turns, within
-- [-0.5, 0.5): positive when `to` is clockwise (on the right) of `from`.
local function compute_angle_between(from, to)
	return ((to - from + 0.5) % 1) - 0.5
end

-- Orientation of the direction (dx, dy).
local function compute_orientation_of(dx, dy)
	return (math.atan2(dx, -dy) / (2 * pi)) % 1
end

-- Orientation of the direction from the car to `target`.
local function compute_orientation_to(car, target)
	return compute_orientation_of(target.x - car.position.x, target.y - car.position.y)
end

-- Where the car steers: the next waypoint of its path (see "Path"), or its
-- destination. Arrival and braking always go by the destination itself.
local function get_target(car_data)
	local path = car_data.path
	if path.active then
		return path.waypoints[path.index]
	end
	return car_data.moving.destination.position
end

-- A waypoint is passed once the car is within two car lengths of it, or within
-- its own `reach` (the approach points of a gate: see add_gate_waypoints). The
-- waypoint in a gate has an `axis` instead: it is passed once the car is past the
-- gate, on its way through, not when it only drives by. The path ends with its
-- last waypoint: the car then drives to its destination as usual, in slow mode
-- for a moment (see update_mode).
local PATH_REACH = 2 * config.car_size.length
local GATE_PASSED = 0.3 -- how far past the plane of a gate the car is once it has gone through

local function advance_path(car, car_data, tick)
	local path = car_data.path
	while path.active do
		local waypoint = path.waypoints[path.index]
		local passed
		if waypoint.axis_x then
			passed = (car.position.x - waypoint.x) * waypoint.axis_x + (car.position.y - waypoint.y) * waypoint.axis_y > GATE_PASSED
		else
			local distance = util.distance(car.position, waypoint)
			passed = distance < (waypoint.reach or PATH_REACH)
			-- A car that cannot turn to a waypoint in time drives by it and circles
			-- back: it is passed as well once the car is past its plane, near it.
			if not passed and not waypoint.reach and distance < config.path.pass_radius then
				local from = path.waypoints[path.index - 1] or path.origin
				passed = (car.position.x - waypoint.x) * (waypoint.x - from.x)
					+ (car.position.y - waypoint.y) * (waypoint.y - from.y) > 0
			end
		end
		if not passed then
			break
		end
		path.index = path.index + 1
		if path.index > #path.waypoints then
			path.active = false
			car_data.slow_until = tick + config.medium_delay
		end
	end
end

-- Whether steering left in reverse turns the orientation the other way round than
-- going forwards. True: steering left in reverse swings the rear of the car to its
-- left, as seen in game. Everything that depends on it goes through get_arc_rotation.
local REVERSE_STEERING_INVERTED = true

-- Turn of the orientation of an arc, as -1 (counter-clockwise), 0 or 1 (clockwise).
local function get_arc_rotation(arc)
	if arc.reverse and REVERSE_STEERING_INVERTED then
		return -arc.turn
	end
	return arc.turn
end

local MARGIN_OFFSET = config.car_size.width * 1.5 -- how far to each side of a heading measure_wall_margin looks

-- True if a car turned toward `orientation` would fit at (x, y). The collision
-- box is turned to the closest of the 16 directions: without it can_place_entity
-- tests the box facing north, which overlaps the car itself for the first sample
-- points of a car that faces another way.
local function fits_at(car, x, y, orientation)
	return car.surface.can_place_entity{
		name = car.name, position = {x, y}, direction = math.floor(orientation * 16 + 0.5) % 16,
	}
end

-- Asks the gates of the car's force within SENSOR_REACH to open, every
-- config.slow_check_interval ticks (offset per car) and for as long: the car
-- cannot open a gate by itself (its prototype has no can_open_gates), and a
-- closed gate is a wall to it. The reach covers the look-ahead, so that the gate
-- is open by the time the car senses it.
local function open_gates(car, tick)
	if not _utils.is_slow_check_due(car, tick) then
		return
	end
	for _, gate in pairs(car.surface.find_entities_filtered{
		position = car.position, radius = SENSOR_REACH, type = "gate", force = car.force,
	}) do
		gate.request_to_open(car.force, config.slow_check_interval)
	end
end

-- True if something built by the player (walls, gates, buildings: the force of
-- the car) lies within config.built_zone_distance of the car. Natural things
-- (trees, rocks, cliffs, resources) are neutral. Ghosts have no collision and
-- other cars do not count.
local BUILT_SCAN_LIMIT = 30 -- cars fill the answer before a wall does: look at several
local function measure_built_nearby(car)
	for _, entity in pairs(car.surface.find_entities_filtered{
		position = car.position, radius = config.built_zone_distance, force = car.force, limit = BUILT_SCAN_LIMIT,
		collision_mask = car.prototype.collision_mask.layers,
	}) do
		if entity ~= car and entity.type ~= "car" then
			return true
		end
	end
	return false
end

-- Obstacle density, in entities per square tile, in a disc of
-- config.density.radius. A disc centred on the car counts the car itself (see
-- "Obstacle density" in config.lua).
local function measure_obstacle_density(car, x, y)
	local radius = config.density.radius
	local count = car.surface.count_entities_filtered{
		position = {x, y},
		radius = radius,
		collision_mask = car.prototype.collision_mask.layers,
	}
	return count / (pi * radius * radius)
end

-- Obstacle density summed over config.density.lookahead_steps + 1 discs laid end
-- to end from the car along the heading (hx, hy), up to `reach` (the distance to
-- the target: what lies beyond it does not matter): steering adds it to the cost
-- of a heading, so that the car steers away from crowded areas well before it
-- reaches them.
local function measure_density_ahead(car, x, y, hx, hy, reach)
	local radius = config.density.radius
	local total = 0
	for step = 0, config.density.lookahead_steps do
		if step > 0 and 2 * step * radius >= reach then
			break -- the disc starts beyond the target: what lies there does not matter
		end
		total = total + measure_obstacle_density(car, x + hx * radius * (2 * step + 1), y + hy * radius * (2 * step + 1))
	end
	return total
end

-- The other cars that are moving near this one: position, unit direction of
-- travel and speed, measured every config.slow_check_interval ticks (offset per
-- car, so they do not all measure on the same tick). A parked or stopped car is
-- an ordinary obstacle, which can_place_entity already sees. Trains could join
-- this list later: it only holds what is_in_neighbour_zone needs.
local function refresh_neighbours(car, car_data, tick)
	if car_data.neighbours and not _utils.is_slow_check_due(car, tick) then
		return
	end
	local list = {}
	for _, other in pairs(car.surface.find_entities_filtered{
		position = car.position, radius = SENSOR_REACH, name = config.names.car,
	}) do
		if other ~= car and math.abs(other.speed) > config.speed.stopped then
			local hx, hy = compute_heading_vector(other.orientation)
			local sign = other.speed < 0 and -1 or 1
			table.insert(list, {x = other.position.x, y = other.position.y, mx = hx * sign, my = hy * sign, speed = math.abs(other.speed)})
		end
	end
	car_data.neighbours = {tick = tick, list = list}
end

-- True when (x, y) lies in the zone in front of a moving neighbour: as wide as
-- a car, as long as the car, plus the distance it covers while braking. The
-- neighbour is moved along its direction since the last measurement.
local function is_in_neighbour_zone(neighbours, tick, x, y)
	if not neighbours then
		return false
	end
	local elapsed = tick - neighbours.tick
	for _, other in ipairs(neighbours.list) do
		local dx = x - (other.x + other.mx * other.speed * elapsed)
		local dy = y - (other.y + other.my * other.speed * elapsed)
		local along = dx * other.mx + dy * other.my
		local across = math.abs(dy * other.mx - dx * other.my)
		if along >= 0 and along <= config.car_size.length + other.speed * config.braking_duration
			and across <= config.car_size.width then
			return true
		end
	end
	return false
end

-- Margin cost of a point: config.steering_cost.margin if the car would not fit one
-- and a half car widths to `side` (-1 left, 1 right, of the heading `orientation`;
-- nil or false to skip), i.e. where an obstacle runs along the point at about a car
-- width from its flank. Makes the car keep away from walls when it can. The point
-- must be at least half a car length from the car, or the box would overlap the
-- car itself.
local function measure_wall_margin(car, x, y, orientation, side)
	if not side then
		return 0
	end
	local hx, hy = compute_heading_vector(orientation)
	if fits_at(car, x - hy * side * MARGIN_OFFSET, y + hx * side * MARGIN_OFFSET, orientation) then
		return 0
	end
	return config.steering_cost.margin
end

-- The segment of the path being followed (its start x, y and unit direction ux,
-- uy), set by drive_tick while the car follows a path, nil otherwise.
local path_segment

-- Steering cost of a sample point: the distance left from there to the target,
-- relative to the car's own, plus config.steering_cost.blocked if the car would
-- not fit there, and again if it lies in front of a moving car, plus the margin
-- cost of `side` (see measure_wall_margin) for a point where it fits, plus
-- config.steering_cost.path_deviation per car width beyond config.path.corridor
-- from path_segment.
local function compute_sample_cost(car, x, y, orientation, target, distance, neighbours, tick, side)
	local blocked = fits_at(car, x, y, orientation) and 0 or 1
	if is_in_neighbour_zone(neighbours, tick, x, y) then
		blocked = blocked + 1
	end
	local deviation = 0
	if path_segment then
		local seg = path_segment
		local lateral = math.abs((x - seg.x) * seg.uy - (y - seg.y) * seg.ux) -- distance to the line
		deviation = config.steering_cost.path_deviation * math.max(lateral - config.path.corridor, 0) / config.car_size.width
	end
	return util.distance({x, y}, target) / distance + config.steering_cost.blocked * blocked + deviation
		+ (blocked == 0 and measure_wall_margin(car, x, y, orientation, side) or 0)
end

-- True if the car would not fit somewhere on the straight line along
-- `orientation`, one tile apart, over `length` tiles: something stands between the
-- car and its destination.
local function is_line_blocked(car, orientation, length)
	local vx, vy = compute_heading_vector(orientation)
	for d = config.car_size.length, length do
		if not fits_at(car, car.position.x + vx * d, car.position.y + vy * d, orientation) then
			return true
		end
	end
	return false
end

-- True if `target`, `distance` away, lies in the cone ahead of the car
-- (config.path_trigger.half_angle around `orientation`) and the straight line to it
-- is free over at most config.path.goal.range: the car can steer there by itself.
local function is_way_open(car, orientation, target, distance)
	local bearing = compute_orientation_to(car, target)
	return math.abs(compute_angle_between(orientation, bearing)) <= config.path_trigger.half_angle
		and not is_line_blocked(car, bearing, math.min(distance, config.path.goal.range))
end

-- ============================================================
-- Friction
-- ============================================================

-- Friction modifier of the tile under the car, measured each time the friction is set.
local function measure_tile_friction(car)
	local tile = car.surface.get_tile(math.floor(car.position.x), math.floor(car.position.y))
	local friction = tile.valid and tile.prototype.vehicle_friction_modifier or 1
	return friction > 0 and friction or 1
end

-- Sets car.friction_modifier from scratch, so that nothing accumulates from one
-- tick to the next. `mode_friction` sets the speed of the mode: the game
-- multiplies it by the friction of the tile under the car, so it is divided by
-- it here and the car goes as fast on grass as on concrete. `braking_factor`
-- (emergency braking) is not: it has to brake on any tile.
local function set_friction(car, mode_friction, braking_factor)
	car.friction_modifier = mode_friction / measure_tile_friction(car) * (braking_factor or 1)
end

-- ============================================================
-- Driving mode
-- ============================================================

-- Picks the driving mode of a moving car for this tick (car_data.mode):
--   fast    cruising where the density is low: left for a higher density, an
--           obstacle ahead, the vicinity of built things, or the destination (the
--           car brakes down to the speed it had on entering, see drive_tick)
--   normal  when no other mode applies
--   slow    near built things, in a very dense area, and for config.medium_delay
--           after an emergency stop, a maneuver or the end of a path (slow_until);
--           the look-ahead is finer
-- In a built or very dense area a destination that is not in front of the car
-- (config.path_trigger) makes it ask for a path (see movement.request_guided_path).
-- Emergency braking (a full stop, at the destination or before an obstacle) is an
-- event, not a mode: it comes on top of the mode's friction.
-- Must run before movement.drive_tick, which reads emergency_brake and mode in
-- the same tick. It may start a maneuver, in which case maneuver_tick runs instead
-- of drive_tick (see update_car in control.lua). It ends by setting
-- car.friction_modifier, the lever that controls cruising speed, from the mode.
-- TODO: make a car flee from danger (enemy force). See "À faire" in CLAUDE.md.
function movement.update_mode(car, tick)
	local car_data = storage.car_data[car.unit_number]
	open_gates(car, tick)
	advance_path(car, car_data, tick)
	if car_data.maneuver.active then
		set_friction(car, config.friction.maneuver)
		return
	end

	local destination_position = car_data.moving.destination.position
	local distance = util.distance(car.position, destination_position)
	local orientation = car.orientation
	local x, y = car.position.x, car.position.y
	local sx, sy = compute_heading_vector(orientation)

	-- Density around the car (weight 2), blended with the density one disc
	-- further ahead (weight 1).
	local density = 1 / 3 * (2 * measure_obstacle_density(car, x, y)
		+ measure_obstacle_density(car, x + sx * 2 * config.density.radius, y + sy * 2 * config.density.radius))

	-- Built things are measured with the other slow checks and remembered between them.
	if _utils.is_slow_check_due(car, tick) then
		car_data.near_built = measure_built_nearby(car)
		-- Built things beside a car whose way is open (target ahead, straight line free, not
		-- close to it, not a gate) do not make it slow down: it drives in normal mode.
		local target = get_target(car_data)
		local target_distance = util.distance(car.position, target)
		car_data.line_clear = car_data.near_built and not target.axis_x
			and target_distance > config.normal_beside_built_distance
			and is_way_open(car, orientation, target, target_distance)
	end
	local in_zone = (car_data.near_built and not car_data.line_clear) or density > config.dense_area_threshold

	-- Two thresholds for fast, so the mode does not flicker when the density hovers around one value.
	local was_fast = car_data.mode == "fast"
	local mode = "normal"
	if in_zone or tick < (car_data.slow_until or 0) then
		mode = "slow"
	elseif not car_data.near_built and distance >= car.speed * config.braking_duration
		and density < (was_fast and config.fast_density.leave or config.fast_density.enter) then
		mode = "fast"
	end
	car_data.mode = mode

	-- Leaving fast, drive_tick brakes down to the speed the car had when it
	-- entered it (see `slowing` in drive_tick): friction alone is too slow.
	if mode == "fast" and not was_fast then
		car_data.entry_speed = car.speed
		car_data.slowing = false
	elseif was_fast and mode ~= "fast" then
		car_data.slowing = true
	end

	refresh_neighbours(car, car_data, tick)

	-- Emergency braking ends once the car has stopped, and cannot start again
	-- before config.short_delay: the car gets a moment to move away instead of
	-- being stopped again on the next tick.
	local emergency_brake = car_data.emergency_brake
	local obstacle_ahead = not fits_at(car, x + sx * config.emergency_brake_lookahead, y + sy * config.emergency_brake_lookahead, orientation)
	local cooldown_over = not emergency_brake.since or tick - emergency_brake.since > config.short_delay
	local allowed = not car_data.path.active -- a path hugs walls and trees within the look-ahead: braking there only stalls the car
	if (distance < config.arrival_distance or obstacle_ahead) and allowed and not emergency_brake.active and cooldown_over then
		emergency_brake.active = true
		emergency_brake.since = tick
		emergency_brake.cause = obstacle_ahead and "obstacle" or "arrival"
		if obstacle_ahead then
			car_data.slow_until = tick + config.medium_delay
		end
	elseif car.speed < config.speed.stopped and emergency_brake.active then
		emergency_brake.active = false
		emergency_brake.since = tick
	end

	-- A destination out of the cone ahead, or behind an obstacle on the straight
	-- line, in a built or dense area: the car cannot find its way by steering
	-- alone, it asks for a path.
	local path = car_data.path
	if in_zone and not path.active and distance > config.path_trigger.min_distance and tick >= path.next_tick then
		if not is_way_open(car, orientation, destination_position, distance) then
			if movement.request_guided_path(car, tick) then
				set_friction(car, config.friction.maneuver)
				return
			end
		else
			path.next_tick = tick + config.short_delay -- the line is measured at this pace
		end
	end

	set_friction(car, config.friction[mode], emergency_brake.active and config.friction.emergency or 1)
end

-- ============================================================
-- Driving
-- ============================================================

-- Sets the acceleration and the steering of a moving car for this tick, and
-- raises the next-task event once it has stopped at its destination.
function movement.drive_tick(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local target = get_target(car_data)
	local distance = util.distance(car.position, car_data.moving.destination.position)
	local arrived = car.speed < config.speed.stopped and distance < config.arrival_distance

	if car_data.emergency_brake.active then
		-- A real stop: a high friction alone slows the car down but does not brake it.
		car.riding_state = {acceleration = riding.acceleration.braking, direction = car.riding_state.direction}
		if arrived then
			_utils.raise_next_task(car)
		end
		return
	end

	-- Stopped dead short of the destination, a while after the leg began or the
	-- last maneuver ended: the car hit something and needs a maneuver.
	if car.speed == 0 and distance >= config.arrival_distance
		and tick - car_data.maneuver.ended_tick > config.short_delay then
		movement.start_maneuver(car, tick, true) -- takes over from the next tick
		return
	end

	-- Brake when close enough to stop at the destination, or when already slow within arrival distance.
	local acceleration = riding.acceleration.accelerating
	if distance < car.speed * config.braking_duration
		or arrived then
		acceleration = riding.acceleration.braking
	end

	-- Just left fast mode: brake down to the speed the car had when it entered
	-- it, but never below config.speed.slow (a car that entered it from rest
	-- would otherwise brake to a stop).
	if car_data.slowing then
		if car.speed > math.max(car_data.entry_speed or 0, config.speed.slow) then
			acceleration = riding.acceleration.braking
		else
			car_data.slowing = false
		end
	end

	-- The current waypoint of a path is behind the car, close by: a U-turn backwards. The car backs slowly,
	-- steering its front toward the waypoint, until the waypoint is within lookahead.angle ahead, or is
	-- reached, or the car stalls (short_delay), or the turn lasts idle_delay. One turn per waypoint (the
	-- path may double back), and a second turn on a path only outside dense areas: in a forest the car
	-- backs into trees. The path starts at the car, so its first waypoint is often passed at once.
	local path = car_data.path
	local waypoint = path.active and path.waypoints[path.index]
	if waypoint and not waypoint.axis_x then
		local u_turn = path.u_turn
		local angle = compute_angle_between(car.orientation, compute_orientation_to(car, waypoint))
		if not u_turn and path.u_turn_done ~= path.index and math.abs(angle) > config.path.u_turn_angle
			and util.distance(car.position, waypoint) < config.path.pass_radius
			and (not path.u_turn_done
				or measure_obstacle_density(car, car.position.x, car.position.y) <= config.dense_area_threshold) then
			u_turn = {tick = tick}
			path.u_turn = u_turn
		end
		if u_turn then
			if math.abs(car.speed) < config.speed.stopped then
				u_turn.stalled_since = u_turn.stalled_since or tick
			else
				u_turn.stalled_since = nil
			end
			if math.abs(angle) <= config.lookahead.angle or tick - u_turn.tick > config.idle_delay
				or (u_turn.stalled_since and tick - u_turn.stalled_since > config.short_delay) then
				path.u_turn, path.u_turn_done = nil, path.index
			else
				local rotation = angle > 0 and 1 or -1
				local direction = get_arc_rotation{reverse = true, turn = -1} == rotation and riding.direction.left or riding.direction.right
				set_friction(car, config.friction.maneuver)
				car.riding_state = {acceleration = riding.acceleration.reversing, direction = direction}
				return
			end
		end
	end

	local side_offset = config.lookahead.side_offset
	local lookahead = car_data.mode == "slow" and config.slow_lookahead or config.lookahead
	local lookahead_start, lookahead_length = lookahead.start, lookahead.length
	local bonus = 0
	if car.speed > config.speed.fast then
		bonus = config.lookahead.speed_bonus
	end

	local x, y = car.position.x, car.position.y
	local orientation = car.orientation
	local sx, sy = compute_heading_vector(orientation)
	local rx, ry = compute_heading_vector(orientation + config.lookahead.angle)
	local lx, ly = compute_heading_vector(orientation - config.lookahead.angle)

	-- Cost of the straight, right and left headings, from sample points one
	-- tile apart along each of them. Near points weigh more than far ones. The
	-- straight heading is sampled along two lines, one on each side of the car.
	local ax, ay = x + sy * side_offset, y - sx * side_offset
	local bx, by = x - sy * side_offset, y + sx * side_offset
	local neighbours = car_data.neighbours
	local target_distance = math.max(util.distance(car.position, target), 1) -- the steering costs are relative to it

	-- The margin cost (see measure_wall_margin) is only worth its extra checks when
	-- something stands near the samples: one entity within reach is the car itself.
	local reach = lookahead_start + lookahead_length + bonus + MARGIN_OFFSET
	local near = car.surface.count_entities_filtered{
		position = car.position, radius = reach, collision_mask = car.prototype.collision_mask.layers,
		limit = 2,
	} > 1
	local left_side, right_side = near and -1, near and 1 -- the outer side of each heading

	path_segment = nil
	if path.active and config.steering_cost.path_deviation > 0 then
		local from = path.waypoints[path.index - 1] or path.origin
		local length = util.distance(from, target)
		if length > 1 then
			path_segment = {x = from.x, y = from.y, ux = (target.x - from.x) / length, uy = (target.y - from.y) / length}
		end
	end

	local straight, right, left = 0, 0, 0
	for d = lookahead_start, lookahead_start + (lookahead_length + bonus) do
		local weight = ((lookahead_start + lookahead_length + bonus - (d / 2)) + 1) / (lookahead_length + bonus)
		straight = straight + (weight * compute_sample_cost(car, ax + sx * d, ay + sy * d, orientation, target, target_distance, neighbours, tick, left_side)
			+ weight * compute_sample_cost(car, bx + sx * d, by + sy * d, orientation, target, target_distance, neighbours, tick, right_side)) / 2
		right = right + weight * compute_sample_cost(car, x + rx * d, y + ry * d, orientation + config.lookahead.angle, target, target_distance, neighbours, tick, right_side)
		left = left + weight * compute_sample_cost(car, x + lx * d, y + ly * d, orientation - config.lookahead.angle, target, target_distance, neighbours, tick, left_side)
	end

	-- Add the obstacle density further along each heading.
	local density_weight = config.steering_cost.density
	if path.active then
		density_weight = density_weight * config.path.density_factor -- the path already avoids what is in the way
	end
	local straight_density = density_weight * measure_density_ahead(car, x, y, sx, sy, target_distance)
	local right_density = density_weight * measure_density_ahead(car, x, y, rx, ry, target_distance)
	local left_density = density_weight * measure_density_ahead(car, x, y, lx, ly, target_distance)
	straight, right, left = straight + straight_density, right + right_density, left + left_density

	-- The costs of this tick, for the debug drawing (see debug_view.lua).
	local steering = car_data.steering
	if not steering then
		steering = {}
		car_data.steering = steering
	end
	steering.straight, steering.right, steering.left = straight, right, left
	steering.straight_density, steering.right_density, steering.left_density = straight_density, right_density, left_density

	-- Steer to the cheapest heading; a tie between right and left goes left.
	local direction = riding.direction.straight
	if right < straight and right < left then
		direction = riding.direction.right
	elseif left < straight and left <= right then
		direction = riding.direction.left
	end

	car.riding_state = {acceleration = acceleration, direction = direction}
	if arrived then
		_utils.raise_next_task(car)
	end
end

-- ============================================================
-- Maneuver
-- ============================================================

-- The six arcs of a maneuver: forward or backward, steering left (-1),
-- straight (0) or right (1). The car follows one arc for
-- config.short_delay, then picks the next.
local ARCS = {
	{reverse = false, turn = 0}, {reverse = false, turn = -1}, {reverse = false, turn = 1},
	{reverse = true, turn = 0}, {reverse = true, turn = -1}, {reverse = true, turn = 1},
}

-- How a maneuver ranks things. These are not tuning values: each one only has to
-- outweigh everything below it.
--  - choose_heading: one probe step of free room outweighs the pull toward the
--    preferred direction (at most 0.5 turn * ANGLE_PULL).
--  - choose_arc: an arc the car fits in, then turning toward the heading, then
--    driving forward, then free room, then the listing order of ARCS.
local ANGLE_PULL = 0.2
local RANK_FITS, RANK_TOWARD_HEADING, RANK_FORWARD = 1000, 100, 10

-- Distance between two probes of measure_free_room: half a car length (see
-- config.maneuver.probe).
local PROBE_STEP = config.car_size.length / 2

-- True if driving the way `reverse` is known to be blocked from where the car
-- is: it stalled straight that way (see back_off), and has neither moved a car
-- length nor turned by an arc's worth since. A stall further away, or at another
-- angle, says nothing about this spot: in a room the car may well have crossed
-- it from one wall to the other.
local function is_blocked(car, maneuver, reverse)
	local stall = maneuver.blocked[reverse]
	return stall ~= nil
		and util.distance(car.position, stall.position) < config.car_size.length
		and math.abs(compute_angle_between(stall.orientation, car.orientation)) < config.lookahead.angle
end

-- Called when the car drives but does not move: something it cannot see is in
-- the way, or a wall stops it from turning (a car turns around its centre, so
-- along a wall it cannot turn into it, nor away from it with its rear). The car
-- is sent the other way, straight, and follows that direction along the wall (see
-- maneuver_tick) until a turn works. A straight stall is the end of the wall in
-- that direction: the car goes the other way round. When it stalled straight both
-- ways at the same spot (see is_blocked) there is nothing more it can do alone.
-- Returns true then.
-- `assumed`: the car did not stall, it is only taken to have been driving forward
-- (a car that stood still on its leg, see start_maneuver). It is sent backwards
-- the same way, but no direction is noted as blocked.
local function back_off(car, maneuver, tick, assumed)
	local stalled, turn = maneuver.reverse, maneuver.turn
	maneuver.stall_since = nil
	if turn == 0 and not assumed then
		maneuver.blocked[stalled] = {position = car.position, orientation = car.orientation}
	end

	local reverse = not stalled
	if maneuver.follow ~= nil and turn ~= 0 then
		reverse = maneuver.follow -- a turn failed: carry on along the wall
		-- A turn that stalled again at the same spot and angle turned nothing (a car in
		-- a pocket against a wall): the other direction may have room to turn.
		local last = maneuver.turn_stall
		if last ~= nil and util.distance(car.position, last.position) < PROBE_STEP
			and math.abs(compute_angle_between(last.orientation, car.orientation)) < config.lookahead.angle / 4 then
			reverse = not maneuver.follow
		end
	end
	if turn ~= 0 then
		maneuver.turn_stall = {position = car.position, orientation = car.orientation}
	end
	if is_blocked(car, maneuver, reverse) then
		return true
	end
	if maneuver.follow ~= reverse then
		maneuver.follow_orientation = car.orientation
	end

	maneuver.follow = reverse
	maneuver.back_off_until = tick + config.short_delay
	maneuver.back_off_from = car.position
	maneuver.reverse = reverse
	maneuver.turn = 0
	car.riding_state = {
		acceleration = reverse and riding.acceleration.reversing or riding.acceleration.accelerating,
		direction = riding.direction.straight,
	}
	return false
end

local start_clearing -- see "Clearing"

-- Starts a maneuver (see movement.maneuver_tick). `backing_off`: the car stopped dead
-- short of its destination, it backs off first (otherwise it only waits for a path).
function movement.start_maneuver(car, tick, backing_off)
	local car_data = storage.car_data[car.unit_number]
	local maneuver = car_data.maneuver
	maneuver.active = true
	maneuver.since = tick
	maneuver.arc_since = nil
	maneuver.arcs = 0
	maneuver.reverse = false
	maneuver.turn = 0
	maneuver.origin = car.position
	maneuver.heading = nil
	maneuver.heading_since = nil
	maneuver.stall_since = nil
	maneuver.back_off_until = nil
	maneuver.follow = nil
	maneuver.follow_orientation = nil
	maneuver.turn_stall = nil
	maneuver.clearing = false
	maneuver.blocked = {}

	-- Emergency braking belongs to drive_tick: it must not hold the car back, and
	-- its cooldown starts now.
	car_data.emergency_brake.active = false
	car_data.emergency_brake.since = tick

	if backing_off then
		-- The car stood still on its leg: it backs off first, as if it had been
		-- driving forward. Nothing says that it stalled straight against something
		-- (its own emergency braking stops it too, and a maneuver that starts over
		-- may have been reversing), so forward is not noted as blocked.
		-- Once the car has cleared its way on this leg, a dead stop clears again at once.
		if car_data.path.clear_count > 0 and start_clearing(car, car_data, maneuver, tick) then
			return
		end
		back_off(car, maneuver, tick, true)
	end
end

-- Free room along a heading, in PROBE_STEP units: how many probes the car fits
-- at before the first one it would not fit at. Two things keep a thin obstacle
-- (a wall is 0.58 tile thick) from slipping through:
--  - the probes start at config.maneuver.probe.start so that the car does not
--    detect itself, which leaves a blind zone next to it: the entities there are
--    looked for apart, with a disc search that skips the car;
--  - the probes are closer to each other than the car is wide.
local function measure_free_room(car, x, y, orientation)
	local vx, vy = compute_heading_vector(orientation)
	local surface = car.surface
	local probe = config.maneuver.probe

	-- The disc sits where the first probe begins, half a car length before its centre.
	local near = probe.start - config.car_size.length / 2
	for _, entity in pairs(surface.find_entities_filtered{
		position = {x + vx * near, y + vy * near},
		radius = probe.near_radius,
		collision_mask = car.prototype.collision_mask.layers,
	}) do
		if entity ~= car then
			return 0
		end
	end

	local steps = math.floor(probe.length / PROBE_STEP)
	for step = 0, steps do
		local distance = probe.start + step * PROBE_STEP
		if not fits_at(car, x + vx * distance, y + vy * distance, orientation) then
			return step
		end
	end
	return steps + 1
end

-- Score of an orientation as the heading a maneuver turns toward: its free
-- room (0 to 1), minus a small pull away from `preferred`, minus the obstacle
-- density around the point 2 * config.density.radius away along it.
local function score_heading(car, x, y, orientation, preferred)
	local room = measure_free_room(car, x, y, orientation) / (math.floor(config.maneuver.probe.length / PROBE_STEP) + 1)
	local vx, vy = compute_heading_vector(orientation)
	local reach = 2 * config.density.radius
	return room - math.abs(compute_angle_between(preferred, orientation)) * ANGLE_PULL
		- config.steering_cost.density * measure_obstacle_density(car, x + vx * reach, y + vy * reach)
end

-- Picks the direction a maneuver turns toward. It starts from the direction of
-- the destination and looks for the roomiest and least dense direction around the
-- car, the one closest to the destination on a tie.
local function choose_heading(car, car_data)
	local x, y = car.position.x, car.position.y
	local preferred = compute_orientation_to(car, get_target(car_data))

	local count = math.floor(1 / config.lookahead.angle + 0.5)
	local best, best_score
	for index = 0, count - 1 do
		local score = score_heading(car, x, y, index / count, preferred)
		if not best or score > best_score then
			best, best_score = index / count, score
		end
	end
	return best
end

-- Picks the next arc to drive the car toward `maneuver.heading`. Ranked: an arc
-- the car fits along (first probe free), then one that turns the car toward the
-- heading (or keeps it straight once it is aligned), then forward, then free
-- room. When it is blocked ahead and behind (no straight arc has room) driving
-- straight leads nowhere: it has to turn, and a turning arc counts as fitting as
-- soon as there is room along it.
local function choose_arc(car, maneuver)
	local x, y = car.position.x, car.position.y
	local orientation = car.orientation
	local angle = compute_angle_between(orientation, maneuver.heading)
	local aligned = math.abs(angle) < config.lookahead.angle / 2 -- half a sector of choose_heading

	-- The arcs open to the car, with the room along each.
	local options = {}
	local straight_free = false
	for index, arc in ipairs(ARCS) do
		-- Following a wall (see back_off), the car keeps to its direction.
		if maneuver.follow == nil or arc.reverse == maneuver.follow then
			-- The orientation turns clockwise with a right turn; in reverse the car moves along the opposite heading.
			local rotation = get_arc_rotation(arc)
			local room = measure_free_room(car, x, y,
				orientation + (arc.reverse and 0.5 or 0) + rotation * config.lookahead.angle)
			table.insert(options, {index = index, arc = arc, rotation = rotation, room = room})
			if rotation == 0 and room >= 1 then
				straight_free = true
			end
		end
	end

	local best, best_rank
	for _, option in ipairs(options) do
		local arc, rotation, room = option.arc, option.rotation, option.room
		local toward = rotation * (angle >= 0 and 1 or -1) -- 1 turns toward the heading, -1 away
		if aligned and straight_free then
			toward = (rotation == 0 and not arc.reverse) and 1 or -1 -- aligned: drive straight ahead
		end
		local fits = room >= 1
		local rank = (fits and RANK_FITS or 0) + toward * RANK_TOWARD_HEADING
			+ (arc.reverse and 0 or RANK_FORWARD) + math.min(room, 9) - option.index / 100
		if not best or rank > best_rank then
			best, best_rank = arc, rank
		end
	end
	return best
end

-- True when the car is out of the situation that called for the maneuver.
local function is_maneuver_done(car, car_data)
	local maneuver = car_data.maneuver
	local target = car_data.moving.destination.position
	local x, y = car.position.x, car.position.y

	if util.distance(car.position, target) < config.arrival_distance then
		return true -- drive_tick lets the car arrive
	end
	if maneuver.arcs == 0 then
		return false -- at least one arc: the situation is not judged from where the car stood still
	end
	if measure_obstacle_density(car, x, y) > config.maneuver.exit_density then
		return false
	end

	local sx, sy = compute_heading_vector(car.orientation)
	if not fits_at(car, x + sx * config.emergency_brake_lookahead, y + sy * config.emergency_brake_lookahead,
		car.orientation) then
		return false
	end

	return util.distance(car.position, maneuver.origin) >= config.maneuver.min_travel
end

-- Ends the maneuver of a car, successful or not, and brakes.
local function end_maneuver(car, maneuver, tick)
	maneuver.active = false
	maneuver.ended_tick = tick
	storage.car_data[car.unit_number].slow_until = tick + config.medium_delay -- slow mode for a moment: fewer repeated crashes
	car.riding_state = {acceleration = riding.acceleration.braking, direction = riding.direction.straight}
end

-- ============================================================
-- Clearing
-- ============================================================
-- The last resort of a car that no maneuver and no path frees (in a dense forest the
-- pathfinder finds no way): for at most config.idle_delay, or until it has moved
-- config.clearing.travel, it destroys the trees and rocks in its way and drives on
-- toward its destination, along the heading that crosses the fewest of them. It
-- never destroys anything else: a car walled in by buildings, walls or cliffs stays
-- stuck. When it ends the car drives as usual; if it stops dead again it clears again at
-- once (see movement.start_maneuver), without going through the maneuvers and paths again,
-- at most config.clearing.max_count times per leg (path.clear_count).

local CLEARABLE_TYPES = {"tree", "simple-entity"}

local function is_clearable(entity)
	return entity.type == "tree" or (entity.type == "simple-entity"
		and entity.prototype.count_as_rock_for_filtered_deconstruction)
end

-- Looks along `orientation`, from `from` to `ahead` tiles in front of the car, in discs of
-- `radius` tiles every `step` tiles. Returns the trees and rocks there (a set), their
-- number, and whether something else the car cannot drive over is there.
local function measure_clearing(car, orientation, from, ahead, step, radius)
	local vx, vy = compute_heading_vector(orientation)
	local layers = car.prototype.collision_mask.layers
	local found, count, blocked = {}, 0, false
	for distance = from, ahead, step do
		local position = {car.position.x + vx * distance, car.position.y + vy * distance}
		-- Trees and rocks do not stop a car by their collision mask: found by their type.
		for _, entity in pairs(car.surface.find_entities_filtered{
			position = position, radius = radius, type = CLEARABLE_TYPES,
		}) do
			if is_clearable(entity) and not found[entity] then
				found[entity] = true
				count = count + 1
			end
		end
		if not blocked then
			for _, entity in pairs(car.surface.find_entities_filtered{
				position = position, radius = radius, collision_mask = layers,
			}) do
				if entity ~= car and not is_clearable(entity) then
					blocked = true
					break
				end
			end
		end
	end
	return found, count, blocked
end

-- The heading that leads toward the destination through the fewest trees and rocks, or
-- nil when every heading is closed by something that must not be destroyed.
local function choose_clearing_heading(car, car_data)
	local clearing = config.clearing
	local preferred = compute_orientation_to(car, get_target(car_data))
	local count = math.floor(1 / config.lookahead.angle + 0.5)
	local best, best_cost
	for index = 0, count - 1 do
		local orientation = index / count
		local _, obstacles, blocked = measure_clearing(car, orientation, 1, clearing.lookahead, 1, clearing.radius)
		if not blocked then
			local cost = obstacles * clearing.obstacle_cost + math.abs(compute_angle_between(preferred, orientation))
			if not best_cost or cost < best_cost then
				best, best_cost = orientation, cost
			end
		end
	end
	return best
end

-- Turns the maneuver of the car into a clearing, at most config.clearing.max_count times
-- per leg, when a tree or a rock lies near enough to be worth it (within
-- config.clearing.lookahead). False otherwise: the car is stuck as before.
function start_clearing(car, car_data, maneuver, tick)
	local path = car_data.path
	if path.clear_count >= config.clearing.max_count then
		return false
	end
	local _, near = measure_clearing(car, car.orientation, 0, 0, 1, config.clearing.lookahead)
	if near == 0 then
		return false
	end
	path.clear_count = path.clear_count + 1
	if not maneuver.active then
		movement.start_maneuver(car, tick)
	end
	maneuver.clearing = true
	maneuver.since = tick
	maneuver.origin = car.position
	maneuver.heading = nil
	maneuver.back_off_until = nil
	maneuver.arc_since = nil
	return true
end

-- Returns true when the car cannot go on (see maneuver_tick).
local function clearing_tick(car, car_data, maneuver, tick)
	local clearing = config.clearing
	if util.distance(car.position, car_data.moving.destination.position) < config.arrival_distance
		or util.distance(car.position, maneuver.origin) >= clearing.travel
		or tick - maneuver.since > config.idle_delay then
		maneuver.clearing = false
		end_maneuver(car, maneuver, tick)
		return false
	end

	if not maneuver.heading or tick - maneuver.heading_since >= config.short_delay then
		maneuver.heading = choose_clearing_heading(car, car_data)
		maneuver.heading_since = tick
		if not maneuver.heading then
			maneuver.clearing = false
			end_maneuver(car, maneuver, tick)
			return true
		end
	end

	-- What stands in the car and just ahead of it goes.
	local found = measure_clearing(car, car.orientation, 0, clearing.reach, 0.5, clearing.clear_radius)
	for entity in pairs(found) do
		entity.destroy{raise_destroy = true}
	end

	local angle = compute_angle_between(car.orientation, maneuver.heading)
	local direction = riding.direction.straight
	if angle > config.lookahead.angle / 2 then
		direction = riding.direction.right
	elseif angle < -config.lookahead.angle / 2 then
		direction = riding.direction.left
	end
	car.riding_state = {acceleration = riding.acceleration.accelerating, direction = direction}
	return false
end

-- ============================================================
-- Path
-- ============================================================
-- Two things send a car to the game's pathfinder, which knows the whole map where
-- driving and maneuvers only see what lies around the car:
--  - a guided request (movement.request_guided_path): in a built or dense area the
--    destination is out of the cone ahead of the car. At most one per
--    config.medium_delay, config.path_trigger.max_requests per leg. When the
--    destination is far, the goal is a point of low density in its direction.
--  - a failure request: the last maneuver attempt failed, or the leg lasts too
--    long. At most config.path.max_requests per leg; when one finds nothing the car
--    goes back to driving and maneuvering; once they are used up it clears its way
--    if it can (see "Clearing"), and is stuck otherwise.
-- The request is asynchronous (see movement.on_path_finished); the car waits,
-- braked, in a maneuver. The path is then followed waypoint by waypoint with the
-- usual driving (drive_tick steers toward the next waypoint, maneuvers included),
-- and ends where the car drives to its destination as before.

-- The box sent to the pathfinder is the car's, larger by config.path.margin so
-- that the path keeps off the walls.
local function send_path_request(car, car_data)
	local path = car_data.path
	local half_width, half_length = config.car_size.width / 2 + config.path.margin, config.car_size.length / 2 + config.path.margin
	local id = car.surface.request_path{
		bounding_box = {{-half_width, -half_length}, {half_width, half_length}},
		collision_mask = car.prototype.collision_mask,
		start = car.position,
		goal = path.goal,
		force = car.force,
		radius = config.arrival_distance / 2,
		can_open_gates = true,
		entity_to_ignore = car,
		pathfind_flags = {cache = false, low_priority = true, prefer_straight_paths = true},
	}
	path.request = id
	path.retry_tick = nil
	storage.path_requests[id] = car.unit_number
end

-- Where a path goes (failure or guided request, config.path.goal): the destination,
-- or when it is further than `range` a point at that distance, in the direction of
-- the destination or close to it, where the car fits and the density is lowest (a
-- turn away from the destination costs `angle_cost` per sector).
local function choose_path_goal(car, car_data)
	local destination_position = car_data.moving.destination.position
	local goal = config.path.goal
	local range = goal.range
	if util.distance(car.position, destination_position) <= range then
		return destination_position
	end
	local bearing = compute_orientation_to(car, destination_position)
	local best, best_cost
	for step = -goal.sectors, goal.sectors do
		local orientation = bearing + step * goal.step
		local vx, vy = compute_heading_vector(orientation)
		local x, y = car.position.x + vx * range, car.position.y + vy * range
		if fits_at(car, x, y, orientation) then
			local cost = measure_obstacle_density(car, x, y) + math.abs(step) * goal.angle_cost
			if not best or cost < best_cost then
				best, best_cost = {x = x, y = y}, cost
			end
		end
	end
	return best or destination_position
end

-- Sends a request and starts waiting for the path. False when this leg has used
-- its requests up (`guided`: those of request_guided_path, else the failure requests).
local function start_path_request(car, car_data, tick, guided)
	local path = car_data.path
	if guided then
		if path.guided_count >= config.path_trigger.max_requests then
			return false
		end
		path.guided_count = path.guided_count + 1
	else
		if path.count >= config.path.max_requests then
			return false
		end
		path.count = path.count + 1
	end
	path.guided = guided
	path.pending = true
	path.result = nil
	path.requested_tick = tick
	path.next_tick = tick + config.medium_delay
	path.goal = choose_path_goal(car, car_data)
	send_path_request(car, car_data)
	return true
end

-- A leg that lasts too long: asks for a path outside a maneuver, the car holds in
-- a maneuver until the answer (see wait_for_path). Once this leg has used its
-- failure requests up the car clears its way if it can (false if not); true also
-- while it waits for the next request.
function movement.request_path(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local path = car_data.path
	if path.count >= config.path.max_requests then
		return start_clearing(car, car_data, car_data.maneuver, tick) -- last resort
	end
	if tick < path.next_tick then
		return true
	end
	if not car_data.maneuver.active then
		movement.start_maneuver(car, tick)
	end
	return start_path_request(car, car_data, tick, false)
end

-- Asks for a path because the destination is out of the cone ahead (see
-- update_mode). False when this leg has used its guided requests up.
function movement.request_guided_path(car, tick)
	local car_data = storage.car_data[car.unit_number]
	if car_data.path.guided_count >= config.path_trigger.max_requests then
		return false
	end
	movement.start_maneuver(car, tick)
	return start_path_request(car, car_data, tick, true)
end

-- A gate is crossed along the axis perpendicular to its wall. The wall runs where
-- the walls and gates beside it are (a gate built by the player does not always
-- have the direction a scripted one has in the same wall). Alone, the gate falls
-- back on its direction: facing east or west it is in a wall that runs
-- north-south, so it is crossed along x.
local function measure_gate_axis(gate)
	local along_x, along_y = 0, 0
	for _, neighbour in pairs(gate.surface.find_entities_filtered{
		position = gate.position, radius = 1.2, type = {"wall", "gate"}, force = gate.force,
	}) do
		if neighbour ~= gate then
			local dx, dy = math.abs(neighbour.position.x - gate.position.x), math.abs(neighbour.position.y - gate.position.y)
			if dx > 0.5 and dy < 0.5 then
				along_x = along_x + 1
			elseif dy > 0.5 and dx < 0.5 then
				along_y = along_y + 1
			end
		end
	end
	if along_x ~= along_y then
		if along_x > along_y then
			return 0, 1 -- the wall runs east-west: crossed along y
		end
		return 1, 0
	end
	if gate.direction == defines.direction.east or gate.direction == defines.direction.west then
		return 1, 0
	end
	return 0, 1
end

-- A path of the game hugs the walls and turns right in front of a gate, which a
-- car cannot follow: it drives by the gate. Where the path goes through a gate
-- (an opening of several gates side by side is one) it is reshaped, see
-- config.gate_waypoints: the points that run along the wall are pushed away from
-- it, the farther the nearer they are to the gate (a ramp), so that the car comes
-- at the gate from out in the open and has its heading by then; then a point
-- `near` tiles before the gate on its axis, the gate itself (passed only once the
-- car is through, see advance_path) and a point `exit` tiles after it. Returns the
-- list of the game's waypoints with these in place.
local function add_gate_waypoints(car, raw)
	local surface, force = car.surface, car.force
	local setting = config.gate_waypoints
	local result, count = {}, #raw
	local index = 1
	while index <= count do
		local p = raw[index].position
		local gate = surface.find_entities_filtered{position = p, radius = 1.2, type = "gate", force = force, limit = 1}[1]
		local crossed = false
		if gate then
			local ax, ay = measure_gate_axis(gate)
			local before, after = raw[math.max(1, index - 4)].position, raw[math.min(count, index + 4)].position
			local gx, gy = gate.position.x, gate.position.y
			local side_before = (before.x - gx) * ax + (before.y - gy) * ay
			local side_after = (after.x - gx) * ax + (after.y - gy) * ay
			if side_before * side_after < 0 then
				crossed = true
				-- the centre of the opening: the gates beside this one in the same wall
				local sum_x, sum_y, number = 0, 0, 0
				for _, other in pairs(surface.find_entities_filtered{position = gate.position, radius = 5, type = "gate", force = force}) do
					if math.abs((other.position.x - gx) * ax + (other.position.y - gy) * ay) < 0.1 then
						sum_x, sum_y, number = sum_x + other.position.x, sum_y + other.position.y, number + 1
					end
				end
				local cx, cy = sum_x / number, sum_y / number
				local sign = side_after > side_before and 1 or -1
				ax, ay = ax * sign, ay * sign
				local orientation = compute_orientation_of(ax, ay)

				-- Points before the gate: those right in front of it are dropped (the near
				-- point takes their place); the others are pushed out where there is room,
				-- and dropped when they are closer than `near` to the wall and cannot be.
				local kept = #result
				while kept > 0 do
					local q = result[kept].position
					local dx, dy = q.x - cx, q.y - cy
					local along, across = dx * ax + dy * ay, -dx * ay + dy * ax
					if math.abs(across) > setting.ramp or along > 0 then
						break
					end
					local close = along > -setting.near - 0.5
					if close and math.abs(across) < setting.near + 0.5 then
						table.remove(result, kept)
					else
						local wanted = setting.clear * (1 - math.abs(across) / setting.ramp)
						local x, y = cx + across * -ay - ax * wanted, cy + across * ax - ay * wanted
						if -along < wanted and fits_at(car, x, y, orientation) then
							result[kept] = {position = {x = x, y = y}, keep = true}
						elseif close then
							table.remove(result, kept)
						end
					end
					kept = kept - 1
				end
				result[#result + 1] = {position = {x = cx - ax * setting.near, y = cy - ay * setting.near}, keep = true, reach = 1.5}
				result[#result + 1] = {position = {x = cx, y = cy}, keep = true, axis_x = ax, axis_y = ay}
				result[#result + 1] = {position = {x = cx + ax * setting.exit, y = cy + ay * setting.exit}, keep = true}
				index = index + 1 -- at least the point that found the gate, whatever the distances
				while index <= count and util.distance(raw[index].position, {x = cx, y = cy}) < setting.exit + 1 do
					index = index + 1
				end
			end
		end
		if not crossed then
			result[#result + 1] = raw[index]
			index = index + 1
		end
	end
	return result
end

-- Keeps the corners and a point every config.lookahead.length tiles: the path of
-- the game has a waypoint per tile. The points of add_gate_waypoints are kept.
local function simplify_path(raw)
	local points, last_kept = {}, nil
	for index, waypoint in ipairs(raw) do
		local p = waypoint.position
		local keep = index == #raw or waypoint.keep
		if not keep and index > 1 then
			local previous, following = raw[index - 1].position, raw[index + 1].position
			keep = math.abs((p.x - previous.x) - (following.x - p.x)) > 0.01
				or math.abs((p.y - previous.y) - (following.y - p.y)) > 0.01
		end
		if not keep and last_kept and util.distance(p, last_kept) >= config.lookahead.length then
			keep = true
		end
		if keep then
			table.insert(points, {x = p.x, y = p.y, axis_x = waypoint.axis_x, axis_y = waypoint.axis_y, reach = waypoint.reach})
			last_kept = p
		end
	end
	return points
end

-- on_script_path_request_finished: stores the answer for the waiting car, which
-- acts on it at its next maneuver_tick.
function movement.on_path_finished(event)
	local unit_number = storage.path_requests[event.id]
	if not unit_number then
		return
	end
	storage.path_requests[event.id] = nil
	local car, car_data = storage.cars[unit_number], storage.car_data[unit_number]
	if not (car and car.valid and car_data) then
		return
	end
	local path = car_data.path
	if not path.pending or path.request ~= event.id then
		return -- the leg changed meanwhile
	end
	if event.try_again_later then
		path.retry_tick = event.tick + config.short_delay
	elseif event.path and #event.path > 1 then
		path.found = simplify_path(add_gate_waypoints(car, event.path)) -- adopted by wait_for_path: the car may still follow an older path
		path.result = "found"
	else
		path.result = "none"
	end
end

-- A maneuver failed: the car asks for a path, or clears its way once its failure
-- requests are used up. Returns true when neither is possible: it is stuck.
local function fail_maneuver(car, car_data, maneuver, tick)
	if start_path_request(car, car_data, tick, false) then
		return false
	end
	if start_clearing(car, car_data, maneuver, tick) then
		return false
	end
	end_maneuver(car, maneuver, tick)
	-- Wedged for good only if no path showed a way out on this leg.
	return true
end

-- The car is waiting for its path: braked, until the answer comes (returns false).
-- When none will come it goes back to driving (returns false), unless it has used
-- up its failure requests: then it fails as a maneuver does (see fail_maneuver).
local function wait_for_path(car, car_data, maneuver, tick)
	local path = car_data.path
	car.riding_state = {acceleration = riding.acceleration.braking, direction = riding.direction.straight}

	if path.retry_tick and tick >= path.retry_tick then
		send_path_request(car, car_data)
	end
	if path.result == "found" then
		path.pending = false
		path.active = true
		path.waypoints = path.found
		path.index = 1
		path.u_turn, path.u_turn_done = nil, nil
		path.origin = {x = car.position.x, y = car.position.y}
		end_maneuver(car, maneuver, tick)

		-- The stuck detection judges the leg by its length: it is the path's now.
		local length, from = 0, car.position
		for _, waypoint in ipairs(path.waypoints) do
			length = length + util.distance(from, waypoint)
			from = waypoint
		end
		local moving = car_data.moving
		moving.departure_tick = tick
		moving.departure_distance = length + util.distance(from, moving.destination.position)
		return false
	end
	if path.result == "none" or tick - path.requested_tick > config.long_delay then
		path.pending = false
		if not path.guided and path.count >= config.path.max_requests then
			return fail_maneuver(car, car_data, maneuver, tick) -- no request left: clears its way, or is stuck
		end
		end_maneuver(car, maneuver, tick)
		return false
	end
	return false
end

-- Drives a car that is in a maneuver, at the slow speed that update_mode's
-- friction gives. It first picks a heading (see choose_heading) and keeps it
-- for config.short_delay; every config.short_delay it checks whether
-- the maneuver is done, then picks the arc that brings the car closer to that
-- heading (see choose_arc), forwards or backwards. The steering is only ever
-- set through riding_state, never the orientation. It does not aim for the
-- destination: that is drive_tick's job, once the maneuver ends.
--
-- A car that drives but does not move for config.short_delay has an obstacle
-- it cannot see, or a wall that stops it from turning (see back_off): it goes
-- the other way, straight, and follows that direction until a turn works. Its
-- arcs keep to that direction meanwhile. When the car is
-- blocked both ways at the same spot the maneuver fails at once.
--
-- A maneuver gets one try, of at most config.idle_delay. When it fails (time out,
-- or a car wedged between walls) the car asks for a path (see "Path"); a path that
-- finds nothing sends it back to driving and maneuvering. Once the failure
-- requests of the leg are used up the car clears its way if it can (see
-- "Clearing"); otherwise maneuver_tick returns true and the car is stuck (see
-- travel.start_stuck). It also drives a clearing, and holds the car while it waits
-- for a path.

function movement.maneuver_tick(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local maneuver = car_data.maneuver

	if car_data.path.pending then
		return wait_for_path(car, car_data, maneuver, tick)
	end
	if maneuver.clearing then
		return clearing_tick(car, car_data, maneuver, tick)
	end

	-- Drive straight along the wall for a car length (or config.short_delay). A car
	-- that did not move is blocked this way as well.
	if maneuver.back_off_until then
		local moved = util.distance(car.position, maneuver.back_off_from)
		if tick < maneuver.back_off_until and moved < config.car_size.length then
			return false
		end
		maneuver.back_off_until = nil
		if moved < PROBE_STEP then
			if back_off(car, maneuver, tick) then
				return fail_maneuver(car, car_data, maneuver, tick) -- both directions blocked
			end
			return false
		end
		maneuver.heading = nil -- looks around again from where the car is now
		maneuver.arc_since = nil
	end

	-- Once the car has turned by an arc's worth while following a wall, the wall
	-- is behind it: it goes back to choosing freely.
	if maneuver.follow ~= nil
		and math.abs(compute_angle_between(maneuver.follow_orientation, car.orientation)) >= config.lookahead.angle then
		maneuver.follow = nil
		maneuver.blocked = {}
	end

	if maneuver.arc_since then
		if math.abs(car.speed) < config.speed.stopped then
			maneuver.stall_since = maneuver.stall_since or tick
			if tick - maneuver.stall_since >= config.short_delay then
				if back_off(car, maneuver, tick) then
					return fail_maneuver(car, car_data, maneuver, tick) -- both directions blocked
				end
				return false
			end
		else
			maneuver.stall_since = nil
		end
		if tick - maneuver.arc_since < config.short_delay then
			return false -- the arc goes on
		end
	end

	if is_maneuver_done(car, car_data) then
		end_maneuver(car, maneuver, tick)
		return false
	end

	if tick - maneuver.since > config.idle_delay then
		return fail_maneuver(car, car_data, maneuver, tick)
	end

	if not maneuver.heading or tick - maneuver.heading_since >= config.short_delay then
		maneuver.heading = choose_heading(car, car_data)
		maneuver.heading_since = tick
	end
	local arc = choose_arc(car, maneuver)
	maneuver.arc_since = tick
	maneuver.arcs = maneuver.arcs + 1
	maneuver.reverse = arc.reverse
	maneuver.turn = arc.turn

	local direction = riding.direction.straight
	if arc.turn < 0 then
		direction = riding.direction.left
	elseif arc.turn > 0 then
		direction = riding.direction.right
	end
	car.riding_state = {
		acceleration = arc.reverse and riding.acceleration.reversing or riding.acceleration.accelerating,
		direction = direction,
	}
	return false
end

return movement
