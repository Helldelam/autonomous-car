-- Interface chests between the cars and the logistic network. Both are supply chests for the cars
-- (see construction.lua):
-- - the delivery chest is a requester chest: the script sets its requests from what the batches of
--   the cars lack (logistic.lua), and the robots fill it;
-- - the return chest is an active provider chest: the cars deposit their leftovers and what they
--   mined in it first, and the robots carry it all away.
-- Each is made from a supply chest and the vanilla chest, which gates it behind the logistic research.
-- Graphics: the chests of graphics/chest/make_chests.py, in the colour of the vanilla chest they are made
-- from (blue for the requester, purple for the active provider), opening on their front like the
-- vanilla ones open on their lid (same 7 frames).

local names = require("config").names
local graphics = "__autonomous-car__/graphics/chest/"

local function create_chest(name, source, color)
	local chest = table.deepcopy(data.raw["logistic-container"][source])
	chest.name = name
	chest.minable.result = name
	chest.fast_replaceable_group = nil
	chest.subgroup = names.subgroup
	chest.icon = graphics .. color .. "-icon.png"
	chest.animation.layers[1].filename = graphics .. color .. "-sheet.png"

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
