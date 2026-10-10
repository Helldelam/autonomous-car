-- Shortcut that shows or hides the window of missing items (see gui.lua).
-- TODO: custom icon; it borrows the info icon of the game for now.

local names = require("config").names

data:extend{
	{
		type = "shortcut",
		name = names.missing_items_shortcut,
		order = "z[autonomous-car]-b[missing-items]",
		action = "lua",
		toggleable = true,
		icon = "__base__/graphics/icons/info.png",
		icon_size = 64,
		small_icon = "__base__/graphics/icons/info.png",
		small_icon_size = 64,
	}
}
