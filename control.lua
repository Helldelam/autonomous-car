-- Control stage: storage, entity tracking, and the per-tick dispatch of each car's state.
local config = require("config")
local _utils = require("scripts._utils")
local movement = require("scripts.movement")
local travel = require("scripts.travel")
local charger_control = require("scripts.charger")
local garage_control = require("scripts.garage")
local chest_control = require("scripts.chest")
local ghost_control = require("scripts.construction")
local gui = require("scripts.gui")
local circuit_control = require("scripts.circuit")
local game_trace = require("scripts.game_trace")
local armed = require("scripts.armed")

local names = config.names

-- ============================================================
-- Entity tracking
-- ============================================================

-- Run by _utils.release_entity for an entity that is gone.
_utils.register_release_handler("car", function(id)
	local car_data = storage.car_data[id]
	if car_data then
		travel.release_charger_slot(car_data)
		travel.requeue_construction(car_data)
		armed.release(car_data)
	end
	storage.cars[id] = nil
	storage.car_data[id] = nil
end)
_utils.register_release_handler("charger", function(id)
	circuit_control.destroy_link(storage.charger_data[id])
	charger_control.release_posts(storage.charger_data[id])
	storage.chargers[id] = nil
	_utils.remove_from_regions("chargers", id)
	storage.charger_data[id] = nil
end)
_utils.register_release_handler("garage", function(id)
	circuit_control.destroy_link(storage.garage_data[id])
	garage_control.release_door(id)
	storage.garages[id] = nil
	_utils.remove_from_regions("garages", id)
	storage.garage_data[id] = nil
end)
_utils.register_release_handler("chest", function(id)
	chest_control.release_hatch(id)
	storage.supply_chests[id] = nil
	_utils.remove_from_regions("supply_chests", id)
end)

local KIND_BY_NAME = {
	[names.car] = "car",
	[names.charger] = "charger",
	[names.garage] = "garage",
	[names.chest] = "chest",
	[names.delivery_chest] = "chest",
	[names.return_chest] = "chest",
}

-- Build and removal events reach the script for these entities only.
local ENTITY_FILTERS = {}
for _, name in ipairs{names.car, names.charger, names.garage, names.chest, names.delivery_chest, names.return_chest} do
	table.insert(ENTITY_FILTERS, {filter = "name", name = name})
end

-- storage.car_data[unit_number].
local function create_car_data(tick)
	return {
		-- States: each tick runs the first active one, in the order of update_car.
		moving = {
			active = false,
			destination = nil, -- entity, or {position, valid}
			departure_tick = nil, departure_distance = nil, -- travel.is_leg_too_long
		},
		charging = {active = false, charger = nil},
		parking = {active = false, garage = nil},
		building = {active = false, next_attempt_tick = 0}, -- active once stopped at the site
		stuck = {active = false, since = 0, final = false, destination = nil}, -- final: abandons instead of retrying
		empty = {active = false}, -- battery empty (travel.handle_empty)
		waiting = {active = true, since = tick - config.idle_delay}, -- elapsed: a new car looks for work at once

		-- Driving (movement.lua); travel.lua only cancels a maneuver and resets the path of a new leg.
		maneuver = {active = false, ended_tick = tick}, -- other fields: movement.start_maneuver
		path = travel.create_path_state(),
		emergency_brake = {active = false, since = nil},
		mode = "normal", -- "fast", "normal" or "slow" (movement.update_mode)
		slow_until = nil,
		near_built = false,
		density = nil, tile_friction = nil, -- slow checks
		entry_speed = nil, -- on entering fast mode
		slowing = false, -- braking to entry_speed after fast mode
		neighbours = nil, -- moving cars nearby

		construction = nil, -- batch (construction.lua)
		tasks = _utils.deque.new(), -- next steps, front first

		flee = {active = false, count = 0}, -- active on the way to the refuge; count: flights of this batch
		just_left_garage = false, -- restock stop first (ghost_control.proceed), until the chest is reached
		turret = nil, turret_ammo = nil, -- armed.lua

		-- Failures (travel.lua).
		charge_detour_count = 0,
		stuck_retry_count = 0,
		unreachable_since = nil,
		critical_fuel_retry_tick = nil,
		alerts = {}, -- alert_once flags
	}
end

-- Built by a player, a robot or a script. Ghosts are tracked only once selected.
local function on_built(event)
	local entity = event.entity
	local id = entity.unit_number

	if entity.name == names.car then
		entity.friction_modifier = config.friction.normal
		entity.color = config.car_color
		entity.riding_state = {acceleration = defines.riding.acceleration.nothing, direction = defines.riding.direction.straight}
		_utils.set_fuel_item(entity)
		_utils.set_trunk_limits(entity)
		if _utils.get_fuel(entity) == 0 then -- new car
			_utils.set_fuel(entity, _utils.get_fuel_capacity(entity) * config.critical_fuel_ratio)
		end
		storage.cars[id] = entity
		storage.car_data[id] = create_car_data(event.tick)
	elseif entity.name == names.charger then
		storage.chargers[id] = entity
		_utils.add_to_regions("chargers", entity)
		charger_control.update_buffer(entity)
		-- users: charging or on the way; transferred: since the last link refresh (circuit.lua)
		storage.charger_data[id] = {users = 0, transferred = 0, posts = {}}
		charger_control.update_posts(entity)
	elseif entity.name == names.garage then
		storage.garages[id] = entity
		_utils.add_to_regions("garages", entity)
		garage_control.update_inventory(entity)
		-- cars: parked, first in first out; exit_tick, exit_count: garage_control.can_release_car
		storage.garage_data[id] = {cars = {}, alerts = {}, exit_count = 0}
	elseif KIND_BY_NAME[entity.name] == "chest" then
		storage.supply_chests[id] = entity
		_utils.add_to_regions("supply_chests", entity)
	end
end

local function on_removed(event)
	local kind = KIND_BY_NAME[event.entity.name]
	if kind == "garage" then
		garage_control.return_cars(event.entity, event.buffer, event.player_index and game.get_player(event.player_index))
	end
	if kind then
		_utils.release_entity(kind, event.entity.unit_number)
	end
end

-- Registered targets only (ghost_control.register_ghost); one without unit_number by its registration.
local function on_object_destroyed(event)
	local id = storage.target_by_registration[event.registration_number]
	storage.target_by_registration[event.registration_number] = nil
	ghost_control.on_ghost_destroyed(id or event.useful_id)
end

-- Ghost selector: the new targets are registered and clustered, over several ticks if needed
-- (storage.selection_job), then the clusters are given out; one selection at a time.
local finish_selection
local function on_area_selected(event)
	if event.item ~= names.ghost_selector then
		return
	end
	gui.hide_selection_preview(event)

	local player = game.get_player(event.player_index)
	if storage.selection_job then
		if player then
			player.print({"autonomous-car-messages.selection-busy"})
		end
		return
	end

	local job = ghost_control.start_selection(event.entities, player and player.force or game.forces.player)
	job.player_index = event.player_index
	if ghost_control.step_selection(job) then
		finish_selection(job)
	else
		storage.selection_job = job
		if player then
			player.print({"autonomous-car-messages.selection-clustering", #event.entities})
		end
	end
end

-- Offers the pending clusters to the cars and tells the player.
local function give_out_clusters(player)
	local any_car = ghost_control.is_any_car_present()
	local assigned = ghost_control.retry_pending_clusters()
	local queued = #storage.pending_clusters

	if player then
		-- A line per batch type that got one (landfill counts as construction).
		local build_count = (assigned.build or 0) + (assigned.landfill or 0)
		if (assigned.deconstruct or 0) > 0 then
			player.print({"autonomous-car-messages.assigned-deconstruct", assigned.deconstruct})
		end
		if build_count > 0 then
			player.print({"autonomous-car-messages.assigned-build", build_count})
		end
		if (assigned.upgrade or 0) > 0 then
			player.print({"autonomous-car-messages.assigned-upgrade", assigned.upgrade})
		end
		if (assigned.network or 0) > 0 then
			player.print({"autonomous-car-messages.assigned-network", assigned.network})
		end
		if queued > 0 then
			if storage.assignment_backlog then
				player.print({"autonomous-car-messages.selection-giving-out", queued})
			elseif any_car then
				player.print({"autonomous-car-messages.queued-waiting", queued})
			else
				player.print({"autonomous-car-messages.queued-no-car", queued})
			end
		end
	end
end

function finish_selection(job)
	local player = game.get_player(job.player_index)
	if job.count > 0 then
		give_out_clusters(player)
	elseif player then
		player.print({"autonomous-car-messages.selection-empty"})
	end
end

-- ============================================================
-- Tick
-- ============================================================

-- An idle car resumes its batch, takes a pending cluster, or parks (topped up first).
-- Starting a leg ends the wait: only the branches that do nothing restart it.
local function end_wait(car, car_data, tick)
	if car_data.construction then
		ghost_control.proceed(car) -- waiting for missing items
	elseif _utils.deque.length(car_data.tasks) > 0 then
		-- tasks of a leg that no longer exists
		car_data.tasks = _utils.deque.new()
		car_data.waiting.since = tick
	elseif not _utils.is_cargo_empty(car) then
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
			local chest = ghost_control.find_restock_chest(car) -- batteries and ammo, if a chest has some
			if chest then
				travel.set_destination(car, chest, {type = "restock"})
			else
				travel.set_destination(car, garage, {type = "parking"})
			end
		end
	end
end

-- Every slow_check_interval, a moving or building car with an enemy within flee.radius flees
-- (travel.start_flee); past flee.max_count it abandons its batch, then ignores enemies. Not while
-- the fuel is critical. True when it took over the car this tick.
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
		ghost_control.abandon(car, {"autonomous-car-messages.alert-abandoned-danger"})
		return true
	end
	travel.start_flee(car, travel.find_refuge(car, enemy))
	return true
end

local function update_car(car, car_data, tick)
	if travel.handle_empty(car, tick) or travel.handle_critical_fuel(car, tick) or handle_danger(car, car_data, tick) then
		return
	end

	if car_data.moving.active then
		local destination = car_data.moving.destination
		if destination and destination.valid then
			-- update_mode sets what drive_tick reads this tick, and may start a maneuver: keep the order.
			movement.update_mode(car, tick)
			if car_data.maneuver.active then
				if movement.maneuver_tick(car, tick) then
					travel.start_stuck(car, tick) -- last maneuver failed
				end
			else
				movement.drive_tick(car, tick)
			end

			-- A leg still under way, not waiting for its path: too long, a rescue path, else stuck.
			if car_data.moving.active and not car_data.path.pending then
				if travel.is_leg_too_long(car, tick) then
					if not movement.request_path(car, tick) then
						travel.start_stuck(car, tick)
					end
				end
			end
		else
			travel.reset_to_waiting(car) -- destination gone (built by a robot, mined...)
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
		-- spread over short_delay by unit number: not every car decides on the same tick
		if tick - car_data.waiting.since >= config.idle_delay + car.unit_number % config.short_delay then
			end_wait(car, car_data, tick)
		end
	else
		-- Safety net (a bug elsewhere): back to waiting, recorded for the tests (NOSTATE).
		table.insert(storage.idle_fallbacks, {tick = tick, car = car.unit_number, surface = car.surface.index})
		log("autonomous car " .. car.unit_number .. " had no state at tick " .. tick .. ", set to waiting")
		travel.reset_to_waiting(car)
	end
end

local function on_tick(event)
	ghost_control.update_chest_visits(event.tick) -- before the cars: a visit ends on the tick its car stops waiting
	for id, car in pairs(storage.cars) do
		if car.valid then
			if _utils.is_slow_check_due(car, event.tick) then -- no event for a changed filter
				_utils.set_trunk_limits(car)
				armed.update(car, storage.car_data[id])
			end
			update_car(car, storage.car_data[id], event.tick)
			if storage.game_trace and car.valid then -- gone once parked
				game_trace.record(car, storage.car_data[id], event.tick)
			end
		else
			_utils.release_entity("car", id)
		end
	end

	if event.tick % config.short_delay == 0 then
		gui.refresh_all()
	end
	if event.tick % config.slow_check_interval == 0 then
		gui.refresh_tooltips()
	end
	-- Buildings: each on its own tick of the period (_utils.is_slow_check_due).
	garage_control.update_doors(event.tick)
	chest_control.update_hatches()
	charger_control.refresh_arcs(event.tick)
	circuit_control.refresh(event.tick)
	chest_control.update_requests(event.tick)
	garage_control.update_inventories(event.tick)
	garage_control.repair_parked_cars(event.tick)
	charger_control.update_buffers(event.tick)
	local long_tick = event.tick % config.long_delay == 0
	ghost_control.refresh_pending_clusters(long_tick)
	if long_tick or storage.assignment_backlog or (storage.assignment_wake_tick and event.tick >= storage.assignment_wake_tick) then
		ghost_control.retry_pending_clusters()
	end
	local job = storage.selection_job
	if job and ghost_control.step_selection(job) then
		storage.selection_job = nil
		finish_selection(job)
	end
end

-- Bound to on_tick rather than on_init, so that a save made before a table existed gets it; then
-- hands over to on_tick and runs it for this tick (a joining player must not skip one).
local function init_storage(event)
	storage.cars = storage.cars or {} -- [unit_number] = car
	storage.car_data = storage.car_data or {} -- [unit_number] = create_car_data
	storage.chargers = storage.chargers or {}
	storage.charger_data = storage.charger_data or {}
	storage.garages = storage.garages or {}
	storage.garage_data = storage.garage_data or {}
	storage.garage_doors = storage.garage_doors or {} -- [garage id] = moving door (garage.lua)
	storage.chest_doors = storage.chest_doors or {} -- [chest id] = open or moving hatch (chest.lua)
	storage.chest_visits = storage.chest_visits or {} -- [car id] = visit (ghost_control.start_chest_visit)
	storage.charger_arcs = storage.charger_arcs or {} -- [car id] = arc (charger.lua)
	storage.supply_chests = storage.supply_chests or {}
	-- _utils.find_closest: .cells[surface index]["x,y"] = {[id] = true}, .where[id] = {surface index, "x,y"}
	storage.regions = storage.regions or {}
	for _, group in pairs{"chargers", "garages", "supply_chests"} do
		storage.regions[group] = storage.regions[group] or {cells = {}, where = {}}
	end
	storage.ghosts = storage.ghosts or {} -- selected targets outside robot networks, assigned or not
	storage.target_by_registration = storage.target_by_registration or {} -- [registration number] = id of a target without unit_number
	storage.ghost_to_car = storage.ghost_to_car or {} -- [ghost id] = car id
	storage.pending_clusters = storage.pending_clusters or {}
	-- storage.selection_job: nil when idle (ghost_control.start_selection)
	storage.assignment_backlog = storage.assignment_backlog or false -- clusters given out over several ticks
	storage.path_requests = storage.path_requests or {} -- [request id] = car id
	storage.idle_fallbacks = storage.idle_fallbacks or {} -- cars found in no state (update_car)
	storage.research = storage.research or {} -- [force index] = _utils.get_upgrade cache
	storage.selection_previews = storage.selection_previews or {} -- [player index] = text by the cursor (gui.lua)

	script.on_event(defines.events.on_tick, on_tick)
	on_tick(event)
end

-- A car arrived or is charged: the task queued for that moment starts (travel.begin_leg).
local function on_next_task(event)
	local car = event.entity
	local car_data = storage.car_data[car.unit_number]
	local moving = car_data.moving

	car_data.stuck_retry_count = 0

	local destination = moving.destination
	moving.active = false
	moving.destination = nil
	car_data.path.active = false
	car_data.path.waypoints = nil

	if _utils.deque.length(car_data.tasks) == 0 then -- back from a step back, or charged
		if not ghost_control.try_assign_pending(car) then
			_utils.start_waiting(car_data)
		end
		return
	end

	local task = _utils.deque.pop_front(car_data.tasks)
	if task.type ~= "charging" then
		car_data.charge_detour_count = 0
	end

	-- A task that does not match what was reached is stale.
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
	elseif task.type == "collect" or task.type == "deposit" or task.type == "restock" then
		ghost_control.start_chest_visit(car, destination, task.type)
	elseif task.type == "flee" then
		-- at the refuge: waits long_delay, then resumes
		car_data.flee.active = false
		_utils.alert_reset(car_data.alerts, "flee")
		_utils.start_waiting(car_data, event.tick + config.long_delay - config.idle_delay)
	end
end

script.on_event(defines.events.on_built_entity, on_built, ENTITY_FILTERS)
script.on_event(defines.events.on_robot_built_entity, on_built, ENTITY_FILTERS)
script.on_event(defines.events.script_raised_built, on_built, ENTITY_FILTERS)
script.on_event(defines.events.script_raised_revive, on_built, ENTITY_FILTERS) -- built by a car
script.on_event(defines.events.on_entity_died, on_removed, ENTITY_FILTERS)
script.on_event(defines.events.on_player_mined_entity, on_removed, ENTITY_FILTERS)
script.on_event(defines.events.on_robot_mined_entity, on_removed, ENTITY_FILTERS)
script.on_event(defines.events.script_raised_destroy, on_removed, ENTITY_FILTERS) -- by another mod, or mined by a car
script.on_event(defines.events.on_object_destroyed, on_object_destroyed)
script.on_event(defines.events.on_player_selected_area, on_area_selected)
script.on_event(defines.events.on_player_alt_selected_area, on_area_selected)
script.on_event(defines.events.on_player_start_selected_area, gui.show_selection_preview)
script.on_event(defines.events.on_player_change_selected_area, gui.show_selection_preview)
script.on_event(defines.events.on_player_cancel_selected_area, gui.hide_selection_preview)
script.on_event(prototypes.custom_event[names.next_task_event], on_next_task)
script.on_event(defines.events.on_lua_shortcut, function(event)
	if event.prototype_name == names.missing_items_shortcut then
		gui.toggle_missing_items(game.get_player(event.player_index))
	end
end)
script.on_event(defines.events.on_gui_click, gui.on_click)
script.on_event(defines.events.on_gui_opened, gui.on_opened)
script.on_event(defines.events.on_gui_closed, gui.on_closed)
script.on_event(defines.events.on_script_path_request_finished, movement.on_path_finished)
commands.add_command("car-trace", {"autonomous-car-messages.command-car-trace"},
	function(command)
		game_trace.toggle(command.player_index and game.get_player(command.player_index), tonumber(command.parameter))
	end)
-- Research changes the values read for its force (_utils.get_upgrade).
local function on_research_changed(event)
	_utils.clear_research_cache(event.research.force)
end

script.on_event(defines.events.on_research_finished, on_research_changed)
script.on_event(defines.events.on_research_reversed, on_research_changed)
-- An update of a mod or of the game may change technologies and upgrade values without a research event.
script.on_configuration_changed(function()
	storage.research = {}
end)
script.on_event(defines.events.on_tick, init_storage)
