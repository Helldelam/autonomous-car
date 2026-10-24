local util = require("util")
local config = require("config")
local _utils = require("scripts._utils")
local charger_control = require("scripts.charger")

-- Trips: legs, charging detours, fleeing, unreachable goals, stuck legs, empty battery.
local travel = {}

-- ============================================================
-- Legs
-- ============================================================

-- Brakes while the car rolls, then lets go.
function travel.stop_car(car)
	local acceleration = defines.riding.acceleration.nothing
	if car.speed > config.speed.stopped then
		acceleration = defines.riding.acceleration.braking
	end
	car.riding_state = {acceleration = acceleration, direction = defines.riding.direction.straight}
end

-- Of the leg under way or waiting out a stuck state.
local function get_leg_destination(car_data)
	if car_data.moving.active then
		return car_data.moving.destination
	elseif car_data.stuck.active then
		return car_data.stuck.destination
	end
	return nil
end

local function is_heading_to_charger(car_data)
	local destination = get_leg_destination(car_data)
	return destination and destination.valid and destination.name == config.names.charger
end

-- Frees the charger place held on the way or while charging (charging stops); safe without one.
function travel.release_charger_slot(car_data)
	local charger
	if car_data.charging.active then
		charger = car_data.charging.charger
		car_data.charging.active = false
		car_data.charging.charger = nil
	elseif is_heading_to_charger(car_data) then
		charger = get_leg_destination(car_data)
	end
	local charger_data = charger and charger.valid and storage.charger_data[charger.unit_number]
	if charger_data and charger_data.users > 0 then
		charger_data.users = charger_data.users - 1
	end
end

-- Per leg (movement.lua, "Path"): count, guided_count, clear_count of this leg; next_tick: no request
-- before it; pending: waiting for the answer; active: following `waypoints`.
function travel.create_path_state()
	return {active = false, pending = false, count = 0, guided_count = 0, clear_count = 0, next_tick = 0}
end

-- Drops the leg or stuck wait, maneuver, charge, parking, their tasks and charger place; the batch stays.
function travel.cancel_trip(car_data)
	travel.release_charger_slot(car_data)
	car_data.parking.active = false
	car_data.parking.garage = nil
	car_data.parking.door_tick = nil
	car_data.building.active = false
	car_data.maneuver.active = false
	car_data.path = travel.create_path_state()
	car_data.stuck.active = false
	car_data.stuck.destination = nil
	car_data.moving.active = false
	car_data.moving.destination = nil
	car_data.moving.retreat = nil
	car_data.moving.departure_tick = nil
	car_data.flee.active = false
	_utils.alert_reset(car_data.alerts, "flee")
	car_data.tasks = _utils.deque.new()
end

-- Drives to `destination` (entity or {position, valid}); `next_task` runs on arrival (on_next_task).
-- No fuel check (set_destination). A replaced leg frees its charger place; a retry keeps it.
function travel.begin_leg(car, destination, next_task)
	local car_data = storage.car_data[car.unit_number]
	local moving = car_data.moving

	if moving.active and moving.destination ~= destination then
		travel.release_charger_slot(car_data)
	end
	car_data.building.active = false
	car_data.waiting.active = false -- not available for a batch
	car_data.stuck.active = false
	car_data.stuck.destination = nil
	moving.active = true
	moving.destination = destination
	moving.retreat = nil -- one rail check per leg (movement.start_retreat)
	moving.rails_checked = false
	moving.departure_tick = game.tick -- travel.is_leg_too_long
	moving.departure_distance = util.distance(car.position, destination.position)

	-- no maneuver, and standing still at departure is not blocked (movement.drive_tick)
	car_data.maneuver.active = false
	car_data.maneuver.ended_tick = game.tick
	car_data.path = travel.create_path_state()
	car_data.slowing = false

	-- stuck_retry_count (reset on arrival) and charge_detour_count (on arrival elsewhere than a
	-- charger) are kept: retries and detours are legs too.
	car_data.unreachable_since = nil
	_utils.alert_reset(car_data.alerts, "stuck")
	_utils.alert_reset(car_data.alerts, "stuck_final") -- a dropped final wait never reset it
	_utils.alert_reset(car_data.alerts, "no_charger")
	_utils.alert_reset(car_data.alerts, "unreachable")

	if next_task then
		_utils.deque.push_front(car_data.tasks, next_task)
	end
end

local function go_to_charger(car, charger)
	local charger_data = storage.charger_data[charger.unit_number]
	charger_data.users = charger_data.users + 1
	travel.begin_leg(car, charger, {type = "charging"})
end

-- Leg to `destination` if the fuel covers it and the way on to a charger, else a charging detour
-- (next_task dropped: the car decides again once charged); a full tank short of it: unreachable.
-- False if the car could not set off.
function travel.set_destination(car, destination, next_task)
	if _utils.get_fuel(car) >= charger_control.compute_fuel_needed(car, destination.position) then
		travel.begin_leg(car, destination, next_task)
		return true
	elseif _utils.get_fuel_ratio(car) >= 1 then
		travel.mark_unreachable(car)
		return false
	end
	return travel.detour_to_charger(car, destination.position)
end

-- To the reachable charger closest to `target_position`; false if the car could not set off.
function travel.detour_to_charger(car, target_position)
	local car_data = storage.car_data[car.unit_number]

	car_data.charge_detour_count = car_data.charge_detour_count + 1
	if car_data.charge_detour_count > config.max_charge_detours then
		travel.mark_unreachable(car)
		return false
	end

	local charger = charger_control.find_charger(car, target_position)
	if not charger then
		charger_control.alert_no_charger(car)
		travel.reset_to_waiting(car)
		return false
	end

	go_to_charger(car, charger)
	return true
end

function travel.reset_to_waiting(car)
	local car_data = storage.car_data[car.unit_number]
	travel.cancel_trip(car_data)
	travel.stop_car(car)
	_utils.start_waiting(car_data)
end

-- ============================================================
-- Fleeing
-- ============================================================

-- Closest charger or garage in the half plane away from `enemy`, within flee.max_refuge_distance and
-- reach; else a waypoint that far straight away, whatever the fuel.
function travel.find_refuge(car, enemy)
	local away_x, away_y = car.position.x - enemy.position.x, car.position.y - enemy.position.y
	local fuel = _utils.get_reachable_fuel(car)
	local function is_away(entity)
		return (entity.position.x - car.position.x) * away_x + (entity.position.y - car.position.y) * away_y > 0
			and util.distance(car.position, entity.position) <= config.flee.max_refuge_distance
			and fuel >= charger_control.compute_fuel_to_reach(car, entity.position)
	end
	local charger = _utils.find_closest("chargers", car.position, is_away, "charger", car.surface)
	local garage = _utils.find_closest("garages", car.position, is_away, "garage", car.surface)
	if charger and garage then
		return util.distance(car.position, charger.position) <= util.distance(car.position, garage.position) and charger or garage
	end
	if charger or garage then
		return charger or garage
	end

	local length = math.sqrt(away_x * away_x + away_y * away_y)
	if length == 0 then
		away_x, away_y, length = 1, 0, 1 -- enemy on the car
	end
	local far = {
		x = car.position.x + away_x / length * config.flee.max_refuge_distance,
		y = car.position.y + away_y / length * config.flee.max_refuge_distance,
	}
	return {position = car.surface.find_non_colliding_position(config.names.car, far, config.flee.radius, 1) or far, valid = true}
end

-- Drops the trip (the batch stays) and drives to `refuge`; waits there (on_next_task), then resumes.
function travel.start_flee(car, refuge)
	local car_data = storage.car_data[car.unit_number]
	travel.cancel_trip(car_data)
	car_data.flee.active = true
	car_data.flee.count = car_data.flee.count + 1
	travel.begin_leg(car, refuge, {type = "flee"})
	_utils.alert_once(car_data.alerts, "flee", car.force, car,
		{"autonomous-car-messages.alert-flee"}, config.names.car)
end

-- ============================================================
-- Unreachable goal
-- ============================================================

-- The ghosts of a construction.clusters entry still in the batch go back to the pending pool as a
-- cluster; those that left it earlier may be with another car.
function travel.requeue_cluster(construction, entry)
	local ghosts = {}
	for id in pairs(entry.ghosts) do
		local ghost = construction.ghosts[id]
		if ghost then
			if ghost.valid then
				table.insert(ghosts, ghost)
			end
			construction.ghosts[id] = nil
			construction.failed_attempts[id] = nil
			storage.ghost_to_car[id] = nil
		end
	end
	if #ghosts > 0 then
		table.insert(storage.pending_clusters, {ghosts = ghosts})
	end
end

-- Cluster by cluster (merged, the next car would build them all from its first stop). Here because
-- construction.lua requires this module.
function travel.requeue_construction(car_data)
	local construction = car_data.construction
	if not construction then
		return
	end

	for _, entry in ipairs(construction.clusters) do
		travel.requeue_cluster(construction, entry)
	end
	car_data.construction = nil
end

-- Too many charging detours: alert, waiting; after very_long_delay the batch is abandoned.
function travel.mark_unreachable(car)
	local car_data = storage.car_data[car.unit_number]

	car_data.unreachable_since = car_data.unreachable_since or game.tick
	_utils.alert_once(car_data.alerts, "unreachable", car.force, car,
		{"autonomous-car-messages.alert-unreachable"}, config.names.car)

	if game.tick - car_data.unreachable_since >= config.very_long_delay then
		_utils.alert(car.force, car,
			{"autonomous-car-messages.alert-abandoned-unreachable"}, config.names.car)
		travel.requeue_construction(car_data)
		car_data.unreachable_since = nil
		car_data.charge_detour_count = 0
	end

	travel.reset_to_waiting(car)
end

-- ============================================================
-- Charging trips
-- ============================================================

-- Critical level: the way to the closest charger plus critical_fuel_ratio, kept in car_data. None
-- above critical_check_fuel_ratio; measured every slow_check_interval, or every short_delay while the
-- tank holds over twice the last one. True below it.
local function measure_critical_fuel(car, car_data, tick)
	local fuel = _utils.get_fuel(car)
	if fuel >= config.critical_check_fuel_ratio * _utils.get_fuel_capacity(car) then
		return false
	end
	local reserve = car_data.critical_fuel
	local interval = (reserve and fuel > 2 * reserve) and config.short_delay or config.slow_check_interval
	if not reserve or _utils.is_slow_check_due(car, tick, interval) then
		reserve = charger_control.compute_fuel_reserve(car, car.position)
		car_data.critical_fuel = reserve
	end
	return fuel < reserve
end

-- By the last measure; such a car gets no batch.
function travel.is_fuel_critical(car)
	local reserve = storage.car_data[car.unit_number].critical_fuel
	local fuel = _utils.get_fuel(car)
	return fuel < config.critical_check_fuel_ratio * _utils.get_fuel_capacity(car) and reserve ~= nil and fuel < reserve
end

-- Under the critical level the car drops its trip for a charger; without one it stays and looks
-- again every short_delay. True when it took over the car this tick.
function travel.handle_critical_fuel(car, tick)
	local car_data = storage.car_data[car.unit_number]
	if car_data.charging.active or is_heading_to_charger(car_data) then
		return false
	end

	-- slow checks, every tick while held for a retry
	local retrying = car_data.critical_fuel_retry_tick and tick < car_data.critical_fuel_retry_tick
	if not retrying and not _utils.is_slow_check_due(car, tick) then
		return false
	end

	if not measure_critical_fuel(car, car_data, tick) then
		return false
	end

	if car_data.critical_fuel_retry_tick and tick < car_data.critical_fuel_retry_tick then
		travel.stop_car(car)
		return true
	end

	travel.cancel_trip(car_data)

	local charger = charger_control.find_charger(car)
	if charger then
		go_to_charger(car, charger)
		car_data.critical_fuel_retry_tick = nil
	else
		charger_control.alert_no_charger(car)
		car_data.critical_fuel_retry_tick = tick + config.short_delay
		travel.stop_car(car)
		-- an active state: the level can drop without a charge (a charger built closer)
		_utils.start_waiting(car_data)
	end
	return true
end

-- Below pre_park_fuel_ratio, to the charger closest to `target_position`; true if the car left.
function travel.top_up_before_parking(car, target_position)
	if _utils.get_fuel_ratio(car) >= config.pre_park_fuel_ratio then
		return false
	end

	local charger = charger_control.find_charger(car, target_position)
	if not charger then
		return false
	end

	go_to_charger(car, charger)
	return true
end

-- ============================================================
-- Stuck
-- ============================================================

-- Longer than its length at stuck.min_speed plus long_delay. On a leg only.
function travel.is_leg_too_long(car, tick)
	local moving = storage.car_data[car.unit_number].moving
	local max_duration = moving.departure_distance / config.stuck.min_speed + config.long_delay
	return tick - moving.departure_tick > max_duration
end

-- Stops and alerts; stuck_tick retries the leg while retries and fuel last, else waits longer and
-- abandons. To a charger without batch: retried without limit (a detour of a batch is limited).
function travel.start_stuck(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local moving = car_data.moving
	local stuck = car_data.stuck

	local to_charger = is_heading_to_charger(car_data) and not car_data.construction
	car_data.stuck_retry_count = car_data.stuck_retry_count + 1
	local can_retry = to_charger or (car_data.stuck_retry_count <= config.stuck.max_retries
		and _utils.get_fuel(car) >= charger_control.compute_fuel_to_reach(car, moving.destination.position))

	if can_retry then
		_utils.alert_once(car_data.alerts, "stuck", car.force, car,
			{"autonomous-car-messages.alert-stuck"}, config.names.car)
	else
		_utils.alert_once(car_data.alerts, "stuck_final", car.force, car,
			{"autonomous-car-messages.alert-stuck-final"}, config.names.car)
	end

	stuck.active = true
	stuck.since = tick
	stuck.final = not can_retry
	stuck.destination = moving.destination -- same leg again: its task is still queued

	car_data.building.active = false
	car_data.maneuver.active = false
	moving.active = false
	moving.destination = nil
	moving.retreat = nil
	moving.departure_tick = nil
	travel.stop_car(car)
end

-- Waits, then starts the leg again; true after the final wait: the caller abandons the task.
function travel.stuck_tick(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local stuck = car_data.stuck

	travel.stop_car(car)
	if tick - stuck.since < (stuck.final and config.stuck.abandon_delay or config.long_delay) then
		return false
	end
	if stuck.final then
		travel.release_charger_slot(car_data)
		stuck.active = false
		stuck.destination = nil
		_utils.alert_reset(car_data.alerts, "stuck_final")
		_utils.alert_reset(car_data.alerts, "stuck")
		car_data.stuck_retry_count = 0
		return true
	end

	local destination = stuck.destination
	if destination and destination.valid then
		travel.begin_leg(car, destination) -- task still at the front
	else
		travel.reset_to_waiting(car) -- destination gone meanwhile
	end
	return false
end

-- ============================================================
-- Empty battery
-- ============================================================

-- One battery below battery_trigger_ratio, so that the car reaches a charger; not while the tank fills.
local function burn_battery_if_low(car, car_data)
	if car_data.charging.active or car_data.parking.active then
		return
	end
	local capacity = _utils.get_fuel_capacity(car)
	if _utils.get_fuel(car) < config.battery_trigger_ratio * capacity and _utils.get_battery_count(car) > 0 then
		_utils.remove_batteries(car, 1)
		_utils.set_fuel(car, _utils.get_fuel(car) + config.battery_fuel_ratio * capacity)
	end
end

-- Before everything (every tick when empty, else with the slow checks). Empty without battery: the
-- trip is dropped, an alert raised, and the car waits for its charge to pass battery_trigger_ratio (a
-- battery in its slot, or the car placed again: a new car), then goes back to waiting. True when it
-- took over the car this tick.
function travel.handle_empty(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local empty = car_data.empty

	if not empty.active and not _utils.is_slow_check_due(car, tick) then
		return false
	end

	burn_battery_if_low(car, car_data)

	if not empty.active then
		-- charging, parking and building need no move
		if _utils.get_fuel(car) > 0 or car_data.charging.active or car_data.parking.active
			or car_data.building.active then
			return false
		end
		empty.active = true
		travel.cancel_trip(car_data)
		car_data.waiting.active = false
		_utils.alert_once(car_data.alerts, "battery_empty", car.force, car,
			{"autonomous-car-messages.alert-battery-empty"}, config.names.car)
	end

	travel.stop_car(car)
	if _utils.get_fuel_ratio(car) >= config.battery_trigger_ratio then
		empty.active = false
		_utils.alert_reset(car_data.alerts, "battery_empty")
		_utils.start_waiting(car_data, tick - config.idle_delay) -- decided next tick
		return false
	end
	return true
end

return travel
