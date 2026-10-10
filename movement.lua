local util = require("util")
local config = require("config")
local _utils = require("_utils")

-- Driving. Each tick, for a moving car, movement.update_mode picks the driving
-- mode, then movement.drive_tick sets the acceleration and the steering, or
-- movement.maneuver_tick does while a maneuver is under way.
local movement = {}

local pi, sin, cos = math.pi, math.sin, math.cos
local riding = defines.riding

-- Friction of a car in a maneuver (see config.friction_base).
local MANEUVER_FRICTION = config.friction_base * config.friction_maneuver_factor

-- How far around the car the slow measurements look (gates, moving neighbours):
-- the longest look-ahead of drive_tick plus the distance covered while braking
-- from a fast speed.
local SENSOR_REACH = config.lookahead_start + config.lookahead_length + config.lookahead_speed_bonus
	+ config.car_size.length + config.speed.fast * config.braking_duration

-- ============================================================
-- Helpers
-- ============================================================

-- Unit vector of an orientation (0 = north, 0.25 = east, as LuaEntity.orientation).
local function get_heading_vector(orientation)
	return sin(2 * pi * orientation), -cos(2 * pi * orientation)
end

-- Angle from orientation `from` to orientation `to`, in turns, within
-- [-0.5, 0.5): positive when `to` is clockwise (on the right) of `from`.
local function compute_angle_between(from, to)
	return ((to - from + 0.5) % 1) - 0.5
end

-- Orientation of the direction from the car to `target`.
local function compute_orientation_to(car, target)
	local dx, dy = target.x - car.position.x, target.y - car.position.y
	return (math.atan2(dx, -dy) / (2 * pi)) % 1
end

-- Where the car steers: the next waypoint of its path (see request_path), or
-- its destination. Arrival and braking always go by the destination itself.
local function get_target(car_data)
	local path = car_data.path
	if path.active then
		return path.waypoints[path.index]
	end
	return car_data.moving.destination.position
end

-- A waypoint is passed once the car is within two car lengths of it. The path
-- ends with its last waypoint: the car then drives to its destination as usual.
local PATH_REACH = 2 * config.car_size.length

local function advance_path(car, car_data)
	local path = car_data.path
	while path.active and util.distance(car.position, path.waypoints[path.index]) < PATH_REACH do
		path.index = path.index + 1
		if path.index > #path.waypoints then
			path.active = false
		end
	end
end

-- Sides of a heading for measure_wall_margin.
local SIDE_LEFT, SIDE_RIGHT = {-1}, {1}

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

-- Obstacle density, in entities per square tile, in a disc of
-- config.density_radius. A disc centred on the car counts the car itself (see
-- "Obstacle density" in config.lua).
local function measure_obstacle_density(car, x, y)
	local radius = config.density_radius
	local count = car.surface.count_entities_filtered{
		position = {x, y},
		radius = radius,
		collision_mask = car.prototype.collision_mask.layers,
	}
	return count / (pi * radius * radius)
end

-- Obstacle density summed over config.density_lookahead_steps + 1 discs laid end
-- to end from the car along the heading (hx, hy): steering adds it to the cost of
-- a heading, so that the car steers away from crowded areas well before it
-- reaches them.
local function measure_density_ahead(car, x, y, hx, hy)
	local radius = config.density_radius
	local total = 0
	for step = 0, config.density_lookahead_steps do
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
			local hx, hy = get_heading_vector(other.orientation)
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

-- Margin cost of a point: config.steering_cost.margin for each of `sides` (-1 left,
-- 1 right, of the heading `orientation`; nil or empty to skip) where the car would
-- not fit one and a half car widths to that side, i.e. where an obstacle runs
-- along the point at about a car width from its flank. Makes the car keep away
-- from walls when it can. The point must be at least half a car length from the
-- car, or the box would overlap the car itself.
local function measure_wall_margin(car, x, y, orientation, sides)
	local cost = 0
	if sides then
		local hx, hy = get_heading_vector(orientation)
		local offset = config.car_size.width * 1.5
		for _, side in ipairs(sides) do
			if not fits_at(car, x - hy * side * offset, y + hx * side * offset, orientation) then
				cost = cost + config.steering_cost.margin
			end
		end
	end
	return cost
end

-- Steering cost of a sample point: the distance left from there to the target,
-- relative to the car's own, plus config.steering_cost.blocked if the car would
-- not fit there, and again if it lies in front of a moving car, plus the margin
-- cost of `sides` (see measure_wall_margin) for a point where it fits.
local function compute_sample_cost(car, x, y, orientation, target, distance, neighbours, tick, sides)
	local blocked = fits_at(car, x, y, orientation) and 0 or 1
	if is_in_neighbour_zone(neighbours, tick, x, y) then
		blocked = blocked + 1
	end
	return util.distance({x, y}, target) / distance + config.steering_cost.blocked * blocked
		+ (blocked == 0 and measure_wall_margin(car, x, y, orientation, sides) or 0)
end

-- ============================================================
-- Friction
-- ============================================================

-- Friction modifier of the tile under the car, read each time the friction is set.
local function get_tile_friction(car)
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
	car.friction_modifier = mode_friction / get_tile_friction(car) * (braking_factor or 1)
end

-- ============================================================
-- Driving mode
-- ============================================================

-- Picks the driving mode of a moving car for this tick, and sets its flags:
--   high_speed       cruising in an open area
--   emergency_brake  full stop, at the destination or before an obstacle
--   precision_mode   slow driving with a finer look-ahead
-- Must run before movement.drive_tick, which reads emergency_brake and
-- precision_mode in the same tick. It may start a maneuver, in which case
-- maneuver_tick runs instead of drive_tick (see update_car in control.lua). It
-- ends by setting car.friction_modifier, the lever that controls cruising
-- speed, from the mode.
-- TODO: make a car flee from danger (enemy force). See "À faire" in CLAUDE.md.
function movement.update_mode(car, tick)
	local car_data = storage.car_data[car.unit_number]
	open_gates(car, tick)
	advance_path(car, car_data)
	if car_data.maneuver.active then
		set_friction(car, MANEUVER_FRICTION)
		return
	end

	local destination = car_data.moving.destination.position
	local target = get_target(car_data)
	local distance = util.distance(car.position, destination)
	local orientation = car.orientation
	local x, y = car.position.x, car.position.y
	local sx, sy = get_heading_vector(orientation)

	-- Density around the car (weight 2), blended with the density one disc
	-- further ahead (weight 1).
	local density = 1 / 3 * (2 * measure_obstacle_density(car, x, y)
		+ measure_obstacle_density(car, x + sx * 2 * config.density_radius, y + sy * 2 * config.density_radius))

	-- Two thresholds, so the flag does not flicker when the density hovers around one value.
	local was_high_speed = car_data.high_speed
	if distance < car.speed * config.braking_duration or density > config.high_speed_density.leave then
		car_data.high_speed = false
	elseif density < config.high_speed_density.enter then
		car_data.high_speed = true
	end

	-- Leaving high speed, drive_tick brakes down to the speed the car had when it
	-- entered it (see `slowing` in drive_tick): friction alone is too slow.
	if car_data.high_speed and not was_high_speed then
		car_data.entry_speed = car.speed
		car_data.slowing = false
	elseif was_high_speed and not car_data.high_speed then
		car_data.slowing = true
	end

	refresh_neighbours(car, car_data, tick)

	-- Emergency braking ends once the car has stopped, and cannot start again
	-- before config.short_delay: the car gets a moment to move away instead of
	-- being stopped again on the next tick.
	local emergency_brake = car_data.emergency_brake
	local obstacle_ahead = not fits_at(car, x + sx * config.emergency_brake_lookahead,
		y + sy * config.emergency_brake_lookahead, orientation)
	local cooldown_over = not emergency_brake.since or tick - emergency_brake.since > config.short_delay
	if (distance < config.arrival_distance or obstacle_ahead) and not emergency_brake.active and cooldown_over then
		emergency_brake.active = true
		emergency_brake.since = tick
	elseif car.speed < config.speed.stopped and emergency_brake.active then
		emergency_brake.active = false
		emergency_brake.since = tick
	end

	-- Work in progress: precision mode only covers dense areas for now.
	car_data.precision_mode = density > config.dense_area_threshold

	local friction = config.friction_base
	if car_data.precision_mode then
		friction = friction * config.friction_precision_factor
	elseif car_data.high_speed then
		friction = friction * config.friction_high_speed_factor
	end
	set_friction(car, friction, emergency_brake.active and config.friction_emergency_factor or 1)
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

	-- Just left high speed: brake down to the speed the car had when it entered
	-- it, but never below config.speed.slow (a car that entered it from rest
	-- would otherwise brake to a stop).
	if car_data.slowing then
		if car.speed > math.max(car_data.entry_speed or 0, config.speed.slow) then
			acceleration = riding.acceleration.braking
		else
			car_data.slowing = false
		end
	end

	local side_offset = config.lookahead_side_offset
	local lookahead_start = config.lookahead_start
	local lookahead_length = config.lookahead_length
	if car_data.precision_mode then
		side_offset = config.precision_lookahead_side_offset
		lookahead_start = config.precision_lookahead_start
		lookahead_length = config.precision_lookahead_length
	end
	local bonus = 0
	if car.speed > config.speed.fast then
		bonus = config.lookahead_speed_bonus
	end

	local x, y = car.position.x, car.position.y
	local orientation = car.orientation
	local sx, sy = get_heading_vector(orientation)
	local rx, ry = get_heading_vector(orientation + config.lookahead_angle)
	local lx, ly = get_heading_vector(orientation - config.lookahead_angle)

	-- Cost of the straight, right and left headings, from sample points one
	-- tile apart along each of them. Near points weigh more than far ones. The
	-- straight heading is sampled along two lines, one on each side of the car.
	local ax, ay = x + sy * side_offset, y - sx * side_offset
	local bx, by = x - sy * side_offset, y + sx * side_offset
	local neighbours = car_data.neighbours
	local target_distance = math.max(util.distance(car.position, target), 1) -- the steering costs are relative to it

	-- The margin cost (see measure_wall_margin) is only worth its extra checks when
	-- something stands near the samples: one entity within reach is the car itself.
	local reach = lookahead_start + lookahead_length + bonus + config.car_size.width * 1.5
	local near = car.surface.count_entities_filtered{
		position = car.position, radius = reach, collision_mask = car.prototype.collision_mask.layers,
		limit = 2,
	} > 1
	local left_side, right_side = near and SIDE_LEFT, near and SIDE_RIGHT -- the outer side of each heading

	local straight, right, left = 0, 0, 0
	for d = lookahead_start, lookahead_start + (lookahead_length + bonus) do
		local weight = ((lookahead_start + lookahead_length + bonus - (d / 2)) + 1) / (lookahead_length + bonus)
		straight = straight + (weight * compute_sample_cost(car, ax + sx * d, ay + sy * d, orientation, target, target_distance, neighbours, tick, left_side)
			+ weight * compute_sample_cost(car, bx + sx * d, by + sy * d, orientation, target, target_distance, neighbours, tick, right_side)) / 2
		right = right + weight * compute_sample_cost(car, x + rx * d, y + ry * d, orientation + config.lookahead_angle, target, target_distance, neighbours, tick, right_side)
		left = left + weight * compute_sample_cost(car, x + lx * d, y + ly * d, orientation - config.lookahead_angle, target, target_distance, neighbours, tick, left_side)
	end

	-- Add the obstacle density further along each heading.
	local density_weight = config.steering_cost.density
	straight = straight + density_weight * measure_density_ahead(car, x, y, sx, sy)
	right = right + density_weight * measure_density_ahead(car, x, y, rx, ry)
	left = left + density_weight * measure_density_ahead(car, x, y, lx, ly)

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
-- config.maneuver_probe).
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
		and math.abs(compute_angle_between(stall.orientation, car.orientation)) < config.lookahead_angle
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
-- (the start of a "blocked" maneuver, see start_maneuver). It is sent backwards
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
		back_off(car, maneuver, tick, true)
	end
end

-- Free room along a heading, in PROBE_STEP units: how many probes the car fits
-- at before the first one it would not fit at. Two things keep a thin obstacle
-- (a wall is 0.58 tile thick) from slipping through:
--  - the probes start at config.maneuver_probe.start so that the car does not
--    detect itself, which leaves a blind zone next to it: the entities there are
--    looked for apart, with a disc search that skips the car;
--  - the probes are closer to each other than the car is wide.
local function measure_free_room(car, x, y, orientation)
	local vx, vy = get_heading_vector(orientation)
	local surface = car.surface
	local probe = config.maneuver_probe

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
-- density around the point 2 * config.density_radius away along it.
local function score_heading(car, x, y, orientation, preferred)
	local room = measure_free_room(car, x, y, orientation) / (math.floor(config.maneuver_probe.length / PROBE_STEP) + 1)
	local vx, vy = get_heading_vector(orientation)
	local reach = 2 * config.density_radius
	return room - math.abs(compute_angle_between(preferred, orientation)) * ANGLE_PULL
		- config.steering_cost.density * measure_obstacle_density(car, x + vx * reach, y + vy * reach)
end

-- Picks the direction a maneuver turns toward. It starts from the direction of
-- the destination and looks for the roomiest and least dense direction around the
-- car, the one closest to the destination on a tie.
local function choose_heading(car, car_data)
	local x, y = car.position.x, car.position.y
	local preferred = compute_orientation_to(car, get_target(car_data))

	local count = math.floor(1 / config.lookahead_angle + 0.5)
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
	local aligned = math.abs(angle) < config.lookahead_angle / 2 -- half a sector of choose_heading

	-- The arcs open to the car, with the room along each.
	local options = {}
	local straight_free = false
	for index, arc in ipairs(ARCS) do
		-- Following a wall (see back_off), the car keeps to its direction.
		if maneuver.follow == nil or arc.reverse == maneuver.follow then
			-- The orientation turns clockwise with a right turn; in reverse the car moves along the opposite heading.
			local rotation = get_arc_rotation(arc)
			local room = measure_free_room(car, x, y,
				orientation + (arc.reverse and 0.5 or 0) + rotation * config.lookahead_angle)
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
	if measure_obstacle_density(car, x, y) > config.maneuver_exit_density then
		return false
	end

	local sx, sy = get_heading_vector(car.orientation)
	if not fits_at(car, x + sx * config.emergency_brake_lookahead, y + sy * config.emergency_brake_lookahead,
		car.orientation) then
		return false
	end

	return util.distance(car.position, maneuver.origin) >= config.maneuver_min_travel
end

-- Ends the maneuver of a car, successful or not, and brakes.
local function end_maneuver(car, maneuver, tick)
	maneuver.active = false
	maneuver.ended_tick = tick
	car.riding_state = {acceleration = riding.acceleration.braking, direction = riding.direction.straight}
end

-- ============================================================
-- Path (last resort)
-- ============================================================
-- A car whose last maneuver attempt has failed asks the game's pathfinder for a
-- way out, once per leg: the maneuver only sees what lies around the car, the
-- pathfinder knows the whole map. The request is asynchronous (see
-- movement.on_path_finished); the car waits, braked, in its maneuver. The path
-- is then followed waypoint by waypoint with the usual driving (drive_tick steers
-- toward the next waypoint, maneuvers included), and ends where the car drives to
-- its destination as before.

-- The box sent to the pathfinder is the car's, a little larger so that the path
-- keeps off the walls.
local PATH_MARGIN = 0.1

local function send_path_request(car, car_data)
	local path = car_data.path
	local half_width, half_length = config.car_size.width / 2 + PATH_MARGIN, config.car_size.length / 2 + PATH_MARGIN
	local id = car.surface.request_path{
		bounding_box = {{-half_width, -half_length}, {half_width, half_length}},
		collision_mask = car.prototype.collision_mask,
		start = car.position,
		goal = car_data.moving.destination.position,
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

-- Starts waiting for a path. False when this leg has already had one.
local function request_path(car, car_data, tick)
	local path = car_data.path
	if path.tried then
		return false
	end
	path.tried = true
	path.pending = true
	path.result = nil
	path.requested_tick = tick
	send_path_request(car, car_data)
	return true
end

-- Asks for a path outside a maneuver: the car holds in a maneuver until the
-- answer (see wait_for_path). False when this leg has already had its path.
function movement.request_path(car, tick)
	local car_data = storage.car_data[car.unit_number]
	if car_data.path.tried then
		return false
	end
	if not car_data.maneuver.active then
		movement.start_maneuver(car, tick)
	end
	return request_path(car, car_data, tick)
end

-- Keeps the corners and a point every config.lookahead_length tiles: the path of
-- the game has a waypoint per tile.
local function simplify_path(raw)
	local points, last_kept = {}, nil
	for index, waypoint in ipairs(raw) do
		local p = waypoint.position
		local keep = index == #raw
		if not keep and index > 1 then
			local previous, following = raw[index - 1].position, raw[index + 1].position
			keep = math.abs((p.x - previous.x) - (following.x - p.x)) > 0.01
				or math.abs((p.y - previous.y) - (following.y - p.y)) > 0.01
		end
		if not keep and last_kept and util.distance(p, last_kept) >= config.lookahead_length then
			keep = true
		end
		if keep then
			table.insert(points, {x = p.x, y = p.y})
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
		path.waypoints = simplify_path(event.path)
		path.result = "found"
	else
		path.result = "none"
	end
end

-- The car is waiting for its path: braked, until the answer comes (returns false),
-- or until it is clear that none will, which makes the car stuck (returns true).
local function wait_for_path(car, car_data, maneuver, tick)
	local path = car_data.path
	car.riding_state = {acceleration = riding.acceleration.braking, direction = riding.direction.straight}

	if path.retry_tick and tick >= path.retry_tick then
		send_path_request(car, car_data)
	end
	if path.result == "found" then
		path.pending = false
		path.active = true
		path.index = 1
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
		end_maneuver(car, maneuver, tick)
		return true
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
-- A maneuver gets one try, of at most config.long_delay. When it fails (time out,
-- or a car wedged between walls) the car asks for a path, once per leg (see
-- request_path); when that fails too, or has already been tried, maneuver_tick
-- returns true and the car is stuck (see travel.start_stuck).
local function fail_maneuver(car, car_data, maneuver, tick)
	if request_path(car, car_data, tick) then
		return false
	end
	end_maneuver(car, maneuver, tick)
	-- Wedged for good only if no path showed a way out on this leg.
	return true
end

function movement.maneuver_tick(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local maneuver = car_data.maneuver

	if car_data.path.pending then
		return wait_for_path(car, car_data, maneuver, tick)
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
		and math.abs(compute_angle_between(maneuver.follow_orientation, car.orientation)) >= config.lookahead_angle then
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
