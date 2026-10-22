local config = require("config")
local _utils = require("scripts._utils")
local garage_door = require("scripts.garage_door")

-- Garages: a parked car is a record in a first-in first-out list of the garage
-- (storage.garage_data[id].cars: quality, health ratio, fuel ratio, batteries, ammo), not an
-- item. The inventory of the garage only has a slot where the player (or an inserter) puts a
-- car to park it, and the repair pack slots; scripts/gui/garage.lua shows the list.
local garage_control = {}

local CAR_SLOT = 1 -- the slot that takes a car to park
local BATTERY_SLOT = 2 -- batteries for the selected parked car (garage_control.load_car)
local AMMO_SLOT = 3 -- ammo for the selected parked car
local FIRST_KIT_SLOT = 4 -- the repair pack slots follow
local STATE_TAG = "state" -- tag of a car item that carries the fuel, batteries and ammo of the car

-- Drops the parking task and hands the car to the waiting loop, which looks for another garage.
local function stop_parking(car_data)
	car_data.parking.active = false
	car_data.parking.garage = nil
	car_data.parking.door_tick = nil
	_utils.start_waiting(car_data)
end

-- Cars the garage holds at most (garage research).
function garage_control.get_capacity(garage)
	return _utils.get_upgrade(garage.force, "garage")
end

-- Writes the car of `entry` into an item stack: quality and health in the item, the fuel
-- ratio in its tag (kept only if the item goes back into a garage; a car placed in the world
-- starts like a new one). The batteries and the ammo travel as separate items.
local function write_car_stack(stack, entry)
	stack.set_stack{name = config.names.car, count = 1, quality = entry.quality}
	stack.health = entry.health
	stack.set_tag(STATE_TAG, {fuel = entry.fuel})
end

-- The record of a car item: the tag is missing on a car that was never in a garage (a new car,
-- like one just built, starts with config.critical_fuel_ratio of a full tank).
local function read_car_stack(stack)
	local state = stack.get_tag(STATE_TAG) or {}
	return {
		quality = stack.quality.name,
		health = stack.health,
		fuel = state.fuel or config.critical_fuel_ratio,
	}
end

-- Called every tick while the car is at its garage: stores the car in the list of the
-- garage and removes it from the map. The trunk must be empty first.
function garage_control.parking_tick(car, garage)
	local car_data = storage.car_data[car.unit_number]

	if not (garage and garage.valid) then
		stop_parking(car_data) -- the garage is gone
		return
	end

	if not garage_control.has_room(garage) then
		_utils.alert_once(car_data.alerts, "garage_full", car.force, garage,
			{"autonomous-car-messages.alert-garage-full"}, config.names.garage)
		stop_parking(car_data)
		return
	end
	_utils.alert_reset(car_data.alerts, "garage_full")

	if not _utils.is_cargo_empty(car) then
		_utils.alert_once(car_data.alerts, "not_empty", car.force, car,
			{"autonomous-car-messages.alert-not-empty"}, config.names.car)
		return
	end
	_utils.alert_reset(car_data.alerts, "not_empty")

	-- The door opens first; the car goes in once it is open.
	local parking = car_data.parking
	if not parking.door_tick then
		parking.door_tick = game.tick
		garage_door.open(garage)
	end
	if game.tick - parking.door_tick < config.garage_door.enter_delay then
		return
	end

	local garage_data = storage.garage_data[garage.unit_number]
	local entry = {
		quality = car.quality.name,
		health = car.get_health_ratio(),
		fuel = _utils.get_fuel_ratio(car),
		-- The batteries and the ammo stay with the car.
		batteries = _utils.remove_batteries(car, _utils.get_battery_count(car)),
		ammo = _utils.remove_ammo(car),
	}
	if entry.batteries == 0 then
		entry.batteries = nil
	end
	table.insert(garage_data.cars, entry)

	-- Once destroyed the car entity is invalid: on_tick releases its state on the next tick.
	car.destroy()
end

-- True if the garage holds at least one car.
function garage_control.has_parked_car(garage)
	return #storage.garage_data[garage.unit_number].cars > 0
end

-- True if the garage's window of exits is full: garage_exit.exits cars left within medium_delay of the first one.
local function is_exit_window_full(garage_data)
	return garage_data.exit_tick ~= nil and game.tick - garage_data.exit_tick < config.medium_delay
		and garage_data.exit_count >= config.garage_exit.exits
end

-- True if the garage holds a car that may leave now.
function garage_control.can_release_car(garage)
	local garage_data = storage.garage_data[garage.unit_number]
	return #garage_data.cars > 0 and not is_exit_window_full(garage_data)
end

-- The tick at which the first garage whose window of exits is full lets cars out again, or nil if none waits.
function garage_control.get_next_release_tick()
	local next_tick
	for id, garage in pairs(storage.garages) do
		local garage_data = storage.garage_data[id]
		if garage.valid and #garage_data.cars > 0 then
			local tick
			if is_exit_window_full(garage_data) then
				tick = garage_data.exit_tick + config.medium_delay
			elseif garage_data.release_tick and game.tick < garage_data.release_tick then
				tick = garage_data.release_tick -- the door is still opening
			end
			if tick then
				next_tick = math.min(next_tick or tick, tick)
			end
		end
	end
	return next_tick
end

-- Puts a new car on the map from the record `entry`; returns it, or nil if nothing could be created.
local function create_car(garage, entry, position)
	-- raise_built makes control.lua track the new car before create_entity returns.
	local car = garage.surface.create_entity{name = config.names.car, quality = entry.quality, position = position,
		raise_built = true, force = garage.force}
	if not (car and car.valid) then
		return nil
	end
	car.health = entry.health * car.max_health
	if car.burner then
		_utils.set_fuel_item(car)
		_utils.set_fuel(car, entry.fuel * _utils.get_fuel_capacity(car))
		_utils.insert_batteries(car, entry.batteries or 0)
		if entry.ammo then
			_utils.insert_ammo(car, entry.ammo, entry.ammo.count)
		end
		storage.car_data[car.unit_number].just_left_garage = true
	end
	return car
end

-- Takes the first parked car out of the garage (the one that has waited longest) and puts it
-- back on the map with its fuel, batteries, ammo and health. Returns the new car, or nil if
-- the garage holds no car, has let out its share of cars lately (can_release_car) or has no
-- free spot around it.
function garage_control.release_car(garage)
	if not (garage and garage.valid) then
		return nil
	end

	local garage_data = storage.garage_data[garage.unit_number]
	if #garage_data.cars == 0 or is_exit_window_full(garage_data) then
		return nil
	end
	local position = garage.surface.find_non_colliding_position(config.names.car, garage.position,
		config.garage_exit.radius, config.garage_exit.precision)
	if not position then
		_utils.alert_once(garage_data.alerts, "no_room", garage.force, garage,
			{"autonomous-car-messages.alert-garage-exit-blocked"}, config.names.garage)
		return nil
	end
	_utils.alert_reset(garage_data.alerts, "no_room")

	-- The door opens first; the car comes out once it is open (the cluster waits, see get_next_release_tick).
	-- The door stays open config.garage_door.hold ticks after the last exit: a release_tick older than that is stale.
	local door = config.garage_door
	if not garage_data.release_tick or game.tick > garage_data.release_tick + door.hold then
		garage_data.release_tick = game.tick + door.enter_delay
		garage_door.open(garage)
	end
	if game.tick < garage_data.release_tick then
		return nil
	end
	garage_door.open(garage)

	local car = create_car(garage, garage_data.cars[1], position)
	if car then
		table.remove(garage_data.cars, 1)
		-- The first exit of a window stamps it; the window is over medium_delay later.
		if garage_data.exit_tick == nil or game.tick - garage_data.exit_tick >= config.medium_delay then
			garage_data.exit_tick, garage_data.exit_count = game.tick, 0
		end
		garage_data.exit_count = garage_data.exit_count + 1
	end
	return car
end

-- Puts the car of `entry` in an inventory as items: the car (health, fuel tag), its batteries
-- and its ammo, each as an item of its own. All or nothing: false, and nothing changed, if
-- the inventory lacks room. An inventory that grows when something is inserted (a mining
-- buffer) has no empty stack before: the new stack is the car stack that carries no tag yet.
local function store_car(inventory, entry)
	local stack = inventory.find_empty_stack(config.names.car)
	if not stack then
		if inventory.insert{name = config.names.car, count = 1, quality = entry.quality} == 0 then
			return false
		end
		for slot = #inventory, 1, -1 do
			local candidate = inventory[slot]
			if candidate.valid_for_read and candidate.name == config.names.car and not candidate.get_tag(STATE_TAG) then
				stack = candidate
				break
			end
		end
	end
	if not stack then
		return false
	end
	write_car_stack(stack, entry)

	local batteries = entry.batteries or 0
	local ammo = entry.ammo
	local batteries_in = batteries > 0 and inventory.insert{name = config.battery_item, count = batteries} or 0
	local ammo_in = ammo and inventory.insert{name = ammo.name, quality = ammo.quality, count = ammo.count} or 0
	if batteries_in < batteries or (ammo and ammo_in < ammo.count) then
		if batteries_in > 0 then
			inventory.remove{name = config.battery_item, count = batteries_in}
		end
		if ammo_in > 0 then
			inventory.remove{name = ammo.name, quality = ammo.quality, count = ammo_in}
		end
		stack.clear()
		return false
	end
	return true
end

-- Gives the car number `index` of the list to a player, as items (see store_car). Returns
-- false, and keeps the car, if the inventory of the player has no room for all of them.
function garage_control.hand_out_car(garage, player, index)
	local cars = storage.garage_data[garage.unit_number].cars
	local entry = cars[index]
	local inventory = player.get_main_inventory()
	if not (entry and inventory and store_car(inventory, entry)) then
		return false
	end
	table.remove(cars, index)
	return true
end

-- Drops the car of `entry` on the ground, as items (last resort).
local function spill_car(surface, position, entry)
	surface.spill_item_stack{position = position, stack = {name = config.names.car, count = 1, quality = entry.quality}}
	if entry.batteries then
		surface.spill_item_stack{position = position, stack = {name = config.battery_item, count = entry.batteries}}
	end
	if entry.ammo then
		surface.spill_item_stack{position = position, stack = {name = entry.ammo.name, quality = entry.ammo.quality, count = entry.ammo.count}}
	end
end

-- A garage that is mined or destroyed gives its cars as items, each with its batteries and ammo
-- apart: in the mined buffer, else in the inventory of the player, else on the ground (as for a
-- destroyed garage, which has neither).
function garage_control.return_cars(garage, buffer, player)
	local player_inventory = player and player.get_main_inventory()
	for _, entry in ipairs(storage.garage_data[garage.unit_number].cars) do
		if not (buffer and store_car(buffer, entry)) and not (player_inventory and store_car(player_inventory, entry)) then
			spill_car(garage.surface, garage.position, entry)
		end
	end
end

-- Moves the car that was put in the car slot (by hand or by an inserter) into the list, if
-- there is room.
local function take_car_slot(garage)
	local stack = garage.get_inventory(defines.inventory.chest)[CAR_SLOT]
	if stack.valid_for_read and stack.name == config.names.car and garage_control.has_room(garage) then
		table.insert(storage.garage_data[garage.unit_number].cars, read_car_stack(stack))
		stack.clear()
	end
end

-- True if `name` is one of the ammo items a car uses (config.ammo_items).
local function is_car_ammo(name)
	for _, item in ipairs(config.ammo_items) do
		if item == name then
			return true
		end
	end
	return false
end

-- Refills the parked car number `index` from the battery and ammo slots of the garage: batteries
-- up to a stack, ammo of its type (or any type of config.ammo_items if it has none) up to a stack.
-- Another type of ammo is left in the slot. Returns true if something moved.
function garage_control.load_car(garage, index)
	local entry = storage.garage_data[garage.unit_number].cars[index]
	if not entry then
		return false
	end
	local inventory = garage.get_inventory(defines.inventory.chest)
	local moved = false

	local batteries = inventory[BATTERY_SLOT]
	if batteries.valid_for_read and batteries.name == config.battery_item then
		local count = math.min(batteries.count, prototypes.item[config.battery_item].stack_size - (entry.batteries or 0))
		if count > 0 then
			entry.batteries = (entry.batteries or 0) + count
			batteries.count = batteries.count - count
			moved = true
		end
	end

	local ammo = inventory[AMMO_SLOT]
	if ammo.valid_for_read and (entry.ammo and entry.ammo.name == ammo.name and entry.ammo.quality == ammo.quality.name
			or not entry.ammo and is_car_ammo(ammo.name)) then
		local held = entry.ammo and entry.ammo.count or 0
		local count = math.min(ammo.count, prototypes.item[ammo.name].stack_size - held)
		if count > 0 then
			entry.ammo = {name = ammo.name, quality = ammo.quality.name, count = held + count}
			ammo.count = ammo.count - count
			moved = true
		end
	end
	return moved
end

-- Layout of the inventory of a garage: the slot that takes a car, filtered to the car, the
-- battery slot, the ammo slot (locked until Military, like the ammo slot of a car), then
-- config.repair_kit_slots slots for repair packs (locked until the repair research). Safe to
-- call again, like _utils.set_trunk_limits.
function garage_control.update_inventory(garage)
	local inventory = garage.get_inventory(defines.inventory.chest)
	local kit = _utils.is_researched(garage.force, config.names.repair_technology) and config.repair_kit or config.names.locked_slot
	local ammo = not _utils.is_armed(garage) and config.names.locked_slot or nil
	_utils.set_filters(garage, inventory, function(slot)
		if slot == CAR_SLOT then
			return config.names.car
		elseif slot == BATTERY_SLOT then
			return config.battery_item
		elseif slot == AMMO_SLOT then
			return ammo
		end
		return kit
	end)
end

-- Called every tick: like the trunk of a car, each garage is checked every
-- config.slow_check_interval ticks (no event tells that the player changed a filter or put a car in).
function garage_control.update_inventories(tick)
	for id, garage in pairs(storage.garages) do
		if garage.valid then
			if _utils.is_slow_check_due(garage, tick) then
				garage_control.update_inventory(garage)
				take_car_slot(garage)
			end
		else
			_utils.release_entity("garage", id)
		end
	end
end

-- True if one more car fits in the garage.
function garage_control.has_room(garage)
	return #storage.garage_data[garage.unit_number].cars < garage_control.get_capacity(garage)
end

-- The first repair pack of a garage, or nil.
local function find_repair_kit(inventory)
	for slot = FIRST_KIT_SLOT, #inventory do
		if inventory[slot].valid_for_read then
			return inventory[slot]
		end
	end
	return nil
end

-- Repairs the parked cars of a garage a little, as long as it holds a repair pack: each
-- car recovers config.garage_repair_rate of its health, and the pack loses the durability
-- that this health costs (the speed of a pack is the health it repairs per durability).
-- The health of the record carries over to the car when it is released.
local function repair_cars(garage)
	local inventory = garage.get_inventory(defines.inventory.chest)
	local max_health = prototypes.entity[config.names.car].get_max_health()
	local speed = prototypes.item[config.repair_kit].speed
	for _, entry in ipairs(storage.garage_data[garage.unit_number].cars) do
		if entry.health < 1 then
			local kit = find_repair_kit(inventory)
			if not kit then
				return
			end
			local gain = math.min(1 - entry.health, config.garage_repair_rate)
			entry.health = entry.health + gain
			kit.drain_durability(gain * max_health / speed)
		end
	end
end

-- Called every tick: each garage repairs every config.long_delay ticks.
function garage_control.repair_parked_cars(tick)
	for id, garage in pairs(storage.garages) do
		if not garage.valid then
			_utils.release_entity("garage", id)
		elseif _utils.is_slow_check_due(garage, tick, config.long_delay)
			and _utils.is_researched(garage.force, config.names.repair_technology) then
			repair_cars(garage)
		end
	end
end

-- Closest garage with room left, or nil.
function garage_control.find_garage(car)
	return _utils.find_closest("garages", car.position, function(garage)
		return garage_control.has_room(garage)
	end, "garage", car.surface)
end

function garage_control.alert_no_garage(car)
	_utils.alert_once(storage.car_data[car.unit_number].alerts, "no_garage", car.force, car,
		{"autonomous-car-messages.alert-no-garage"}, config.names.garage)
end

return garage_control
