local config = require("config")
local _utils = require("scripts._utils")
local garage_control = require("scripts.garage")
local car_gui = require("scripts.gui.car")

-- Lines added to the tooltip of the cars, garages and chargers (LuaEntity.set_tooltip_field):
-- what a car is doing, its charge, batteries and work; how many cars a garage holds; how full a
-- charger is and how many of its places are taken. Only the entity under the cursor of a player is
-- brought up to date: the lines stay on the entity, so a tooltip shows them at most
-- config.slow_check_interval ticks late. It only reads the state.
local tooltips = {}

local names = config.names

local function percent(ratio)
	return {"autonomous-car-gui.percent", math.floor(ratio * 100 + 0.5)}
end

local function ratio(count, total)
	return {"autonomous-car-gui.ratio", count, total}
end

-- The lines of an entity, as {name (key suffix), value}, or nil if it is not a tracked entity of the mod.
local function get_lines(entity)
	local id = entity.unit_number
	if entity.name == names.car then
		local car_data = storage.car_data[id]
		return car_data and {
			{"state", car_gui.get_state_text(car_data)},
			{"charge", percent(_utils.get_fuel_ratio(entity))},
			{"batteries", tostring(_utils.get_battery_count(entity))},
			{"work", car_gui.get_work_text(car_data)},
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

-- Called every config.slow_check_interval ticks.
function tooltips.refresh()
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

return tooltips
