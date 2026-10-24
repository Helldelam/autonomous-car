-- Constants of both stages: what prototypes and scripts share, then the tuning.
-- Units: ticks (60 per second), tiles, tiles per tick, turns, joules.
local config = {}

-- ============================================================
-- Prototypes
-- ============================================================
-- Shared by prototypes and scripts: never written as a literal elsewhere.

-- Stored in saves (renaming one drops it from them) and keys of locale/ (a line per language).
-- car, charger, garage and chest each name an entity, its item and its recipe.
config.names = {
	car = "autonomous_car",
	charger = "autonomous_car_charger",
	garage = "autonomous_car_garage",
	charger_post = "autonomous_car_charger_post", -- drawn around a charger (charger.lua)
	charger_arc = "autonomous_car_charger_arc",
	charger_post_shadow = "autonomous_car_charger_post_shadow",
	charger_support = "autonomous_car_charger_support", -- + _tl, _tr, _bl or _br
	garage_door = "autonomous_car_garage_door", -- drawn while a garage door moves (garage.lua)
	garage_interior = "autonomous_car_garage_interior",
	chest_interior = "autonomous_car_chest_interior", -- drawn while a hatch moves (chest.lua); the hatch is "<chest name>_door"
	chest = "autonomous_car_chest", -- supply chest
	delivery_chest = "autonomous_car_delivery_chest", -- requester (chest.lua)
	return_chest = "autonomous_car_return_chest", -- active provider: cars deposit there first
	link = "autonomous_car_link", -- puts a garage or charger on the circuit network (circuit.lua)
	signal_subgroup = "autonomous_car_signals",
	signals = { -- of the links
		free_places = "autonomous_car_signal_free_places", -- garage
		health = "autonomous_car_signal_health", -- garage
		charge = "autonomous_car_signal_charge", -- garage
		buffer = "autonomous_car_signal_buffer", -- charger
		power = "autonomous_car_signal_power", -- charger
		users = "autonomous_car_signal_users", -- charger
	},
	locked_slot = "autonomous_car_locked_slot", -- hidden item no inventory takes: filter of a locked slot
	fuel = "autonomous_car_fuel", -- hidden fuel item and its category
	subgroup = "autonomous_car",
	ghost_selector = "autonomous_car_ghost_selector",
	ghost_selector_shortcut = "autonomous_car_ghost_selector_shortcut",
	ghost_selector_input = "autonomous_car_ghost_selector_input",
	missing_items_shortcut = "autonomous_car_missing_items_shortcut",
	next_task_event = "autonomous_car_next_task", -- _utils.raise_next_task
	turret = "autonomous_car_turret", -- hidden turret of an armed car (armed.lua)
	technology = "autonomous_car", -- also the prefix of the upgrades
	repair_technology = "autonomous_car_repair",
}

config.car_size = {width = 0.7, length = 1} -- collision box; the maneuver probes derive from it
config.car_color = {r = 0.28, g = 0.40, b = 0.58, a = 0.5} -- given to each car built (a prototype has none); icon and remnants share it
-- Raised by research (_utils.get_upgrade): value without, then per level (<names.technology>_<key>_<level>).
config.upgrades = {
	cargo = {20, 30, 40}, -- trunk slots for cargo (the battery slot follows)
	garage = {30, 40, 50}, -- cars per garage
	chargers = {2, 4, 8}, -- cars per charger at once
	charge_speed = {0.5, 1, 2}, -- relative to full_charge_duration
	build_speed = {0.5, 1, 2}, -- build attempts per build_interval
}
config.car_inventory_size = config.upgrades.cargo[#config.upgrades.cargo] + 1 -- most cargo plus the battery slot; later slots locked (_utils.set_trunk_limits)
config.armed_technology = "military" -- the cars carry their gun after it (_utils.is_armed)
config.battery_item = "battery" -- burnt when the tank is almost empty; last trunk slot
config.ammo_items = {"uranium-rounds-magazine", "piercing-rounds-magazine", "firearm-magazine"} -- strongest first (ghost_control.restock)
config.repair_kit_slots = 2 -- locked before repair_technology
config.repair_kit = "repair-pack"
config.garage_inventory_size = 3 + config.repair_kit_slots -- car, battery, ammo, then repair packs (garage_control.update_inventory)
config.charger_buffer_capacity = "60MJ" -- of the prototype; charger_control.update_buffer sets the real size
config.charger_input_flow_limit = "1600kW"

-- ============================================================
-- Steering (movement.drive_tick)
-- ============================================================
-- Three headings (straight, ± lookahead.angle) scored by sample points one tile apart: distance left
-- to the target relative to the car's own (about 1), plus steering_cost.

config.lookahead = {
	angle = 1 / 12, -- of the side headings; also the sectors and arcs of maneuvers and clearings
	side_offset = config.car_size.width, -- the straight heading is sampled on two lines this far each side
	start = 1.3, -- first sample point; minimum about 1.11 (half length + half diagonal), else it overlaps the car (assert)
	length = 4, -- covered by the next points; also the spacing of the points kept on a path
	speed_bonus = 2, -- extra length above speed.fast
}
config.slow_lookahead = { -- finer, in slow mode
	start = 1.6, -- closer, a side sample overlaps the turned car: circles and long detours (assert)
	length = 2,
}
config.steering_cost = {
	blocked = 3, -- point where the car does not fit; again in front of a moving car
	density = 1.5, -- weight of the density further along the heading (and of a maneuver heading)
	path_deviation = 1, -- per car width beyond path.corridor from the followed segment
	margin = 0.5, -- per side, obstacle about a car width beside a point: keeps off the walls
}
config.arrival_distance = 6
config.rails = { -- an arrived car with a rail beside it drives off first (movement.start_retreat)
	scan = 3, -- side of the square searched for rails
	clearance = 3.5, -- no rail closer to the retreat spot
	reach = 2, -- spot reached this close (1.5: the car stopped short, maneuver loop)
	search_radius = 8, -- around the destination
}
config.emergency_brake_lookahead = 3 -- obstacle this far ahead: emergency braking; also keeps a maneuver from ending

-- ============================================================
-- Obstacle density (movement.lua)
-- ============================================================
-- Colliding entities per square tile in a disc. The car counts itself: about 0.035 in a disc on it,
-- 0.024 in the blended density (disc on the car × 2, disc ahead × 1). Mind it in the thresholds.

config.density = {
	radius = 3,
	lookahead_steps = 5, -- steering sums discs 0 to N ahead, end to end
}
config.fast_density = { -- blended density of fast mode; two thresholds: no flicker
	enter = 0.03,
	leave = 0.05,
}
config.dense_area_threshold = 0.12 -- above: slow mode
config.built_zone_distance = 6 -- this close to something built by its force: slow mode (see the next one)
config.normal_beside_built_distance = 6 -- built zone: normal mode while the target is ahead, further than this, not a gate, line free

-- ============================================================
-- Speed and driving modes (movement.update_mode)
-- ============================================================
-- fast (low density, far from anything built), slow (built or very dense, and medium_delay after an
-- emergency stop, a maneuver or a path end), normal otherwise.

config.speed = {
	stopped = 0.01, -- below: stopped (arrived, braking over, stalled)
	slow = 0.1, -- leaving fast mode, the car brakes to its entry speed, not below this
	fast = 0.25, -- above: longer look-ahead (lookahead.speed_bonus)
}
config.braking_duration = 30 -- (0.5s) of travel: a nearer destination brakes the car (no fast mode); also the zone kept free ahead

-- Factors of car.friction_modifier (higher: slower), rebuilt every tick (no drift) and divided by the
-- tile friction the game applies too (except emergency): same speed on any tile.
config.friction = {
	fast = 0.1,
	normal = 1,
	slow = 4,
	maneuver = 10, -- maneuvers, U-turns, wait for a path
	emergency = 100, -- on top of the mode
}

-- ============================================================
-- Path (movement.lua, "Path")
-- ============================================================
-- From the game pathfinder: rescue (maneuver failed, leg too long) or guided (built or dense area,
-- destination out of the cone ahead).

config.path = {
	margin = 0.4, -- added around the car box: further off the walls, no one-tile gaps
	corridor = 2.5, -- no deviation cost within this of the followed segment
	pass_radius = 8, -- a waypoint whose plane is behind within this is passed (else the car circles back)
	u_turn_angle = 0.35, -- waypoint nearer than pass_radius and further off the heading: U-turn (0.25: backed into trees)
	density_factor = 0.3, -- factor of steering_cost.density on a path, which already avoids obstacles
	max_requests = 3, -- rescue requests per leg
	goal = { -- movement.choose_path_goal
		range = 40, -- further destination: the goal is the least dense point this far toward it; also the reach of movement.is_way_open
		sectors = 3, -- directions tried each side, `step` apart
		step = 1 / 12,
		angle_cost = 0.1, -- density equivalent of one step off
		radius = 5, -- pathfinder goal radius, under arrival_distance (3: no path to a garage in a crowded room)
	},
}
config.path_trigger = { -- guided path
	half_angle = 0.2, -- half cone ahead (72°)
	min_distance = config.arrival_distance, -- larger: a ring where the car may neither arrive nor ask (circles)
	max_requests = 10, -- per leg
}
config.gate_waypoints = { -- movement.add_gate_waypoints
	clear = 7, -- path points along the wall pushed out up to this, fading over `ramp`: the gate is taken on a bend
	ramp = 12,
	near = 3, -- point in front of the gate, on its axis
	exit = 3, -- point past the gate
}

-- ============================================================
-- Maneuver (movement.maneuver_tick)
-- ============================================================
-- Slow driving toward a heading (roomiest, least dense), one of six arcs at a time; at most idle_delay.

config.maneuver = {
	probe = { -- car-sized, half a car length apart: no thin wall unseen
		start = 1.5, -- above car length (assert): the car would detect itself
		length = 4,
		near_radius = 0.6, -- the gap before the first probe is searched in this disc
	},
	exit_density = 0.08, -- no end above it (the car and one entity at most)
	min_travel = 2, -- no end before this distance
}

-- ============================================================
-- Clearing (movement.lua, "Clearing")
-- ============================================================
-- Last resort: the car destroys the trees and rocks in its way, at most idle_delay.

config.clearing = {
	lookahead = 8, -- trees and rocks counted along each heading; one within this starts a clearing
	radius = 0.8, -- of the discs of that count
	clear_radius = 1.3, -- destroyed within this of the car and of the points up to `reach` ahead
	reach = 2.5,
	travel = 15, -- ends after this distance
	obstacle_cost = 0.01, -- per tree or rock on a heading, in turns off the destination
	max_count = 10, -- per leg
}

-- ============================================================
-- Fleeing (control.lua, handle_danger)
-- ============================================================

config.flee = {
	radius = 40, -- enemy military target this close: flight
	max_refuge_distance = 150, -- charger or garage away from the enemy, within this and the reachable fuel; else this far straight away
	max_count = 3, -- flights per batch; then the batch is abandoned and enemies ignored until a new one
}

-- ============================================================
-- Shared delays
-- ============================================================
-- Every wait or retry uses one of these; a new usage goes in its list.

config.short_delay = 30 -- (0.5s)
	-- movement.update_mode: no emergency braking again this soon after a stop; check of the straight line without a path
	-- movement.drive_tick: standing still this long after a leg start or a maneuver: hit something; a stalled U-turn ends
	-- movement.maneuver_tick: driving without moving this long: back-off; length of an arc and of a back-off; heading of a
	--   maneuver or clearing chosen again
	-- movement.on_path_finished: retry of a request the pathfinder could not take
	-- travel.handle_critical_fuel: retry without reachable charger; critical check while the tank holds much more
	-- control.lua: refresh of the open windows; spread of an idle car's decision (by unit number)
	-- circuit_control.refresh: period of the links
	-- charger_control.refresh_arcs: period of the arcs
	-- config.garage_door: move_ticks, hold, enter_delay
	-- game_trace: moving cars sampled every half of it
config.medium_delay = 180 -- (3s)
	-- ghost_control.attempt_one_ghost: cooldown of a failed ghost, times its failures
	-- movement.update_mode: slow mode after an emergency stop, a maneuver or a path end
	-- movement.start_path_request: between two requests
	-- garage_control.can_release_car: window of garage_exit.exits
	-- chest_control.update_requests: period of the delivery passes
config.idle_delay = 300 -- (5s)
	-- control.lua: an idle car looks for a task or a garage (set as elapsed by ghost_control.go_idle, travel.handle_empty
	--   and a new car: decision next tick)
	-- movement.maneuver_tick: longest maneuver, a single try; then path, clearing, stuck
	-- movement: longest clearing or U-turn
config.long_delay = 600 -- (10s)
	-- ghost_control.proceed: wait for missing items before their clusters go back; ghost_control.wait_for_phase: a batch
	--   held by an earlier phase gives way
	-- movement.wait_for_path: longest wait for the pathfinder
	-- control.lua: fallback scan of pending clusters, repair of parked cars; wait of a car at its refuge
	-- charger_control.update_buffers: buffer and posts follow the research
	-- travel.stuck_tick: wait before a stuck car retries
	-- travel.is_leg_too_long: margin over the expected duration
	-- gui.show_selection_preview: lifetime of the count by the cursor if the end of the selection is not reported
config.very_long_delay = 3600 -- (60s)
	-- ghost_control.requeue_ghost: a ghost given up after max_revive_attempts waits this long before a car may take it
	-- travel.mark_unreachable: without a way to recharge this long, the car abandons its task

-- Checks that need not run every tick, offset per car (_utils.is_slow_check_due): gates, nearby cars and
-- buildings, density and tile friction (the mode reacts up to this late), critical fuel.
config.slow_check_interval = 6 -- (0.1s)
	-- gui.refresh_tooltips: period of the tooltip lines
	-- _utils.set_trunk_limits, armed.update, garage_control.update_inventories: filters and slots put back (no event)

-- Closest-entity search (_utils.find_closest): chargers, garages and supply chests indexed per square,
-- the nearest squares first; the answer is always the closest.
config.regions = {
	size = 64, -- tiles
	rings = 2, -- rings of squares looked at before every entity is
}

-- ============================================================
-- Construction (construction.lua)
-- ============================================================

config.cluster_radius = 10 -- max distance between neighbouring ghosts of a cluster
config.selection_ghosts_per_tick = 200 -- per tick in each selection phase (ghost_control.step_selection); also the most per cluster
config.assignments_per_tick = 2 -- batches given per tick (ghost_control.retry_pending_clusters)
config.logistic_per_tick = 20 -- cars, then delivery chests, per tick (chest_control.update_requests)
config.build_interval = 6 -- between two build attempts
config.max_revive_attempts = 3 -- failures before a ghost goes back to the pending pool
config.step_back_distance = 30 -- back-off when every ghost left is on cooldown (assert)
config.chest_group_radius = 1.5 -- supply chests this close form a group: reaching one reaches all

-- ============================================================
-- Fuel and charging (charger.lua, travel.lua)
-- ============================================================

config.full_charge_duration = 900 -- (15s) empty to full
-- High estimate for d tiles: fixed + near_per_tile * min(d, near_distance) + far_per_tile * the rest
-- (364 trips of 5 to 11000 tiles, `range-*`: about 90% of the short trips covered, all the long ones).
config.fuel_estimate = {
	fixed = 50000,
	near_per_tile = 2500,
	near_distance = 100,
	far_per_tile = 450, -- measured 165 to 315 on long trips, at most 490
}
-- Posts and arcs of a charger (charger.lua), in tiles from it. Corners in the order of the places (2: top
-- left and bottom right, 4: the other diagonal); at 8 each post splits on the vertices of a support at its
-- corner (charger.png: 50 px each side of the centre, 135 and 70 px above the bottom, 64 px per tile).
config.charger_visual = {
	posts = {{x = -0.78, y = -0.98}, {x = 0.78, y = 0.04}, {x = 0.78, y = -0.98}, {x = -0.78, y = 0.04}},
	split_posts = {}, -- slots i (sideways vertex) and i + 4 (vertical vertex) from post i, filled below
	sideways = {x = 0.34, y = 0.02}, -- vertices of the support from its corner vertex (top left; others mirrored)
	vertical = {x = 0.05, y = 0.25},
	support = {x = 0.15, y = 0.12}, -- centre of the support from its corner vertex
	post_height = 0.64, -- post.png: 90 px at scale 0.5 * 41 / 90
	tip = 0.62, -- above the foot
	shadow = {x = 0.35, y = -0.04}, -- centre of post-shadow.png from the foot
}
for i, corner in ipairs(config.charger_visual.posts) do
	local side_x, side_y = corner.x < 0 and -1 or 1, corner.y < -0.5 and -1 or 1
	local visual = config.charger_visual
	visual.split_posts[i] = {x = corner.x + side_x * visual.sideways.x, y = corner.y + side_y * visual.sideways.y}
	visual.split_posts[i + #visual.posts] = {x = corner.x - side_x * visual.vertical.x, y = corner.y + side_y * visual.vertical.y}
end
config.max_charge_detours = 5 -- in a row before the destination is unreachable
config.critical_fuel_ratio = 0.1 -- below: the car drops everything to recharge; charge of a new car
config.critical_check_fuel_ratio = 0.8 -- above: no critical check (a charger is near)
config.battery_fuel_ratio = config.critical_fuel_ratio / 2 -- one battery
config.battery_trigger_ratio = config.critical_fuel_ratio / 4 -- below: a battery burns; an empty car resumes above
config.pre_park_fuel_ratio = 0.9 -- below: an idle car tops up before parking

-- ============================================================
-- Stuck (travel.lua, "Stuck")
-- ============================================================

config.stuck = {
	min_speed = 0.1, -- lowest average speed of a leg: bounds its duration (travel.is_leg_too_long)
	max_retries = 3, -- then the task is abandoned (unlimited to a charger)
	abandon_delay = 1800, -- (30s) last wait, then the ghosts are released (travel.stuck_tick)
}

-- ============================================================
-- Garage and chests (garage.lua, chest.lua)
-- ============================================================

-- Door, in tiles from the garage (sprite at scale 0.5, shift (-0.25, -19.5) px); redo if the sprite changes.
config.garage_door = {
	x = -0.023, -- centre
	top = -0.125, -- top edge, fixed while the door lifts
	rows = 129, -- height of door.png in pixels (64 per tile)
	open_scale = 0.12, -- share still seen once lifted (hazard strip)
	move_ticks = config.short_delay, -- to open or close, one sprite per tick (prototypes/garage.lua)
	hold = 2 * config.short_delay, -- open
	enter_delay = config.short_delay + 10, -- a parking car stays in view this long after the door starts to open
}
config.garage_door.height = config.garage_door.rows / 64

-- Rows of door.png cut off after `step` ticks of opening.
function config.garage_door.hidden_rows(step)
	local door = config.garage_door
	return math.floor(step / door.move_ticks * door.rows * (1 - door.open_scale) + 0.5)
end

-- Hatch, in tiles from the chest (sprite at scale 0.5, shift (0, -2) px; hatch: pixels 13 to 53 by 36 to 58);
-- redo if the sprite changes.
config.chest_door = {
	left = -0.3125, -- hinges
	top = -0.0781,
	width = 0.6406, -- closed
	height = 0.3594,
	open_scale = 0.12, -- open width / closed width
	move_ticks = 7, -- like the game's logistic chests (opened_duration)
	transfer_delay = 10, -- from the arrival of a car to the transfer, the hatch open by then
}

config.garage_exit = { -- free spot where a garage releases a car
	radius = 8,
	precision = 0.25,
	exits = 4, -- cars per medium_delay: more collide and start badly
}
config.garage_repair_rate = 0.01 -- health fraction per long_delay with a repair pack, which wears as much

-- ============================================================
-- Consistency checks
-- ============================================================
-- Relations the code relies on: a broken one stops the mod from loading.

assert(config.maneuver.probe.start > config.car_size.length,
	"config.maneuver.probe.start must be above config.car_size.length: the car would detect itself")
assert(config.car_size.length / 2 < config.car_size.width,
	"the maneuver probes are half a car length apart: that must stay below config.car_size.width")
assert(config.speed.stopped < config.speed.slow and config.speed.slow < config.speed.fast,
	"config.speed must go up from stopped to slow to fast")
assert(config.fast_density.enter < config.fast_density.leave,
	"config.fast_density.enter must be below config.fast_density.leave")
assert(config.path.goal.radius < config.arrival_distance,
	"config.path.goal.radius must be below config.arrival_distance: a path would end where the car has not arrived")
assert(config.step_back_distance > config.arrival_distance,
	"config.step_back_distance must be above config.arrival_distance: the car would arrive without moving")
assert(config.rails.clearance >= config.rails.scan / 2 + config.rails.reach and config.rails.search_radius > config.rails.clearance,
	"config.rails: a car that stops within reach of its spot must not see rails in its scan (clearance >= scan / 2 + reach), and the search radius must cover the clearance")

-- The first sample point lies beyond the car's own box.
local car_reach = config.car_size.length / 2 + math.sqrt((config.car_size.length / 2) ^ 2 + (config.car_size.width / 2) ^ 2)
assert(config.lookahead.start >= car_reach,
	"config.lookahead.start must be above half the car length plus its half diagonal: the first sample point would overlap the car")
assert(config.slow_lookahead.start >= car_reach,
	"config.slow_lookahead.start must be above half the car length plus its half diagonal: the first sample point would overlap the car")

assert(config.critical_fuel_ratio < config.critical_check_fuel_ratio and config.critical_check_fuel_ratio < config.pre_park_fuel_ratio,
	"config.critical_check_fuel_ratio must lie between config.critical_fuel_ratio and config.pre_park_fuel_ratio")
assert(#config.charger_visual.split_posts >= config.upgrades.chargers[#config.upgrades.chargers]
	and #config.charger_visual.posts < #config.charger_visual.split_posts,
	"config.charger_visual.split_posts needs a post for every place of the charger at the last level of research")

return config
