-- Shortcut that shows or hides the debug drawing of the cars (see scripts/debug/debug_view.lua).
-- TODO: custom icon; it borrows the car icon of the game for now.

local names = require("config").names

data:extend{
	{
		type = "shortcut",
		name = names.debug_view_shortcut,
		order = "z[autonomous-car]-c[debug-view]",
		action = "lua",
		toggleable = true,
		icon = "__base__/graphics/icons/car.png",
		icon_size = 64,
		small_icon = "__base__/graphics/icons/car.png",
		small_icon_size = 64,
	}
}
