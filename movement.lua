local util = require("util")
local config = require("config")
local _utils = require("_utils")

-- Driving. Each tick, for a moving car, movement.update_mode picks the driving
-- mode, then movement.drive sets the acceleration and the steering, or
-- movement.maneuver does while a maneuver is under way.
local movement = {}

local pi, sin, cos = math.pi, math.sin, math.cos
local riding = defines.riding

local STOPPED_SPEED = 0.01 -- below this speed the car counts as stopped
local BRAKING_TICKS = 30 -- the car brakes once its destination is less than this many ticks away at its current speed

-- Assumed, not checked in game yet: whether steering left in reverse turns the
-- car the other way round than steering left going forwards. If it does, set this.
local REVERSE_STEERING_INVERTED = false

-- The six headings of a maneuver: forward or backward, steering left (-1),
-- straight (0) or right (1).
local ARCS = {
	{reverse = false, turn = 0}, {reverse = false, turn = -1}, {reverse = false, turn = 1},
	{reverse = true, turn = 0}, {reverse = true, turn = -1}, {reverse = true, turn = 1},
}

-- Unit vector of an orientation (0 = north, 0.25 = east, as LuaEntity.orientation).
local function heading_vector(orientation)
	return sin(2 * pi * orientation), -cos(2 * pi * orientation)
end

-- Angle from the heading of the car to `target`, in turns, within [-0.5, 0.5):
-- positive when the target is on the right.
local function maneuver_angle(car, target)
	local dx, dy = target.x - car.position.x, target.y - car.position.y
	local target_orientation = (math.atan2(dx, -dy) / (2 * pi)) % 1
	return ((target_orientation - car.orientation + 0.5) % 1) - 0.5
end

-- Obstacle density, in entities per square tile, in a disc of config.density_radius.
local function obstacle_density(car, x, y)
	local radius = config.density_radius
	local count = car.surface.count_entities_filtered{
		position = {x, y},
		radius = radius,
		collision_mask = car.prototype.collision_mask.layers,
	}
	return count / (pi * radius * radius)
end

-- Steering cost of a sample point: the distance left from there to the target,
-- relative to the car's own, plus 3 if the car would not fit there.
local function sample_cost(car, x, y, target, distance)
	local blocked = car.surface.can_place_entity{name = car.name, position = {x, y}} and 0 or 1
	return util.distance({x, y}, target) / distance + 3 * blocked
end

-- Starts a maneuver (see movement.maneuver). `reason` tells when it may end:
--   rear_turn    the target is behind a slow car
--   blocked      the car stopped dead short of its destination
--   no_progress  the car barely moved over config.medium_delay (see travel.stuck_reason)
-- The attempts count is left alone: it is reset by a maneuver that succeeds and
-- at the start of each leg (see travel.begin_leg).
function movement.start_maneuver(car, tick, reason)
	local car_data = storage.car_data[car.unit_number]
	local maneuver = car_data.maneuver
	maneuver.active = true
	maneuver.reason = reason
	maneuver.since = tick
	maneuver.arc_since = nil
	maneuver.arcs = 0
	maneuver.reverse = false
	maneuver.turn = 0
	maneuver.origin = car.position

	-- Emergency braking belongs to drive: it must not hold the car back, and
	-- its cooldown starts now.
	car_data.emergency_brake.active = false
	car_data.emergency_brake.since = tick
end

-- Picks the driving mode of a moving car for this tick, and sets its flags:
--   high_speed       cruising in an open area
--   emergency_brake  full stop, at the destination or before an obstacle
--   precision_mode   slow driving with a finer look-ahead
-- Must run before movement.drive, which reads emergency_brake and
-- precision_mode in the same tick. It may start a maneuver, which then
-- replaces drive (see update_car in control.lua). It ends by setting
-- car.friction_modifier, the lever that controls cruising speed, from the mode.
function movement.update_mode(car, tick)
	local car_data = storage.car_data[car.unit_number]
	if car_data.maneuver.active then
		car.friction_modifier = config.friction_base * config.friction_maneuver_factor
		return
	end

	local target = car_data.moving.destination.position
	local distance = util.distance(car.position, target)
	local orientation = car.orientation
	local x, y = car.position.x, car.position.y
	local sx, sy = heading_vector(orientation)

	-- Density around the car, blended with the density one disc further ahead.
	local density = 1 / 3 * (2 * obstacle_density(car, x, y)
		+ obstacle_density(car, x + sx * 2 * config.density_radius, y + sy * 2 * config.density_radius))

	-- Two thresholds, so the flag does not flicker when the density hovers around one value.
	if distance < car.speed * BRAKING_TICKS or density > 0.05 then
		car_data.high_speed = false
	elseif density < 0.03 then
		car_data.high_speed = true
	end

	-- Emergency braking ends once the car has stopped, and cannot start again
	-- before config.short_delay: the car gets a moment to move away instead of
	-- being stopped again on the next tick.
	local emergency_brake = car_data.emergency_brake
	local obstacle_ahead = not car.surface.can_place_entity{
		name = car.name,
		position = {x + sx * config.emergency_brake_lookahead, y + sy * config.emergency_brake_lookahead},
	}
	local cooldown_over = not emergency_brake.since or tick - emergency_brake.since > config.short_delay
	if (distance < config.arrival_distance or obstacle_ahead) and not emergency_brake.active and cooldown_over then
		emergency_brake.active = true
		emergency_brake.since = tick
	elseif car.speed < STOPPED_SPEED and emergency_brake.active then
		emergency_brake.active = false
		emergency_brake.since = tick
	end

	local angle = maneuver_angle(car, target)

	-- The target is behind a slow car: turn around with a maneuver. Not near the
	-- destination, where the car stops instead.
	if math.abs(angle) > config.rear_turn_min_angle and car.speed <= config.rear_turn_max_speed
		and distance >= config.arrival_distance and not emergency_brake.active then
		movement.start_maneuver(car, tick, "rear_turn")
		car.friction_modifier = config.friction_base * config.friction_maneuver_factor
		return
	end

	-- Work in progress: precision mode only covers dense areas for now.
	car_data.precision_mode = density > config.dense_area_threshold

	local friction = config.friction_base
	if car_data.precision_mode then
		friction = friction * config.friction_precision_factor
	elseif car_data.high_speed then
		friction = friction * config.friction_high_speed_factor
	end
	if emergency_brake.active then
		friction = friction * config.friction_emergency_factor
	end
	car.friction_modifier = friction
end

-- Sets the acceleration and the steering of a moving car for this tick, and
-- raises the next-task event once it has stopped at its destination.
function movement.drive(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local target = car_data.moving.destination.position
	local distance = util.distance(car.position, target)
	local arrived = car.speed < STOPPED_SPEED and distance < config.arrival_distance

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
		movement.start_maneuver(car, tick, "blocked") -- takes over from the next tick
		return
	end

	-- Brake when close enough to stop at the destination, or when already slow within arrival distance.
	local acceleration = riding.acceleration.accelerating
	if distance < car.speed * BRAKING_TICKS or (car.speed < 0.1 and distance < config.arrival_distance) then
		acceleration = riding.acceleration.braking
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
	if car.speed > 0.25 then
		bonus = config.lookahead_speed_bonus
	end

	local x, y = car.position.x, car.position.y
	local orientation = car.orientation
	local sx, sy = heading_vector(orientation)
	local rx, ry = heading_vector(orientation + config.lookahead_angle)
	local lx, ly = heading_vector(orientation - config.lookahead_angle)

	-- Cost of the straight, right and left headings, from sample points one
	-- tile apart along each of them. Near points weigh more than far ones. The
	-- straight heading is sampled along two lines, one on each side of the car.
	local ax, ay = x + sy * side_offset, y - sx * side_offset
	local bx, by = x - sy * side_offset, y + sx * side_offset
	local straight, right, left = 0, 0, 0
	for d = lookahead_start, lookahead_start + (lookahead_length + bonus) do
		local weight = ((lookahead_start + lookahead_length + bonus - (d / 2)) + 1) / 4
		straight = straight + (weight * sample_cost(car, ax + sx * d, ay + sy * d, target, distance)
			+ weight * sample_cost(car, bx + sx * d, by + sy * d, target, distance)) / 2
		right = right + weight * sample_cost(car, x + rx * d, y + ry * d, target, distance)
		left = left + weight * sample_cost(car, x + lx * d, y + ly * d, target, distance)
	end

	-- Add the obstacle density further along each heading, so the car steers
	-- away from crowded areas well before it reaches them.
	local radius = config.density_radius
	local straight_density, right_density, left_density = 0, 0, 0
	for step = 0, config.density_lookahead_steps do
		straight_density = straight_density + obstacle_density(car, x + sx * radius * (2 * step + 1), y + sy * radius * (2 * step + 1))
		right_density = right_density + obstacle_density(car, x + rx * radius * (2 * step + 1), y + ry * radius * (2 * step + 1))
		left_density = left_density + obstacle_density(car, x + lx * radius * (2 * step + 1), y + ly * radius * (2 * step + 1))
	end
	straight = straight + 1.5 * straight_density
	right = right + 1.5 * right_density
	left = left + 1.5 * left_density

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

-- Free room along a heading, in PROBE_STEP units: how many probe points the car
-- fits at before the first one it would not fit at. Two things keep a thin
-- obstacle (a wall is 0.58 tile thick) from slipping through:
--  - the probes start at config.maneuver_probe_start so that the car does not
--    detect itself, which leaves a blind zone next to it: the entities there are
--    looked for apart, with an area search that skips the car;
--  - the probes are closer than the width of the car.
local PROBE_STEP = 0.5
local function free_room(car, x, y, orientation)
	local vx, vy = heading_vector(orientation)
	local surface = car.surface

	local near = config.maneuver_probe_start - 0.5
	for _, entity in pairs(surface.find_entities_filtered{
		position = {x + vx * near, y + vy * near},
		radius = 0.6,
		collision_mask = car.prototype.collision_mask.layers,
	}) do
		if entity ~= car then
			return 0
		end
	end

	local steps = math.floor(config.maneuver_probe_length / PROBE_STEP)
	for step = 0, steps do
		local distance = config.maneuver_probe_start + step * PROBE_STEP
		if not surface.can_place_entity{name = car.name, position = {x + vx * distance, y + vy * distance}} then
			return step
		end
	end
	return steps + 1
end

-- Picks the heading of the next arc: the one with the most free room. On a tie
-- the arc that steers toward a target behind the car comes first, then the
-- current arc (so the car does not flip between two equal headings), then the
-- listing order of ARCS (forward and straight first). `side` is the side of the
-- target: -1 left, 1 right, 0 when the maneuver does not turn toward it.
local function choose_arc(car, maneuver, side)
	local x, y = car.position.x, car.position.y
	local orientation = car.orientation
	local best, best_rank

	for index, arc in ipairs(ARCS) do
		-- Steering is applied to the heading, which in reverse is the opposite of the way the car moves.
		local turn = arc.turn
		if arc.reverse and REVERSE_STEERING_INVERTED then
			turn = -turn
		end
		local line = orientation + (arc.reverse and 0.5 or 0) + turn * config.lookahead_angle

		local rank = free_room(car, x, y, line) * 100 - index
		if arc.turn ~= 0 and arc.turn == side then
			rank = rank + 20
		end
		if arc.reverse == maneuver.reverse and arc.turn == maneuver.turn and maneuver.arcs > 0 then
			rank = rank + 10
		end
		if not best or rank > best_rank then
			best, best_rank = arc, rank
		end
	end
	return best
end

-- True when the car is out of the situation that called for the maneuver.
local function maneuver_done(car, car_data)
	local maneuver = car_data.maneuver
	local target = car_data.moving.destination.position
	local x, y = car.position.x, car.position.y

	if util.distance(car.position, target) < config.arrival_distance then
		return true -- drive lets the car arrive
	end
	if maneuver.arcs == 0 then
		return false -- at least one arc: the situation is not judged from where the car stood still
	end
	if obstacle_density(car, x, y) > config.maneuver_exit_density then
		return false
	end

	local sx, sy = heading_vector(car.orientation)
	if not car.surface.can_place_entity{
		name = car.name,
		position = {x + sx * config.emergency_brake_lookahead, y + sy * config.emergency_brake_lookahead},
	} then
		return false
	end

	if maneuver.reason == "rear_turn" then
		return math.abs(maneuver_angle(car, target)) < config.maneuver_exit_angle
	end
	return util.distance(car.position, maneuver.origin) >= config.maneuver_min_travel
end

-- Drives a car that is in a maneuver. Every config.maneuver_arc_duration it checks
-- whether the maneuver is done, then picks the roomiest of the six headings and
-- steers along it, forwards or backwards, at the slow speed that
-- update_mode's friction gives. The steering is only ever set through
-- riding_state, never the orientation. It does not aim for the destination: that
-- is drive's job, once the maneuver ends.
--
-- A maneuver that lasts longer than config.maneuver_duration has failed: a new
-- one starts, until config.max_maneuver_attempts. Returns true when the last
-- attempt failed, which makes the car stuck (see travel.handle_stuck).
function movement.maneuver(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local maneuver = car_data.maneuver

	if maneuver.arc_since and tick - maneuver.arc_since < config.maneuver_arc_duration then
		return false -- the arc goes on
	end

	if maneuver_done(car, car_data) then
		maneuver.active = false
		maneuver.attempts = 0
		maneuver.ended_tick = tick
		car.riding_state = {acceleration = riding.acceleration.braking, direction = riding.direction.straight}
		return false
	end

	if tick - maneuver.since > config.maneuver_duration then
		maneuver.active = false
		maneuver.attempts = maneuver.attempts + 1
		maneuver.ended_tick = tick
		car.riding_state = {acceleration = riding.acceleration.braking, direction = riding.direction.straight}
		if maneuver.attempts >= config.max_maneuver_attempts then
			return true
		end
		movement.start_maneuver(car, tick, maneuver.reason)
		return false
	end

	local side = 0
	if maneuver.reason == "rear_turn" then
		side = maneuver_angle(car, car_data.moving.destination.position) >= 0 and 1 or -1
	end
	local arc = choose_arc(car, maneuver, side)
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
