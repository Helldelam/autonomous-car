local util = require("util")
local config = require("config")

-- Shared helpers: fuel, closest entity, slow checks, waiting, deque, item keys, research, trunk,
-- ammo, alerts, entity release, next-task event.
local _utils = {}

-- ============================================================
-- Fuel
-- ============================================================
-- No fuel slot: the burner always burns one hidden item, whose fuel value is the tank and
-- remaining_burning_fuel the charge. A burner that runs dry loses the item and ignores any write:
-- read and write the charge here only.

function _utils.set_fuel_item(car)
	car.burner.currently_burning = config.names.fuel
end

-- Also puts the item back.
function _utils.get_fuel_capacity(car)
	local burner = car.burner
	if not burner.currently_burning then
		burner.currently_burning = config.names.fuel
	end
	return burner.currently_burning.name.fuel_value
end

function _utils.get_fuel(car)
	return car.burner.remaining_burning_fuel
end

function _utils.get_fuel_ratio(car)
	local capacity = _utils.get_fuel_capacity(car) -- first: puts the item back
	return _utils.get_fuel(car) / capacity
end

function _utils.set_fuel(car, fuel)
	_utils.get_fuel_capacity(car) -- puts the item back, else the write is ignored
	car.burner.remaining_burning_fuel = fuel
end

-- ============================================================
-- Closest entity
-- ============================================================
-- storage.regions[group].cells[surface index]["x,y"] = {[id] = true}, x and y the position divided
-- by config.regions.size; the entities never move: listed when built, unlisted when released.

local function get_region_key(position)
	local size = config.regions.size
	return math.floor(position.x / size), math.floor(position.y / size)
end

function _utils.add_to_regions(group, entity)
	local regions = storage.regions[group]
	local id = entity.unit_number
	_utils.remove_from_regions(group, id)
	local x, y = get_region_key(entity.position)
	local surface_index = entity.surface.index
	local key = x .. "," .. y
	local surface_cells = regions.cells[surface_index]
	if not surface_cells then
		surface_cells = {}
		regions.cells[surface_index] = surface_cells
	end
	local cell = surface_cells[key]
	if not cell then
		cell = {}
		surface_cells[key] = cell
	end
	cell[id] = true
	regions.where[id] = {surface_index, key}
end

function _utils.remove_from_regions(group, id)
	local regions = storage.regions[group]
	local where = regions.where[id]
	if where then
		regions.cells[where[1]][where[2]][id] = nil
		regions.where[id] = nil
	end
end

-- Closest valid entity of storage[group] on `surface` that `accept(entity, id)` takes, or nil; a
-- stale one is released as `kind` if given. Rings of regions first (ring r is at least r - 1 regions
-- away: stop once the best is closer), then, without a proven answer, every entity.
function _utils.find_closest(group, position, accept, kind, surface)
	local entities = storage[group]
	local best, best_distance
	local function consider(id)
		local entity = entities[id]
		if entity and entity.valid then
			if entity.surface == surface and (not accept or accept(entity, id)) then
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

	local surface_cells = storage.regions[group].cells[surface.index]
	if surface_cells then
		local size, rings = config.regions.size, config.regions.rings
		local x, y = get_region_key(position)
		for ring = 0, rings do
			if best and best_distance <= (ring - 1) * size then
				return best
			end
			for dx = -ring, ring do
				for dy = -ring, ring do
					if math.max(math.abs(dx), math.abs(dy)) == ring then
						local cell = surface_cells[(x + dx) .. "," .. (y + dy)]
						if cell then
							for id in pairs(cell) do
								consider(id)
							end
						end
					end
				end
			end
		end
		if best and best_distance <= rings * size then
			return best
		end
	end

	best = nil
	for id in pairs(entities) do
		consider(id)
	end
	return best
end

-- ============================================================
-- Slow checks and waiting
-- ============================================================

-- Every slow_check_interval (or `interval`) ticks, offset by unit number.
function _utils.is_slow_check_due(entity, tick, interval)
	return (tick + entity.unit_number) % (interval or config.slow_check_interval) == 0
end

-- control.lua end_wait decides idle_delay after `since` (default now; idle_delay ago: next tick).
function _utils.start_waiting(car_data, since)
	car_data.waiting.active = true
	car_data.waiting.since = since or game.tick
end

-- ============================================================
-- Deque
-- ============================================================
-- Values at indices head to tail - 1 of `items`.

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

-- Not on an empty deque.
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
-- Key of an item in [key] = count tables: the name for normal quality, "name|quality" otherwise.
-- Quality: a name, a LuaQualityPrototype, or nil (normal).

function _utils.make_item_key(name, quality)
	local quality_name = type(quality) == "string" and quality or (quality and quality.name)
	if not quality_name or quality_name == "normal" then
		return name
	end
	return name .. "|" .. quality_name
end

-- Name and quality (nil for normal).
function _utils.split_item_key(key)
	local name, quality = key:match("^(.-)|(.+)$")
	if name then
		return name, quality
	end
	return key, nil
end

-- For insert, remove, can_insert.
function _utils.make_stack(key, count)
	local name, quality = _utils.split_item_key(key)
	return {name = name, quality = quality or "normal", count = count}
end

function _utils.get_item_count(inventory, key)
	local name, quality = _utils.split_item_key(key)
	return inventory.get_item_count{name = name, quality = quality or "normal"}
end

-- [key] = count.
function _utils.get_contents(inventory)
	local contents = {}
	for _, item in pairs(inventory.get_contents()) do
		local key = _utils.make_item_key(item.name, item.quality)
		contents[key] = (contents[key] or 0) + item.count
	end
	return contents
end

-- ============================================================
-- Research and trunk
-- ============================================================
-- The prototype has the largest trunk: the battery slot follows the researched cargo slots, the
-- next ones are locked by a filter nothing matches (names.locked_slot); a research enlarges every
-- car without replacing it (a car trunk has no bar). Batteries are not cargo.

local BATTERY = {name = config.battery_item, quality = "normal"}

-- storage.research[force index], until a research changes.
local function get_research_cache(force)
	local cache = storage.research[force.index]
	if not cache then
		cache = {}
		storage.research[force.index] = cache
	end
	return cache
end

-- config.upgrades[key] at the last researched level.
function _utils.get_upgrade(force, key)
	local cache = get_research_cache(force)
	local value = cache[key]
	if not value then
		local values = config.upgrades[key]
		value = values[1]
		for level = 2, #values do
			if force.technologies[config.names.technology .. "_" .. key .. "_" .. (level - 1)].researched then
				value = values[level]
			end
		end
		cache[key] = value
	end
	return value
end

function _utils.is_researched(force, name)
	local cache = get_research_cache(force)
	if cache[name] == nil then
		cache[name] = force.technologies[name].researched
	end
	return cache[name]
end

function _utils.clear_research_cache(force)
	if storage.research then
		storage.research[force.index] = nil
	end
end

-- nil clears it; what the slot held and does not match goes to other slots, or to the ground.
local function set_slot_filter(entity, inventory, slot, name)
	local stack = inventory[slot]
	local other
	if name and stack.valid_for_read and stack.name ~= name then
		other = {name = stack.name, quality = stack.quality, count = stack.count}
		stack.clear()
	end
	inventory.set_filter(slot, name)
	if other then
		local inserted = inventory.insert(other)
		if inserted < other.count then
			entity.surface.spill_item_stack{position = entity.position, stack = {name = other.name, quality = other.quality, count = other.count - inserted}}
		end
	end
end

local function has_filter(inventory, slot, name)
	local filter = inventory.get_filter(slot)
	return (filter and filter.name) == name
end

-- Filter of each slot = wanted(slot), set only where it differs.
function _utils.set_filters(entity, inventory, wanted)
	for slot = 1, #inventory do
		local name = wanted(slot)
		if not has_filter(inventory, slot, name) then
			set_slot_filter(entity, inventory, slot, name)
		end
	end
end

-- Battery slot, then locked slots; every slow_check_interval (no event for a changed filter).
function _utils.set_trunk_limits(car)
	local trunk = car.get_inventory(defines.inventory.car_trunk)
	local battery_slot = _utils.get_upgrade(car.force, "cargo") + 1
	_utils.set_filters(car, trunk, function(slot)
		if slot == battery_slot then
			return config.battery_item
		end
		return slot > battery_slot and config.names.locked_slot or nil
	end)
end

-- Charge plus the batteries.
function _utils.get_reachable_fuel(car)
	return _utils.get_fuel(car) + _utils.get_battery_count(car) * config.battery_fuel_ratio * _utils.get_fuel_capacity(car)
end

function _utils.get_battery_count(car)
	return car.get_inventory(defines.inventory.car_trunk).get_item_count(BATTERY)
end

-- Returns how many were removed.
function _utils.remove_batteries(car, count)
	if count <= 0 then
		return 0
	end
	return car.get_inventory(defines.inventory.car_trunk).remove{name = BATTERY.name, quality = BATTERY.quality, count = count}
end

function _utils.insert_batteries(car, count)
	if count <= 0 then
		return 0
	end
	return car.get_inventory(defines.inventory.car_trunk).insert{name = BATTERY.name, quality = BATTERY.quality, count = count}
end

function _utils.is_cargo_empty(car)
	local trunk = car.get_inventory(defines.inventory.car_trunk)
	return trunk.get_item_count() - trunk.get_item_count(BATTERY) <= 0
end

-- [key] = count, batteries excluded.
function _utils.get_cargo_contents(trunk)
	local contents = _utils.get_contents(trunk)
	contents[BATTERY.name] = nil
	return contents
end

-- ============================================================
-- Ammo
-- ============================================================
-- One slot (car_ammo), fired by the hidden turret of armed.lua.

function _utils.is_armed(car)
	return _utils.is_researched(car.force, config.armed_technology)
end

-- {name, quality, count} or nil.
function _utils.get_ammo(car)
	local stack = car.get_inventory(defines.inventory.car_ammo)[1]
	if stack.valid_for_read then
		return {name = stack.name, quality = stack.quality.name, count = stack.count}
	end
	return nil
end

function _utils.remove_ammo(car)
	local ammo = _utils.get_ammo(car)
	if ammo then
		car.get_inventory(defines.inventory.car_ammo).clear()
	end
	return ammo
end

-- Returns how many went in.
function _utils.insert_ammo(car, ammo, count)
	if count <= 0 then
		return 0
	end
	return car.get_inventory(defines.inventory.car_ammo).insert{name = ammo.name, quality = ammo.quality, count = count}
end

-- ============================================================
-- Alerts
-- ============================================================
-- Printed to the force and pinned on `target`, marked by the icon of `item`.

function _utils.alert(force, target, message, item)
	force.print(message)
	force.add_custom_alert(target, {type = "item", name = item}, message, true)
end

-- Once until alert_reset: a retry loop does not repeat it.
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
-- Entity release and next task
-- ============================================================
-- Handlers registered by control.lua per kind ("car", "charger", "garage", "chest"): any module
-- releases a stale entity without depending on the modules its cleanup needs.

local release_handlers = {}

function _utils.register_release_handler(kind, handler)
	release_handlers[kind] = handler
end

function _utils.release_entity(kind, id)
	release_handlers[kind](id)
end

-- A car arrived or is charged; an event, since control.lua sits above every module.
function _utils.raise_next_task(car)
	script.raise_event(prototypes.custom_event[config.names.next_task_event], {entity = car})
end

return _utils
