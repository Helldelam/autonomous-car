-- Ghost selector ("Autonomous car selector" in game): the tool a player drags over
-- ghosts and marked entities to hand them to the cars (see on_area_selected in
-- control.lua), with its shortcut and its key binding.
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
		-- Ghosts, and every entity: the flags "deconstruct", "upgrade" and their "cancel-" variants do not
		-- select what is already marked (they act as filters, and with "cancel-" nothing was selected at
		-- all), so on_area_selected keeps the marked ones itself (ghost_control.is_target).
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
		send_pre_selection_events = true, -- the count next to the cursor while dragging (scripts/gui/selection_preview.lua)
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
