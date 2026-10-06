local util = require("util")
local config = require("config")
local _utils = require("_utils")
local charger_control = require("charge")

-- Trips: starting a leg, detours to a charger, and what happens when a car
-- gets stuck or cannot reach its goal.
local travel = {}

-- Brakes while the car still rolls forward, then lets go of the controls.
function travel.stop_car(car)
	local acceleration = defines.riding.acceleration.nothing
	if car.speed > 0.01 then
		acceleration = defines.riding.acceleration.braking
	end
	car.riding_state = {acceleration = acceleration, direction = defines.riding.direction.straight}
end

-- Starts driving to `destination`: an entity, or any table with `position` and
-- `valid`. `next_task`, if given, is what the car does on arrival (see
-- on_next_task in control.lua). Fuel is not checked here: see travel.set_destination.
function travel.begin_leg(car, destination, next_task)
	local car_data = storage.car_data[car.unit_number]
	local moving = car_data.moving

	car_data.building.active = false
	car_data.stuck.active = false
	car_data.stuck.destination = nil
	moving.active = true
	moving.destination = destination
	-- Reference points of the stuck detection (see travel.stuck_reason).
	moving.departure_tick = game.tick
	moving.departure_distance = util.distance(car.position, destination.position)
	moving.last_check_position = car.position
	moving.last_check_tick = game.tick

	-- A new leg starts without a maneuver, and a car that stands still at
	-- departure is not blocked (see movement.drive_tick).
	car_data.maneuver.active = false
	car_data.maneuver.attempts = 0
	car_data.maneuver.ended_tick = game.tick

	-- stuck_retry_count is not reset here: a retry is a new leg too. It is reset on arrival.
	car_data.charge_detour_count = 0
	car_data.unreachable_since = nil
	_utils.alert_reset(car_data.alerts, "stuck")
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
-- lacks the fuel for it. On a detour `next_task` is dropped: the car decides
-- again once charged. Returns false if the car could not set off at all.
function travel.set_destination(car, destination, next_task)
	if _utils.remaining_fuel(car) >= charger_control.fuel_needed(car, destination.position) then
		travel.begin_leg(car, destination, next_task)
		return true
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
	car_data.building.active = false
	car_data.moving.active = false
	car_data.moving.destination = nil
	car_data.moving.departure_tick = nil
	travel.stop_car(car)
	car_data.waiting.active = true
	car_data.waiting.since = game.tick
end

-- Takes the construction batch away from a car and puts its remaining ghosts
-- back in the pending pool, as one cluster. It lives here rather than in
-- ghost.lua because ghost.lua requires this module, not the other way round.
function travel.requeue_construction(car_data)
	local construction = car_data.construction
	if not construction then
		return
	end

	local ghosts = {}
	for id, ghost in pairs(construction.ghosts) do
		if ghost.valid then
			table.insert(ghosts, ghost)
		end
		storage.ghost_to_car[id] = nil
	end
	if #ghosts > 0 then
		table.insert(storage.pending_clusters, {ghosts = ghosts})
	end
	car_data.construction = nil
end

-- Called when a goal keeps failing, after too many charging detours: alerts
-- once, then sends the car back to waiting. A goal that has been failing for
-- config.unreachable_abandon_delay is abandoned: louder alert, and the
-- construction batch is requeued.
function travel.mark_unreachable(car)
	local car_data = storage.car_data[car.unit_number]
	local icon = {type = "item", name = "autonomous_car"}

	car_data.unreachable_since = car_data.unreachable_since or game.tick
	_utils.alert_once(car_data.alerts, "unreachable", car.force, car,
		"An autonomous car cannot find a way to recharge enough to reach its destination.", icon)

	if game.tick - car_data.unreachable_since >= config.unreachable_abandon_delay then
		_utils.alert(car.force, car,
			"An autonomous car has ABANDONED its current task after failing for a long time - check the area for obstructions or missing chargers.", icon)
		travel.requeue_construction(car_data)
		car_data.unreachable_since = nil
	end

	travel.reset_to_waiting(car)
end

-- The destination of the leg the car is on, or is waiting out a stuck state on.
local function leg_destination(car_data)
	if car_data.moving.active then
		return car_data.moving.destination
	elseif car_data.stuck.active then
		return car_data.stuck.destination
	end
	return nil
end

local function heading_to_charger(car_data)
	local destination = leg_destination(car_data)
	return destination and destination.valid and destination.name == "autonomous_car_charger"
end

-- Gives back the charger slot that a leg to a charger holds (see go_to_charger),
-- when that leg is dropped.
local function release_charger_slot(car_data)
	if heading_to_charger(car_data) then
		local charger_data = storage.charger_data[leg_destination(car_data).unit_number]
		if charger_data and charger_data.users > 0 then
			charger_data.users = charger_data.users - 1
		end
	end
end

-- Runs for every car, every tick, right after travel.handle_empty. Below
-- config.critical_fuel_ratio the car drops its trip and its queued tasks and
-- heads for a charger; if none is reachable it stays put and looks again every
-- config.short_delay. Returns true when it took over the car for this tick.
function travel.handle_critical_fuel(car, tick)
	local car_data = storage.car_data[car.unit_number]
	if car_data.charging.active or heading_to_charger(car_data) then
		return false
	end

	local capacity = _utils.fuel_capacity(car)
	if _utils.remaining_fuel(car) / capacity >= config.critical_fuel_ratio then
		return false
	end

	if car_data.critical_fuel_retry_tick and tick < car_data.critical_fuel_retry_tick then
		travel.stop_car(car)
		return true
	end

	car_data.building.active = false
	car_data.moving.active = false
	car_data.tasks = _utils.deque.new()

	local charger = charger_control.find_charger(car)
	if charger then
		go_to_charger(car, charger)
		car_data.critical_fuel_retry_tick = nil
	else
		charger_control.alert_no_charger(car)
		car_data.critical_fuel_retry_tick = tick + config.short_delay
		travel.stop_car(car)
	end
	return true
end

-- Sends an idle car to the charger closest to `target_position` if its tank is
-- below config.pre_park_fuel_ratio. Returns true if the car left for a charger.
function travel.top_up_before_parking(car, target_position)
	local capacity = _utils.fuel_capacity(car)
	if _utils.remaining_fuel(car) / capacity >= config.pre_park_fuel_ratio then
		return false
	end

	local charger = charger_control.find_charger(car, target_position)
	if not charger then
		return false
	end

	go_to_charger(car, charger)
	return true
end

-- Why the current leg no longer makes real progress, or nil if it does:
--   "timeout"      it has lasted much longer than its length justifies: stuck
--   "no_progress"  the car barely moved over the last config.medium_delay: it
--                  needs a maneuver (see movement.start_maneuver)
-- The progress window is suspended during a maneuver, where the car moves little
-- on purpose, and within arrival distance, where it is about to stop; it starts
-- again afterwards. The car must be on a leg (see update_car in control.lua).
function travel.stuck_reason(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local moving = car_data.moving

	local max_duration = moving.departure_distance / config.stuck_min_speed + config.long_delay
	if tick - moving.departure_tick > max_duration then
		return "timeout"
	end

	-- No progress is expected while maneuvering, or within arrival distance of the destination.
	if car_data.maneuver.active or util.distance(car.position, moving.destination.position) < config.arrival_distance then
		moving.last_check_position = car.position
		moving.last_check_tick = tick
	elseif tick - moving.last_check_tick >= config.medium_delay then
		if util.distance(car.position, moving.last_check_position) < config.stuck_min_progress then
			return "no_progress"
		end
		moving.last_check_position = car.position
		moving.last_check_tick = tick
	end

	return nil
end

-- Stops a stuck car and alerts the player. The car waits for the player to free
-- it, then tries its leg again (see travel.stuck_tick). It tries again only
-- while it has retries left and fuel for the leg: otherwise it waits longer, then
-- abandons its task. A leg to a charger is always retried: the car has nothing
-- better to do.
function travel.start_stuck(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local moving = car_data.moving
	local stuck = car_data.stuck
	local icon = {type = "item", name = "autonomous_car"}

	-- TODO: retry a leg to a charger without limit only when the car is on its
	-- way back (top-up before the garage, or after an abandon); otherwise limit
	-- it like any other leg. See "À faire" in CLAUDE.md.
	local to_charger = heading_to_charger(car_data)
	car_data.stuck_retry_count = car_data.stuck_retry_count + 1
	local can_retry = to_charger or (car_data.stuck_retry_count <= config.max_stuck_retries
		and _utils.remaining_fuel(car) >= charger_control.fuel_needed(car, moving.destination.position))

	if can_retry then
		_utils.alert_once(car_data.alerts, "stuck", car.force, car,
			"An autonomous car is stuck. It will try again in a few seconds unless you free it.", icon)
	else
		_utils.alert_once(car_data.alerts, "stuck_final", car.force, car,
			"An autonomous car is stuck for good. It will abandon its task soon: free it or check the area.", icon)
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
	if tick - stuck.since < (stuck.final and config.stuck_abandon_delay or config.long_delay) then
		return false
	end
	if stuck.final then
		release_charger_slot(car_data)
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
		-- The destination disappeared while the car waited.
		stuck.active = false
		stuck.destination = nil
		car_data.tasks = _utils.deque.new()
		travel.reset_to_waiting(car)
	end
	return false
end

-- Runs before everything else for every car, every tick. A car with a completely
-- empty battery cannot move: it drops its trip and its queued tasks, alerts the
-- player, and does nothing but check whether its battery is back above
-- config.critical_fuel_ratio, in which case it resumes its batch through the
-- waiting loop. Nothing in the mod refills an empty car: the player's way out
-- is to pick the car up and place it again, which makes a new car (see on_built
-- in control.lua) instead of waking this one. Returns true when it took over
-- the car for this tick.
-- TODO: add one or more ways to recharge an empty car. See "À faire" in CLAUDE.md.
function travel.handle_empty(car, tick)
	local car_data = storage.car_data[car.unit_number]
	local empty = car_data.empty

	if not empty.active then
		-- Charging, parking and building do not need the car to move.
		if _utils.remaining_fuel(car) > 0 or car_data.charging.active or car_data.parking.active
			or car_data.building.active then
			return false
		end
		empty.active = true
		release_charger_slot(car_data)
		car_data.moving.active = false
		car_data.moving.destination = nil
		car_data.moving.departure_tick = nil
		car_data.stuck.active = false
		car_data.stuck.destination = nil
		car_data.maneuver.active = false
		car_data.waiting.active = false
		car_data.tasks = _utils.deque.new()
		_utils.alert_once(car_data.alerts, "battery_empty", car.force, car,
			"An autonomous car has run out of battery and cannot move: recover it or recharge it.",
			{type = "item", name = "autonomous_car"})
	end

	travel.stop_car(car)
	if _utils.remaining_fuel(car) / _utils.fuel_capacity(car) >= config.critical_fuel_ratio then
		empty.active = false
		_utils.alert_reset(car_data.alerts, "battery_empty")
		car_data.waiting.active = true
		car_data.waiting.since = tick - config.idle_delay -- already elapsed: handled on the next tick
		return false
	end
	return true
end

return travel
