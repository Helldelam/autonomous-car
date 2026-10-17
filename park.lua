local config = require("config")
local _utils = require("_utils")

-- Garages: a parked car is stored as an item in the garage inventory, and the
-- garage remembers its fuel level until it is released.
local garage_control = {}

local function alert_parking_failed(car, garage)
	_utils.alert_once(storage.car_data[car.unit_number].alerts, "parking_failed", car.force, garage,
		"Unexpected error while parking an autonomous car.", config.names.car)
end

-- Drops the parking task and hands the car to the waiting loop, which looks for another garage.
local function stop_parking(car_data)
	car_data.parking.active = false
	car_data.parking.garage = nil
	_utils.start_waiting(car_data)
end

-- TODO: do not park on rails; repair kit slots in the garage. See "À faire" in CLAUDE.md.
-- Called every tick while the car is at its garage: mines the car into the
-- garage inventory. The trunk must be empty first.
function garage_control.parking_tick(car, garage)
	local car_data = storage.car_data[car.unit_number]

	if not (garage and garage.valid) then
		stop_parking(car_data) -- the garage is gone
		return
	end

	local inventory = garage.get_inventory(defines.inventory.chest)

	if inventory.is_full() then
		_utils.alert_once(car_data.alerts, "garage_full", car.force, garage,
			"No room left in this garage for the car trying to park.", config.names.garage)
		stop_parking(car_data)
		return
	end
	_utils.alert_reset(car_data.alerts, "garage_full")

	if not _utils.is_cargo_empty(car) then
		_utils.alert_once(car_data.alerts, "not_empty", car.force, car,
			"An autonomous car still carries items and cannot park until its trunk is empty.", config.names.car)
		return
	end
	_utils.alert_reset(car_data.alerts, "not_empty")

	-- The car item goes to the first empty slot: its fuel level is kept under that slot index.
	local _, slot = inventory.find_empty_stack()
	if not slot then
		alert_parking_failed(car, garage)
		return
	end
	local garage_data = storage.garage_data[garage.unit_number]
	garage_data.fuel[slot] = _utils.get_fuel(car)
	-- The batteries stay with the car, not in the garage slots.
	local batteries = _utils.remove_batteries(car, _utils.get_battery_count(car))
	garage_data.batteries[slot] = batteries > 0 and batteries or nil

	-- Once mined the car entity is invalid: on_tick releases its state on the next tick.
	if not car.mine{inventory = inventory} then
		_utils.insert_batteries(car, batteries)
		garage_data.batteries[slot] = nil
		alert_parking_failed(car, garage)
	end
end

-- Stack and slot of a car parked in the garage (of any quality), or nil if it holds none.
function garage_control.find_parked_car(garage)
	local inventory = garage.get_inventory(defines.inventory.chest)
	for slot = 1, #inventory do
		local stack = inventory[slot]
		if stack.valid_for_read and stack.name == config.names.car then
			return stack, slot
		end
	end
	return nil
end

-- Takes a parked car out of the garage and restores its fuel level. Returns
-- the new car, or nil if the garage holds no car or has no free spot around it.
function garage_control.release_car(garage)
	if not (garage and garage.valid) then
		return nil
	end

	local garage_data = storage.garage_data[garage.unit_number]
	local surface = garage.surface
	local position = surface.find_non_colliding_position(config.names.car, garage.position,
		config.garage_exit.radius, config.garage_exit.precision)
	if not position then
		_utils.alert_once(garage_data.alerts, "no_room", garage.force, garage,
			"No room for a car to leave this garage.", config.names.garage)
		return nil
	end
	_utils.alert_reset(garage_data.alerts, "no_room")

	local stack, slot = garage_control.find_parked_car(garage)
	if not (stack and slot) then
		return nil
	end

	-- raise_built makes control.lua track the new car before create_entity returns.
	local car = surface.create_entity{name = config.names.car, quality = stack.quality.name, position = position,
		raise_built = true, item = stack, force = garage.force}
	if car and car.valid and car.burner then
		_utils.set_fuel_item(car)
		if garage_data.fuel[slot] then
			_utils.set_fuel(car, garage_data.fuel[slot])
		end
		if garage_data.batteries[slot] then
			_utils.insert_batteries(car, garage_data.batteries[slot])
		end
	end
	stack.clear()
	garage_data.fuel[slot] = nil
	garage_data.batteries[slot] = nil
	return car
end

-- Repairs the parked cars a little, for free: config.garage_repair_rate of their
-- health each time it runs (every config.long_delay, see on_tick in control.lua).
-- The health of the item carries over to the car when it is released.
function garage_control.repair_parked_cars()
	for id, garage in pairs(storage.garages) do
		if garage.valid then
			local inventory = garage.get_inventory(defines.inventory.chest)
			for slot = 1, #inventory do
				local stack = inventory[slot]
				if stack.valid_for_read and stack.name == config.names.car and stack.health < 1 then
					stack.health = math.min(1, stack.health + config.garage_repair_rate)
				end
			end
		else
			_utils.release_entity("garage", id)
		end
	end
end

-- Closest garage with room left, or nil.
function garage_control.find_garage(car)
	return _utils.find_closest(storage.garages, car.position, function(garage)
		return not garage.get_inventory(defines.inventory.chest).is_full()
	end, "garage", car.surface)
end

function garage_control.alert_no_garage(car)
	_utils.alert_once(storage.car_data[car.unit_number].alerts, "no_garage", car.force, car,
		"No available garage found for an autonomous car to park in.", config.names.garage)
end

return garage_control
