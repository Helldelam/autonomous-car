local util = require("util")
local config = require("config")
local _utils = require("_utils")
local charger_control = require("charge")

-- Trips: starting a leg, detours to a charger, and what happens when a car
-- cannot reach its goal, gets stuck or runs out of battery.
local travel = {}

-- ============================================================
-- Legs
-- ============================================================

-- Brakes while the car still rolls forward, then lets go of the controls.
function travel.stop_car(car)
	local acceleration = defines.riding.acceleration.nothing
	if car.speed > config.speed.stopped then
		acceleration = defines.riding.acceleration.braking
	end
	car.riding_state = {acceleration = acceleration, direction = defines.riding.direction.straight}
end

-- The destination of the leg the car is on, or is waiting out a stuck state on.
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

-- Gives back the charger slot that a car holds (see go_to_charger), whether it
-- is still on its way to the charger or already charging there, when the trip
-- is dropped. A car that was charging stops charging. Does nothing for a car
-- that holds no slot, so it is safe to call whenever a trip ends.
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

-- State of the path of a car (see movement.lua, "Path") at the start of a leg:
-- requests and clearings are counted per leg. `count`, `guided_count`: failure
-- and guided requests of this leg; `clear_count`: its clearings; `next_tick`: no
-- request before it; `pending`: waiting for the answer; `active`: following
-- `waypoints`.
function travel.create_path_state()
	return {active = false, pending = false, count = 0, guided_count = 0, clear_count = 0, next_tick = 0}
end

-- Drops the trip in progress: the leg or the stuck wait, a maneuver, a charge,
-- a parking, the tasks queued for them and the charger slot they hold. The car
-- keeps its batch: it decides again from the waiting loop (see reset_to_waiting)
-- or by starting another leg.
function travel.cancel_trip(car_data)
	travel.release_charger_slot(car_data)
	car_data.parking.active = false
	car_data.parking.garage = nil
	car_data.building.active = false
	car_data.maneuver.active = false
	car_data.path = travel.create_path_state()
	car_data.stuck.active = false
	car_data.stuck.destination = nil
	car_data.moving.active = false
	car_data.moving.destination = nil
	car_data.moving.departure_tick = nil
	car_data.tasks = _utils.deque.new()
end

-- Starts driving to `destination`: an entity, or any table with `position` and
-- `valid`. `next_task`, if given, is what the car does on arrival (see
-- on_next_task in control.lua). Fuel is not checked here: see travel.set_destination.
-- A leg under way is replaced: it gives back its charger slot, if it held one.
-- A retry after a stuck wait is not a replacement: its slot is still held.
function travel.begin_leg(car, destination, next_task)
	local car_data = storage.car_data[car.unit_number]
	local moving = car_data.moving

	if moving.active and moving.destination ~= destination then
		travel.release_charger_slot(car_data)
	end
	car_data.building.active = false
	car_data.waiting.active = false -- a car on its way is not available for a batch
	car_data.stuck.active = false
	car_data.stuck.destination = nil
	moving.active = true
	moving.destination = destination
	-- Reference points of the stuck detection (see travel.is_leg_too_long).
	moving.departure_tick = game.tick
	moving.departure_distance = util.distance(car.position, destination.position)

	-- A new leg starts without a maneuver, and a car that stands still at
	-- departure is not blocked (see movement.drive_tick).
	car_data.maneuver.active = false
	car_data.maneuver.ended_tick = game.tick
	car_data.path = travel.create_path_state()
	car_data.slowing = false

	-- stuck_retry_count is not reset here: a retry is a new leg too. It is reset on arrival.
	-- Neither is charge_detour_count: a detour is a leg too, and the detours of one
	-- trip must add up. It is reset on arrival at a destination that is not a charger.
	car_data.unreachable_since = nil
	_utils.alert_reset(car_data.alerts, "stuck")
	_utils.alert_reset(car_data.alerts, "stuck_final") -- a final wait that was dropped (see cancel_trip) never reset it
	_utils.alert_reset(car_data.alerts, "no_charger")
	_utils.alert_reset(car_data.alerts, "unreachable")

	if next_task then
		_utils.deque.push_front(car_data.tasks, next_task)
	end
end

-- Reserves a slot at the charger and sends the car there.
local function go_to_charger(car, charger)
	local charger_data = storage.charger_data[charger.unit_number]
	charger_data.users = charger_data.users + 1
	travel.begin_leg(car, charger, {type = "charging"})
end

-- Starts a trip to `destination`, or a detour to a charger first if the car
-- lacks the fuel for it and for the way from there to a charger. A full tank
-- that is still not enough means the destination is out of range: charging again
-- would not help, so it is reported unreachable. On a detour `next_task` is
-- dropped: the car decides again once charged. Returns false if the car could
-- not set off at all.
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

-- Sends the car to a charger it can reach, the closest to `target_position`.
-- Returns false if it could not set off.
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

-- Stops the car and hands it back to the waiting loop of control.lua, which
-- decides what it does next.
function travel.reset_to_waiting(car)
	local car_data = storage.car_data[car.unit_number]
	travel.cancel_trip(car_data) -- the queued tasks belonged to the trip that was dropped
	travel.stop_car(car)
	_utils.start_waiting(car_data)
end

-- ============================================================
-- Unreachable goal
-- ============================================================

-- Takes one cluster (an entry of construction.clusters) out of a batch and puts
-- its ghosts still to build back in the pending pool, as a cluster. The ghosts
-- of that entry that left the batch earlier (built, gone, or given up on and
-- queued again) are left alone: they may be with another car by now.
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

-- Takes the construction batch away from a car and puts its remaining ghosts
-- back in the pending pool, cluster by cluster: merged into one, the next car
-- would build them all from its first stop (see ghost_control.go_to_site). It
-- lives here rather than in ghost.lua because ghost.lua requires this module,
-- not the other way round.
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

-- Called when a goal keeps failing, after too many charging detours: alerts
-- once, then sends the car back to waiting. A goal that has been failing for
-- config.very_long_delay is abandoned: louder alert, and the
-- construction batch is requeued.
function travel.mark_unreachable(car)
	local car_data = storage.car_data[car.unit_number]

	car_data.unreachable_since = car_data.unreachable_since or game.tick
	_utils.alert_once(car_data.alerts, "unreachable", car.force, car,
		"An autonomous car cannot find a way to recharge enough to reach its destination.", config.names.car)

	if game.tick - car_data.unreachable_since >= config.very_long_delay then
		_utils.alert(car.force, car,
			"An autonomous car has ABANDONED its current task after failing for a long time - check the area for obstructions or missing chargers.", config.names.car)
		travel.requeue_construction(car_data)
		car_data.unreachable_since = nil
		car_data.charge_detour_count = 0 -- the next task gets its full detour budget
	end

	travel.reset_to_waiting(car)
end

-- ============================================================
-- Charging trips
-- ============================================================

-- Fuel below which a car drops everything to recharge: what it takes to reach
-- the closest charger from where it is, plus the critical level
-- (config.critical_fuel_ratio). Not measured at all above
-- config.critical_check_fuel_ratio of a full tank. Below it, measured every
-- config.slow_check_interval ticks, or every config.short_delay while the tank
-- holds more than twice the last level measured, and kept in car_data.
-- Returns whether the fuel of the car is below it.
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

-- Whether the fuel of a car is below its critical level, by the last measure
-- (see measure_critical_fuel): a car that is, and has no charger to go to, must
-- not be given a batch.
function travel.is_fuel_critical(car)
	local reserve = storage.car_data[car.unit_number].critical_fuel
	local fuel = _utils.get_fuel(car)
	return fuel < config.critical_check_fuel_ratio * _utils.get_fuel_capacity(car) and reserve ~= nil and fuel < reserve
end

-- Runs for every car, every tick, right after travel.handle_empty. Below the
-- critical fuel (see above) the car drops its trip and its queued tasks and
-- heads for a charger; if none is reachable it stays put and looks again every
-- config.short_delay. Returns true when it took over the car for this tick.
function travel.handle_critical_fuel(car, tick)
	local car_data = storage.car_data[car.unit_number]
	if car_data.charging.active or is_heading_to_charger(car_data) then
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
		-- The car must keep an active state: its fuel can stop being critical
		-- without a charge (a charger built closer lowers the level, see
		-- measure_critical_fuel), and the waiting loop then decides what it does.
		_utils.start_waiting(car_data)
	end
	return true
end

-- Sends an idle car to the charger closest to `target_position` if its tank is
-- below config.pre_park_fuel_ratio. Returns true if the car left for a charger.
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

-- True when the current leg has lasted much longer than its length justifies
-- (see config.stuck.min_speed): the car is stuck. A leg that lasts too long first
-- gets its path (see update_car in control.lua). The car must be on a leg.
function travel.is_leg_too_long(car, tick)
	local moving = storage.car_data[car.unit_number].moving
	local max_duration = moving.departure_distance / config.stuck.min_speed + config.long_delay
	return tick - moving.departure_tick > max_duration
end

-- TODO: send another car to rescue a stuck car (and could
-- later fetch a broken-down train). See "À faire" in CLAUDE.md.
-- Stops a stuck car and alerts the player. The car waits for the player to free
-- it, then tries its leg again (see travel.stuck_tick). It tries again only
-- while it has retries left and fuel for the leg: otherwise it waits longer, then
-- abandons its task. A leg to a charger is retried without limit only when the car
-- has no batch (it is on its way back, with nothing better to do); a charging detour
-- of a batch is limited like any other leg, and the batch is abandoned if it fails.
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
			"An autonomous car is stuck. It will try again in a few seconds unless you free it.", config.names.car)
	else
		_utils.alert_once(car_data.alerts, "stuck_final", car.force, car,
			"An autonomous car is stuck for good. It will abandon its task soon: free it or check the area.", config.names.car)
	end

	stuck.active = true
	stuck.since = tick
	stuck.final = not can_retry
	stuck.destination = moving.destination -- kept to retry the same leg: its task is still queued

	car_data.building.active = false
	car_data.maneuver.active = false
	moving.active = false
	moving.destination = nil
	moving.departure_tick = nil
	travel.stop_car(car)
end

-- Called every tick while the car is stuck: waits. Once the wait is over the car
-- starts its leg again, or, if this was its final stuck wait, the function
-- returns true: the caller abandons the task (see ghost_control.abandon).
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
		travel.begin_leg(car, destination) -- its task is still at the front of the queue
	else
		travel.reset_to_waiting(car) -- the destination disappeared while the car waited
	end
	return false
end

-- ============================================================
-- Empty battery
-- ============================================================

-- Burns one battery of the battery slot when the tank is almost empty (below
-- config.battery_trigger_ratio), so that the car keeps going to a charger. Not
-- while charging or parking: the tank is being filled.
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

-- Runs before everything else for every car, every tick. First burns a battery if
-- the tank is almost empty (see above). A car with a completely empty battery and
-- no battery to burn cannot move: it drops its trip and its queued tasks, alerts
-- the player, and does nothing but check whether its battery is back above
-- config.battery_trigger_ratio (a battery put in its battery slot, or the player
-- picking the car up and placing it again, which makes a new car: see on_built in
-- control.lua), in which case it goes back to waiting; below the critical level
-- it then heads for a charger (handle_critical_fuel). Returns true when it took
-- over the car for this tick.
function travel.handle_empty(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local empty = car_data.empty

	burn_battery_if_low(car, car_data)

	if not empty.active then
		-- Charging, parking and building do not need the car to move.
		if _utils.get_fuel(car) > 0 or car_data.charging.active or car_data.parking.active
			or car_data.building.active then
			return false
		end
		empty.active = true
		travel.cancel_trip(car_data)
		car_data.waiting.active = false
		_utils.alert_once(car_data.alerts, "battery_empty", car.force, car,
			"An autonomous car has run out of battery and cannot move: put a battery in the battery slot "
				.. "(last slot of its trunk), or recover it.",
			config.names.car)
	end

	travel.stop_car(car)
	if _utils.get_fuel_ratio(car) >= config.battery_trigger_ratio then
		empty.active = false
		_utils.alert_reset(car_data.alerts, "battery_empty")
		_utils.start_waiting(car_data, tick - config.idle_delay) -- already elapsed: handled on the next tick
		return false
	end
	return true
end

return travel
