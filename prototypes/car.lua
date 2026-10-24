-- Autonomous car (look of the base game car, trunk, no fuel slot: its burner takes only the hidden
-- fuel item), then the hidden turret of an armed car. The colour is set on each car (control.lua).
local config = require("config")
local names = config.names
local hit_effects = require("__base__/prototypes/entity/hit-effects")
local sounds = require("__base__/prototypes/entity/sounds")
local movement_triggers = require("__base__/prototypes/entity/movement-triggers")
local item_sounds = require("__base__.prototypes.item_sounds")

local icon = "__autonomous-car__/graphics/car/icon.png"

local half_width, half_length = config.car_size.width / 2, config.car_size.length / 2
local box = {{-half_width, -half_length}, {half_width, half_length}}

local car = {
	type = "car",
	name = names.car,
	icon = icon,
	flags = {"placeable-neutral", "player-creation", "placeable-off-grid", "not-flammable"},
	minable = {mining_time = 0.2, result = names.car},
	mined_sound = sounds.deconstruct_medium(0.8),
	max_health = 250,
	is_military_target = true,
	deliver_category = "vehicle",
	dying_explosion = "gun-turret-explosion", -- the base car's is sized for a car twice as big
	alert_icon_shift = util.by_pixel(0, -13),
	energy_per_hit_point = 1,
	collision_mask = {layers={player=true}},
	has_belt_immunity = true,
	resistances =
	{
		{
			type = "fire",
			percent = 50
		},
		{
			type = "impact",
			percent = 30,
			decrease = 50
		},
		{
			type = "acid",
			percent = 20
		}
	},
	collision_box = box,
	selection_box = box,
	damaged_trigger_effect = hit_effects.entity(),
	effectivity = 0.6,
	braking_force = (50 * 1000) / 60, -- 50 kW, per tick (as the base car writes its 200 kW)
	energy_source =
	{
		type = "burner",
		fuel_categories = {names.fuel},
		effectivity = 1,
		fuel_inventory_size = 0,
		smoke =
		{
			{
				name = "car-smoke",
				deviation = {0.25, 0.25},
				frequency = 200,
				position = {0, 1.5},
				starting_frame = 0,
				starting_frame_deviation = 60
			}
		}
	},
	consumption = "8kW",
	friction_force = 2e-3,
	light =
	{
		{
			type = "oriented",
			minimum_darkness = 0.3,
			picture =
			{
				filename = "__core__/graphics/light-cone.png",
				priority = "extra-high",
				flags = { "light" },
				scale = 1,
				width = 200,
				height = 200
			},
			shift = {-0.3, -7},
			size = 2,
			intensity = 0.3,
			color = {0.92, 0.77, 0.3}
		},
		{
			type = "oriented",
			minimum_darkness = 0.3,
			picture =
			{
				filename = "__core__/graphics/light-cone.png",
				priority = "extra-high",
				flags = { "light" },
				scale = 1,
				width = 200,
				height = 200
			},
			shift = {0.3, -7},
			size = 2,
			intensity = 0.3,
			color = {0.92, 0.77, 0.3}
		}
	},
	render_layer = "object",
	light_animation =
	{
		filename = "__base__/graphics/entity/car/car-light.png",
		priority = "low",
		blend_mode = "additive",
		draw_as_glow = true,
		width = 206,
		height = 162,
		line_length = 8,
		direction_count = 64,
		scale = 0.25,
		shift = util.by_pixel(-1 + 2, -6 + 3),
		repeat_count = 2,
	},
	animation =
	{
		layers =
		{
			{
				priority = "low",
				width = 201,
				height = 172,
				frame_count = 2,
				scale = 0.25,
				direction_count = 64,
				shift = util.by_pixel(0+2, -11.5+8.5),
				animation_speed = 8,
				max_advance = 0.2,
				stripes =
				{
					{
						filename = "__base__/graphics/entity/car/car-1.png",
						width_in_frames = 2,
						height_in_frames = 11
					},
					{
						filename = "__base__/graphics/entity/car/car-2.png",
						width_in_frames = 2,
						height_in_frames = 11
					},
					{
						filename = "__base__/graphics/entity/car/car-3.png",
						width_in_frames = 2,
						height_in_frames = 11
					},
					{
						filename = "__base__/graphics/entity/car/car-4.png",
						width_in_frames = 2,
						height_in_frames = 11
					},
					{
						filename = "__base__/graphics/entity/car/car-5.png",
						width_in_frames = 2,
						height_in_frames = 11
					},
					{
						filename = "__base__/graphics/entity/car/car-6.png",
						width_in_frames = 2,
						height_in_frames = 9
					}
				}
			},
			{
				priority = "low",
				width = 199,
				height = 147,
				frame_count = 2,
				apply_runtime_tint = true,
				scale = 0.25,
				direction_count = 64,
				max_advance = 0.2,
				shift = util.by_pixel(0+2, -11+8.5),
				line_length = 1,
				stripes = util.multiplystripes(2,
					{
						{
							filename = "__base__/graphics/entity/car/car-mask-1.png",
							width_in_frames = 1,
							height_in_frames = 13
						},
						{
							filename = "__base__/graphics/entity/car/car-mask-2.png",
							width_in_frames = 1,
							height_in_frames = 13
						},
						{
							filename = "__base__/graphics/entity/car/car-mask-3.png",
							width_in_frames = 1,
							height_in_frames = 13
						},
						{
							filename = "__base__/graphics/entity/car/car-mask-4.png",
							width_in_frames = 1,
							height_in_frames = 13
						},
						{
							filename = "__base__/graphics/entity/car/car-mask-5.png",
							width_in_frames = 1,
							height_in_frames = 12
						}
				})
			},
			{
				scale = 0.5,
				priority = "low",
				width = 114,
				height = 76,
				frame_count = 2,
				draw_as_shadow = true,
				direction_count = 64,
				shift = {0.28125, 0.25},
				max_advance = 0.2,
				stripes = util.multiplystripes(2,
					{
						{
							filename = "__base__/graphics/entity/car/car-shadow-1.png",
							width_in_frames = 1,
							height_in_frames = 22
						},
						{
							filename = "__base__/graphics/entity/car/car-shadow-2.png",
							width_in_frames = 1,
							height_in_frames = 22
						},
						{
							filename = "__base__/graphics/entity/car/car-shadow-3.png",
							width_in_frames = 1,
							height_in_frames = 20
						}
				})
			}
		}
	},
	sound_no_fuel = { filename = "__base__/sound/fight/car-no-fuel-1.ogg", volume = 0.3 },
	stop_trigger_speed = 0.15,
	stop_trigger =
	{
		{
			type = "play-sound",
			sound = {filename = "__base__/sound/car-breaks.ogg", volume = 0.1 }
		}
	},
	impact_category = "metal",
	impact_speed_to_volume_ratio = 4.0,
	working_sound =
	{
		main_sounds =
		{
			{
				sound = {filename = "__base__/sound/car-engine-driving.ogg", volume = 0.33, modifiers = volume_multiplier("main-menu", 2.2)},
				match_volume_to_activity = true,
				activity_to_volume_modifiers =
				{
					multiplier = 1.8,
					offset = 0.95,
				},
				match_speed_to_activity = true,
				activity_to_speed_modifiers =
				{
					multiplier = 0.8,
					minimum = 1.0,
					maximum = 1.4,
					offset = 0.1,
				}
			},
			{
				sound = { filename = "__base__/sound/car-engine.ogg", volume = 0.33 },
				match_volume_to_activity = true,
				fade_in_ticks = 22,
				activity_to_volume_modifiers =
				{
					multiplier = 2.4,
					offset = 1.5,
					inverted = true
				}
			},
		},
		activate_sound = { filename = "__base__/sound/car-engine-start.ogg", volume = 0.33 },
		deactivate_sound = { filename = "__base__/sound/car-engine-stop.ogg", volume = 0.33 },
	},
	open_sound = { filename = "__base__/sound/car-door-open.ogg", volume=0.25 },
	close_sound = { filename = "__base__/sound/car-door-close.ogg", volume = 0.2 },
	rotation_speed = 0.0252,
	rotation_snap_angle = 0.015,
	weight = 100,
	inventory_size = config.car_inventory_size,
	guns = {"vehicle-machine-gun"}, -- shoots after Military, through the turret below (armed.lua)
	allow_passengers = false,
	trash_inventory_size = 0, -- no logistics tab
	track_particle_triggers = movement_triggers.car,
	water_reflection = car_reflection(1),
}

local item = {
	type = "item-with-tags",
	name = names.car,
	icon = icon,
	subgroup = names.subgroup,
	order = "a[robot]-c[autonomous_car]",
	inventory_move_sound = item_sounds.robotic_inventory_move,
	pick_sound = item_sounds.robotic_inventory_pickup,
	drop_sound = item_sounds.robotic_inventory_move,
	place_result = names.car,
	stack_size = 1 -- carries the state of a car out of a garage (tags, health)
}

local recipe = {
	type = "recipe",
	name = names.car,
	enabled = false, -- unlocked by names.technology
	energy_required = 8,
	ingredients = {
		{type = "item", name = "electric-engine-unit", amount = 1},
		{type = "item", name = "iron-plate", amount = 10},
		{type = "item", name = "advanced-circuit", amount = 5},
		{type = "item", name = "steel-plate", amount = 2}
	},
	results = {{type = "item", name = names.car, amount = 1}}
}

-- Remnants of the base car, mask baked in the car colour, at the car's scale (0.25, not 0.5).
require("prototypes.corpse")(car, "car-remnants", "__autonomous-car__/graphics/car/remnants/car-remnants.png",
	function(corpse, animations)
		for _, animation in pairs(animations) do
			animation.layers[2] = nil -- the mask layer, tinted at runtime
			animation.layers[1].scale = 0.25
			animation.layers[1].shift = util.by_pixel(0, 2.25)
		end
		corpse.tile_width = 2
		corpse.tile_height = 2
		corpse.selection_box = {{-1, -1}, {1, 1}}
	end)

data:extend{car, item, recipe}

-- Hidden turret on an armed car that fires its ammo (a script cannot make a car shoot): a gun turret
-- nothing collides with, unseen, unselectable, untargetable, without item.
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
turret.attack_parameters.range = 20 -- that of the base car's machine gun

data:extend{turret}
