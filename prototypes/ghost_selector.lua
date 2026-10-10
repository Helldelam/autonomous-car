-- Ghost selector: the tool a player drags over ghosts to hand them to the cars
-- (see on_area_selected in control.lua), with its shortcut and its key binding.
-- TODO: custom icon; it borrows the blueprint's for now.

local names = require("config").names

data:extend{
	{
		type = "selection-tool",
		name = names.ghost_selector,
		icon = "__base__/graphics/icons/blueprint.png",
		icon_size = 64,
		-- Same flags as the deconstruction planner: the item only ever exists in
		-- the cursor, and is never crafted or stored.
		flags = {"only-in-cursor", "not-stackable", "spawnable"},
		hidden = true,
		subgroup = "tool",
		order = "z[autonomous-car]-a[ghost-selector]",
		stack_size = 1,
		skip_fog_of_war = true,
		select = {
			border_color = {r = 0, g = 0.6, b = 1},
			cursor_box_type = "entity",
			mode = {"entity-ghost", "deconstruct", "upgrade"},
		},
		alt_select = {
			border_color = {r = 1, g = 0.2, b = 0.2},
			cursor_box_type = "entity",
			mode = {"entity-ghost", "deconstruct", "upgrade"},
		},
	},
	{
		type = "shortcut",
		name = names.ghost_selector_shortcut,
		order = "z[autonomous-car]",
		action = "spawn-item",
		item_to_spawn = names.ghost_selector,
		icon = "__base__/graphics/icons/blueprint.png",
		icon_size = 64,
		associated_control_input = names.ghost_selector_input,
		small_icon = "__base__/graphics/icons/blueprint.png",
	},
	{
		type = "custom-input",
		name = names.ghost_selector_input,
		key_sequence = "ALT + G",
		action = "spawn-item",
		item_to_spawn = names.ghost_selector,
	}
}
