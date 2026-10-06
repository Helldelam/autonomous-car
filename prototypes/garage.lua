-- Garage: a large chest that stores parked cars as items, one per slot.
local config = require("config")

local garage = table.deepcopy(data.raw["container"]["steel-chest"])
garage.name = "autonomous_car_garage"
garage.minable.result = "autonomous_car_garage"
garage.minable.mining_time = 1
garage.subgroup = "autonomous_car"
garage.icon = "__autonomous-car__/graphics/garage/icon.png"
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
garage.inventory_type = "with_custom_stack_size"
garage.inventory_properties = {stack_size_max = 1, with_bar = true}
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
garage_item.name = "autonomous_car_garage"
garage_item.place_result = "autonomous_car_garage"
garage_item.icon = "__autonomous-car__/graphics/garage/icon.png"
garage_item.subgroup = "autonomous_car"
garage_item.stack_size = 4

local garage_recipe = {
  type = "recipe",
  name = "autonomous_car_garage",
  enabled = true,
  energy_required = 30,
  ingredients = {
    {type = "item", name = "electric-engine-unit", amount = 2},
    {type = "item", name = "iron-gear-wheel", amount = 4},
    {type = "item", name = "iron-stick", amount = 20},
    {type = "item", name = "steel-plate", amount = 40}
  },
  results = {{type = "item", name = "autonomous_car_garage", amount = 1}}
}

data:extend{garage, garage_item, garage_recipe}
