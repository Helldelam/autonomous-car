-- Virtual signals of the links (circuit.lua): the state of a garage or a charger on a wire.
local names = require("config").names

local signal_icons = "__base__/graphics/icons/signal/"
local car_icon = "__autonomous-car__/graphics/car/icon.png"
local garage_icon = "__autonomous-car__/graphics/garage/icon.png"
local charger_icon = "__autonomous-car__/graphics/charger/icon.png"

-- A small icon in the bottom right corner of a larger one.
local function badge(icon)
	return {icon = icon, icon_size = 64, scale = 0.5, shift = {10, 10}}
end

local function create_signal(name, order, icons)
	return {
		type = "virtual-signal",
		name = name,
		icons = icons,
		subgroup = names.signal_subgroup,
		order = order,
	}
end

data:extend{
	{
		type = "item-subgroup",
		name = names.signal_subgroup,
		group = "signals",
		order = "zz",
	},
	create_signal(names.signals.free_places, "a", {
		{icon = garage_icon, icon_size = 64},
		badge(signal_icons .. "signal-checked-green.png"),
	}),
	create_signal(names.signals.health, "b", {{icon = signal_icons .. "signal-heart.png", icon_size = 64}}),
	create_signal(names.signals.charge, "c", {
		{icon = signal_icons .. "signal-battery-mid-level.png", icon_size = 64},
		badge(garage_icon),
	}),
	create_signal(names.signals.buffer, "cb", {
		{icon = signal_icons .. "signal-battery-mid-level.png", icon_size = 64},
		badge(charger_icon),
	}),
	create_signal(names.signals.power, "d", {{icon = signal_icons .. "signal-lightning.png", icon_size = 64}}),
	create_signal(names.signals.users, "e", {
		{icon = car_icon, icon_size = 64},
		badge(signal_icons .. "signal-lightning.png"),
	}),
}
