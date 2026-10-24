-- Shortcut that shows or hides the window of missing items (see scripts/gui/missing_items.lua).
-- Icons: graphics/shortcut/make_shortcuts.py.

local names = require("config").names

data:extend{
	{
		type = "shortcut",
		name = names.missing_items_shortcut,
		order = "z[autonomous-car]-b[missing-items]",
		action = "lua",
		toggleable = true,
		icon = "__autonomous-car__/graphics/shortcut/missing-x56.png",
		icon_size = 56,
		small_icon = "__autonomous-car__/graphics/shortcut/missing-x24.png",
		small_icon_size = 24,
	}
}
