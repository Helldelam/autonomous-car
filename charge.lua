local util = require("util")
local config = require("config")
local _utils = require("_utils")

-- Chargers: finding one a car can reach, and filling the car's tank from it.
local charger_control = {}

-- Rough fuel cost of driving from the car to `position` (see config.fuel_per_tile).
function charger_control.fuel_needed(car, position)
	return util.distance(car.position, position) * config.fuel_per_tile * config.fuel_safety_margin
end

-- Closest charger to `target_position` (the car itself by default) that has a
-- free slot and that the car has enough fuel to reach. Returns nil if there is none.
function charger_control.find_charger(car, target_position)
	local remaining_fuel = _utils.remaining_fuel(car)
	return _utils.closest(storage.chargers, target_position or car.position, function(charger, id)
		return storage.charger_data[id].users < config.max_charger_users
			and remaining_fuel >= charger_control.fuel_needed(car, charger.position)
	end, "charger")
end

-- Called every tick while the car is charging: moves energy from the charger
-- buffer to the car's tank, then frees the charger slot and starts the car's
-- next task once the tank is full.
function charger_control.charging_tick(car, charger)
	local car_data = storage.car_data[car.unit_number]

	if not (charger and charger.valid) then
		-- The charger is gone: go back to waiting and let the car decide again.
		car_data.charging.active = false
		car_data.charging.charger = nil
		car_data.waiting.active = true
		car_data.waiting.since = game.tick
		return
	end

	local transfer = _utils.fuel_capacity(car) / config.full_charge_duration
	if charger.energy > transfer then
		_utils.set_fuel(car, _utils.remaining_fuel(car) + transfer)
		charger.energy = charger.energy - transfer
	end

	if _utils.fuel_ratio(car) >= 1 then
		local charger_data = storage.charger_data[charger.unit_number]
		charger_data.users = charger_data.users - 1
		car_data.charging.active = false
		car_data.charging.charger = nil
		_utils.raise_next_task(car)
	end
end

function charger_control.alert_no_charger(car)
	_utils.alert_once(storage.car_data[car.unit_number].alerts, "no_charger", car.force, car,
		"An autonomous car needs to recharge but no reachable charging station is available.",
		config.names.car)
end

return charger_control
