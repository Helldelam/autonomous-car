local config = require("config")
local _utils = require("scripts._utils")

-- Garages: a parked car is a record (quality, health, fuel, batteries, ammo) in the FIFO list
-- storage.garage_data[id].cars, not an item; the door drawn while a car goes in or out.
local garage_control = {}

local CAR_SLOT = 1 -- a car put here parks
local BATTERY_SLOT = 2 -- refill the selected parked car (load_car)
local AMMO_SLOT = 3
local FIRST_KIT_SLOT = 4 -- repair packs
local STATE_TAG = "state" -- tag of a car item: its fuel

local function stop_parking(car_data)
	car_data.parking.active = false
	car_data.parking.garage = nil
	car_data.parking.door_tick = nil
	_utils.start_waiting(car_data)
end

function garage_control.get_capacity(garage)
	return _utils.get_upgrade(garage.force, "garage")
end

-- Quality and health in the item, fuel in its tag (read back by a garage only: placed in the world
-- the car starts new). Batteries and ammo are separate items.
local function write_car_stack(stack, entry)
	stack.set_stack{name = config.names.car, count = 1, quality = entry.quality}
	stack.health = entry.health
	stack.set_tag(STATE_TAG, {fuel = entry.fuel})
end

-- No tag: a new car, at config.critical_fuel_ratio like one just built.
local function read_car_stack(stack)
	local state = stack.get_tag(STATE_TAG) or {}
	return {
		quality = stack.quality.name,
		health = stack.health,
		fuel = state.fuel or config.critical_fuel_ratio,
	}
end

-- Every tick at the garage: once the trunk is empty and the door open, the car becomes a record.
function garage_control.parking_tick(car, garage)
	local car_data = storage.car_data[car.unit_number]

	if not (garage and garage.valid) then
		stop_parking(car_data)
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

	local parking = car_data.parking
	if not parking.door_tick then
		parking.door_tick = game.tick
		garage_control.open_door(garage)
	end
	if game.tick - parking.door_tick < config.garage_door.enter_delay then
		return
	end

	local garage_data = storage.garage_data[garage.unit_number]
	local entry = {
		quality = car.quality.name,
		health = car.get_health_ratio(),
		fuel = _utils.get_fuel_ratio(car),
		batteries = _utils.remove_batteries(car, _utils.get_battery_count(car)),
		ammo = _utils.remove_ammo(car),
	}
	if entry.batteries == 0 then
		entry.batteries = nil
	end
	table.insert(garage_data.cars, entry)

	car.destroy() -- its state is released by on_tick, next tick
end

function garage_control.has_parked_car(garage)
	return #storage.garage_data[garage.unit_number].cars > 0
end

-- garage_exit.exits cars left within medium_delay of the first one.
local function is_exit_window_full(garage_data)
	return garage_data.exit_tick ~= nil and game.tick - garage_data.exit_tick < config.medium_delay
		and garage_data.exit_count >= config.garage_exit.exits
end

function garage_control.can_release_car(garage)
	local garage_data = storage.garage_data[garage.unit_number]
	return #garage_data.cars > 0 and not is_exit_window_full(garage_data)
end

-- First tick a waiting garage lets a car out (exit window or door), or nil.
function garage_control.get_next_release_tick()
	local next_tick
	for id, garage in pairs(storage.garages) do
		local garage_data = storage.garage_data[id]
		if garage.valid and #garage_data.cars > 0 then
			local tick
			if is_exit_window_full(garage_data) then
				tick = garage_data.exit_tick + config.medium_delay
			elseif garage_data.release_tick and game.tick < garage_data.release_tick then
				tick = garage_data.release_tick -- door opening
			end
			if tick then
				next_tick = math.min(next_tick or tick, tick)
			end
		end
	end
	return next_tick
end

local function create_car(garage, entry, position)
	-- raise_built: tracked by control.lua before create_entity returns
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

-- Puts the first parked car back on the map; nil if none, exit window full, no free spot, or
-- door still opening.
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

	-- The door opens first (the cluster waits, get_next_release_tick); a release_tick older than
	-- the door's hold is stale.
	local door = config.garage_door
	if not garage_data.release_tick or game.tick > garage_data.release_tick + door.hold then
		garage_data.release_tick = game.tick + door.enter_delay
		garage_control.open_door(garage)
	end
	if game.tick < garage_data.release_tick then
		return nil
	end
	garage_control.open_door(garage)

	local car = create_car(garage, garage_data.cars[1], position)
	if car then
		table.remove(garage_data.cars, 1)
		if garage_data.exit_tick == nil or game.tick - garage_data.exit_tick >= config.medium_delay then
			garage_data.exit_tick, garage_data.exit_count = game.tick, 0
		end
		garage_data.exit_count = garage_data.exit_count + 1
	end
	return car
end

-- The car, its batteries and its ammo as items; all or nothing. A mining buffer grows on insert
-- (no empty stack before): the new stack is the car without tag.
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

-- Car number `index` to the player's inventory (store_car); false if no room.
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

local function spill_car(surface, position, entry)
	surface.spill_item_stack{position = position, stack = {name = config.names.car, count = 1, quality = entry.quality}}
	if entry.batteries then
		surface.spill_item_stack{position = position, stack = {name = config.battery_item, count = entry.batteries}}
	end
	if entry.ammo then
		surface.spill_item_stack{position = position, stack = {name = entry.ammo.name, quality = entry.ammo.quality, count = entry.ammo.count}}
	end
end

-- Mined or destroyed garage: its cars as items, to the mining buffer, else the player, else the ground.
function garage_control.return_cars(garage, buffer, player)
	local player_inventory = player and player.get_main_inventory()
	for _, entry in ipairs(storage.garage_data[garage.unit_number].cars) do
		if not (buffer and store_car(buffer, entry)) and not (player_inventory and store_car(player_inventory, entry)) then
			spill_car(garage.surface, garage.position, entry)
		end
	end
end

-- A car put in the car slot (player or inserter) joins the list, if there is room.
local function take_car_slot(garage)
	local stack = garage.get_inventory(defines.inventory.chest)[CAR_SLOT]
	if stack.valid_for_read and stack.name == config.names.car and garage_control.has_room(garage) then
		table.insert(storage.garage_data[garage.unit_number].cars, read_car_stack(stack))
		stack.clear()
	end
end

local function is_car_ammo(name)
	for _, item in ipairs(config.ammo_items) do
		if item == name then
			return true
		end
	end
	return false
end

-- Refills parked car `index` from the battery and ammo slots, up to a stack each (ammo of its
-- type, any car ammo if it has none). True if something moved.
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

-- Slot filters: car, batteries, ammo (locked before Military), repair packs (locked before the
-- repair research).
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

-- Every slow check: no event tells of a changed filter or a car put in.
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

function garage_control.has_room(garage)
	return #storage.garage_data[garage.unit_number].cars < garage_control.get_capacity(garage)
end

local function find_repair_kit(inventory)
	for slot = FIRST_KIT_SLOT, #inventory do
		if inventory[slot].valid_for_read then
			return inventory[slot]
		end
	end
	return nil
end

-- Each car gains config.garage_repair_rate of its health; the pack loses that health / its speed.
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

-- Closest garage with room, or nil.
function garage_control.find_garage(car)
	return _utils.find_closest("garages", car.position, function(garage)
		return garage_control.has_room(garage)
	end, "garage", car.surface)
end

function garage_control.alert_no_garage(car)
	_utils.alert_once(storage.car_data[car.unit_number].alerts, "no_garage", car.force, car,
		{"autonomous-car-messages.alert-no-garage"}, config.names.garage)
end

-- ============================================================
-- Door
-- ============================================================
-- A container has no animation: while a car goes in or out, an interior and the door are drawn
-- over the closed sprite, the door sliding up one cut sprite per tick (prototypes/garage.lua).
-- storage.garage_doors[id] = {garage, step (0 closed, move_ticks open), hold_until, interior, door};
-- moving doors only.

local door_settings = config.garage_door

local function place_door(door)
	local position = door.garage.position
	door.door.sprite = config.names.garage_door .. "_" .. door.step
	door.door.target = {
		x = position.x + door_settings.x,
		y = position.y + door_settings.top + (door_settings.rows - door_settings.hidden_rows(door.step)) / 64 / 2,
	}
end

local function destroy_door(id)
	local door = storage.garage_doors[id]
	if door then
		door.interior.destroy()
		door.door.destroy()
		storage.garage_doors[id] = nil
	end
end

-- Opens the door, holds it open, then closes it.
function garage_control.open_door(garage)
	local door = storage.garage_doors[garage.unit_number]
	if not door then
		local position = garage.position
		local target = {x = position.x + door_settings.x, y = position.y + door_settings.top + door_settings.height / 2}
		door = {
			garage = garage,
			step = 0,
			interior = rendering.draw_sprite{sprite = config.names.garage_interior, target = target, surface = garage.surface,
				render_layer = "object"},
			door = rendering.draw_sprite{sprite = config.names.garage_door .. "_0", target = target, surface = garage.surface,
				render_layer = "cargo-hatch"}, -- above the interior and a car beside the garage
		}
		storage.garage_doors[garage.unit_number] = door
	end
	door.hold_until = game.tick + door_settings.move_ticks + door_settings.hold
end

-- Every tick: each moving door by one step.
function garage_control.update_doors(tick)
	for id, door in pairs(storage.garage_doors) do
		if not door.garage.valid then
			destroy_door(id)
		else
			local open = tick < door.hold_until
			local step = open and math.min(door_settings.move_ticks, door.step + 1) or math.max(0, door.step - 1)
			if step ~= door.step then
				door.step = step
				place_door(door)
			elseif step == 0 and not open then
				destroy_door(id)
			end
		end
	end
end

function garage_control.release_door(id)
	destroy_door(id)
end

return garage_control
