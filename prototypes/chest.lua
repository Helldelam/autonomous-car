-- Supply chest: where cars collect the items of a construction batch and
-- drop off their leftovers. A plain container has no opening animation: it stays closed (the
-- frame 0 of the sheet drawn by graphics/chest/make_chests.py, like the other chests of the mod); the
-- hatch of the three chests opens when a car uses them, drawn by scripts/chest_door.lua.

local names = require("config").names
local graphics = "__autonomous-car__/graphics/chest/"
local icon = graphics .. "yellow-icon.png"

local supply_chest = table.deepcopy(data.raw["container"]["steel-chest"])
supply_chest.name = names.chest
supply_chest.minable.result = names.chest
supply_chest.subgroup = names.subgroup
supply_chest.icon = icon
-- The remnants of the storage chest (yellow), in the colours of the chest.
require("prototypes.corpse")(supply_chest, "storage-chest-remnants", graphics .. "remnants/yellow-remnants.png")
supply_chest.picture = {
	layers = {
		{
			filename = graphics .. "yellow-sheet.png",
			priority = "extra-high",
			width = 66,
			height = 74,
			x = 0, -- the first frame, closed
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

-- Drawn by scripts/chest_door.lua over the closed hatch while a car uses the chest (41 x 23 pixels): the dark
-- inside, shared by the three chests, and the hatch of each, named after its chest.
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
