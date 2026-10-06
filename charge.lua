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
	target_position = target_position or car.position
	local remaining_fuel = _utils.remaining_fuel(car)
	local best, best_distance

	for id, charger in pairs(storage.chargers) do
		if charger.valid then
			if storage.charger_data[id].users < config.max_charger_users
				and remaining_fuel >= charger_control.fuel_needed(car, charger.position) then
				local distance = util.distance(target_position, charger.position)
				if not best or distance < best_distance then
					best = charger
					best_distance = distance
				end
			end
		else
			_utils.release_entity("charger", id)
		end
	end

	return best
end

-- Called every tick while the car is charging: moves energy from the charger
-- buffer to the car's tank, then frees the charger slot and starts the car's
-- next task once the tank is full.
function charger_control.charge(car, charger)
	local car_data = storage.car_data[car.unit_number]

	if not (charger and charger.valid) then
		-- The charger is gone: go back to waiting and let the car decide again.
		car_data.charging.active = false
		car_data.charging.charger = nil
		car_data.waiting.active = true
		car_data.waiting.since = game.tick
		return
	end

	local capacity = _utils.fuel_capacity(car)
	local transfer = capacity / config.full_charge_duration
	if charger.energy > transfer then
		car.burner.remaining_burning_fuel = _utils.remaining_fuel(car) + transfer
		charger.energy = charger.energy - transfer
	end

	if _utils.remaining_fuel(car) / capacity >= 1 then
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
		{type = "item", name = "autonomous_car"})
end

return charger_control
