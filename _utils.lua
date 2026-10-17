local util = require("util")
local config = require("config")

-- Shared helpers: car fuel, closest-entity search, slow checks, the waiting
-- state, deque, item keys (name and quality), alerts, entity cleanup and the
-- next-task event.
local _utils = {}

-- ============================================================
-- Fuel
-- ============================================================
-- The car is electric in spirit. Its burner has no fuel slot and always burns
-- one hidden fuel item: burner.remaining_burning_fuel is the charge, and the
-- fuel value of that item is the tank capacity. The charge is read and written
-- through these helpers only.

-- Puts the fuel item in the car's burner. Without it the burner ignores any
-- write to remaining_burning_fuel.
function _utils.set_fuel_item(car)
	car.burner.currently_burning = config.names.fuel
end

-- Tank capacity. A burner that ran dry loses its fuel item, so this also puts
-- it back.
function _utils.get_fuel_capacity(car)
	local burner = car.burner
	if not burner.currently_burning then
		burner.currently_burning = config.names.fuel
	end
	return burner.currently_burning.name.fuel_value
end

-- Charge left in the tank.
function _utils.get_fuel(car)
	return car.burner.remaining_burning_fuel
end

-- Charge left, as a fraction of the tank capacity.
function _utils.get_fuel_ratio(car)
	local capacity = _utils.get_fuel_capacity(car) -- read first: it puts the fuel item back
	return _utils.get_fuel(car) / capacity
end

-- Sets the charge of the tank.
function _utils.set_fuel(car, fuel)
	_utils.get_fuel_capacity(car) -- puts the fuel item back if needed: without it the write is ignored
	car.burner.remaining_burning_fuel = fuel
end

-- ============================================================
-- Closest entity
-- ============================================================

-- Closest valid entity of `entities` ([id] = entity) to `position`, or nil.
-- `accept(entity, id)`, if given, tells whether an entity may be chosen. A
-- stale entity is released as `kind` (see "Entity cleanup") when a kind is
-- given, and just skipped otherwise. Of two entities at the same distance, the
-- first one in the table wins. With a `surface`, entities of other surfaces are
-- skipped: positions of two surfaces cannot be compared.
function _utils.find_closest(entities, position, accept, kind, surface)
	local best, best_distance
	for id, entity in pairs(entities) do
		if entity.valid then
			if (not surface or entity.surface == surface) and (not accept or accept(entity, id)) then
				local distance = util.distance(position, entity.position)
				if not best or distance < best_distance then
					best = entity
					best_distance = distance
				end
			end
		elseif kind then
			_utils.release_entity(kind, id)
		end
	end
	return best
end

-- ============================================================
-- Slow checks
-- ============================================================

-- True on the ticks when a car does its slow measurements (nearby cars, closest
-- charger): every config.slow_check_interval ticks (or every `interval`, for a
-- measure that can wait longer), offset by the id of the car so that the cars do
-- not all measure on the same tick.
function _utils.is_slow_check_due(car, tick, interval)
	return (tick + car.unit_number) % (interval or config.slow_check_interval) == 0
end

-- ============================================================
-- Waiting state
-- ============================================================

-- Hands a car to the waiting loop of control.lua (see end_wait), which decides
-- what it does next once config.idle_delay has passed since `since` (the
-- current tick by default). A wait that should end on the next tick starts
-- config.idle_delay ago.
function _utils.start_waiting(car_data, since)
	car_data.waiting.active = true
	car_data.waiting.since = since or game.tick
end

-- ============================================================
-- Deque
-- ============================================================
-- Double-ended queue: its values sit at indices head to tail - 1 of `items`.

_utils.deque = {}

function _utils.deque.new()
	return {head = 0, tail = 0, items = {}}
end

function _utils.deque.length(deque)
	return deque.tail - deque.head
end

function _utils.deque.push_front(deque, value)
	deque.head = deque.head - 1
	deque.items[deque.head] = value
end

function _utils.deque.push_back(deque, value)
	deque.items[deque.tail] = value
	deque.tail = deque.tail + 1
end

-- The deque must not be empty.
function _utils.deque.pop_front(deque)
	local value = deque.items[deque.head]
	deque.items[deque.head] = nil
	deque.head = deque.head + 1
	if _utils.deque.length(deque) == 0 then
		deque.head = 0
		deque.tail = 0
	end
	return value
end

-- ============================================================
-- Item keys
-- ============================================================
-- An item is identified by its name and its quality. The key used in tables
-- ([key] = count) is the plain name for the normal quality, so most keys read
-- as before, and "name|quality" for any other. Quality is a name (string), a
-- LuaQualityPrototype, or nil for normal.

function _utils.make_item_key(name, quality)
	local quality_name = type(quality) == "string" and quality or (quality and quality.name)
	if not quality_name or quality_name == "normal" then
		return name
	end
	return name .. "|" .. quality_name
end

-- Name and quality name (nil for normal) of an item key.
function _utils.split_item_key(key)
	local name, quality = key:match("^(.-)|(.+)$")
	if name then
		return name, quality
	end
	return key, nil
end

-- A stack definition for insert / remove / can_insert.
function _utils.make_stack(key, count)
	local name, quality = _utils.split_item_key(key)
	return {name = name, quality = quality or "normal", count = count}
end

-- Items of a key in an inventory (only that quality).
function _utils.get_item_count(inventory, key)
	local name, quality = _utils.split_item_key(key)
	return inventory.get_item_count{name = name, quality = quality or "normal"}
end

-- The records of LuaInventory.get_contents() as a table of [key] = count.
function _utils.get_contents(inventory)
	local contents = {}
	for _, item in pairs(inventory.get_contents()) do
		local key = _utils.make_item_key(item.name, item.quality)
		contents[key] = (contents[key] or 0) + item.count
	end
	return contents
end

-- ============================================================
-- Batteries
-- ============================================================
-- The last trunk slot only takes batteries (set_battery_filter): the player
-- puts them there to recharge an empty car (travel.handle_empty). They are not
-- cargo: the helpers below tell the cargo of a car from them.

local BATTERY = {name = config.battery_item, quality = "normal"}

-- Locks the last trunk slot of a car to batteries. Safe to call again: the
-- player may have changed the filter, and no event tells, so on_tick calls it
-- every config.slow_check_interval. What a changed filter let into the slot goes to the
-- cargo slots, or to the ground.
function _utils.set_battery_filter(car)
	local trunk = car.get_inventory(defines.inventory.car_trunk)
	local slot = #trunk
	local filter = trunk.get_filter(slot)
	if filter and filter.name == config.battery_item then
		return
	end
	local stack = trunk[slot]
	local other
	if stack.valid_for_read and stack.name ~= config.battery_item then
		other = {name = stack.name, quality = stack.quality, count = stack.count}
		stack.clear()
	end
	trunk.set_filter(slot, config.battery_item)
	if other then
		local inserted = trunk.insert(other)
		if inserted < other.count then
			car.surface.spill_item_stack{position = car.position, stack = {name = other.name, quality = other.quality, count = other.count - inserted}}
		end
	end
end

-- Batteries a car can burn at most, as fuel: the battery slot adds to the charge.
function _utils.get_reachable_fuel(car)
	return _utils.get_fuel(car) + _utils.get_battery_count(car) * config.battery_fuel_ratio * _utils.get_fuel_capacity(car)
end

-- Batteries in the trunk of a car.
function _utils.get_battery_count(car)
	return car.get_inventory(defines.inventory.car_trunk).get_item_count(BATTERY)
end

-- Removes up to `count` batteries from the trunk; returns how many.
function _utils.remove_batteries(car, count)
	if count <= 0 then
		return 0
	end
	return car.get_inventory(defines.inventory.car_trunk).remove{name = BATTERY.name, quality = BATTERY.quality, count = count}
end

-- Puts `count` batteries in the trunk (the battery slot takes them).
function _utils.insert_batteries(car, count)
	if count <= 0 then
		return 0
	end
	return car.get_inventory(defines.inventory.car_trunk).insert{name = BATTERY.name, quality = BATTERY.quality, count = count}
end

-- True if the trunk holds nothing but batteries.
function _utils.is_cargo_empty(car)
	local trunk = car.get_inventory(defines.inventory.car_trunk)
	return trunk.get_item_count() - trunk.get_item_count(BATTERY) <= 0
end

-- The cargo of a trunk as `get_contents` ([key] = count), without the batteries.
function _utils.get_cargo_contents(trunk)
	local contents = _utils.get_contents(trunk)
	contents[BATTERY.name] = nil
	return contents
end

-- ============================================================
-- Alerts
-- ============================================================
-- `item` is the name of the item whose icon marks the alert on the map.

-- Prints `message` to a force and pins it on `target` as a map alert.
function _utils.alert(force, target, message, item)
	local icon = {type = "item", name = item}
	force.print(message)
	for _, player in pairs(force.players) do
		player.add_custom_alert(target, icon, message, true)
	end
end

-- Same, but only once: `flags[key]` remembers that the alert was raised, until
-- alert_reset clears it. Keeps a retry loop from repeating the same alert.
function _utils.alert_once(flags, key, force, target, message, item)
	if flags[key] then
		return
	end
	flags[key] = true
	_utils.alert(force, target, message, item)
end

function _utils.alert_reset(flags, key)
	flags[key] = nil
end

-- ============================================================
-- Entity cleanup
-- ============================================================
-- control.lua registers one handler per kind of tracked entity ("car",
-- "charger", "garage", "chest"). Any module that finds a stale entity releases
-- it through here, without depending on the modules its cleanup needs.

local release_handlers = {}

function _utils.register_release_handler(kind, handler)
	release_handlers[kind] = handler
end

function _utils.release_entity(kind, id)
	release_handlers[kind](id)
end

-- ============================================================
-- Next-task event
-- ============================================================

-- Tells control.lua that a car finished its current step (it arrived, or it is
-- fully charged) and should start its next task. This is an event rather than
-- a call because control.lua sits above every other module.
function _utils.raise_next_task(car)
	script.raise_event(prototypes.custom_event[config.names.next_task_event], {entity = car})
end

return _utils
