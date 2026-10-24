-- Supply chest (yellow), then the delivery (requester, blue) and return (active provider, purple)
-- chests, both supply chests for the cars. A container has no opening animation: frame 0 of the
-- sheet, the hatch drawn for cars by scripts/chest.lua (for robots and players, the 7 frames).

local names = require("config").names
local graphics = "__autonomous-car__/graphics/chest/"
local icon = graphics .. "yellow-icon.png"

local supply_chest = table.deepcopy(data.raw["container"]["steel-chest"])
supply_chest.name = names.chest
supply_chest.minable.result = names.chest
supply_chest.subgroup = names.subgroup
supply_chest.icon = icon
require("prototypes.corpse")(supply_chest, "storage-chest-remnants", graphics .. "remnants/yellow-remnants.png")
supply_chest.picture = {
	layers = {
		{
			filename = graphics .. "yellow-sheet.png",
			priority = "extra-high",
			width = 66,
			height = 74,
			x = 0, -- closed
			shift = util.by_pixel(0, -2),
			scale = 0.5
		},
		{
			filename = "__base__/graphics/entity/logistic-chest/logistic-chest-shadow.png",
			priority = "extra-high",
			width = 112,
			height = 46,
			shift = util.by_pixel(12, 4.5),
			draw_as_shadow = true,
			scale = 0.5
		}
	}
}

local supply_chest_item = table.deepcopy(data.raw.item["steel-chest"])
supply_chest_item.name = names.chest
supply_chest_item.place_result = names.chest
supply_chest_item.subgroup = names.subgroup
supply_chest_item.icon = icon
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

-- Drawn over the closed hatch (41 x 23 pixels): the inside, shared, and the hatch of each chest.
local function hatch_sprite(name, file)
	return {
		type = "sprite",
		name = name,
		filename = graphics .. file,
		priority = "extra-high",
		width = 41,
		height = 23,
		scale = 0.5
	}
end

data:extend{supply_chest, supply_chest_item, supply_chest_recipe,
	hatch_sprite(names.chest_interior, "interior.png"), hatch_sprite(names.chest .. "_door", "yellow-door.png"),
	hatch_sprite(names.delivery_chest .. "_door", "blue-door.png"), hatch_sprite(names.return_chest .. "_door", "purple-door.png")}

-- Made from a supply chest and the vanilla chest, which gates it behind the logistic research.
local function create_chest(name, source, color)
	local chest = table.deepcopy(data.raw["logistic-container"][source])
	chest.name = name
	chest.minable.result = name
	chest.fast_replaceable_group = nil
	chest.subgroup = names.subgroup
	chest.icon = graphics .. color .. "-icon.png"
	chest.robot_door.animation.layers[1].filename = graphics .. color .. "-sheet.png"
	require("prototypes.corpse")(chest, source .. "-remnants", graphics .. "remnants/" .. color .. "-remnants.png")

	local item = table.deepcopy(data.raw.item[source])
	item.name = name
	item.place_result = name
	item.subgroup = names.subgroup
	item.icon = graphics .. color .. "-icon.png"
	item.stack_size = 10

	local recipe = {
		type = "recipe",
		name = name,
		enabled = false, -- unlocked by names.technology
		energy_required = 5,
		ingredients = {
			{type = "item", name = names.chest, amount = 1},
			{type = "item", name = source, amount = 1}
		},
		results = {{type = "item", name = name, amount = 1}}
	}
	data:extend{chest, item, recipe}
end

create_chest(names.delivery_chest, "requester-chest", "blue")
create_chest(names.return_chest, "active-provider-chest", "purple")
