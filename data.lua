-- Shared prototypes; each entity has its file in prototypes/, every name comes from config.names.
local names = require("config").names

data:extend{
	{
		type = "fuel-category",
		name = names.fuel
	},
	{
		type = "item-subgroup",
		name = names.subgroup,
		group = "logistics",
		order = "fa" -- next to transport
	},
	-- Hidden fuel item: the car's battery (fuel helpers of _utils.lua).
	{
		type = "item",
		name = names.fuel,
		hidden = true,
		fuel_categories = {names.fuel},
		fuel_value = "6MJ",
		stack_size = 50,
		icon = "__autonomous-car__/graphics/fuel/icon.png", -- transparent, never shown
		subgroup = names.subgroup,
		order = "zz[fuel]",
	},
	-- Filter of a locked slot, which nothing can enter. An ammo item, since an ammo slot only takes
	-- ammo filters of its category; it deals no damage and nothing ever puts it in a slot.
	{
		type = "ammo",
		name = names.locked_slot,
		hidden = true,
		stack_size = 1,
		ammo_category = "bullet",
		magazine_size = 1,
		ammo_type = {
			action = {
				type = "direct",
				action_delivery = {type = "instant", target_effects = {{type = "damage", damage = {amount = 0, type = "physical"}}}},
			},
		},
		icon = "__autonomous-car__/graphics/locked/icon.png",
		icon_size = 64,
		subgroup = "ammo", -- listed last by the research
		order = "zz[locked]",
	},
	-- A car finished its step (_utils.raise_next_task).
	{
		type = "custom-event",
		name = names.next_task_event,
	}
}

require("prototypes.car")
require("prototypes.charger")
require("prototypes.garage")
require("prototypes.chest")
require("prototypes.circuit")
require("prototypes.shortcuts")
require("prototypes.technology")
