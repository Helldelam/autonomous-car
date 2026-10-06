local util = require("util")
local config = require("config")
local _utils = require("_utils")

-- Garages: a parked car is stored as an item in the garage inventory, and the
-- garage remembers its fuel level until it is released.
local garage_control = {}

-- Called every tick while the car is at its garage: mines the car into the
-- garage inventory. The trunk must be empty first.
function garage_control.parking_tick(car, garage)
	local car_data = storage.car_data[car.unit_number]

	if not (garage and garage.valid) then
		-- The garage is gone: go back to waiting and look for another one.
		car_data.parking.active = false
		car_data.parking.garage = nil
		car_data.waiting.active = true
		car_data.waiting.since = game.tick
		return
	end

	local inventory = garage.get_inventory(defines.inventory.chest)

	if inventory.is_full() then
		_utils.alert_once(car_data.alerts, "garage_full", car.force, garage,
			"No room left in this garage for the car trying to park.",
			{type = "item", name = "autonomous_car_garage"})
		-- Drop the parking task. No other state is activated here.
		car_data.parking.active = false
		car_data.parking.garage = nil
		return
	end
	_utils.alert_reset(car_data.alerts, "garage_full")

	if not car.get_inventory(defines.inventory.car_trunk).is_empty() then
		_utils.alert_once(car_data.alerts, "not_empty", car.force, car,
			"An autonomous car still carries items and cannot park until its trunk is empty.",
			{type = "item", name = "autonomous_car"})
		return
	end
	_utils.alert_reset(car_data.alerts, "not_empty")

	-- The car item goes to the first empty slot: its fuel level is kept under that slot index.
	local _, slot = inventory.find_empty_stack()
	if not slot then
		_utils.alert_once(car_data.alerts, "parking_failed", car.force, garage,
			"Unexpected error while parking an autonomous car.",
			{type = "item", name = "autonomous_car"})
		return
	end
	storage.garage_data[garage.unit_number].fuel[slot] = _utils.remaining_fuel(car)

	-- Once mined the car entity is invalid: on_tick releases its state on the next tick.
	if not car.mine{inventory = inventory} then
		_utils.alert_once(car_data.alerts, "parking_failed", car.force, garage,
			"Unexpected error while parking an autonomous car.",
			{type = "item", name = "autonomous_car"})
	end
end

-- Takes a parked car out of the garage and restores its fuel level. Returns
-- the new car, or nil if the garage holds no car or has no free spot around it.
function garage_control.release_car(garage)
	if not (garage and garage.valid) then
		return nil
	end

	local garage_data = storage.garage_data[garage.unit_number]
	local surface = garage.surface
	local position = surface.find_non_colliding_position("autonomous_car", garage.position,
		config.garage_exit_radius, config.garage_exit_precision)
	if not position then
		_utils.alert_once(garage_data.alerts, "no_room", garage.force, garage,
			"No room for a car to leave this garage.",
			{type = "item", name = "autonomous_car_garage"})
		return nil
	end
	_utils.alert_reset(garage_data.alerts, "no_room")

	local stack, slot = garage.get_inventory(defines.inventory.chest).find_item_stack("autonomous_car")
	if not stack then
		return nil
	end

	-- raise_built makes control.lua track the new car before create_entity returns.
	local car = surface.create_entity{name = "autonomous_car", position = position, raise_built = true, item = stack, force = garage.force}
	if car and car.valid and car.burner then
		_utils.set_fuel_item(car)
		if garage_data.fuel[slot] then
			car.burner.remaining_burning_fuel = garage_data.fuel[slot]
		end
	end
	stack.clear()
	garage_data.fuel[slot] = nil
	return car
end

-- Closest garage with room left, or nil.
function garage_control.find_garage(car)
	local best, best_distance

	for id, garage in pairs(storage.garages) do
		if garage.valid then
			if not garage.get_inventory(defines.inventory.chest).is_full() then
				local distance = util.distance(car.position, garage.position)
				if not best or distance < best_distance then
					best = garage
					best_distance = distance
				end
			end
		else
			_utils.release_entity("garage", id)
		end
	end

	return best
end

function garage_control.alert_no_garage(car)
	_utils.alert_once(storage.car_data[car.unit_number].alerts, "no_garage", car.force, car,
		"No available garage found for an autonomous car to park in.",
		{type = "item", name = "autonomous_car_garage"})
end

return garage_control
