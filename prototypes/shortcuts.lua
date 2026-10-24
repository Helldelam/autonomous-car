-- Ghost selector (the tool dragged over ghosts and marked entities, control.lua on_area_selected),
-- its shortcut and key, and the shortcut of the missing items window.

local names = require("config").names

data:extend{
	{
		type = "selection-tool",
		name = names.ghost_selector,
		icon = "__autonomous-car__/graphics/shortcut/selector-icon.png",
		icon_size = 64,
		flags = {"only-in-cursor", "not-stackable", "spawnable"}, -- like the deconstruction planner
		hidden = true,
		subgroup = "tool",
		order = "z[autonomous-car]-a[ghost-selector]",
		stack_size = 1,
		skip_fog_of_war = true,
		-- Every entity: the "deconstruct" and "upgrade" modes skip what is already marked, so the script
		-- keeps the marked ones itself (ghost_control.is_target).
		select = {
			border_color = {r = 0, g = 0.6, b = 1},
			cursor_box_type = "entity",
			mode = {"entity-ghost", "tile-ghost", "any-entity"},
		},
		alt_select = {
			border_color = {r = 1, g = 0.2, b = 0.2},
			cursor_box_type = "entity",
			mode = {"entity-ghost", "tile-ghost", "any-entity"},
		},
		always_include_tiles = true,
		send_pre_selection_events = true, -- count by the cursor (gui.show_selection_preview)
	},
	{
		type = "shortcut",
		name = names.ghost_selector_shortcut,
		order = "z[autonomous-car]",
		action = "spawn-item",
		item_to_spawn = names.ghost_selector,
		icon = "__autonomous-car__/graphics/shortcut/selector-x56.png",
		icon_size = 56,
		associated_control_input = names.ghost_selector_input,
		small_icon = "__autonomous-car__/graphics/shortcut/selector-x24.png",
		small_icon_size = 24,
	},
	{
		type = "custom-input",
		name = names.ghost_selector_input,
		key_sequence = "ALT + G",
		action = "spawn-item",
		item_to_spawn = names.ghost_selector,
	}
}

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
