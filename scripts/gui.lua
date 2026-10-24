local config = require("config")
local _utils = require("scripts._utils")
local garage_control = require("scripts.garage")

-- Interface: window of missing items, car and garage panels, tooltip lines, count next to the
-- selector. Read only, except the garage panel (load_car, hand_out_car).
local gui = {}

local names = config.names

-- ============================================================
-- Missing items window (shortcut)
-- ============================================================

local MISSING_FRAME = "autonomous_car_missing_frame"
local CLOSE = "autonomous_car_missing_close"

-- [item key] = {count, cars} of the batches waiting for items.
local function find_missing_items()
	local missing = {}
	for _, car_data in pairs(storage.car_data) do
		local construction = car_data.construction
		if construction and construction.missing_since then
			for key, count in pairs(construction.items_needed) do
				local entry = missing[key] or {count = 0, cars = 0}
				entry.count = entry.count + count
				entry.cars = entry.cars + 1
				missing[key] = entry
			end
		end
	end
	return missing
end

-- Sorted keys and a signature: the window is rebuilt only when it changes.
local function build_signature(missing)
	local keys = {}
	for key in pairs(missing) do
		table.insert(keys, key)
	end
	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do
		table.insert(parts, key .. ":" .. missing[key].count .. ":" .. missing[key].cars)
	end
	return keys, table.concat(parts, ",")
end

local function build_body(frame, missing, keys)
	local body = frame.add{type = "frame", name = "body", style = "inside_shallow_frame", direction = "vertical"}
	body.style.padding = 8
	if #keys == 0 then
		body.add{type = "label", caption = {"autonomous-car-gui.nothing-missing"}}
		return
	end

	local list = body.add{type = "table", column_count = 3}
	list.style.horizontal_spacing = 12
	list.add{type = "label", caption = {"autonomous-car-gui.item"}, style = "bold_label"}
	list.add{type = "label", caption = {"autonomous-car-gui.count"}, style = "bold_label"}
	list.add{type = "label", caption = {"autonomous-car-gui.cars"}, style = "bold_label"}
	for _, key in ipairs(keys) do
		local item_name, quality = _utils.split_item_key(key)
		local prototype = prototypes.item[item_name]
		local icon = "[item=" .. item_name .. (quality and ",quality=" .. quality or "") .. "] "
		local caption = {"", icon, prototype and prototype.localised_name or item_name}
		if quality and prototypes.quality[quality] then
			caption = {"", icon, prototype and prototype.localised_name or item_name, " (", prototypes.quality[quality].localised_name, ")"}
		end
		list.add{type = "label", caption = caption}
		list.add{type = "label", caption = tostring(missing[key].count)}
		list.add{type = "label", caption = tostring(missing[key].cars)}
	end
end

local function set_body(frame, missing, keys, signature)
	if frame.body then
		frame.body.destroy()
	end
	build_body(frame, missing, keys)
	frame.tags = {signature = signature}
end

local function refresh_missing(player, missing, keys, signature)
	local frame = player.gui.screen[MISSING_FRAME]
	if frame and not (frame.tags and frame.tags.signature == signature) then
		set_body(frame, missing, keys, signature)
	end
end

local function open_missing(player)
	local frame = player.gui.screen.add{type = "frame", name = MISSING_FRAME, direction = "vertical"}
	frame.auto_center = true

	local bar = frame.add{type = "flow", direction = "horizontal"}
	bar.drag_target = frame
	bar.add{type = "label", caption = {"autonomous-car-gui.title"}, style = "frame_title", ignored_by_interaction = true}
	local filler = bar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
	filler.style.horizontally_stretchable = true
	filler.style.height = 24
	bar.add{
		type = "sprite-button", name = CLOSE, style = "frame_action_button", sprite = "utility/close",
		tooltip = {"gui.close"},
	}

	local missing = find_missing_items()
	local keys, signature = build_signature(missing)
	set_body(frame, missing, keys, signature)
end

local function close_missing(player)
	local frame = player.gui.screen[MISSING_FRAME]
	if frame then
		frame.destroy()
	end
end

-- Shows or hides the window, and toggles the shortcut with it.
function gui.toggle_missing_items(player)
	if player.gui.screen[MISSING_FRAME] then
		close_missing(player)
	else
		open_missing(player)
	end
	player.set_shortcut_toggled(names.missing_items_shortcut, player.gui.screen[MISSING_FRAME] ~= nil)
end

-- ============================================================
-- Garage panel (beside its inventory)
-- ============================================================

local GARAGE_FRAME = "autonomous_car_garage_frame"
local COUNT = "count"
local LIST = "list"
local TAKE = "autonomous_car_garage_take"

local function make_line(index, entry)
	local ammo = entry.ammo and entry.ammo.count or 0
	return {"autonomous-car-gui.garage-car", index, math.floor(entry.health * 100 + 0.5),
		math.floor(entry.fuel * 100 + 0.5), entry.batteries or 0, ammo}
end

local function find_garage(frame)
	local garage = storage.garages[frame.tags.garage]
	return garage and garage.valid and garage or nil
end

-- The battery and ammo slots refill the selected car; the selection stays on its place.
local function refresh_garage(frame)
	local garage = find_garage(frame)
	if not garage then
		frame.destroy()
		return
	end
	local cars = storage.garage_data[garage.unit_number].cars
	local list = frame[LIST]
	local selected = list.selected_index
	if selected > 0 then
		garage_control.load_car(garage, selected)
	end
	local lines = {}
	for index, entry in ipairs(cars) do
		lines[index] = make_line(index, entry)
	end
	list.items = lines
	list.selected_index = selected <= #lines and selected or 0
	frame[COUNT].caption = {"autonomous-car-gui.garage-count", #cars, garage_control.get_capacity(garage)}
	frame[TAKE].enabled = #cars > 0
end

local function open_garage(player, garage)
	if player.gui.relative[GARAGE_FRAME] then
		player.gui.relative[GARAGE_FRAME].destroy()
	end
	local frame = player.gui.relative.add{
		type = "frame", name = GARAGE_FRAME, direction = "vertical", caption = {"autonomous-car-gui.garage-title"},
		anchor = {gui = defines.relative_gui_type.container_gui, position = defines.relative_gui_position.right, names = {names.garage}},
	}
	frame.tags = {garage = garage.unit_number}
	frame.add{type = "label", name = COUNT}
	frame.add{type = "label", caption = {"autonomous-car-gui.garage-refill"}}
	local list = frame.add{type = "list-box", name = LIST}
	list.style.minimal_width = 360
	list.style.height = 300
	frame.add{type = "button", name = TAKE, caption = {"autonomous-car-gui.garage-take"}, tooltip = {"autonomous-car-gui.garage-take-tooltip"}}
	refresh_garage(frame)
end

-- ============================================================
-- Car panel (beside its inventory)
-- ============================================================

local CAR_FRAME = "autonomous_car_car_frame"
-- Label names: prefixed, a name must not be a property of LuaGuiElement (state...).
local STATE = "car_state"
local HEALTH = "car_health"
local FUEL = "car_fuel"
local AMMO = "car_ammo"
local BATCH = "car_batch"

local STATES = {"empty", "moving", "charging", "parking", "building", "stuck", "waiting"} -- in the order of update_car

local function get_state_text(car_data)
	if car_data.flee.active then
		return {"autonomous-car-gui.car-state-fleeing"}
	end
	for _, name in ipairs(STATES) do
		if car_data[name].active then
			return {"autonomous-car-gui.car-state-" .. name}
		end
	end
	return {"autonomous-car-gui.car-state-waiting"}
end

local function get_work_text(car_data)
	local construction = car_data.construction
	if not construction then
		return {"autonomous-car-gui.work-none"}
	end
	local count = 0
	for _ in pairs(construction.ghosts) do
		count = count + 1
	end
	return {construction.missing_since and "autonomous-car-gui.work-missing" or "autonomous-car-gui.work-targets", count}
end

local function refresh_car(frame)
	local car = storage.cars[frame.tags.car]
	if not (car and car.valid) then
		frame.destroy()
		return
	end
	local car_data = storage.car_data[car.unit_number]
	local ammo = _utils.get_ammo(car)
	frame[STATE].caption = get_state_text(car_data)
	frame[HEALTH].caption = {"autonomous-car-gui.car-health", math.floor(car.get_health_ratio() * 100 + 0.5)}
	frame[FUEL].caption = {"autonomous-car-gui.car-fuel", math.floor(_utils.get_fuel_ratio(car) * 100 + 0.5), _utils.get_battery_count(car)}
	frame[AMMO].caption = ammo and {"autonomous-car-gui.car-ammo", ammo.count} or {"autonomous-car-gui.car-no-ammo"}
	frame[BATCH].caption = {"autonomous-car-gui.car-batch", get_work_text(car_data)}
end

local function open_car(player, car)
	if player.gui.relative[CAR_FRAME] then
		player.gui.relative[CAR_FRAME].destroy()
	end
	local frame = player.gui.relative.add{
		type = "frame", name = CAR_FRAME, direction = "vertical", caption = {"autonomous-car-gui.car-title"},
		anchor = {gui = defines.relative_gui_type.car_gui, position = defines.relative_gui_position.right, names = {names.car}},
	}
	frame.tags = {car = car.unit_number}
	frame.style.minimal_width = 300
	for _, name in ipairs{STATE, HEALTH, FUEL, AMMO, BATCH} do
		frame.add{type = "label", name = name}
	end
	refresh_car(frame)
end

-- ============================================================
-- Events
-- ============================================================

function gui.on_click(event)
	local element = event.element
	if not element.valid then
		return
	end
	local player = game.get_player(event.player_index)
	if element.name == CLOSE then
		close_missing(player)
		player.set_shortcut_toggled(names.missing_items_shortcut, false)
	elseif element.name == TAKE then
		local frame = player.gui.relative[GARAGE_FRAME]
		local garage = frame and find_garage(frame)
		if garage then
			local index = frame[LIST].selected_index
			if not garage_control.hand_out_car(garage, player, index > 0 and index or 1) then
				player.print({"autonomous-car-messages.garage-no-room"})
			end
			refresh_garage(frame)
		end
	end
end

function gui.on_opened(event)
	local entity = event.entity
	if event.gui_type ~= defines.gui_type.entity or not entity then
		return
	end
	if entity.name == names.garage then
		open_garage(game.get_player(event.player_index), entity)
	elseif entity.name == names.car and storage.car_data[entity.unit_number] then
		open_car(game.get_player(event.player_index), entity)
	end
end

function gui.on_closed(event)
	local entity = event.entity
	if event.gui_type ~= defines.gui_type.entity or not entity then
		return
	end
	local frame_name = (entity.name == names.garage and GARAGE_FRAME) or (entity.name == names.car and CAR_FRAME)
	local frame = frame_name and game.get_player(event.player_index).gui.relative[frame_name]
	if frame then
		frame.destroy()
	end
end

-- Every config.short_delay ticks: the open windows and panels.
function gui.refresh_all()
	local missing, keys, signature
	for _, player in pairs(game.connected_players) do
		if player.gui.screen[MISSING_FRAME] then
			if not signature then
				missing = find_missing_items()
				keys, signature = build_signature(missing)
			end
			refresh_missing(player, missing, keys, signature)
		end
		local garage_frame = player.gui.relative[GARAGE_FRAME]
		if garage_frame then
			refresh_garage(garage_frame)
		end
		local car_frame = player.gui.relative[CAR_FRAME]
		if car_frame then
			refresh_car(car_frame)
		end
	end
end

-- ============================================================
-- Tooltip lines (set_tooltip_field) of the entity under the cursor
-- ============================================================

local function percent(ratio)
	return {"autonomous-car-gui.percent", math.floor(ratio * 100 + 0.5)}
end

local function ratio(count, total)
	return {"autonomous-car-gui.ratio", count, total}
end

-- {key suffix, value} lines of a tracked entity of the mod, or nil.
local function get_lines(entity)
	local id = entity.unit_number
	if entity.name == names.car then
		local car_data = storage.car_data[id]
		return car_data and {
			{"state", get_state_text(car_data)},
			{"charge", percent(_utils.get_fuel_ratio(entity))},
			{"batteries", tostring(_utils.get_battery_count(entity))},
			{"work", get_work_text(car_data)},
		}
	elseif entity.name == names.garage then
		local garage_data = storage.garage_data[id]
		return garage_data and {
			{"parked", ratio(#garage_data.cars, garage_control.get_capacity(entity))},
		}
	elseif entity.name == names.charger then
		local charger_data = storage.charger_data[id]
		return charger_data and entity.electric_buffer_size > 0 and {
			{"energy", percent(entity.energy / entity.electric_buffer_size)},
			{"places", ratio(charger_data.users, _utils.get_upgrade(entity.force, "chargers"))},
		}
	end
	return nil
end

-- Every config.slow_check_interval ticks; the lines stay on the entity (at most that late).
function gui.refresh_tooltips()
	for _, player in pairs(game.connected_players) do
		local entity = player.selected
		local lines = entity and get_lines(entity)
		if lines then
			for index, line in ipairs(lines) do
				entity.set_tooltip_field{id = index, order = index, name = {"autonomous-car-gui.tooltip-" .. line[1]}, value = line[2]}
			end
		end
	end
end

-- ============================================================
-- Count next to the cursor while dragging the selector (pre-selection events)
-- ============================================================
-- Counted by the game, whatever the size; includes what robots cover or a car already has.

local OFFSET = {1, 1} -- tiles from the cursor

function gui.hide_selection_preview(event)
	local text = storage.selection_previews[event.player_index]
	if text then
		if text.valid then
			text.destroy()
		end
		storage.selection_previews[event.player_index] = nil
	end
end

-- Lasts config.long_delay at most: the end of a selection is only reported "best effort".
function gui.show_selection_preview(event)
	if event.item ~= names.ghost_selector then
		return
	end
	gui.hide_selection_preview(event)
	local player = game.get_player(event.player_index)
	local surface, area = event.surface, event.area
	storage.selection_previews[event.player_index] = rendering.draw_text{
		text = {"autonomous-car-messages.selection-preview",
			surface.count_entities_filtered{area = area, type = {"entity-ghost", "tile-ghost"}, force = player.force},
			surface.count_entities_filtered{area = area, to_be_deconstructed = true},
			surface.count_entities_filtered{area = area, to_be_upgraded = true, force = player.force}},
		surface = surface, target = {type = "cursor", offset = OFFSET}, players = {player},
		color = {1, 1, 1}, scale_with_zoom = true, time_to_live = config.long_delay,
	}
end

return gui
