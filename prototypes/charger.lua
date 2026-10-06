-- Charging station: an electric energy interface whose buffer the cars draw from.
local config = require("config")

local charger = table.deepcopy(data.raw["electric-energy-interface"]["electric-energy-interface"])
charger.name = "autonomouscar_charging_station"
charger.minable.result = "autonomouscar_charging_station"
charger.hidden = false
charger.gui_mode = "none"
charger.subgroup = "autocar"
charger.energy_production = "0W"
charger.energy_source.buffer_capacity = config.charger_buffer_capacity
charger.energy_source.usage_priority = "secondary-input"
charger.energy_source.input_flow_limit = config.charger_input_flow_limit
charger.energy_source.output_flow_limit = "0W"
charger.picture =
{
  layers =
  {
    {
      filename = "__autonomous-car__/graphics/charger/charger.png",
      priority = "high",
      width = 130,
      height = 189,
      shift = util.by_pixel(0, -11),
      tint = {1, 1, 1, 1},
      scale = 0.5
    },
    {
      filename = "__autonomous-car__/graphics/charger/charger-shadow.png",
      priority = "high",
      width = 234,
      height = 106,
      shift = util.by_pixel(29, 6),
      draw_as_shadow = true,
      scale = 0.5
    }
  }
}

local charger_item = table.deepcopy(data.raw.item["electric-energy-interface"])
charger_item.name = "autonomouscar_charging_station"
charger_item.place_result = "autonomouscar_charging_station"
charger_item.icon = "__autonomous-car__/graphics/acs_icon.png"
charger_item.subgroup = "autocar"
charger_item.stack_size = 5

local charger_recipe = {
  type = "recipe",
  name = "autonomouscar_charging_station",
  enabled = true,
  energy_required = 8,
  ingredients = {
    {type = "item", name = "battery", amount = 10},
    {type = "item", name = "advanced-circuit", amount = 10},
    {type = "item", name = "steel-plate", amount = 10}
  },
  results = {{type = "item", name = "autonomouscar_charging_station", amount = 1}}
}

data:extend{charger, charger_item, charger_recipe}
