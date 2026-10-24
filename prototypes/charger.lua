-- Charger: an electric energy interface the cars draw from, with the look of the accumulator in steel
-- blue, without its posts (drawn by scripts/charger.lua).
local config = require("config")
local names = config.names
local icon = "__autonomous-car__/graphics/charger/icon.png"

local charger = table.deepcopy(data.raw["electric-energy-interface"]["electric-energy-interface"])
charger.name = names.charger
charger.minable.result = names.charger
-- The copy is hidden and has `icons`, which win over `icon`.
charger.hidden = false
charger.icons = nil
charger.icon = icon
charger.gui_mode = "none"
require("prototypes.corpse")(charger, "accumulator-remnants", "__autonomous-car__/graphics/charger/remnants/charger-remnants.png")
charger.subgroup = names.subgroup
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
charger_item.name = names.charger
charger_item.place_result = names.charger
charger_item.hidden = false
charger_item.icons = nil
charger_item.icon = icon
charger_item.subgroup = names.subgroup
charger_item.stack_size = 5

local charger_recipe = {
	type = "recipe",
	name = names.charger,
	enabled = false, -- unlocked by names.technology
	energy_required = 8,
	ingredients = {
		{type = "item", name = "battery", amount = 10},
		{type = "item", name = "advanced-circuit", amount = 10},
		{type = "item", name = "steel-plate", amount = 10}
	},
	results = {{type = "item", name = names.charger, amount = 1}}
}

-- Drawn around the charger: a post per place, an arc at its tip while a car charges.
data:extend{charger, charger_item, charger_recipe,
	{
		type = "sprite",
		name = names.charger_post,
		filename = "__autonomous-car__/graphics/charger/post.png",
		priority = "high",
		width = 48,
		height = 90,
		scale = 0.5 * 41 / 90 -- 40 pixels at the scale of the body (0.5)
	},
	{
		type = "sprite",
		name = names.charger_post_shadow,
		filename = "__autonomous-car__/graphics/charger/post-shadow.png",
		priority = "high",
		width = 90,
		height = 11,
		draw_as_shadow = true,
		scale = 0.25
	},
	{
		type = "animation",
		name = names.charger_arc,
		filename = "__autonomous-car__/graphics/charger/arc.png",
		priority = "high",
		width = 64,
		height = 64,
		frame_count = 12,
		line_length = 6,
		animation_speed = 0.5,
		scale = 0.5,
		draw_as_glow = true
	}}

-- Support under the posts of a corner (8 places).
for _, corner in pairs{"tl", "tr", "bl", "br"} do
	data:extend{{
		type = "sprite",
		name = names.charger_support .. "_" .. corner,
		filename = "__autonomous-car__/graphics/charger/support-" .. corner .. ".png",
		priority = "high",
		width = 31,
		height = 23,
		scale = 0.5
	}}
end
