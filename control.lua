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
local garage_gui = require("garage_gui")
local car_gui = require("car_gui")
local circuit_control = require("circuit")
local logistic_control = require("logistic")
local debug_view = require("debug_view")
local game_trace = require("game_trace")
local armed = require("armed")

local names = config.names

-- ============================================================
-- Entity tracking
-- ============================================================

-- What to forget when a tracked entity is gone. A stale entity is always
-- released through _utils.release_entity, which runs the handler set here.
_utils.register_release_handler("car", function(id)
	local car_data = storage.car_data[id]
	if car_data then
		travel.release_charger_slot(car_data) -- a car lost on its way to a charger, or at it, must not keep the slot
		travel.requeue_construction(car_data)
		armed.release(car_data)
	end
	storage.cars[id] = nil
	storage.car_data[id] = nil
end)
_utils.register_release_handler("charger", function(id)
	circuit_control.destroy_link(storage.charger_data[id])
	storage.chargers[id] = nil
	storage.charger_data[id] = nil
end)
_utils.register_release_handler("garage", function(id)
	circuit_control.destroy_link(storage.garage_data[id])
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
	[names.delivery_chest] = "chest",
	[names.return_chest] = "chest",
}

-- Runtime state of a car, kept in storage.car_data[unit_number].
local function create_car_data(tick)
	return {
		-- Tick states: each tick runs the first active one, in the order of update_car.
		moving = {
			active = false,
			destination = nil, -- entity, or waypoint table with `position` and `valid`
			departure_tick = nil, departure_distance = nil, -- stuck detection, see travel.is_leg_too_long
		},
		charging = {active = false, charger = nil},
		parking = {active = false, garage = nil},
		building = {active = false, next_attempt_tick = 0}, -- only active once the car has stopped at its site
		-- Waiting for the player after a failed leg, see travel.start_stuck. `final`: the car will not retry but abandon its task.
		stuck = {active = false, since = 0, final = false, destination = nil},
		empty = {active = false}, -- battery completely empty, see travel.handle_empty
		waiting = {active = true, since = tick - config.idle_delay}, -- already elapsed: a new car looks for work at once

		-- Driving state, set by movement.lua. travel.lua only cancels a maneuver
		-- (new leg, stuck, empty battery) and resets the path when a leg begins.
		-- Maneuver, a sub-mode of moving: movement.start_maneuver sets its other fields.
		-- `ended_tick` is when the last one ended (or the leg began).
		maneuver = {active = false, ended_tick = tick},
		path = travel.create_path_state(),
		emergency_brake = {active = false, since = nil},
		mode = "normal", -- "fast", "normal" or "slow", see movement.update_mode
		slow_until = nil, -- tick until which the mode stays slow (after an emergency stop, a maneuver, a path)
		near_built = false, -- something built lies near the car, see movement.lua
		entry_speed = nil, -- speed of the car when it entered fast mode
		slowing = false, -- braking down to entry_speed after leaving fast mode
		neighbours = nil, -- moving cars nearby, see movement.lua

		construction = nil, -- current batch, see ghost.lua
		tasks = _utils.deque.new(), -- what to do when the current step ends; the front task runs first

		-- Fleeing from an enemy (handle_danger): `active` while on the way to the refuge, `count` the flights of this batch.
		flee = {active = false, count = 0},
		just_left_garage = false, -- set by garage_control.release_car: its batch starts with a restock stop (ghost_control.proceed), kept until the car reaches the chest
		turret = nil, turret_ammo = nil, -- hidden turret of an armed car and the ammo it holds, see armed.lua

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
		entity.friction_modifier = config.friction.normal
		entity.color = colors.car
		entity.riding_state = {acceleration = defines.riding.acceleration.nothing, direction = defines.riding.direction.straight}
		-- A new car starts with config.critical_fuel_ratio of a full tank.
		_utils.set_fuel_item(entity)
		_utils.set_trunk_limits(entity)
		if _utils.get_fuel(entity) == 0 then
			_utils.set_fuel(entity, _utils.get_fuel_capacity(entity) * config.critical_fuel_ratio)
		end
		storage.cars[id] = entity
		storage.car_data[id] = create_car_data(event.tick)
	elseif entity.name == names.charger then
		storage.chargers[id] = entity
		charger_control.update_buffer(entity)
		storage.charger_data[id] = {users = 0, transferred = 0} -- users: cars charging here or on their way; transferred: energy given to cars since the last circuit.lua refresh
	elseif entity.name == names.garage then
		storage.garages[id] = entity
		garage_control.update_inventory(entity)
		storage.garage_data[id] = {cars = {}, alerts = {}} -- cars: the parked cars, first in first out (see park.lua)
	elseif KIND_BY_NAME[entity.name] == "chest" then
		storage.supply_chests[id] = entity
	end
end

-- An entity died or was mined.
local function on_removed(event)
	local kind = KIND_BY_NAME[event.entity.name]
	if kind == "garage" then
		-- mined or destroyed: the parked cars come out as items (on the ground if destroyed)
		garage_control.return_cars(event.entity, event.buffer, event.player_index and game.get_player(event.player_index))
	end
	if kind then
		_utils.release_entity(kind, event.entity.unit_number)
	end
end

-- Only ghosts and entities marked for deconstruction or upgrade are registered for this
-- event (see ghost_control.register_ghost); one without a unit_number is found by its registration number.
local function on_object_destroyed(event)
	local id = storage.target_by_registration[event.registration_number]
	storage.target_by_registration[event.registration_number] = nil
	ghost_control.on_ghost_destroyed(id or event.useful_id)
end

-- The player dragged the ghost selector over an area: tracks the selected
-- ghosts and entities marked for deconstruction or upgrade, splits them into clusters, and gives each cluster to a car or queues it.
-- TODO: if the mod gets too costly, spread the sorting, clustering and assignment over several ticks. See "À faire" in CLAUDE.md.
local function on_area_selected(event)
	if event.item ~= names.ghost_selector then
		return
	end

	local player = game.get_player(event.player_index)
	local selected = {}
	for _, entity in pairs(event.entities) do
		-- Only the targets that are newly tracked: one selected before is with a car
		-- or in the pending pool already.
		if ghost_control.register_ghost(entity) then
			table.insert(selected, entity)
		end
	end

	if #selected == 0 then
		if player then
			player.print("No new ghost or entity marked for deconstruction or upgrade outside the robot network found in the selection.")
		end
		return
	end

	-- All the clusters go to the pending pool first, so that a car can take
	-- several of them along (see ghost_control.fill_batch).
	for _, cluster in pairs(ghost_control.build_clusters(selected, player and player.force or game.forces.player)) do
		table.insert(storage.pending_clusters, cluster)
	end
	local any_car = ghost_control.is_any_car_present()
	local assigned = ghost_control.retry_pending_clusters()
	local queued = #storage.pending_clusters

	if player then
		-- One line per batch type, none for a type without batch (landfill counts as construction).
		local build_count = (assigned.build or 0) + (assigned.landfill or 0)
		if (assigned.deconstruct or 0) > 0 then
			player.print(assigned.deconstruct .. " destruction batch(es) assigned.")
		end
		if build_count > 0 then
			player.print(build_count .. " construction batch(es) assigned.")
		end
		if (assigned.upgrade or 0) > 0 then
			player.print(assigned.upgrade .. " upgrade batch(es) assigned.")
		end
		if (assigned.network or 0) > 0 then
			player.print(assigned.network .. " logistic network batch(es) assigned.")
		end
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
-- cluster, or goes to park, topping up its tank and batteries first if needed.
local function end_wait(car, car_data, tick)
	-- Whatever starts a leg ends the wait (travel.begin_leg), and a car that
	-- cannot set off goes back to waiting (travel.reset_to_waiting): only the
	-- branches that do nothing restart the wait themselves.
	if car_data.construction then
		-- The batch was waiting for missing items: try again.
		ghost_control.proceed(car)
	elseif _utils.deque.length(car_data.tasks) > 0 then
		-- Tasks are still queued but the car is idle: they belong to a leg that no
		-- longer exists. Drop them and wait again.
		car_data.tasks = _utils.deque.new()
		car_data.waiting.since = tick
	elseif not _utils.is_cargo_empty(car) then
		-- Leftovers must be unloaded before the car takes a new batch or parks.
		if not ghost_control.deposit_leftovers(car) then
			car_data.waiting.since = tick
		end
	elseif not ghost_control.try_assign_pending(car) then
		local garage = garage_control.find_garage(car)
		if not garage then
			garage_control.alert_no_garage(car)
			car_data.waiting.since = tick
		elseif not travel.top_up_before_parking(car, garage.position) then
			_utils.alert_reset(car_data.alerts, "no_garage")
			-- Batteries and ammo are topped up just before parking, if a chest has some: without
			-- them the car parks all the same.
			local chest = ghost_control.find_restock_chest(car)
			if chest then
				travel.set_destination(car, chest, {type = "restock"})
			else
				travel.set_destination(car, garage, {type = "parking"})
			end
		end
	end
end

-- A moving or building car that finds an enemy within config.flee.radius flees (see
-- travel.start_flee). Past config.flee.max_count flights in one batch it abandons the
-- batch; with no batch left, it ignores enemies until it has a new one. Measured every
-- config.slow_check_interval ticks. A car short of fuel is left to handle_critical_fuel.
-- Returns true when it took over the car for this tick.
local function handle_danger(car, car_data, tick)
	local flee = car_data.flee
	if flee.active or not (car_data.moving.active or car_data.building.active) or not _utils.is_slow_check_due(car, tick)
		or travel.is_fuel_critical(car) then
		return false
	end
	local exhausted = flee.count >= config.flee.max_count
	if exhausted and not car_data.construction then
		return false
	end
	local enemy = car.surface.find_nearest_enemy{position = car.position, max_distance = config.flee.radius, force = car.force}
	if not enemy then
		return false
	end
	if exhausted then
		ghost_control.abandon(car, "An autonomous car ABANDONED its task: enemies keep coming near its site. Select the ghosts again once the area is safe.")
		return true
	end
	travel.start_flee(car, travel.find_refuge(car, enemy))
	return true
end

local function update_car(car, car_data, tick)
	-- An empty battery, then a critically low tank, come before everything else.
	if travel.handle_empty(car, tick) or travel.handle_critical_fuel(car, tick) or handle_danger(car, car_data, tick) then
		return
	end

	if car_data.moving.active then
		local destination = car_data.moving.destination
		if destination and destination.valid then
			-- update_mode sets the flags that drive_tick reads in the same tick, and may
			-- start a maneuver: keep this order.
			movement.update_mode(car, tick)
			if car_data.maneuver.active then
				if movement.maneuver_tick(car, tick) then
					travel.start_stuck(car, tick) -- the last maneuver failed
				end
			else
				movement.drive_tick(car, tick)
			end

			-- Drive may have ended the leg (arrival): only a leg under way is checked,
			-- and not while the car waits for its path.
			if car_data.moving.active and not car_data.path.pending then
				if travel.is_leg_too_long(car, tick) then
					-- A leg that lasts too long gets its path, as a last resort, before it is stuck.
					if not movement.request_path(car, tick) then
						travel.start_stuck(car, tick)
					end
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
	else
		-- Safety net: a car in no state at all would do nothing for ever. Back to
		-- waiting; the case is recorded so that the tests report it (a bug elsewhere
		-- left the car without a state).
		table.insert(storage.idle_fallbacks, {tick = tick, car = car.unit_number, surface = car.surface.index})
		log("autonomous car " .. car.unit_number .. " had no state at tick " .. tick .. ", set to waiting")
		travel.reset_to_waiting(car)
	end
end

local function on_tick(event)
	for id, car in pairs(storage.cars) do
		if car.valid then
			-- No event tells that the player changed the filter of the battery slot.
			if _utils.is_slow_check_due(car, event.tick) then
				_utils.set_trunk_limits(car)
				armed.update(car, storage.car_data[id])
			end
			update_car(car, storage.car_data[id], event.tick)
			if storage.game_trace and car.valid then -- the car is gone when it has just parked in a garage
				game_trace.record(car, storage.car_data[id], event.tick)
			end
		else
			_utils.release_entity("car", id)
		end
	end

	if event.tick % config.short_delay == 0 then
		gui.refresh_all()
		garage_gui.refresh_all()
		car_gui.refresh_all()
		circuit_control.refresh(event.tick)
	end
	if event.tick % config.medium_delay == 0 then
		logistic_control.update_requests()
	end
	if event.tick % config.slow_check_interval == 0 then
		debug_view.refresh()
	end
	garage_control.update_inventories(event.tick)
	if event.tick % config.long_delay == 0 then
		ghost_control.retry_pending_clusters()
		charger_control.update_buffers()
		garage_control.repair_parked_cars()
	end
end

-- Creates the storage tables that are missing. This is bound to on_tick instead
-- of on_init so that it also runs on a save made before a table existed; it
-- then hands on_tick over to the real handler, so it runs once per load, and
-- runs that handler for this tick too: a player who joins a multiplayer game
-- must not skip a tick that the others run.
local function init_storage(event)
	storage.cars = storage.cars or {} -- [unit_number] = car entity
	storage.car_data = storage.car_data or {} -- [unit_number] = runtime state, see create_car_data
	storage.chargers = storage.chargers or {}
	storage.charger_data = storage.charger_data or {}
	storage.garages = storage.garages or {}
	storage.garage_data = storage.garage_data or {}
	storage.supply_chests = storage.supply_chests or {}
	storage.ghosts = storage.ghosts or {} -- selected ghosts and entities marked for deconstruction or upgrade outside any robot network, assigned or not
	storage.target_by_registration = storage.target_by_registration or {} -- [registration number] = id of a tracked entity without unit_number
	storage.ghost_to_car = storage.ghost_to_car or {} -- [ghost unit_number] = unit_number of its car
	storage.pending_clusters = storage.pending_clusters or {} -- clusters waiting for a free car
	storage.path_requests = storage.path_requests or {} -- [request id] = unit_number of the car waiting for that path
	storage.idle_fallbacks = storage.idle_fallbacks or {} -- cars found in no state, see update_car
	storage.research = storage.research or {} -- [force index] = values read from the research, see _utils.get_upgrade
	storage.debug_view = storage.debug_view or {} -- [player index] = false or true when the player toggled the debug drawing, see debug_view.lua

	debug_view.sync_shortcuts()

	script.on_event(defines.events.on_tick, on_tick)
	on_tick(event)
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
	car_data.path.active = false -- the car arrived before the end of its path: it is of no use to the next leg
	car_data.path.waypoints = nil

	if _utils.deque.length(car_data.tasks) == 0 then
		-- Nothing queued (the car arrived from a step back, or is charged).
		if not ghost_control.try_assign_pending(car) then
			_utils.start_waiting(car_data)
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
		travel.reset_to_waiting(car)
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
	elseif task.type == "restock" then
		ghost_control.restock(car, destination)
	elseif task.type == "flee" then
		-- Safe for now: waits for the danger to pass, then the waiting loop resumes the batch.
		car_data.flee.active = false
		_utils.alert_reset(car_data.alerts, "flee")
		_utils.start_waiting(car_data, event.tick + config.long_delay - config.idle_delay)
	end
end

script.on_event(defines.events.on_built_entity, on_built)
script.on_event(defines.events.on_robot_built_entity, on_built)
script.on_event(defines.events.script_raised_built, on_built)
script.on_event(defines.events.script_raised_revive, on_built) -- a ghost built by a car (see ghost_control.revive_ghost)
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
	elseif event.prototype_name == names.debug_view_shortcut then
		debug_view.toggle(game.get_player(event.player_index))
	end
end)
script.on_event(defines.events.on_player_created, function(event)
	debug_view.sync_shortcut(game.get_player(event.player_index))
end)
script.on_event(defines.events.on_gui_click, function(event)
	gui.on_click(event)
	garage_gui.on_click(event)
end)
script.on_event(defines.events.on_gui_opened, function(event)
	garage_gui.on_opened(event)
	car_gui.on_opened(event)
end)
script.on_event(defines.events.on_gui_closed, function(event)
	garage_gui.on_closed(event)
	car_gui.on_closed(event)
end)
script.on_event(defines.events.on_script_path_request_finished, movement.on_path_finished)
commands.add_command("car-trace", "Writes a trace of the autonomous cars to script-output (see game_trace.lua). Optional argument: the unit number of one car. Run it again to stop.",
	function(command)
		game_trace.toggle(game.get_player(command.player_index), tonumber(command.parameter))
	end)
-- A research changes the values the script reads for its force (_utils.get_upgrade).
local function on_research_changed(event)
	_utils.clear_research_cache(event.research.force)
end

script.on_event(defines.events.on_research_finished, on_research_changed)
script.on_event(defines.events.on_research_reversed, on_research_changed)
script.on_event(defines.events.on_tick, init_storage)
