local config = require("config")
local garage_control = require("scripts.garage")

-- The panel next to the inventory of a garage: how many cars it holds, the list of the parked
-- cars (first out first) with their state, and a button that gives the selected car, or the
-- first one, to the player (the car, its batteries and its ammo as items, if there is room for
-- all). It reads the list of the garage and only changes it through
-- garage_control.hand_out_car and garage_control.load_car (the battery and ammo slots refill the
-- selected car).
local garage_gui = {}

local FRAME = "autonomous_car_garage_frame"
local COUNT = "count"
local LIST = "list"
local TAKE = "autonomous_car_garage_take"

-- One line of the list: place, health, fuel, batteries and ammo of a parked car.
local function make_line(index, entry)
	local ammo = entry.ammo and entry.ammo.count or 0
	return {"autonomous-car-gui.garage-car", index, math.floor(entry.health * 100 + 0.5),
		math.floor(entry.fuel * 100 + 0.5), entry.batteries or 0, ammo}
end

-- Garage shown by the panel of a player, or nil if it is gone.
local function find_garage(frame)
	local garage = storage.garages[frame.tags.garage]
	return garage and garage.valid and garage or nil
end

-- Brings the panel up to date with the list of its garage; the selection stays on the same place.
local function refresh(frame)
	local garage = find_garage(frame)
	if not garage then
		frame.destroy()
		return
	end
	local cars = storage.garage_data[garage.unit_number].cars
	local list = frame[LIST]
	local selected = list.selected_index
	-- What lies in the battery and ammo slots goes to the selected car.
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

local function open(player, garage)
	if player.gui.relative[FRAME] then
		player.gui.relative[FRAME].destroy()
	end
	local frame = player.gui.relative.add{
		type = "frame", name = FRAME, direction = "vertical", caption = {"autonomous-car-gui.garage-title"},
		anchor = {gui = defines.relative_gui_type.container_gui, position = defines.relative_gui_position.right, names = {config.names.garage}},
	}
	frame.tags = {garage = garage.unit_number}
	frame.add{type = "label", name = COUNT}
	frame.add{type = "label", caption = {"autonomous-car-gui.garage-refill"}}
	local list = frame.add{type = "list-box", name = LIST}
	list.style.minimal_width = 360
	list.style.height = 300
	frame.add{type = "button", name = TAKE, caption = {"autonomous-car-gui.garage-take"}, tooltip = {"autonomous-car-gui.garage-take-tooltip"}}
	refresh(frame)
end

function garage_gui.on_opened(event)
	if event.gui_type == defines.gui_type.entity and event.entity and event.entity.name == config.names.garage then
		open(game.get_player(event.player_index), event.entity)
	end
end

function garage_gui.on_closed(event)
	if event.gui_type == defines.gui_type.entity and event.entity and event.entity.name == config.names.garage then
		local frame = game.get_player(event.player_index).gui.relative[FRAME]
		if frame then
			frame.destroy()
		end
	end
end

function garage_gui.on_click(event)
	if not (event.element.valid and event.element.name == TAKE) then
		return
	end
	local player = game.get_player(event.player_index)
	local frame = player.gui.relative[FRAME]
	local garage = frame and find_garage(frame)
	if not garage then
		return
	end
	local index = frame[LIST].selected_index
	if not garage_control.hand_out_car(garage, player, index > 0 and index or 1) then
		player.print({"autonomous-car-messages.garage-no-room"})
	end
	refresh(frame)
end

-- Called every config.short_delay ticks: updates the panels that are open.
function garage_gui.refresh_all()
	for _, player in pairs(game.connected_players) do
		local frame = player.gui.relative[FRAME]
		if frame then
			refresh(frame)
		end
	end
end

return garage_gui
