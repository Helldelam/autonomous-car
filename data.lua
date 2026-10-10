-- Prototypes shared by the whole mod. Each entity has its own file in prototypes/.
-- Every prototype name comes from config.names, which the scripts read too.
local names = require("config").names

-- TODO: technologies (TechnologyPrototype) that unlock the mod's items and improve charge and
-- repair speed, garage repair, garage/charger/car capacity, build speed and driving speed.
-- See "À faire" in CLAUDE.md.
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
		fuel_category = names.fuel,
		fuel_value = "6MJ",
		stack_size = 50,
		icon = "__autonomous-car__/graphics/fuel/icon.png",
		subgroup = names.subgroup,
		order = "zz[fuel]",
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
require("prototypes/ghost_selector.lua")
require("prototypes/missing_items.lua")
