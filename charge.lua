local util = require("util")
local config = require("config")
local _utils = require("_utils")

-- Chargers: finding one a car can reach, and filling the car's tank from it.
local charger_control = {}

-- High estimate of the fuel burnt driving `distance` tiles in a straight line (see "Carburant" in
-- CLAUDE.md): a fixed part, a steep rate over the first tiles (detours, manoeuvres, slow zones) and
-- a gentle one beyond, where the car mostly drives fast on open ground.
local function compute_fuel_for_distance(distance)
	local near = math.min(distance, config.fuel_near_distance)
	return config.fuel_fixed + near * config.fuel_per_tile + (distance - near) * config.fuel_far_per_tile
end

-- Rough fuel cost of driving from the car to `position`.
function charger_control.compute_fuel_to_reach(car, position)
	return compute_fuel_for_distance(util.distance(car.position, position))
end

-- Fuel a car should still have on arriving at `position`: enough to get from
-- there to the closest charger (whatever its free slots), plus the critical
-- level. Without any charger only the critical level is kept.
function charger_control.compute_fuel_reserve(car, position)
	local reserve = config.critical_fuel_ratio * _utils.get_fuel_capacity(car)
	local charger = _utils.find_closest(storage.chargers, position, nil, "charger", car.surface)
	if charger then
		reserve = reserve + compute_fuel_for_distance(util.distance(position, charger.position))
	end
	return reserve
end

-- Fuel a trip to `position` needs: the way there, then the reserve above. This
-- is what lets a car recharge between two clusters, and never end a trip
-- unable to reach a charger.
function charger_control.compute_fuel_needed(car, position)
	return charger_control.compute_fuel_to_reach(car, position) + charger_control.compute_fuel_reserve(car, position)
end

-- TODO: build chargers automatically to reach a distant destination. See "À faire" in CLAUDE.md.
-- Closest charger to `target_position` (the car itself by default) that has a
-- free slot and that the car has enough fuel to reach. Returns nil if there is none.
function charger_control.find_charger(car, target_position)
	local remaining_fuel = _utils.get_fuel(car)
	return _utils.find_closest(storage.chargers, target_position or car.position, function(charger, id)
		return storage.charger_data[id].users < config.max_charger_users
			and remaining_fuel >= charger_control.compute_fuel_to_reach(car, charger.position)
	end, "charger", car.surface)
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
		_utils.start_waiting(car_data)
		return
	end

	local transfer = _utils.get_fuel_capacity(car) / config.full_charge_duration
	if charger.energy > transfer then
		_utils.set_fuel(car, _utils.get_fuel(car) + transfer)
		charger.energy = charger.energy - transfer
	end

	if _utils.get_fuel_ratio(car) >= 1 then
		local charger_data = storage.charger_data[charger.unit_number]
		charger_data.users = charger_data.users - 1
		car_data.charging.active = false
		car_data.charging.charger = nil
		_utils.raise_next_task(car)
	end
end

function charger_control.alert_no_charger(car)
	_utils.alert_once(storage.car_data[car.unit_number].alerts, "no_charger", car.force, car,
		"An autonomous car needs to recharge but no reachable charger is available.",
		config.names.car)
end

return charger_control
