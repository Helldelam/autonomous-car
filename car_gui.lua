local config = require("config")
local _utils = require("_utils")

-- The panel next to the inventory of a car: what it is doing, its health, charge, batteries and
-- ammo, and its batch. It only reads the car and its state.
local car_gui = {}

local FRAME = "autonomous_car_car_frame"
-- Names of the labels; a name must not be a property of LuaGuiElement (state, ...), hence the prefix.
local STATE = "car_state"
local HEALTH = "car_health"
local FUEL = "car_fuel"
local AMMO = "car_ammo"
local BATCH = "car_batch"

-- The active tick states in the order update_car runs them, with the key of their text.
local STATES = {"empty", "moving", "charging", "parking", "building", "stuck", "waiting"}

-- Key of the text that tells what the car is doing.
local function get_state_key(car_data)
	if car_data.flee.active then
		return "fleeing"
	end
	for _, name in ipairs(STATES) do
		if car_data[name].active then
			return name
		end
	end
	return "waiting"
end

-- Text about the batch of the car: how many targets are left, and whether it waits for items.
local function make_batch_text(car_data)
	local construction = car_data.construction
	if not construction then
		return {"autonomous-car-gui.car-no-batch"}
	end
	local count = 0
	for _ in pairs(construction.ghosts) do
		count = count + 1
	end
	return {construction.missing_since and "autonomous-car-gui.car-batch-missing" or "autonomous-car-gui.car-batch", count}
end

-- Brings the panel up to date with its car.
local function refresh(frame)
	local car = storage.cars[frame.tags.car]
	if not (car and car.valid) then
		frame.destroy()
		return
	end
	local car_data = storage.car_data[car.unit_number]
	local ammo = _utils.get_ammo(car)
	frame[STATE].caption = {"autonomous-car-gui.car-state-" .. get_state_key(car_data)}
	frame[HEALTH].caption = {"autonomous-car-gui.car-health", math.floor(car.get_health_ratio() * 100 + 0.5)}
	frame[FUEL].caption = {"autonomous-car-gui.car-fuel", math.floor(_utils.get_fuel_ratio(car) * 100 + 0.5), _utils.get_battery_count(car)}
	frame[AMMO].caption = ammo and {"autonomous-car-gui.car-ammo", ammo.count} or {"autonomous-car-gui.car-no-ammo"}
	frame[BATCH].caption = make_batch_text(car_data)
end

local function open(player, car)
	if player.gui.relative[FRAME] then
		player.gui.relative[FRAME].destroy()
	end
	local frame = player.gui.relative.add{
		type = "frame", name = FRAME, direction = "vertical", caption = {"autonomous-car-gui.car-title"},
		anchor = {gui = defines.relative_gui_type.car_gui, position = defines.relative_gui_position.right, names = {config.names.car}},
	}
	frame.tags = {car = car.unit_number}
	frame.style.minimal_width = 300
	for _, name in ipairs{STATE, HEALTH, FUEL, AMMO, BATCH} do
		frame.add{type = "label", name = name}
	end
	refresh(frame)
end

function car_gui.on_opened(event)
	if event.gui_type == defines.gui_type.entity and event.entity and event.entity.name == config.names.car
			and storage.car_data[event.entity.unit_number] then
		open(game.get_player(event.player_index), event.entity)
	end
end

function car_gui.on_closed(event)
	if event.gui_type == defines.gui_type.entity and event.entity and event.entity.name == config.names.car then
		local frame = game.get_player(event.player_index).gui.relative[FRAME]
		if frame then
			frame.destroy()
		end
	end
end

-- Called every config.short_delay ticks: updates the panels that are open.
function car_gui.refresh_all()
	for _, player in pairs(game.connected_players) do
		local frame = player.gui.relative[FRAME]
		if frame then
			refresh(frame)
		end
	end
end

return car_gui
