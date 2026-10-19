-- Research of the mod: one technology unlocks the recipes, one makes the garages repair the
-- parked cars, and the others raise a value the script reads (config.upgrades, through
-- _utils.get_upgrade): cargo size, garage capacity, cars per charger, charge speed and
-- build speed. The Military research arms the cars (_utils.is_armed), so it has no
-- technology here.
-- TODO: placeholder costs; adjust them when the mod is balanced.
local config = require("config")
local names = config.names

-- Icons (graphics/technology/<name>.png, 256 pixels): the item the research is about, with
-- the small mark of the researches of the base game when it improves a value. Made from the
-- icons of the items and the marks of the base game (graphics/technology/make_icons.py).
local function icon_of(name)
	return "__autonomous-car__/graphics/technology/" .. name .. ".png"
end

local red_green = {
	{"automation-science-pack", 1},
	{"logistic-science-pack", 1}
}
local chemical = table.deepcopy(red_green)
table.insert(chemical, {"chemical-science-pack", 1})
local production = table.deepcopy(chemical)
table.insert(production, {"production-science-pack", 1})

local function create_technology(name, prerequisites, ingredients, count, effects, order, icon)
	return {
		type = "technology",
		name = name,
		icon = icon_of(icon),
		icon_size = 256,
		effects = effects,
		prerequisites = prerequisites,
		unit = {count = count, ingredients = ingredients, time = 30},
		order = order
	}
end

local technologies = {
	create_technology(names.technology, {"automobilism", "battery", "electric-engine"}, chemical, 200, {
		{type = "unlock-recipe", recipe = names.car},
		{type = "unlock-recipe", recipe = names.charger},
		{type = "unlock-recipe", recipe = names.chest},
		{type = "unlock-recipe", recipe = names.delivery_chest},
		{type = "unlock-recipe", recipe = names.return_chest},
		{type = "unlock-recipe", recipe = names.garage}
	}, "e-a-a", "main"),
	-- The garages repair the parked cars with repair packs (garage_control.update_inventory).
	create_technology(names.repair_technology, {names.technology, "automation-3"}, production, 150, {
		{type = "nothing", effect_description = {"effect-description." .. names.repair_technology}}
	}, "e-a-b", "repair")
}

-- Like "Worker robot cargo size": the effect has no meaning for the game, its description gives
-- the new value. Level 1 needs the main research, level 2 the first level and the production science.
local costs = {
	cargo = {200, 300},
	garage = {150, 250},
	chargers = {150, 250},
	charge_speed = {150, 250},
	build_speed = {150, 250},
}
local order = "e-a-c"
for _, key in ipairs{"cargo", "garage", "chargers", "charge_speed", "build_speed"} do
	for level = 1, 2 do
		local name = names.technology .. "_" .. key .. "_" .. level
		local prerequisites = level == 1 and {names.technology, "chemical-science-pack"}
			or {names.technology .. "_" .. key .. "_1", "production-science-pack"}
		-- Speeds are shown as the factor over the force without the research (x2 then x4); the others as the new value.
		local shown = tostring(string.find(key, "speed") and config.upgrades[key][level + 1] / config.upgrades[key][1] or config.upgrades[key][level + 1])
		local technology = create_technology(name, prerequisites, level == 1 and chemical or production, costs[key][level], {{
			type = "nothing",
			effect_description = {"effect-description." .. names.technology .. "_" .. key, shown}
		}}, order .. key, key)
		technology.localised_description = {"technology-description." .. names.technology .. "_" .. key, shown}
		table.insert(technologies, technology)
	end
end

data:extend(technologies)
