-- Prototypes shared by the whole mod. Each entity has its own file in prototypes/.
-- Every prototype name comes from config.names, which the scripts read too.
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
	-- Hidden fuel item that stands for the car's battery (see the fuel helpers in _utils.lua).
	{
		type = "item",
		name = names.fuel,
		hidden = true,
		fuel_categories = {names.fuel},
		fuel_value = "6MJ",
		stack_size = 50,
		icon = "__autonomous-car__/graphics/fuel/icon.png",
		subgroup = names.subgroup,
		order = "zz[fuel]",
	},
	-- Filter of a locked inventory slot: nothing can be put in it (trunk slots above the cargo
	-- size, garage slots above the capacity, repair pack slots before the research, ammo slot
	-- before Military). An ammo slot only takes filters that are ammo of its category, hence
	-- the ammo type: it deals no damage, and no script or recipe ever puts it in a slot.
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
		subgroup = "ammo", -- the research lists the ammo of its category by subgroup and order: last
		order = "zz[locked]",
	},
	-- Raised when a car finishes its current step (see _utils.raise_next_task).
	{
		type = "custom-event",
		name = names.next_task_event,
	}
}

require("prototypes/car.lua")
require("prototypes/charger.lua")
require("prototypes/garage.lua")
require("prototypes/chest.lua")
require("prototypes/interface_chests.lua")
require("prototypes/link.lua")
require("prototypes/signals.lua")
require("prototypes/ghost_selector.lua")
require("prototypes/missing_items.lua")
require("prototypes/debug_view.lua")
require("prototypes/turret.lua")
require("prototypes/technology.lua")
