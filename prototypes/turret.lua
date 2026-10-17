-- Hidden turret that follows an armed car and fires its ammo for it (see armed.lua):
-- a car cannot be told to shoot by script. It is a gun turret that nothing collides
-- with, that cannot be seen, selected, targeted or hurt, and that the player never
-- builds (no item): the script creates it.

local names = require("config").names

local empty = {filename = "__core__/graphics/empty.png", width = 1, height = 1, frame_count = 1, direction_count = 1}

local turret = table.deepcopy(data.raw["ammo-turret"]["gun-turret"])
turret.name = names.turret
turret.flags = {"placeable-off-grid", "not-on-map", "not-blueprintable", "not-deconstructable", "not-repairable", "hide-alt-info", "not-in-kill-statistics"}
turret.hidden = true
turret.hidden_in_factoriopedia = true
turret.minable = nil
turret.placeable_by = nil
turret.fast_replaceable_group = nil
turret.corpse = nil
turret.dying_explosion = nil
turret.create_ghost_on_death = false
turret.is_military_target = false
turret.selectable_in_game = false
turret.alert_when_attacking = false
turret.alert_when_damaged = false
turret.collision_mask = {layers = {}}
turret.collision_box = {{0, 0}, {0, 0}}
turret.selection_box = {{0, 0}, {0, 0}}
turret.circuit_connector = nil
turret.circuit_wire_max_distance = nil
turret.icon_draw_specification = nil
turret.icons_positioning = nil
turret.graphics_set = {}
turret.base_picture = nil
turret.folded_animation = empty
turret.preparing_animation = empty
turret.prepared_animation = empty
turret.attacking_animation = empty
turret.folding_animation = empty
turret.preparing_sound = nil
turret.folding_sound = nil
turret.open_sound = nil
turret.close_sound = nil
turret.damaged_trigger_effect = nil
turret.attack_parameters.range = 20 -- the range of the machine gun of the base game car

data:extend{turret}
