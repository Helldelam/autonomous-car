local config = require("config")

-- The small window that lists the items the cars are waiting for: the player
-- shows or hides it with a shortcut. It reads the batches in storage and
-- changes nothing there.
local gui = {}

local FRAME = "autonomous_car_missing_frame"
local CLOSE = "autonomous_car_missing_close"

-- ============================================================
-- Content
-- ============================================================

-- The items that cars wait for because no supply chest holds them (see
-- construction.missing_since in ghost.lua):
-- [item name] = {count = still to collect, cars = number of cars waiting for it}.
local function missing_items()
	local missing = {}
	for _, car_data in pairs(storage.car_data) do
		local construction = car_data.construction
		if construction and construction.missing_since then
			for item_name, count in pairs(construction.items_needed) do
				local entry = missing[item_name] or {count = 0, cars = 0}
				entry.count = entry.count + count
				entry.cars = entry.cars + 1
				missing[item_name] = entry
			end
		end
	end
	return missing
end

-- Item names in a fixed order, and a string that changes when the content does,
-- so that the window is only rebuilt when something changed.
local function sorted_signature(missing)
	local names = {}
	for item_name in pairs(missing) do
		table.insert(names, item_name)
	end
	table.sort(names)
	local parts = {}
	for _, item_name in ipairs(names) do
		table.insert(parts, item_name .. ":" .. missing[item_name].count .. ":" .. missing[item_name].cars)
	end
	return names, table.concat(parts, ",")
end

-- ============================================================
-- Window
-- ============================================================

local function build_body(frame, missing, names)
	local body = frame.add{type = "frame", name = "body", style = "inside_shallow_frame", direction = "vertical"}
	body.style.padding = 8
	if #names == 0 then
		body.add{type = "label", caption = {"autonomous-car-gui.nothing-missing"}}
		return
	end

	local list = body.add{type = "table", column_count = 3}
	list.style.horizontal_spacing = 12
	list.add{type = "label", caption = {"autonomous-car-gui.item"}, style = "bold_label"}
	list.add{type = "label", caption = {"autonomous-car-gui.count"}, style = "bold_label"}
	list.add{type = "label", caption = {"autonomous-car-gui.cars"}, style = "bold_label"}
	for _, item_name in ipairs(names) do
		local prototype = prototypes.item[item_name]
		list.add{
			type = "label",
			caption = {"", "[item=" .. item_name .. "] ", prototype and prototype.localised_name or item_name},
		}
		list.add{type = "label", caption = tostring(missing[item_name].count)}
		list.add{type = "label", caption = tostring(missing[item_name].cars)}
	end
end

local function refresh(player, missing, names, signature)
	local frame = player.gui.screen[FRAME]
	if not frame or (frame.tags and frame.tags.signature == signature) then
		return
	end
	if frame.body then
		frame.body.destroy()
	end
	build_body(frame, missing, names)
	frame.tags = {signature = signature}
end

local function open(player)
	local frame = player.gui.screen.add{type = "frame", name = FRAME, direction = "vertical"}
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

	local missing = missing_items()
	local names, signature = sorted_signature(missing)
	build_body(frame, missing, names)
	frame.tags = {signature = signature}
end

local function close(player)
	local frame = player.gui.screen[FRAME]
	if frame then
		frame.destroy()
	end
end

-- Shows the window, or hides it if it is shown, and moves the shortcut with it.
function gui.toggle(player)
	if player.gui.screen[FRAME] then
		close(player)
	else
		open(player)
	end
	player.set_shortcut_toggled(config.names.missing_items_shortcut, player.gui.screen[FRAME] ~= nil)
end

function gui.on_click(event)
	if event.element.valid and event.element.name == CLOSE then
		local player = game.get_player(event.player_index)
		close(player)
		player.set_shortcut_toggled(config.names.missing_items_shortcut, false)
	end
end

-- Called every config.short_delay ticks: updates the windows that are open.
function gui.refresh_all()
	local missing, names, signature
	for _, player in pairs(game.connected_players) do
		if player.gui.screen[FRAME] then
			if not signature then
				missing = missing_items()
				names, signature = sorted_signature(missing)
			end
			refresh(player, missing, names, signature)
		end
	end
end

return gui
