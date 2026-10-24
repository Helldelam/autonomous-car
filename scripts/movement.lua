local util = require("util")
local config = require("config")
local _utils = require("scripts._utils")

-- Driving: each tick update_mode picks the mode, then drive_tick (or maneuver_tick) sets
-- acceleration and steering.
local movement = {}

local pi, sin, cos = math.pi, math.sin, math.cos
local riding = defines.riding

-- Of the slow measurements (gates, moving neighbours): longest look-ahead plus braking from fast.
local SENSOR_REACH = config.lookahead.start + config.lookahead.length + config.lookahead.speed_bonus
	+ config.car_size.length + config.speed.fast * config.braking_duration

-- ============================================================
-- Helpers
-- ============================================================

-- Unit vector of an orientation (0 north, 0.25 east).
local function compute_heading_vector(orientation)
	return sin(2 * pi * orientation), -cos(2 * pi * orientation)
end

-- In turns, within [-0.5, 0.5): positive when `to` is clockwise of `from`.
local function compute_angle_between(from, to)
	return ((to - from + 0.5) % 1) - 0.5
end

local function compute_orientation_of(dx, dy)
	return (math.atan2(dx, -dy) / (2 * pi)) % 1
end

local function compute_orientation_to(car, target)
	return compute_orientation_of(target.x - car.position.x, target.y - car.position.y)
end

-- The destination, or the free spot of a retreat from rails.
local function get_goal(car_data)
	return car_data.moving.retreat or car_data.moving.destination
end

local function get_arrival_distance(car_data)
	return car_data.moving.retreat and config.rails.reach or config.arrival_distance
end

-- Where the car steers: the current waypoint, or the goal (arrival and braking go by the goal).
local function get_target(car_data)
	local path = car_data.path
	if path.active then
		return path.waypoints[path.index]
	end
	return get_goal(car_data).position
end

-- A waypoint is passed within two car lengths or its own `reach` (gate approach); the gate waypoint
-- (`axis`) once the car is through. After the last one, slow mode for medium_delay.
local PATH_REACH = 2 * config.car_size.length
local GATE_PASSED = 0.3 -- past the plane of the gate

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
			-- also past its plane, near it (else a car that cannot turn in time circles back)
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

-- Steering left in reverse swings the rear to the left (seen in game): the orientation turns the
-- other way. Read through get_arc_rotation only.
local REVERSE_STEERING_INVERTED = true

-- -1 counter-clockwise, 0, 1 clockwise.
local function get_arc_rotation(arc)
	if arc.reverse and REVERSE_STEERING_INVERTED then
		return -arc.turn
	end
	return arc.turn
end

local MARGIN_OFFSET = config.car_size.width * 1.5 -- each side of a heading (measure_wall_margin)

-- Box turned to the closest of 16 directions (facing north it would overlap a turned car).
local function fits_at(car, x, y, orientation)
	return car.surface.can_place_entity{
		name = car.name, position = {x, y}, direction = math.floor(orientation * 16 + 0.5) % 16,
	}
end

-- A car cannot open gates itself: those of its force within SENSOR_REACH are opened every
-- slow_check_interval, before the look-ahead reaches them.
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

-- Something of the car's force (not a car) within built_zone_distance; nature is neutral.
local BUILT_SCAN_LIMIT = 30 -- cars may fill the answer before a wall
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

-- Per square tile in a disc of density.radius (one on the car counts it).
local function measure_obstacle_density(car, x, y)
	local radius = config.density.radius
	local count = car.surface.count_entities_filtered{
		position = {x, y},
		radius = radius,
		collision_mask = car.prototype.collision_mask.layers,
	}
	return count / (pi * radius * radius)
end

-- Summed over lookahead_steps + 1 discs end to end along (hx, hy), up to `reach` (the target): the
-- car steers away from crowded areas early.
local function measure_density_ahead(car, x, y, hx, hy, reach)
	local radius = config.density.radius
	local total = 0
	for step = 0, config.density.lookahead_steps do
		if step > 0 and 2 * step * radius >= reach then
			break -- beyond the target
		end
		total = total + measure_obstacle_density(car, x + hx * radius * (2 * step + 1), y + hy * radius * (2 * step + 1))
	end
	return total
end

-- Moving cars nearby (position, direction, speed), every slow_check_interval; a stopped car is an
-- ordinary obstacle. Trains could join the list.
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

-- In front of a moving neighbour (moved on since the measure): a car wide, a car long plus its braking.
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

-- steering_cost.margin if the car does not fit MARGIN_OFFSET to `side` (-1 left, 1 right; nil skips):
-- an obstacle about a car width from its flank. The point must be half a car length off the car.
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

-- Followed segment {x, y, ux, uy}, set by drive_tick on a path.
local path_segment

-- Relative distance left to the target, plus blocked (does not fit; in front of a moving car), the
-- wall margin where it fits, and the deviation beyond path.corridor from path_segment.
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

-- The car does not fit somewhere along `orientation`, every tile over `length`.
local function is_line_blocked(car, orientation, length)
	local vx, vy = compute_heading_vector(orientation)
	for d = config.car_size.length, length do
		if not fits_at(car, car.position.x + vx * d, car.position.y + vy * d, orientation) then
			return true
		end
	end
	return false
end

-- Target in the cone ahead (path_trigger.half_angle) and line free over at most path.goal.range.
local function is_way_open(car, orientation, target, distance)
	local bearing = compute_orientation_to(car, target)
	return math.abs(compute_angle_between(orientation, bearing)) <= config.path_trigger.half_angle
		and not is_line_blocked(car, bearing, math.min(distance, config.path.goal.range))
end

-- ============================================================
-- Friction
-- ============================================================

-- With the slow checks (car_data.tile_friction).
local function measure_tile_friction(car, car_data, tick)
	if not car_data.tile_friction or _utils.is_slow_check_due(car, tick) then
		local tile = car.surface.get_tile(math.floor(car.position.x), math.floor(car.position.y))
		local friction = tile.valid and tile.prototype.vehicle_friction_modifier or 1
		car_data.tile_friction = friction > 0 and friction or 1
	end
	return car_data.tile_friction
end

-- From scratch each tick; the mode friction divided by the tile's (same speed everywhere), the
-- emergency factor not (it brakes on any tile).
local function set_friction(car, car_data, tick, mode_friction, braking_factor)
	car.friction_modifier = mode_friction / measure_tile_friction(car, car_data, tick) * (braking_factor or 1)
end

-- ============================================================
-- Driving mode
-- ============================================================

-- car_data.mode: fast (low density, nothing built near, destination beyond braking), slow (built or
-- very dense zone, slow_until), else normal. Emergency braking comes on top. In a zone, a destination
-- out of the cone asks for a guided path. Before drive_tick (same tick); may start a maneuver; ends
-- by setting the friction.
function movement.update_mode(car, tick)
	local car_data = storage.car_data[car.unit_number]
	open_gates(car, tick)
	advance_path(car, car_data, tick)
	if car_data.maneuver.active then
		set_friction(car, car_data, tick, config.friction.maneuver)
		return
	end

	local destination_position = get_goal(car_data).position
	local distance = util.distance(car.position, destination_position)
	local orientation = car.orientation
	local x, y = car.position.x, car.position.y
	local sx, sy = compute_heading_vector(orientation)

	-- slow checks: density (disc on the car × 2, next disc ahead × 1), built things, tile
	if not car_data.density or _utils.is_slow_check_due(car, tick) then
		car_data.density = 1 / 3 * (2 * measure_obstacle_density(car, x, y)
			+ measure_obstacle_density(car, x + sx * 2 * config.density.radius, y + sy * 2 * config.density.radius))
	end
	local density = car_data.density
	if _utils.is_slow_check_due(car, tick) then
		car_data.near_built = measure_built_nearby(car)
		-- way open beside built things (target ahead, far, not a gate, line free): normal mode
		local target = get_target(car_data)
		local target_distance = util.distance(car.position, target)
		car_data.line_clear = car_data.near_built and not target.axis_x
			and target_distance > config.normal_beside_built_distance
			and is_way_open(car, orientation, target, target_distance)
	end
	local in_zone = (car_data.near_built and not car_data.line_clear) or density > config.dense_area_threshold
	car_data.trace_info = storage.game_trace and {density = density, in_zone = in_zone} or nil -- game_trace.lua

	local was_fast = car_data.mode == "fast"
	local mode = "normal"
	if in_zone or tick < (car_data.slow_until or 0) then
		mode = "slow"
	elseif not car_data.near_built and distance >= car.speed * config.braking_duration
		and density < (was_fast and config.fast_density.leave or config.fast_density.enter) then
		mode = "fast"
	end
	car_data.mode = mode

	-- leaving fast, drive_tick brakes to the entry speed (friction alone is too slow)
	if mode == "fast" and not was_fast then
		car_data.entry_speed = car.speed
		car_data.slowing = false
	elseif was_fast and mode ~= "fast" then
		car_data.slowing = true
	end

	refresh_neighbours(car, car_data, tick)

	-- Emergency braking: until stopped, then not again for short_delay (time to move away).
	local emergency_brake = car_data.emergency_brake
	local obstacle_ahead = not fits_at(car, x + sx * config.emergency_brake_lookahead, y + sy * config.emergency_brake_lookahead, orientation)
	local cooldown_over = not emergency_brake.since or tick - emergency_brake.since > config.short_delay
	local allowed = not car_data.path.active -- a path hugs walls and trees: braking there stalls the car
	if (distance < get_arrival_distance(car_data) or obstacle_ahead) and allowed and not emergency_brake.active and cooldown_over then
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

	-- in a zone, destination out of the cone or behind an obstacle: guided path
	local path = car_data.path
	if in_zone and not path.active and distance > config.path_trigger.min_distance and tick >= path.next_tick then
		local way_open = is_way_open(car, orientation, destination_position, distance)
		if car_data.trace_info then
			car_data.trace_info.way_open = way_open
		end
		if not way_open then
			if movement.request_guided_path(car, tick) then
				set_friction(car, car_data, tick, config.friction.maneuver)
				return
			end
		else
			path.next_tick = tick + config.short_delay -- pace of the line check
		end
	end

	set_friction(car, car_data, tick, config.friction[mode], emergency_brake.active and config.friction.emergency or 1)
end

-- ============================================================
-- Rails
-- ============================================================

-- At ground level (the car passes under an elevated rail).
local RAIL_TYPES = {"straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail", "rail-ramp"}

-- Within `half` tiles each side.
local function is_near_rail(surface, position, half)
	return #surface.find_entities_filtered{
		area = {{position.x - half, position.y - half}, {position.x + half, position.y + half}},
		type = RAIL_TYPES, limit = 1,
	} > 0
end

-- Arrived with a rail within rails.scan: drives to the free spot (no rail within rails.clearance)
-- closest to the destination, then to the car, and arrives there (moving.retreat, rails.reach). No
-- path request (rails do not stop a car). Once per leg; true if started.
local function start_retreat(car, car_data, tick)
	local surface = car.surface
	if not is_near_rail(surface, car.position, config.rails.scan / 2) then
		return false
	end

	local moving = car_data.moving
	local destination = moving.destination.position
	local direction = math.floor(car.orientation * 16 + 0.5) % 16
	for radius = 0, config.rails.search_radius do
		local best, best_distance
		for step = 0, radius == 0 and 0 or 15 do
			local angle = step / 16 * 2 * pi
			local position = {x = destination.x + sin(angle) * radius, y = destination.y - cos(angle) * radius}
			local distance = util.distance(position, car.position)
			if (not best_distance or distance < best_distance)
				and surface.can_place_entity{name = car.name, position = position, direction = direction}
				and not is_near_rail(surface, position, config.rails.clearance) then
				best, best_distance = position, distance
			end
		end
		if best then
			moving.retreat = {position = best, valid = true}
			-- new stretch: no path, standing still is not blocked, leg judged from here
			car_data.path.active = false
			car_data.path.waypoints = nil
			car_data.maneuver.ended_tick = tick
			moving.departure_tick = tick
			moving.departure_distance = best_distance
			return true
		end
	end
	return false
end

-- ============================================================
-- Driving
-- ============================================================

local function arrive(car, car_data)
	car_data.moving.retreat = nil
	_utils.raise_next_task(car)
end

-- Acceleration and steering; the next-task event once stopped at the (rail-free) goal.
function movement.drive_tick(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local moving = car_data.moving
	local distance = util.distance(car.position, get_goal(car_data).position)
	local arrived = car.speed < config.speed.stopped and distance < get_arrival_distance(car_data)
	if arrived and not moving.retreat and not moving.rails_checked then
		moving.rails_checked = true
		if start_retreat(car, car_data, tick) then
			distance = util.distance(car.position, moving.retreat.position)
			arrived = false
		end
	end
	local target = get_target(car_data)

	if car_data.emergency_brake.active then
		-- friction alone does not stop it
		car.riding_state = {acceleration = riding.acceleration.braking, direction = car.riding_state.direction}
		if arrived then
			arrive(car, car_data)
		end
		return
	end

	-- stopped dead short of it, short_delay after the leg start or the last maneuver: it hit something
	if car.speed == 0 and distance >= get_arrival_distance(car_data)
		and tick - car_data.maneuver.ended_tick > config.short_delay then
		movement.start_maneuver(car, tick, true) -- takes over from the next tick
		return
	end

	local acceleration = riding.acceleration.accelerating
	if distance < car.speed * config.braking_duration
		or arrived then
		acceleration = riding.acceleration.braking
	end

	-- out of fast mode: down to the entry speed, not below speed.slow (from rest it would stop)
	if car_data.slowing then
		if car.speed > math.max(car_data.entry_speed or 0, config.speed.slow) then
			acceleration = riding.acceleration.braking
		else
			car_data.slowing = false
		end
	end

	-- U-turn: waypoint close and off the heading: slow reverse, front toward it, until it is within
	-- lookahead.angle ahead or reached, a stall (short_delay) or idle_delay. One per waypoint; a second
	-- on the path only outside dense areas (in a forest the car backed into trees).
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
				set_friction(car, car_data, tick, config.friction.maneuver)
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

	-- Straight (two lines, one per side), right and left headings; near points weigh more.
	local ax, ay = x + sy * side_offset, y - sx * side_offset
	local bx, by = x - sy * side_offset, y + sx * side_offset
	local neighbours = car_data.neighbours
	local target_distance = math.max(util.distance(car.position, target), 1) -- costs are relative to it

	-- margins only with something near the samples (one entity is the car itself)
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

	local density_weight = config.steering_cost.density
	if path.active then
		density_weight = density_weight * config.path.density_factor
	end
	local straight_density = density_weight * measure_density_ahead(car, x, y, sx, sy, target_distance)
	local right_density = density_weight * measure_density_ahead(car, x, y, rx, ry, target_distance)
	local left_density = density_weight * measure_density_ahead(car, x, y, lx, ly, target_distance)
	straight, right, left = straight + straight_density, right + right_density, left + left_density

	-- cheapest; a right-left tie goes left
	local direction = riding.direction.straight
	if right < straight and right < left then
		direction = riding.direction.right
	elseif left < straight and left <= right then
		direction = riding.direction.left
	end

	car.riding_state = {acceleration = acceleration, direction = direction}
	if arrived then
		arrive(car, car_data)
	end
end

-- ============================================================
-- Maneuver
-- ============================================================

-- Forward or backward, left (-1), straight (0) or right (1); each lasts short_delay.
local ARCS = {
	{reverse = false, turn = 0}, {reverse = false, turn = -1}, {reverse = false, turn = 1},
	{reverse = true, turn = 0}, {reverse = true, turn = -1}, {reverse = true, turn = 1},
}

-- Rankings, not tuning: each outweighs everything below it. choose_heading: a probe step of room
-- beats the pull toward the destination (at most 0.5 × ANGLE_PULL). choose_arc: fits, toward the
-- heading, forward, room, order of ARCS.
local ANGLE_PULL = 0.2
local RANK_FITS, RANK_TOWARD_HEADING, RANK_FORWARD = 1000, 100, 10

local PROBE_STEP = config.car_size.length / 2

-- Stalled straight that way (back_off) without moving a car length or turning an arc since.
local function is_blocked(car, maneuver, reverse)
	local stall = maneuver.blocked[reverse]
	return stall ~= nil
		and util.distance(car.position, stall.position) < config.car_size.length
		and math.abs(compute_angle_between(stall.orientation, car.orientation)) < config.lookahead.angle
end

-- The car drives but does not move (unseen obstacle, or a wall that stops it from pivoting): straight
-- the other way, then along the wall (`follow`) until a turn works. A straight stall marks that way
-- blocked; true when both are at the same spot. `assumed`: no stall (standing still on its leg), sent
-- backwards without marking anything.
local function back_off(car, maneuver, tick, assumed)
	local stalled, turn = maneuver.reverse, maneuver.turn
	maneuver.stall_since = nil
	if turn == 0 and not assumed then
		maneuver.blocked[stalled] = {position = car.position, orientation = car.orientation}
	end

	local reverse = not stalled
	if maneuver.follow ~= nil and turn ~= 0 then
		reverse = maneuver.follow -- a turn failed: on along the wall
		-- twice at the same spot and angle (a pocket): the other way
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

local start_clearing -- "Clearing"

-- `backing_off`: stopped dead short of the destination, it backs off first (else it waits for a path).
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

	-- emergency braking is drive_tick's; its cooldown starts now
	car_data.emergency_brake.active = false
	car_data.emergency_brake.since = tick

	if backing_off then
		-- as if driving forward, nothing marked (its emergency braking stops it too); after a
		-- clearing on this leg, a dead stop clears again at once
		if car_data.path.clear_count > 0 and start_clearing(car, car_data, maneuver, tick) then
			return
		end
		back_off(car, maneuver, tick, true)
	end
end

-- Probes the car fits at before the first it does not (PROBE_STEP apart, closer than the car is wide:
-- a wall is 0.58 thick). The blind zone before the first probe is searched apart, skipping the car.
local function measure_free_room(car, x, y, orientation)
	local vx, vy = compute_heading_vector(orientation)
	local surface = car.surface
	local probe = config.maneuver.probe

	-- where the first probe begins
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

-- Free room (0 to 1), minus the pull off `preferred`, minus the density two radii along it.
local function score_heading(car, x, y, orientation, preferred)
	local room = measure_free_room(car, x, y, orientation) / (math.floor(config.maneuver.probe.length / PROBE_STEP) + 1)
	local vx, vy = compute_heading_vector(orientation)
	local reach = 2 * config.density.radius
	return room - math.abs(compute_angle_between(preferred, orientation)) * ANGLE_PULL
		- config.steering_cost.density * measure_obstacle_density(car, x + vx * reach, y + vy * reach)
end

-- Roomiest and least dense sector, the closest to the destination on a tie.
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

-- Toward maneuver.heading, ranked: fits (first probe free), turns toward the heading (straight once
-- aligned), forward, room. Blocked ahead and behind, a turning arc with room counts as fitting.
local function choose_arc(car, maneuver)
	local x, y = car.position.x, car.position.y
	local orientation = car.orientation
	local angle = compute_angle_between(orientation, maneuver.heading)
	local aligned = math.abs(angle) < config.lookahead.angle / 2 -- half a sector

	local options = {}
	local straight_free = false
	for index, arc in ipairs(ARCS) do
		if maneuver.follow == nil or arc.reverse == maneuver.follow then -- along a wall: its direction
			-- in reverse the car moves along the opposite heading
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
			toward = (rotation == 0 and not arc.reverse) and 1 or -1
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

-- Near the goal, or after an arc: low density, front free, min_travel covered.
local function is_maneuver_done(car, car_data)
	local maneuver = car_data.maneuver
	local target = get_goal(car_data).position
	local x, y = car.position.x, car.position.y

	if util.distance(car.position, target) < get_arrival_distance(car_data) then
		return true -- drive_tick lets the car arrive
	end
	if maneuver.arcs == 0 then
		return false
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

-- Success or not; brakes, then slow mode for medium_delay (fewer repeated crashes).
local function end_maneuver(car, maneuver, tick)
	maneuver.active = false
	maneuver.ended_tick = tick
	storage.car_data[car.unit_number].slow_until = tick + config.medium_delay
	car.riding_state = {acceleration = riding.acceleration.braking, direction = riding.direction.straight}
end

-- ============================================================
-- Clearing
-- ============================================================
-- Last resort (in a dense forest the pathfinder finds no way): up to idle_delay or clearing.travel,
-- the car destroys the trees and rocks in its way along the heading crossing the fewest, nothing else.
-- A later dead stop on the leg clears again at once (start_maneuver), up to clearing.max_count.

local CLEARABLE_TYPES = {"tree", "simple-entity"}

local function is_clearable(entity)
	return entity.type == "tree" or (entity.type == "simple-entity"
		and entity.prototype.count_as_rock_for_filtered_deconstruction)
end

-- Discs of `radius` every `step` from `from` to `ahead` along `orientation`: the trees and rocks
-- (set), their count, and whether something else blocks.
local function measure_clearing(car, orientation, from, ahead, step, radius)
	local vx, vy = compute_heading_vector(orientation)
	local layers = car.prototype.collision_mask.layers
	local found, count, blocked = {}, 0, false
	for distance = from, ahead, step do
		local position = {car.position.x + vx * distance, car.position.y + vy * distance}
		-- by type: their collision mask does not stop a car
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

-- Fewest trees and rocks toward the destination; nil when every heading is closed otherwise.
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

-- With a tree or rock within clearing.lookahead and clearings left; false otherwise.
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

-- True when the car cannot go on.
local function clearing_tick(car, car_data, maneuver, tick)
	local clearing = config.clearing
	if util.distance(car.position, get_goal(car_data).position) < get_arrival_distance(car_data)
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
-- Requests: guided (zone, destination out of the cone; path_trigger.max_requests per leg) or rescue
-- (maneuver failed, leg too long; path.max_requests, then clearing or stuck). At most one per
-- medium_delay; asynchronous (on_path_finished), the car waits braked in a maneuver. The waypoints are
-- then followed by the usual driving.

-- Box enlarged by path.margin.
local function send_path_request(car, car_data)
	local path = car_data.path
	local half_width, half_length = config.car_size.width / 2 + config.path.margin, config.car_size.length / 2 + config.path.margin
	local id = car.surface.request_path{
		bounding_box = {{-half_width, -half_length}, {half_width, half_length}},
		collision_mask = car.prototype.collision_mask,
		start = car.position,
		goal = path.goal,
		force = car.force,
		radius = config.path.goal.radius,
		can_open_gates = true,
		entity_to_ignore = car,
		pathfind_flags = {cache = false, low_priority = true, prefer_straight_paths = true},
	}
	path.request = id
	path.retry_tick = nil
	storage.path_requests[id] = car.unit_number
end

-- The destination, or beyond goal.range the least dense point (angle_cost per step off) that far
-- toward it where the car fits.
local function choose_path_goal(car, car_data)
	local destination_position = get_goal(car_data).position
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

-- False when the leg has used its requests (guided or rescue) up.
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

-- Leg too long: a rescue request (the car holds in a maneuver); requests used up, a clearing (false
-- if none); true while the next request waits.
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

-- False when the guided requests are used up.
function movement.request_guided_path(car, tick)
	local car_data = storage.car_data[car.unit_number]
	if car_data.path.guided_count >= config.path_trigger.max_requests then
		return false
	end
	movement.start_maneuver(car, tick)
	return start_path_request(car, car_data, tick, true)
end

-- Crossing axis, across the wall given by the neighbouring walls and gates (a player's gate may face
-- otherwise than a scripted one); alone, by its direction.
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
			return 0, 1 -- wall east-west: along y
		end
		return 1, 0
	end
	if gate.direction == defines.direction.east or gate.direction == defines.direction.west then
		return 1, 0
	end
	return 0, 1
end

-- The game's path hugs the wall and turns right at a gate, which a car cannot follow. At each opening
-- crossed (side-by-side gates are one): points along the wall pushed out (gate_waypoints, a ramp),
-- then a point `near` before it on its axis, the gate (passed once through) and a point `exit` after.
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
				-- centre of the opening
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

				-- points before it: right in front, dropped (the near point replaces them); others
				-- pushed out where they fit, or dropped if closer than `near` to the wall
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
				index = index + 1 -- at least the point that found the gate
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

-- Corners, a point every lookahead.length, and the gate points (the game gives one per tile).
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

-- Stores the answer for the waiting car (wait_for_path).
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
		path.found = simplify_path(add_gate_waypoints(car, event.path)) -- an older path may still be followed
		path.result = "found"
	else
		path.result = "none"
	end
end

-- A rescue path, else a clearing; true when neither: stuck.
local function fail_maneuver(car, car_data, maneuver, tick)
	if start_path_request(car, car_data, tick, false) then
		return false
	end
	if start_clearing(car, car_data, maneuver, tick) then
		return false
	end
	end_maneuver(car, maneuver, tick)
	return true
end

-- Braked until the answer; none: back to driving, or with no request left, fail_maneuver.
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

		-- the leg is judged by the path's length now
		local length, from = 0, car.position
		for _, waypoint in ipairs(path.waypoints) do
			length = length + util.distance(from, waypoint)
			from = waypoint
		end
		local moving = car_data.moving
		moving.departure_tick = tick
		moving.departure_distance = length + util.distance(from, get_goal(car_data).position)
		return false
	end
	if path.result == "none" or tick - path.requested_tick > config.long_delay then
		path.pending = false
		if not path.guided and path.count >= config.path.max_requests then
			return fail_maneuver(car, car_data, maneuver, tick)
		end
		end_maneuver(car, maneuver, tick)
		return false
	end
	return false
end

-- Every short_delay: done?, heading (choose_heading), then an arc toward it (choose_arc). Stalled
-- short_delay: back_off. One try of at most idle_delay, then fail_maneuver; true: stuck. Also drives a
-- clearing and holds the car waiting for a path.
function movement.maneuver_tick(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local maneuver = car_data.maneuver

	if car_data.path.pending then
		return wait_for_path(car, car_data, maneuver, tick)
	end
	if maneuver.clearing then
		return clearing_tick(car, car_data, maneuver, tick)
	end

	-- back-off: straight for a car length or short_delay; no move: blocked this way too
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
		maneuver.heading = nil
		maneuver.arc_since = nil
	end

	-- turned an arc's worth: the wall is behind
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
