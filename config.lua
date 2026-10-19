-- Constants shared by the data stage (prototypes) and the control stage: first
-- what the two stages must agree on, then the tuning values.
-- Units: durations in ticks (60 per second), distances in tiles, speeds in
-- tiles per tick, angles as a fraction of a full turn, energy in joules.
local config = {}

-- ============================================================
-- Prototypes
-- ============================================================
-- Everything the prototypes and the scripts must agree on is defined here once
-- and read by both. Never write one of these names or sizes as a literal
-- anywhere else: that is what keeps the two stages consistent.

-- Prototype names. car, charger, garage and chest each name an entity, its
-- item and its recipe. They are stored in saved games: renaming one removes
-- it from every existing save. The names shown in game are in locale/, one
-- file per language: a new or renamed prototype needs its line in each.
config.names = {
	car = "autonomous_car",
	charger = "autonomous_car_charger",
	garage = "autonomous_car_garage",
	chest = "autonomous_car_chest", -- supply chest
	delivery_chest = "autonomous_car_delivery_chest", -- supply chest that requests from the logistic network what the cars lack (see logistic.lua)
	return_chest = "autonomous_car_return_chest", -- supply chest the robots empty: the cars deposit their leftovers in it first
	link = "autonomous_car_link", -- invisible-collision constant combinator beside a garage or a charger that puts their state on the circuit network (see circuit.lua)
	signal_subgroup = "autonomous_car_signals", -- row of the signals menu
	signals = { -- virtual signals of the links (see circuit.lua)
		free_places = "autonomous_car_signal_free_places", -- garage
		health = "autonomous_car_signal_health", -- garage
		charge = "autonomous_car_signal_charge", -- garage: average charge of the parked cars
		buffer = "autonomous_car_signal_buffer", -- charger: charge of its buffer
		power = "autonomous_car_signal_power", -- charger
		users = "autonomous_car_signal_users", -- charger
	},
	locked_slot ="autonomous_car_locked_slot", -- hidden item that no inventory takes: the filter of a locked slot (see _utils.set_filters)
	fuel = "autonomous_car_fuel", -- hidden fuel item of the car, and its fuel category
	subgroup = "autonomous_car", -- row of the crafting menu
	ghost_selector = "autonomous_car_ghost_selector", -- selection tool
	ghost_selector_shortcut = "autonomous_car_ghost_selector_shortcut",
	ghost_selector_input = "autonomous_car_ghost_selector_input", -- key binding
	missing_items_shortcut = "autonomous_car_missing_items_shortcut", -- shows or hides the window of missing items
	debug_view_shortcut = "autonomous_car_debug_view_shortcut", -- shows or hides the debug drawing of the selected car
	next_task_event = "autonomous_car_next_task", -- custom event, see _utils.raise_next_task
	turret = "autonomous_car_turret", -- hidden turret that follows each armed car and shoots for it, see armed.lua
	technology = "autonomous_car", -- research that unlocks the mod's items; also the prefix of the others (see config.upgrades)
	repair_technology = "autonomous_car_repair", -- research that makes the garages repair the parked cars, with repair packs
}

config.car_size = {width = 0.7, length = 1} -- collision box of the car; the maneuver probes are derived from it
-- Values the researches raise (see _utils.get_upgrade): a list per key, the first value without
-- research, then one more per research (technology <names.technology>_<key>_<level>, level 1 first).
-- A cluster of ghosts never needs more cargo slots than the current value.
config.upgrades = {
	cargo = {20, 30, 40}, -- trunk slots of a car for its cargo (the battery slot comes after them)
	garage = {30, 40, 50}, -- cars a garage holds
	chargers = {2, 4, 8}, -- cars that can use the same charger at once; its buffer follows (charger_control.update_buffer)
	charge_speed = {0.5, 1, 2}, -- charge transfer per tick, relative to the full charge duration
	build_speed = {0.5, 1, 2}, -- build attempts per config.build_interval
}
config.car_inventory_size = config.upgrades.cargo[#config.upgrades.cargo] + 1 -- trunk slots of the prototype: the most cargo plus the battery slot; the bar hides the others (see _utils.set_trunk_limits)
config.armed_technology = "military" -- vanilla research after which the cars carry their gun (see _utils.is_armed)
config.battery_item = "battery" -- item a car burns when its tank is almost empty; the last trunk slot is reserved for it
config.ammo_items = {"uranium-rounds-magazine", "piercing-rounds-magazine", "firearm-magazine"} -- ammo a car takes from a supply chest, strongest first: it fills an empty slot with the strongest one the chest holds and swaps a weaker one for a stronger one (see ghost_control.restock)
config.repair_kit_slots = 2 -- slots of a garage for repair packs, after its car, battery and ammo slots; locked until config.names.repair_technology is researched
config.repair_kit = "repair-pack"
config.garage_inventory_size = 3 + config.repair_kit_slots -- slots of the prototype: the slot that takes a car to park, the battery slot and the ammo slot (they refill the selected car), then the repair pack slots (see garage_control.update_inventory)
config.charger_buffer_capacity = "60MJ" -- of the prototype; the script sets the real size from the number of users (charger_control.update_buffer)
config.charger_input_flow_limit = "1600kW"

-- ============================================================
-- Steering (see movement.drive_tick)
-- ============================================================
-- Each tick a moving car scores three headings - straight, slightly right and
-- slightly left - from sample points one tile apart ahead of it, and steers to
-- the cheapest. A sample point costs the distance left from there to the
-- target, relative to the car's own (so about 1), plus what steering_cost adds.

config.lookahead = {
	angle = 1 / 12, -- between the straight heading and each side heading; also the width of the sectors and arcs of the maneuvers and clearings
	side_offset = config.car_size.width, -- the straight heading is sampled along two lines, this far on each side of the car
	start = 1.3, -- distance of the first sample point. Its minimum is about 1.11: half the car length plus the
		-- furthest a corner of the car reaches from its centre (hypot(length / 2, width / 2) = 0.61). Closer, the point overlaps
		-- the car itself, the heading counts as blocked and the car does not steer toward it. Checked at the end of this file.
	length = 4, -- distance covered by the sample points beyond the first one; also the spacing of the points kept on a path
	speed_bonus = 2, -- extra length above speed.fast
}
config.slow_lookahead = { -- replaces start and length of lookahead in slow mode: a finer look-ahead
	start = 1.6, -- above the minimum of lookahead.start (checked at the end): closer, a sample on a side heading overlaps the car
		-- itself when the car is turned, and the car stops steering that way (cause of circles and long detours, see CLAUDE.md)
	length = 2,
}
config.steering_cost = {
	blocked = 3, -- added for a sample point where the car would not fit, and again in front of a moving car
	density = 1.5, -- weight of the obstacle density summed further along the heading (and of a maneuver's heading)
	path_deviation = 1, -- added, per car width, for a sample point further than path.corridor from the segment of the path being followed
	margin = 0.5, -- added, per side, for a sample point with an obstacle about a car width beside it: keeps the car off the walls
}
config.arrival_distance = 6 -- a car this close to its destination has arrived and can act on it
config.rails = { -- a car that arrives with a rail beside it first drives off the rails (movement.start_retreat): a train would hit it
	scan = 3, -- side of the square around the arrived car that is searched for rails
	clearance = 3, -- the spot it retreats to has no rail closer than this
	reach = 1.5, -- the car has reached that spot this close to it (arrival_distance is too coarse for a few tiles)
	search_radius = 8, -- how far from its destination that spot is looked for
}
config.emergency_brake_lookahead = 3 -- an obstacle this far straight ahead triggers emergency braking, and keeps a maneuver from ending

-- ============================================================
-- Obstacle density (see movement.lua)
-- ============================================================
-- Entities per square tile in a disc, counting those the car collides with.
-- A disc centred on the car counts the car itself: about 0.035 with the radius
-- below. movement.update_mode blends that disc (weight 2) with one further
-- ahead (weight 1): on open ground its density is about 0.024, not 0. Keep
-- this in mind when setting a density threshold: fast_density and
-- dense_area_threshold here, maneuver.exit_density further down.

config.density = {
	radius = 3, -- radius of the discs
	lookahead_steps = 5, -- steering sums the density of discs 0 to N ahead of the car, laid end to end
}
config.fast_density = { -- blended density of fast mode
	enter = 0.03, -- below it the car cruises fast
	leave = 0.05, -- above it it stops doing so; two thresholds, so the mode does not flicker
}
config.dense_area_threshold = 0.12 -- blended density above which the area is very dense: slow mode
config.built_zone_distance = 6 -- a car within this of anything built by its force (walls, gates, buildings) is in a built zone:
	-- slow mode, unless the car may stay in normal mode beside it (see normal_beside_built_distance)
config.normal_beside_built_distance = 6 -- in a built zone the car stays in normal mode while its target (waypoint or
	-- destination) is ahead, further than this, not a gate, and the straight line to it is free

-- ============================================================
-- Speed and driving modes (see movement.update_mode)
-- ============================================================
-- Three modes of speed: fast (low density, far from anything built), slow
-- (built or very dense areas, and a moment after an emergency stop on an
-- obstacle, a maneuver or the end of a path) and normal (otherwise).

config.speed = {
	stopped = 0.01, -- below this the car counts as stopped: it has arrived, its emergency braking is over, it stalls
	slow = 0.1, -- a car that leaves fast mode brakes down to the speed it entered it at, but never below this
	fast = 0.25, -- above this the car looks further ahead (see lookahead.speed_bonus)
}
config.braking_duration = 30 -- (0.5s) ticks of travel at the current speed: a car whose destination is nearer than that brakes,
	-- and is not in fast mode; also the length of the zone kept free in front of a moving car

-- car.friction_modifier scales the friction of the car prototype: more friction
-- means a lower cruising speed. It is rebuilt from these factors every tick
-- (see movement.update_mode), so it cannot drift. The game also multiplies it by
-- the friction of the tile under the car: the factors below are divided by that
-- friction, except the emergency one, so a mode has the same speed on any tile.
config.friction = {
	fast = 0.1, -- fast mode: cruising in an open area
	normal = 1, -- normal mode: the friction of the car prototype
	slow = 4, -- slow mode
	maneuver = 10, -- maneuvers, U-turns and the wait for a path: much slower than slow mode
	emergency = 100, -- emergency braking, on top of the mode
}

-- ============================================================
-- Path (see movement.lua, "Path")
-- ============================================================
-- A path from the game's pathfinder, asked for when the maneuver fails or the
-- leg lasts too long (failure request, the rescue path), or by a driving car in a
-- built or very dense area whose destination is out of the cone ahead of it
-- (guided request).

config.path = {
	margin = 0.4, -- added around the car's box in a request: the path keeps that much further off the walls,
		-- and a gap of one tile (narrower than the box) is no passage
	corridor = 2.5, -- distance to the followed segment within which steering has no deviation cost (steering_cost.path_deviation)
	pass_radius = 8, -- a waypoint is also passed once the car is past its plane within this distance:
		-- a car that cannot turn to it in time would drive by and circle back
	u_turn_angle = 0.35, -- the current waypoint further off the car's heading than this, and nearer than pass_radius,
		-- makes the car back up in a U-turn (see movement.drive_tick). 0.25 made cars back into the trees of a forest at bends
	density_factor = 0.3, -- factor of steering_cost.density while the car follows a path, which already avoids what is in the way:
		-- the density ahead no longer pulls the car off it
	max_requests = 3, -- failure requests per leg (maneuver failed or leg too long)
	goal = { -- where a path goes, failure or guided (see movement.choose_path_goal)
		range = 40, -- a destination further than this is not the goal: a point at this distance in its direction is,
			-- where the density is lowest. The straight line to a target is checked over at most this (movement.is_way_open)
		sectors = 3, -- directions tried on each side of the bearing of the destination, `step` apart, for that point
		step = 1 / 12, -- turns between two of these directions
		angle_cost = 0.1, -- density equivalent of one such step away from the destination
		radius = 5, -- how close to the goal the pathfinder must get (LuaSurface.request_path radius): a little under arrival_distance,
		-- so that the path ends where the car counts as arrived. At 3 a goal hemmed in by buildings (a garage in a crowded room)
		-- had no free spot within reach: no path, and the car circled the walls until it was stuck
	},
}
config.path_trigger = { -- guided path
	half_angle = 0.2, -- half the cone ahead of the car: 72 degrees on each side
	min_distance = config.arrival_distance, -- no guided request once the car has arrived; a larger value leaves a ring
		-- where the car is neither arrived nor allowed to ask (a destination behind a wall corner: it turned in circles)
	max_requests = 10, -- guided requests per leg
}
config.gate_waypoints = { -- how a path is reshaped where it crosses a gate (see movement.add_gate_waypoints)
	clear = 7, -- the path points that run along the wall are pushed out from it, up to this distance opposite the gate
		-- (less further along: see ramp), so that the car comes at the gate on a bend, not along the wall
	ramp = 12, -- tiles along the wall over which that push fades out
	near = 3, -- the point in front of the gate, on its axis
	exit = 3, -- the point past the gate
}

-- ============================================================
-- Maneuver (see movement.maneuver_tick)
-- ============================================================
-- Slow driving, forwards or backwards, to get out of a dense area or away from an
-- obstacle. It does not head for the destination: it picks a heading (the
-- roomiest and least dense direction around the car), then drives one of six
-- arcs (forward or backward, each straight, left or right) at a time to turn
-- toward it. A maneuver lasts at most idle_delay.

config.maneuver = {
	-- Free room is measured with probes the size of the car, placed along a heading
	-- half a car length apart (see car_size): they overlap, so even a thin wall
	-- cannot sit unseen between two of them.
	probe = {
		start = 1.5, -- distance of the first probe; must stay above the car length, or the car would detect itself
		length = 4, -- distance covered by the probes beyond the first one
		near_radius = 0.6, -- the gap between the car and the first probe is searched apart, in a disc of this radius
	},
	exit_density = 0.08, -- a maneuver cannot end while the density around the car is above this:
		-- with the default radius, that is the car and one other entity at most (see "Obstacle density")
	min_travel = 2, -- a maneuver ends only once the car has moved this far
}

-- ============================================================
-- Clearing (see movement.lua, "Clearing")
-- ============================================================
-- Last resort of a car no maneuver and no path frees: it destroys the trees and
-- rocks in its way, for at most idle_delay.

config.clearing = {
	lookahead = 8, -- tiles looked at along each heading to count the trees and rocks it would cross;
		-- also the radius around the car within which one must stand for a clearing to start
	radius = 0.8, -- radius of the discs searched along a heading for that count
	clear_radius = 1.3, -- trees and rocks within this of the car, and of the points up to `reach` ahead of it, are destroyed
	reach = 2.5, -- tiles ahead of the car where trees and rocks are destroyed
	travel = 15, -- the clearing ends once the car has moved this far
	obstacle_cost = 0.01, -- cost of a heading per tree or rock on it, in turns of deviation from the destination
	max_count = 10, -- clearings per leg
}

-- ============================================================
-- Fleeing (see control.lua, handle_danger)
-- ============================================================
-- A moving or building car that meets an enemy (a force other than its own and the
-- neutral one: biters, worms, spawners, enemy turrets) drops its leg and drives to
-- the closest charger or garage lying away from it, else a point straight away from it.
-- It waits there, then resumes its batch.

config.flee = {
	radius = 40, -- an enemy military target this close makes the car flee
	max_refuge_distance = 150, -- a charger or garage is a refuge within this distance and the car's reachable fuel; without one the car drives this far straight away from the enemy
	max_count = 3, -- flights per batch: past it the car abandons its batch (the site is too dangerous), then ignores enemies
		-- until it has a new one
}

-- ============================================================
-- Shared delays
-- ============================================================
-- Every "wait, then retry or re-evaluate" in the mod uses one of these five
-- delays, grouped by time scale. Reuse the closest one instead of adding a
-- constant, and list the new usage here.

config.short_delay = 30 -- (0.5s)
	-- movement.update_mode: emergency braking cannot start again this soon after a stop; pace at which a car without a path
	--   checks the straight line to its destination
	-- movement.drive_tick: a car that stands still this long after a leg began or a maneuver ended has hit something; a U-turn
	--   that stalls this long ends
	-- movement.maneuver_tick: a car that drives but does not move this long backs off; an arc and a back-off last this long, and
	--   the heading of a maneuver or a clearing is looked for again this often
	-- movement.on_path_finished: a request the pathfinder could not take yet is sent again after this
	-- travel.handle_critical_fuel: pause between two charger searches when none is reachable; period of the critical level
	--   measure while the tank holds much more than it
	-- control.lua: period at which an open window of missing items is refreshed (gui.refresh_all)
config.medium_delay = 180 -- (3s)
	-- ghost_control.attempt_one_ghost: cooldown of a ghost that failed to revive, times the number of failures
	-- movement.update_mode: slow mode lasts this long after an emergency stop on an obstacle, a maneuver or the end of a path
	-- movement.start_path_request: wait between two path requests
config.idle_delay = 300 -- (5s) long on purpose during development, so idle waits are easy to see
	-- TODO: lower to 60-120 before release; it also bounds the maneuvers, clearings and U-turns. See "À faire" in CLAUDE.md.
	-- control.lua: wait before an idle car looks for a new task or a garage (ghost_control.go_idle, travel.handle_empty and a
	--   new car set it as already elapsed, so that the car decides on the next tick)
	-- movement.maneuver_tick: longest a maneuver may last, its single try; past it the car asks for a path, then clears its
	--   way, then is stuck
	-- movement: longest a clearing or a U-turn may last
config.long_delay = 600 -- (10s)
	-- ghost_control.proceed: a batch waits this long for missing items before the clusters lacking them go back to the pending
	--   pool; ghost_control.wait_for_phase: a batch held back by an earlier phase gives way after this
	-- movement.wait_for_path: longest wait for the answer of the pathfinder
	-- control.lua: period of the fallback scan of pending clusters and of the repair of parked cars
	-- travel.stuck_tick: wait before a stuck car tries its leg again
	-- travel.is_leg_too_long: margin added to the expected duration of a leg
	-- control.lua (on_next_task): a car that fled waits this long at its refuge before resuming
config.very_long_delay = 3600 -- (60s)
	-- ghost_control.requeue_ghost: a ghost given up after max_revive_attempts waits this long in the pending pool before any
	--   car may take it again, so that the cars do not all gather on a ghost that cannot be built
	-- travel.mark_unreachable: a car that has found no way to recharge for this long abandons its task: its batch goes back
	--   to the pending pool

-- Measurements that need not happen every tick are repeated this often, offset
-- per car (_utils.is_slow_check_due): gates opened ahead, moving cars nearby,
-- built things nearby, critical fuel level. Raise it if the mod slows the game
-- down: every player gets the same behaviour.
config.slow_check_interval = 6 -- (0.1s)
	-- debug_view.refresh: period of the debug drawing

-- Debug drawing of the car under the cursor or opened (see scripts/debug/debug_view.lua): its
-- destination, path, state and steering costs. Each player toggles it with a
-- shortcut; this is the state of a player who has not touched it.
-- TODO: off by default before release (see "À faire" in CLAUDE.md).
config.debug_view_default = true

-- ============================================================
-- Construction (see construction.lua)
-- ============================================================

config.cluster_radius = 10 -- max distance between two neighbouring ghosts of a cluster
config.build_interval = 6 -- ticks between two build attempts, so a batch visibly goes up one entity at a time
config.max_revive_attempts = 3 -- failed attempts on a ghost before it goes back to the pending pool
config.step_back_distance = 30 -- how far a car backs away when every ghost left is on a retry cooldown.
	-- Must stay above arrival_distance, or the car would count as arrived without moving.
config.chest_group_radius = 1.5 -- supply chests this close to each other form one group: reaching one gives access to all

-- ============================================================
-- Fuel and charging (see scripts/charger.lua, travel.lua)
-- ============================================================

config.full_charge_duration = 900 -- (15s) time to fill an empty tank; the transfer per tick is derived from it and the tank capacity
-- High estimate of the fuel a trip of d tiles burns, used to decide whether it needs a charging detour and where the
-- critical level lies (see scripts/charger.lua; measured on 364 trips of 5 to 11000 tiles, `range-*` scenarios):
-- fixed + near_per_tile * min(d, near_distance) + far_per_tile * the rest.
-- Covers about 90% of the short trips of the test scenarios (traps included) and all the long ones.
config.fuel_estimate = {
	fixed = 50000, -- the fixed margin of a trip
	near_per_tile = 2500, -- per tile over the first near_distance tiles
	near_distance = 100,
	far_per_tile = 450, -- per tile beyond (measured 165 to 315 on long trips, at most 490)
}
config.max_charge_detours = 5 -- consecutive charging detours before the destination is reported unreachable
config.critical_fuel_ratio = 0.1 -- below this fraction of a full tank a car drops everything to recharge.
	-- Also the charge of a new car.
config.critical_check_fuel_ratio = 0.8 -- above this fraction of a full tank a car does not look for the critical level at all: it is certainly near a charger
config.battery_fuel_ratio = config.critical_fuel_ratio / 2 -- fraction of a full tank that one battery gives
config.battery_trigger_ratio = config.critical_fuel_ratio / 4 -- below this fraction of a full tank a car burns a battery; an empty car resumes above it
config.pre_park_fuel_ratio = 0.9 -- an idle car below this fraction tops up before it parks

-- ============================================================
-- Stuck (see travel.lua, "Stuck")
-- ============================================================

config.stuck = {
	min_speed = 0.1, -- lowest average speed expected over a leg; bounds how long the leg may last (travel.is_leg_too_long)
	max_retries = 3, -- times a car retries a stuck leg before it abandons its task (a leg to a charger is retried without limit)
	abandon_delay = 1800, -- (30s) a car out of retries waits this long for the player, then abandons its task:
		-- its ghosts are released and must be selected again (see travel.stuck_tick, ghost_control.abandon)
}

-- ============================================================
-- Garage (see scripts/garage.lua)
-- ============================================================

config.garage_exit = { -- free spot where a garage releases a car
	radius = 8, -- how far around the garage to look
	precision = 0.25, -- step of that search
}
config.garage_repair_rate = 0.01 -- fraction of its health a parked car recovers every long_delay while the garage holds a repair pack, which wears out with it

-- ============================================================
-- Consistency checks
-- ============================================================
-- Relations between the values above that the code relies on. A value that
-- breaks one stops the mod from loading, with the message, instead of making
-- the cars misbehave in game.

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

-- The first sample point of a heading must lie beyond the car's own box, or the
-- car would detect itself.
local car_reach = config.car_size.length / 2 + math.sqrt((config.car_size.length / 2) ^ 2 + (config.car_size.width / 2) ^ 2)
assert(config.lookahead.start >= car_reach,
	"config.lookahead.start must be above half the car length plus its half diagonal: the first sample point would overlap the car")
assert(config.slow_lookahead.start >= car_reach,
	"config.slow_lookahead.start must be above half the car length plus its half diagonal: the first sample point would overlap the car")

assert(config.critical_fuel_ratio < config.critical_check_fuel_ratio and config.critical_check_fuel_ratio < config.pre_park_fuel_ratio,
	"config.critical_check_fuel_ratio must lie between config.critical_fuel_ratio and config.pre_park_fuel_ratio")

return config
