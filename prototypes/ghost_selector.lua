-- Ghost selector: the tool a player drags over ghosts to hand them to the cars
-- (see on_area_selected in control.lua), with its shortcut and its key binding.
-- TODO: custom icon; it borrows the deconstruction planner's for now.

data:extend{
	{
		type = "selection-tool",
		name = "autonomous_car_ghost_selector",
		icon = "__base__/graphics/icons/deconstruction-planner.png",
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
			mode = {"entity-ghost"},
		},
		alt_select = {
			border_color = {r = 1, g = 0.2, b = 0.2},
			cursor_box_type = "entity",
			mode = {"entity-ghost"},
		},
	},
	{
		type = "shortcut",
		name = "autonomous_car_ghost_selector_shortcut",
		order = "z[autonomous-car]",
		action = "spawn-item",
		item_to_spawn = "autonomous_car_ghost_selector",
		icon = "__base__/graphics/icons/deconstruction-planner.png",
		icon_size = 64,
		associated_control_input = "autonomous_car_ghost_selector_input",
		small_icon = "__base__/graphics/icons/deconstruction-planner.png",
	},
	{
		type = "custom-input",
		name = "autonomous_car_ghost_selector_input",
		key_sequence = "ALT + G",
		action = "spawn-item",
		item_to_spawn = "autonomous_car_ghost_selector",
	}
}
