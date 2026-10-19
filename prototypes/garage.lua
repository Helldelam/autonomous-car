-- Garage: a large chest with a slot for a car to park, a battery slot and an ammo slot (they refill the selected parked car) and slots for repair packs; the parked
-- cars are a list kept by the script (park.lua), shown by garage_gui.lua.
local config = require("config")
local names = config.names
local icon = "__autonomous-car__/graphics/garage/icon.png"

local garage = table.deepcopy(data.raw["container"]["steel-chest"])
garage.name = names.garage
garage.minable.result = names.garage
garage.minable.mining_time = 1
garage.subgroup = names.subgroup
garage.icon = icon
garage.max_health = 3500
garage.dying_explosion = "steel-chest-explosion"
-- TODO: use graphics/garage/remnants as the corpse.
garage.resistances =
{
	{
		type = "fire",
		percent = 90
	},
	{
		type = "impact",
		percent = 99
	}
}
garage.collision_box = {{-1.8, -1.8}, {1.8, 1.8}}
garage.selection_box = {{-2, -2}, {2, 2}}
garage.fast_replaceable_group = nil
garage.inventory_size = config.garage_inventory_size
garage.inventory_type = "with_filters_and_bar" -- filters keep the car slot to cars and lock the repair pack slots before the research (garage_control.update_inventory)
-- The connector of the steel chest sits at the centre of a 1x1 chest: this one is at the south-west
-- corner of the garage (the link of circuit.lua is at the south-east corner). Offsets in pixels.
garage.circuit_connector = circuit_connector_definitions.create_single(universal_connector_template,
	{variation = 26, main_offset = util.by_pixel(-45, 62), shadow_offset = util.by_pixel(-40.5, 64), show_shadow = true})
garage.picture =
{
	layers =
	{
		{
			filename = "__autonomous-car__/graphics/garage/garage.png",
			priority = "extra-high",
			width = 128,
			height = 160,
			shift = util.by_pixel(-0.25, -0.5),
			scale = 1
		},
		{
			filename = "__autonomous-car__/graphics/garage/garage-shadow.png",
			priority = "extra-high",
			width = 220,
			height = 92,
			shift = util.by_pixel(49, 32),
			draw_as_shadow = true,
			scale = 1
		}
	}
}

local garage_item = table.deepcopy(data.raw.item["steel-chest"])
garage_item.name = names.garage
garage_item.place_result = names.garage
garage_item.icon = icon
garage_item.subgroup = names.subgroup
garage_item.stack_size = 4

local garage_recipe = {
	type = "recipe",
	name = names.garage,
	enabled = false, -- unlocked by names.technology
	energy_required = 30,
	ingredients = {
		{type = "item", name = "electric-engine-unit", amount = 2},
		{type = "item", name = "iron-gear-wheel", amount = 4},
		{type = "item", name = "iron-stick", amount = 20},
		{type = "item", name = "steel-plate", amount = 40}
	},
	results = {{type = "item", name = names.garage, amount = 1}}
}

data:extend{garage, garage_item, garage_recipe}
