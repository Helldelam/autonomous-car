-- Supply chest: where cars collect the items of a construction batch and
-- drop off their leftovers.
-- TODO: custom graphics and icon; it looks like a steel chest for now.

local names = require("config").names

local supply_chest = table.deepcopy(data.raw["container"]["steel-chest"])
supply_chest.name = names.chest
supply_chest.minable.result = names.chest
supply_chest.subgroup = names.subgroup

local supply_chest_item = table.deepcopy(data.raw.item["steel-chest"])
supply_chest_item.name = names.chest
supply_chest_item.place_result = names.chest
supply_chest_item.subgroup = names.subgroup
supply_chest_item.stack_size = 10

local supply_chest_recipe = {
	type = "recipe",
	name = names.chest,
	enabled = false, -- unlocked by names.technology
	energy_required = 5,
	ingredients = {
		{type = "item", name = "steel-plate", amount = 8},
		{type = "item", name = "iron-gear-wheel", amount = 4}
	},
	results = {{type = "item", name = names.chest, amount = 1}}
}

data:extend{supply_chest, supply_chest_item, supply_chest_recipe}
