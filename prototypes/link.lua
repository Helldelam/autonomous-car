-- Link: a constant combinator the script places beside each garage and charger and fills with
-- their state (circuit.lua). It has no collision, cannot be mined or blueprinted, and goes away
-- with its building.
local names = require("config").names

local link = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
link.name = names.link
link.minable = nil
link.hidden = true
link.collision_mask = {layers = {}}
link.flags = {"placeable-neutral", "player-creation", "not-rotatable", "not-blueprintable", "not-deconstructable", "not-flammable"}
link.max_health = 500
link.allow_copy_paste = false

data:extend{link}
