local config = require("config")
local garage_control = require("scripts.garage")
local _utils = require("scripts._utils")

-- Circuit network output of the garages and the chargers. A garage or a charger cannot show its
-- state on a wire by itself (the cars of a garage are a list of the script, a charger is an energy
-- interface without connector), so each gets a link: a constant combinator beside it, without
-- collision, that the script fills (see prototypes/link.lua). The slots of a garage and its
-- supply chests are read from their own connector.
-- Garage: the item "car" = parked cars, then the signals of config.names.signals: free_places,
-- health (average, %), charge (average, %). Charger: buffer (charge of its buffer, %), power (drawn from
-- the electric network by the charger, kW), users (cars using it).
local circuit_control = {}
local signals = config.names.signals

-- Where the link stands, relative to the building (the garage connector is at its south-west corner).
local OFFSETS = {
	garage = {x = 2.4, y = 1.4}, -- beside the garage, not in front of its door
	charger = {x = 0, y = 1.4},
}

-- Creates the link of a garage or a charger (`kind`), and returns it.
local function create_link(entity, kind)
	local offset = OFFSETS[kind]
	return entity.surface.create_entity{
		name = config.names.link,
		position = {entity.position.x + offset.x, entity.position.y + offset.y},
		force = entity.force,
	}
end

-- Makes sure the data of a building (`data.link`) holds a valid link.
local function ensure_link(entity, data, kind)
	if not (data.link and data.link.valid) then
		data.link = create_link(entity, kind)
	end
	return data.link
end

function circuit_control.destroy_link(data)
	if data and data.link and data.link.valid then
		data.link.destroy()
	end
end

-- Writes `values` ({{type, name, count}, ...}) in the link; nothing is written when they did
-- not change since the last call (`data.link_signals` keeps the last ones as a string).
local function set_signals(link, data, values)
	local parts = {}
	for _, signal in ipairs(values) do
		parts[#parts + 1] = signal.name .. "=" .. signal.count
	end
	local key = table.concat(parts, ",")
	if key == data.link_signals and link.get_or_create_control_behavior().sections_count > 0 then
		return
	end
	data.link_signals = key

	local behavior = link.get_or_create_control_behavior()
	local section = behavior.get_section(1) or behavior.add_section()
	local filters = {}
	for _, signal in ipairs(values) do
		filters[#filters + 1] = {value = {type = signal.type, name = signal.name, quality = "normal", comparator = "="}, min = signal.count}
	end
	section.filters = filters
end

local function round(value)
	return math.floor(value + 0.5)
end

local function refresh_garage(garage, data)
	local cars = data.cars
	local health, fuel = 0, 0
	for _, entry in ipairs(cars) do
		health = health + entry.health
		fuel = fuel + entry.fuel
	end
	local count = #cars
	set_signals(ensure_link(garage, data, "garage"), data, {
		{type = "item", name = config.names.car, count = count},
		{type = "virtual", name = signals.free_places, count = garage_control.get_capacity(garage) - count},
		{type = "virtual", name = signals.health, count = count > 0 and round(health / count * 100) or 0},
		{type = "virtual", name = signals.charge, count = count > 0 and round(fuel / count * 100) or 0},
	})
end

local function refresh_charger(charger, data, tick)
	-- Power drawn from the network since the last call: the change of the buffer plus what the cars took.
	local energy = charger.energy
	local power = data.power or 0
	if data.last_tick and tick > data.last_tick then
		local drawn = energy - data.last_energy + data.transferred
		power = math.max(0, round(drawn / (tick - data.last_tick) * 60 / 1000))
	end
	data.power, data.last_energy, data.last_tick, data.transferred = power, energy, tick, 0
	set_signals(ensure_link(charger, data, "charger"), data, {
		{type = "virtual", name = signals.buffer, count = round(energy / charger.electric_buffer_size * 100)},
		{type = "virtual", name = signals.power, count = power},
		{type = "virtual", name = signals.users, count = data.users},
	})
end

-- Called every tick: each garage and charger is refreshed every config.short_delay ticks.
function circuit_control.refresh(tick)
	for id, garage in pairs(storage.garages) do
		if garage.valid and _utils.is_slow_check_due(garage, tick, config.short_delay) then
			refresh_garage(garage, storage.garage_data[id])
		end
	end
	for id, charger in pairs(storage.chargers) do
		if charger.valid and _utils.is_slow_check_due(charger, tick, config.short_delay) then
			refresh_charger(charger, storage.charger_data[id], tick)
		end
	end
end

return circuit_control
