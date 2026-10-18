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

-- TODO: do not park on rails. See "À faire" in CLAUDE.md.
-- Called every tick while the car is at its garage: mines the car into the
-- garage inventory. The trunk must be empty first.
function garage_control.parking_tick(car, garage)
	local car_data = storage.car_data[car.unit_number]

	if not (garage and garage.valid) then
		stop_parking(car_data) -- the garage is gone
		return
	end

	local inventory = garage.get_inventory(defines.inventory.chest)

	if not garage_control.has_room(garage) then
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
	local _, slot = inventory.find_empty_stack{name = config.names.car}
	if not slot then
		alert_parking_failed(car, garage)
		return
	end
	local garage_data = storage.garage_data[garage.unit_number]
	garage_data.fuel[slot] = _utils.get_fuel(car)
	-- The batteries and the ammo stay with the car, not in the garage slots.
	local batteries = _utils.remove_batteries(car, _utils.get_battery_count(car))
	garage_data.batteries[slot] = batteries > 0 and batteries or nil
	local ammo = _utils.remove_ammo(car)
	garage_data.ammo[slot] = ammo

	-- Once mined the car entity is invalid: on_tick releases its state on the next tick.
	if not car.mine{inventory = inventory} then
		_utils.insert_batteries(car, batteries)
		garage_data.batteries[slot] = nil
		if ammo then
			_utils.insert_ammo(car, ammo, ammo.count)
		end
		garage_data.ammo[slot] = nil
		alert_parking_failed(car, garage)
	end
end

-- Stack and slot of a car parked in the garage (of any quality), or nil if it holds none.
function garage_control.find_parked_car(garage)
	local inventory = garage.get_inventory(defines.inventory.chest)
	for slot = 1, config.garage_car_slots do
		local stack = inventory[slot]
		if stack.valid_for_read and stack.name == config.names.car then
			return stack, slot
		end
	end
	return nil
end

-- TODO: a car taken out by hand leaves its fuel, batteries and ammo in garage_data. See "À faire" in CLAUDE.md.
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
		local ammo = garage_data.ammo[slot]
		if ammo then
			_utils.insert_ammo(car, ammo, ammo.count)
		end
		storage.car_data[car.unit_number].just_left_garage = true
	end
	stack.clear()
	garage_data.fuel[slot] = nil
	garage_data.batteries[slot] = nil
	garage_data.ammo[slot] = nil
	return car
end

-- Layout of the inventory of a garage: one slot per parked car (config.garage_car_slots, those
-- above the capacity the garage research allows are locked), then config.repair_kit_slots
-- slots for repair packs (locked until the repair research). Car slots are filtered to the
-- car, so that no pack takes one. Safe to call again, like _utils.set_trunk_limits.
function garage_control.update_inventory(garage)
	local inventory = garage.get_inventory(defines.inventory.chest)
	local capacity = _utils.get_upgrade(garage.force, "garage")
	local kit = _utils.is_researched(garage.force, config.names.repair_technology) and config.repair_kit or config.names.locked_slot
	_utils.set_filters(garage, inventory, function(slot)
		if slot > config.garage_car_slots then
			return kit
		end
		return slot <= capacity and config.names.car or config.names.locked_slot
	end)
end

-- Called every tick: like the trunk of a car, each garage is checked every
-- config.slow_check_interval ticks (no event tells that the player changed a filter).
function garage_control.update_inventories(tick)
	for id, garage in pairs(storage.garages) do
		if garage.valid then
			if _utils.is_slow_check_due(garage, tick) then
				garage_control.update_inventory(garage)
			end
		else
			_utils.release_entity("garage", id)
		end
	end
end

-- True if one more car fits in the garage.
function garage_control.has_room(garage)
	return garage.get_inventory(defines.inventory.chest).can_insert{name = config.names.car, count = 1}
end

-- The first repair pack of a garage, or nil.
local function find_repair_kit(inventory)
	for slot = config.garage_car_slots + 1, #inventory do
		if inventory[slot].valid_for_read then
			return inventory[slot]
		end
	end
	return nil
end

-- Repairs the parked cars of a garage a little, as long as it holds a repair pack: each
-- car recovers config.garage_repair_rate of its health, and the pack loses the durability
-- that this health costs (the speed of a pack is the health it repairs per durability).
-- The health of the item carries over to the car when it is released.
local function repair_cars(garage)
	local inventory = garage.get_inventory(defines.inventory.chest)
	local max_health = prototypes.entity[config.names.car].get_max_health()
	local speed = prototypes.item[config.repair_kit].speed
	for slot = 1, config.garage_car_slots do
		local stack = inventory[slot]
		if stack.valid_for_read and stack.name == config.names.car and stack.health < 1 then
			local kit = find_repair_kit(inventory)
			if not kit then
				return
			end
			local gain = math.min(1 - stack.health, config.garage_repair_rate)
			stack.health = stack.health + gain
			kit.drain_durability(gain * max_health / speed)
		end
	end
end

-- Called every config.long_delay (see on_tick in control.lua).
function garage_control.repair_parked_cars()
	for id, garage in pairs(storage.garages) do
		if not garage.valid then
			_utils.release_entity("garage", id)
		elseif _utils.is_researched(garage.force, config.names.repair_technology) then
			repair_cars(garage)
		end
	end
end

-- Closest garage with room left, or nil.
function garage_control.find_garage(car)
	return _utils.find_closest(storage.garages, car.position, function(garage)
		return garage_control.has_room(garage)
	end, "garage", car.surface)
end

function garage_control.alert_no_garage(car)
	_utils.alert_once(storage.car_data[car.unit_number].alerts, "no_garage", car.force, car,
		"No available garage found for an autonomous car to park in.", config.names.garage)
end

return garage_control
