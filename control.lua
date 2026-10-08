-- Control stage entry point: storage setup, entity tracking, and the per-tick
-- dispatch of each car's state.
local config = require("config")
local colors = require("colors")
local _utils = require("_utils")
local movement = require("movement")
local travel = require("travel")
local charger_control = require("charge")
local garage_control = require("park")
local ghost_control = require("ghost")
local gui = require("gui")

local names = config.names

-- ============================================================
-- Entity tracking
-- ============================================================

-- What to forget when a tracked entity is gone. A stale entity is always
-- released through _utils.release_entity, which runs the handler set here.
_utils.register_release_handler("car", function(id)
	local car_data = storage.car_data[id]
	if car_data then
		travel.requeue_construction(car_data)
	end
	storage.cars[id] = nil
	storage.car_data[id] = nil
end)
_utils.register_release_handler("charger", function(id)
	storage.chargers[id] = nil
	storage.charger_data[id] = nil
end)
_utils.register_release_handler("garage", function(id)
	storage.garages[id] = nil
	storage.garage_data[id] = nil
end)
_utils.register_release_handler("chest", function(id)
	storage.supply_chests[id] = nil
end)

-- Kind of each tracked entity, as _utils.release_entity names it.
local KIND_BY_NAME = {
	[names.car] = "car",
	[names.charger] = "charger",
	[names.garage] = "garage",
	[names.chest] = "chest",
}

-- Runtime state of a car, kept in storage.car_data[unit_number].
local function new_car_data(tick)
	return {
		-- Tick states: each tick runs the first active one, in the order of update_car.
		moving = {
			active = false,
			destination = nil, -- entity, or waypoint table with `position` and `valid`
			departure_tick = nil, departure_distance = nil, -- stuck detection, see travel.stuck_reason
			last_check_position = nil, last_check_tick = nil,
		},
		charging = {active = false, charger = nil},
		parking = {active = false, garage = nil},
		building = {active = false, next_attempt_tick = 0}, -- only active once the car has stopped at its site
		-- Waiting for the player after a failed leg, see travel.start_stuck. `final`: the car will not retry but abandon its task.
		stuck = {active = false, since = 0, final = false, destination = nil},
		empty = {active = false}, -- battery completely empty, see travel.handle_empty
		waiting = {active = true, since = tick - config.idle_delay}, -- already elapsed: a new car looks for work at once

		-- Driving flags, set by movement.lua. travel.lua only cancels a maneuver
		-- (new leg, stuck, empty battery) and resets its counters when a leg begins.
		-- Maneuver mode, a sub-mode of moving. `reason`: rear_turn, blocked or no_progress.
		-- `arcs` counts the arcs of the current maneuver, `attempts` the failed maneuvers in a row,
		-- and `ended_tick` is when the last one ended (or the leg began). `heading` is the orientation
		-- the maneuver turns toward, `last_arc` the arc it drove last (the opposite one is forbidden),
		-- `stall_since` the tick the car stopped moving while driving, `back_off_until` the end of a back-off,
		-- `follow` the direction (reverse or not) the car follows along a wall, `blocked` the directions found blocked.
		maneuver = {
			active = false, reason = nil, since = nil, arc_since = nil, arcs = 0,
			reverse = false, turn = 0, origin = nil, attempts = 0, ended_tick = tick,
			heading = nil, heading_since = nil, last_arc = nil, stall_since = nil, back_off_until = nil, back_off_from = nil,
			follow = nil, follow_orientation = nil, blocked = {},
		},
		emergency_brake = {active = false, since = nil},
		high_speed = false,
		entry_speed = nil, -- speed of the car when it entered high speed
		slowing = false, -- braking down to entry_speed after leaving high speed
		precision_mode = false,
		neighbours = nil, -- moving cars nearby, see movement.lua


		construction = nil, -- current batch, see ghost.lua
		tasks = _utils.deque.new(), -- what to do when the current step ends; the front task runs first

		-- Failure tracking, see travel.lua.
		charge_detour_count = 0,
		stuck_retry_count = 0,
		unreachable_since = nil,
		critical_fuel_retry_tick = nil,
		alerts = {}, -- alert_once flags
	}
end

-- An entity was built by a player, a robot or a script. Ghosts are not tracked
-- here, only once the player selects them (see on_area_selected).
local function on_built(event)
	local entity = event.entity
	local id = entity.unit_number

	if entity.name == names.car then
		entity.friction_modifier = config.friction_base
		entity.color = colors.car
		entity.riding_state = {acceleration = defines.riding.acceleration.nothing, direction = defines.riding.direction.straight}
		-- A new car starts with config.critical_fuel_ratio of a full tank.
		_utils.set_fuel_item(entity)
		if _utils.remaining_fuel(entity) == 0 then
			_utils.set_fuel(entity, _utils.fuel_capacity(entity) * config.critical_fuel_ratio)
		end
		storage.cars[id] = entity
		storage.car_data[id] = new_car_data(event.tick)
	elseif entity.name == names.charger then
		storage.chargers[id] = entity
		storage.charger_data[id] = {users = 0} -- cars charging here or on their way
	elseif entity.name == names.garage then
		storage.garages[id] = entity
		storage.garage_data[id] = {fuel = {}, alerts = {}} -- fuel[slot] = fuel level of the car parked in that slot
	elseif entity.name == names.chest then
		storage.supply_chests[id] = entity
	end
end

-- An entity died or was mined.
local function on_removed(event)
	local kind = KIND_BY_NAME[event.entity.name]
	if kind then
		_utils.release_entity(kind, event.entity.unit_number)
	end
end

-- Only ghosts are registered for this event (see ghost_control.register_ghost).
local function on_object_destroyed(event)
	ghost_control.on_ghost_destroyed(event.useful_id)
end

-- The player dragged the ghost selector over an area: tracks the selected
-- ghosts, splits them into clusters, and gives each cluster to a car or queues it.
local function on_area_selected(event)
	if event.item ~= names.ghost_selector then
		return
	end

	local player = game.get_player(event.player_index)
	local selected = {}
	for _, entity in pairs(event.entities) do
		if entity.valid and entity.type == "entity-ghost" then
			ghost_control.register_ghost(entity)
			if storage.ghosts[entity.unit_number] then
				table.insert(selected, entity)
			end
		end
	end

	if #selected == 0 then
		if player then
			player.print("No ghost outside the robot network found in the selection.")
		end
		return
	end

	-- All the clusters go to the pending pool first, so that a car can take
	-- several of them along (see ghost_control.fill_batch).
	for _, cluster in pairs(ghost_control.build_clusters(selected)) do
		table.insert(storage.pending_clusters, cluster)
	end
	local any_car = ghost_control.any_car_exists()
	local assigned = ghost_control.retry_pending_clusters()
	local queued = #storage.pending_clusters

	if player then
		player.print(assigned .. " construction batch(es) assigned.")
		if queued > 0 then
			if any_car then
				player.print(queued .. " batch(es) queued, waiting for a car to become available.")
			else
				player.print(queued .. " batch(es) queued: no autonomous car available at all, build one.")
			end
		end
	end
end

-- ============================================================
-- Tick
-- ============================================================

-- The wait of an idle car is over: it resumes its batch, takes a pending
-- cluster, or goes to park, topping up its tank first if needed.
local function end_wait(car, car_data, tick)
	if car_data.construction then
		-- The batch was waiting for missing items: try again.
		car_data.waiting.active = false
		ghost_control.proceed(car)
	elseif _utils.deque.length(car_data.tasks) > 0 then
		-- Tasks are still queued but the car is idle: they belong to a leg that no
		-- longer exists. Drop them and wait again.
		car_data.tasks = _utils.deque.new()
		car_data.waiting.since = tick
	elseif not car.get_inventory(defines.inventory.car_trunk).is_empty() then
		-- Leftovers must be unloaded before the car takes a new batch or parks.
		if ghost_control.deposit_leftovers(car) then
			car_data.waiting.active = false
		else
			car_data.waiting.since = tick
		end
	elseif not ghost_control.try_assign_pending(car) then
		local garage = garage_control.find_garage(car)
		if not garage then
			garage_control.alert_no_garage(car)
			car_data.waiting.since = tick
		elseif not travel.top_up_before_parking(car, garage.position) then
			_utils.alert_reset(car_data.alerts, "no_garage")
			car_data.waiting.active = false
			travel.set_destination(car, garage, {type = "parking"})
		end
	end
end

local function update_car(car, car_data, tick)
	-- An empty battery, then a critically low tank, come before everything else.
	if travel.handle_empty(car, tick) or travel.handle_critical_fuel(car, tick) then
		return
	end

	if car_data.moving.active then
		local destination = car_data.moving.destination
		if destination and destination.valid then
			-- update_mode sets the flags that drive_tick reads in the same tick, and may
			-- start a maneuver: keep this order.
			movement.update_mode(car, tick)
			if car_data.maneuver.active then
				local failed, hopeless = movement.maneuver_tick(car, tick)
				if failed then
					travel.start_stuck(car, tick, hopeless) -- the last maneuver failed
				end
			else
				movement.drive_tick(car, tick)
			end

			-- Drive may have ended the leg (arrival): only a leg under way is checked.
			if car_data.moving.active then
				local reason = travel.stuck_reason(car, tick)
				if reason == "timeout" then
					travel.start_stuck(car, tick)
				elseif reason == "no_progress" then
					movement.start_maneuver(car, tick, reason)
				end
			end
		else
			-- The destination disappeared on the way (ghost built by a robot, chest mined...).
			travel.reset_to_waiting(car)
		end
	elseif car_data.charging.active then
		charger_control.charging_tick(car, car_data.charging.charger)
	elseif car_data.parking.active then
		garage_control.parking_tick(car, car_data.parking.garage)
	elseif car_data.building.active then
		ghost_control.building_tick(car, tick)
	elseif car_data.stuck.active then
		if travel.stuck_tick(car, tick) then
			ghost_control.abandon(car)
		end
	elseif car_data.waiting.active then
		travel.stop_car(car)
		if tick - car_data.waiting.since >= config.idle_delay then
			end_wait(car, car_data, tick)
		end
	end
end

local function on_tick(event)
	for id, car in pairs(storage.cars) do
		if car.valid then
			update_car(car, storage.car_data[id], event.tick)
		else
			_utils.release_entity("car", id)
		end
	end

	if event.tick % config.short_delay == 0 then
		gui.refresh_all()
	end
	if event.tick % config.long_delay == 0 then
		ghost_control.retry_pending_clusters()
		garage_control.repair_parked_cars()
	end
end

-- Creates the storage tables that are missing. This is bound to on_tick instead
-- of on_init so that it also runs on a save made before a table existed; it
-- then hands on_tick over to the real handler, so it runs once per load.
local function init_storage()
	storage.cars = storage.cars or {} -- [unit_number] = car entity
	storage.car_data = storage.car_data or {} -- [unit_number] = runtime state, see new_car_data
	storage.chargers = storage.chargers or {}
	storage.charger_data = storage.charger_data or {}
	storage.garages = storage.garages or {}
	storage.garage_data = storage.garage_data or {}
	storage.supply_chests = storage.supply_chests or {}
	storage.ghosts = storage.ghosts or {} -- selected ghosts outside any robot network, assigned or not
	storage.ghost_to_car = storage.ghost_to_car or {} -- [ghost unit_number] = unit_number of its car
	storage.pending_clusters = storage.pending_clusters or {} -- clusters waiting for a free car

	script.on_event(defines.events.on_tick, on_tick)
end

-- A car finished its current step - it arrived, or its tank is full: starts
-- the task queued for that moment (see travel.begin_leg).
local function on_next_task(event)
	local car = event.entity
	local car_data = storage.car_data[car.unit_number]
	local moving = car_data.moving

	car_data.stuck_retry_count = 0 -- the step was completed: nothing to retry

	-- The leg, if the step was one, is over: what the car reached goes to its next task.
	local destination = moving.destination
	moving.active = false
	moving.destination = nil

	if _utils.deque.length(car_data.tasks) == 0 then
		-- Nothing queued (the car arrived from a step back).
		if not ghost_control.try_assign_pending(car) then
			car_data.waiting.active = true
			car_data.waiting.since = event.tick
		end
		return
	end

	local task = _utils.deque.pop_front(car_data.tasks)
	if task.type ~= "charging" then
		car_data.charge_detour_count = 0 -- the trip reached a destination of its own
	end

	-- A task that does not match what the car reached is stale: drop it and let
	-- the waiting loop decide.
	local reached = destination and destination.valid and destination.name
	if (task.type == "charging" and reached ~= names.charger) or (task.type == "parking" and reached ~= names.garage) then
		car_data.tasks = _utils.deque.new()
		car_data.waiting.active = true
		car_data.waiting.since = event.tick
		return
	end

	if task.type == "charging" then
		car_data.charging.active = true
		car_data.charging.charger = destination
	elseif task.type == "parking" then
		car_data.parking.active = true
		car_data.parking.garage = destination
	elseif task.type == "building" then
		car_data.building.active = true
		car_data.building.next_attempt_tick = event.tick
	elseif task.type == "collect" then
		ghost_control.collect_items(car, destination)
	elseif task.type == "deposit" then
		ghost_control.deposit_items(car, destination)
	end
end

script.on_event(defines.events.on_built_entity, on_built)
script.on_event(defines.events.on_robot_built_entity, on_built)
script.on_event(defines.events.script_raised_built, on_built)
script.on_event(defines.events.on_entity_died, on_removed)
script.on_event(defines.events.on_player_mined_entity, on_removed)
script.on_event(defines.events.on_robot_mined_entity, on_removed)
script.on_event(defines.events.on_object_destroyed, on_object_destroyed)
script.on_event(defines.events.on_player_selected_area, on_area_selected)
script.on_event(defines.events.on_player_alt_selected_area, on_area_selected)
script.on_event(prototypes.custom_event[names.next_task_event], on_next_task)
script.on_event(defines.events.on_lua_shortcut, function(event)
	if event.prototype_name == names.missing_items_shortcut then
		gui.toggle(game.get_player(event.player_index))
	end
end)
script.on_event(defines.events.on_gui_click, gui.on_click)
script.on_event(defines.events.on_tick, init_storage)
