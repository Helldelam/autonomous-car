-- Garage: a large chest (slots: car to park, battery, ammo, repair packs); the parked cars are
-- records of scripts/garage.lua.
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
require("prototypes.corpse")(garage, "steel-chest-remnants", "__autonomous-car__/graphics/garage/remnants/garage-remnants.png",
	function(corpse, animations)
		corpse.tile_width = 4
		corpse.tile_height = 4
		corpse.selection_box = {{-2, -2}, {2, 2}}
		for _, animation in pairs(animations) do
			animation.width = 600
			animation.height = 352
			animation.scale = 0.5
			animation.shift = {1.719, -0.39} -- the garage of the image (x 62 to 316, y 2 to 322) where the sprite is
		end
	end)
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
garage.inventory_type = "with_filters_and_bar" -- garage_control.update_inventory
-- Connector at the south-west corner (the link is at the south-east one).
garage.circuit_connector = circuit_connector_definitions.create_vector(universal_connector_template,
	{{variation = 26, main_offset = util.by_pixel(-45, 62), shadow_offset = util.by_pixel(-40.5, 64), show_shadow = true}})
garage.picture =
{
	layers =
	{
		{
			filename = "__autonomous-car__/graphics/garage/garage.png",
			priority = "extra-high",
			width = 256,
			height = 320,
			shift = util.by_pixel(-0.25, -19.5), -- foot on the lower edge of the selection box
			scale = 0.5
		},
		{
			filename = "__autonomous-car__/graphics/garage/garage-shadow.png",
			priority = "extra-high",
			width = 440,
			height = 184,
			shift = util.by_pixel(49.75, 14.5), -- that of the steel chest shadow, times 4
			draw_as_shadow = true,
			scale = 0.5
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

-- Drawn over the closed door while it lifts (200 x 129 pixels): the interior, and per step of the
-- opening the door without its rows already above the top edge (names.garage_door .. "_" .. step).
local door = config.garage_door
local function door_sprite(name, file, hidden)
	return {
		type = "sprite",
		name = name,
		filename = "__autonomous-car__/graphics/garage/" .. file,
		priority = "extra-high",
		y = hidden,
		width = 200,
		height = door.rows - hidden,
		scale = 0.5
	}
end

local sprites = {garage, garage_item, garage_recipe, door_sprite(names.garage_interior, "interior.png", 0)}
for step = 0, door.move_ticks do
	sprites[#sprites + 1] = door_sprite(names.garage_door .. "_" .. step, "door.png", door.hidden_rows(step))
end
data:extend(sprites)
