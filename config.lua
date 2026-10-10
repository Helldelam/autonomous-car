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
	fuel = "autonomous_car_fuel", -- hidden fuel item of the car, and its fuel category
	subgroup = "autonomous_car", -- row of the crafting menu
	ghost_selector = "autonomous_car_ghost_selector", -- selection tool
	ghost_selector_shortcut = "autonomous_car_ghost_selector_shortcut",
	ghost_selector_input = "autonomous_car_ghost_selector_input", -- key binding
	missing_items_shortcut = "autonomous_car_missing_items_shortcut", -- shows or hides the window of missing items
	next_task_event = "autonomous_car_next_task", -- custom event, see _utils.raise_next_task
}

config.car_size = {width = 0.7, length = 1} -- collision box of the car; the maneuver probes are derived from it
config.car_inventory_size = 40 -- trunk slots of the car; also the most a cluster can require
config.garage_inventory_size = 50 -- slots of a garage, one parked car each
config.charger_buffer_capacity = "60MJ"
config.charger_input_flow_limit = "1600kW"

-- ============================================================
-- Steering (see movement.drive_tick)
-- ============================================================
-- Each tick a moving car scores three headings - straight, slightly right and
-- slightly left - from sample points ahead of it, and steers to the cheapest.
-- A sample point costs the distance left from there to the target, relative
-- to the car's own (so about 1), plus what config.steering_cost adds.

config.lookahead_angle = 1 / 12 -- angle between the straight heading and each side heading; a maneuver uses it for its left and right arcs too
config.lookahead_side_offset = config.car_size.width -- the straight heading is sampled along two lines, this far on each side of the car
config.lookahead_start = 1.3 -- distance of the first sample point. Its minimum is about 1.11: half the car length plus the
	-- furthest a corner of the car reaches from its centre (hypot(length / 2, width / 2) = 0.61). Closer, the point overlaps
	-- the car itself, the heading counts as blocked and the car does not steer toward it. Checked at the end of this file.
config.lookahead_length = 4 -- distance covered by the sample points beyond the first one
config.lookahead_speed_bonus = 2 -- extra look-ahead length above config.speed.fast
config.steering_cost = {
	blocked = 3, -- added for a sample point where the car would not fit
	density = 1.5, -- weight of the obstacle density summed further along the heading
	margin = 0.5, -- added, per side, for a sample point with an obstacle about a car width beside it: keeps the car off the walls
}
config.arrival_distance = 6 -- a car this close to its destination has arrived and can act on it
config.emergency_brake_lookahead = 3 -- an obstacle this far straight ahead triggers emergency braking, and keeps a maneuver from ending

-- ============================================================
-- Obstacle density (see movement.lua)
-- ============================================================
-- Entities per square tile in a disc, counting those the car collides with.
-- A disc centred on the car counts the car itself: about 0.035 with the radius
-- below. movement.update_mode blends that disc (weight 2) with one further
-- ahead (weight 1): on open ground its density is about 0.024, not 0. Keep
-- this in mind when setting a density threshold: high_speed_density here,
-- dense_area_threshold and maneuver_exit_density further down.

config.density_radius = 3 -- radius of the discs
config.density_lookahead_steps = 5 -- steering measures density in discs 0 to N ahead of the car, laid end to end
config.high_speed_density = {
	enter = 0.03, -- blended density below which the car cruises at high speed
	leave = 0.05, -- and above which it stops doing so; two thresholds, so the mode does not flicker
}

-- ============================================================
-- Speed (see movement.lua)
-- ============================================================

config.speed = {
	stopped = 0.01, -- below this the car counts as stopped: it has arrived, or its emergency braking is over
	slow = 0.1, -- within arrival distance, a car slower than this brakes to a stop
	fast = 0.25, -- above this the car looks further ahead (see lookahead_speed_bonus)
}
config.braking_duration = 30 -- (0.5s) the car brakes, and leaves high speed, once its destination is less than this many ticks away at its current speed

-- car.friction_modifier scales the friction of the car prototype: more friction
-- means a lower cruising speed. It is rebuilt from these factors every tick
-- (see movement.update_mode), so it cannot drift. The game also multiplies it by
-- the friction of the tile under the car: the factors below are divided by that
-- friction, except the emergency one, so a mode has the same speed on any tile.
config.friction_base = 1
config.friction_high_speed_factor = 0.1 -- cruising in an open area
config.friction_precision_factor = 4 -- precision mode
config.friction_maneuver_factor = 10 -- maneuver mode: much slower than precision mode
config.friction_emergency_factor = 100 -- emergency braking, on top of the mode above

-- ============================================================
-- Maneuver mode (see movement.maneuver_tick)
-- ============================================================
-- Slow driving, forwards or backwards, to get out of a dense area or away from an
-- obstacle. It does not head for the destination: it picks a heading (the
-- roomiest and least dense direction around the car), then drives one of six
-- arcs (forward or backward, each straight, left or right) at a time to turn
-- toward it. A maneuver lasts at most idle_delay.

config.maneuver_arc_duration = 6 -- the car follows one arc this long before the room around it is measured again

-- Free room is measured with probes the size of the car, placed along a heading
-- half a car length apart (see config.car_size): they overlap, so even a thin
-- wall cannot sit unseen between two of them.
config.maneuver_probe = {
	start = 1.5, -- distance of the first probe; must stay above the car length, or the car would detect itself
	length = 4, -- distance covered by the probes beyond the first one
	near_radius = 0.6, -- the gap between the car and the first probe is searched apart, in a disc of this radius
}
config.maneuver_exit_density = 0.08 -- a maneuver cannot end while the density around the car is above this:
	-- with the default radius, that is the car and one other entity at most (see "Obstacle density")
config.maneuver_min_travel = 2 -- a maneuver ends only once the car has moved this far

-- ============================================================
-- Precision mode (work in progress)
-- ============================================================
-- Slow driving with a finer look-ahead. For now it is on in dense areas only.

config.dense_area_threshold = 0.12 -- blended density above which precision mode turns on (see "Obstacle density")
config.precision_lookahead_side_offset = config.lookahead_side_offset
config.precision_lookahead_start = 1.2 -- replaces lookahead_start; same minimum, see there and the checks at the end
config.precision_lookahead_length = 2 -- replaces lookahead_length

-- ============================================================
-- Shared delays
-- ============================================================
-- Every "wait, then retry or re-evaluate" in the mod uses one of these four
-- delays, grouped by time scale. Reuse the closest one instead of adding a
-- constant, and list the new usage here.

config.short_delay = 60 -- (1s)
	-- travel.handle_critical_fuel: pause between two charger searches when none is reachable
	-- movement.update_mode: cooldown before emergency braking can trigger again after a stop
	-- movement.drive_tick: a car that stands still this long after a leg began or a maneuver ended has hit an obstacle
	-- movement.maneuver_tick: a car that drives but does not move this long backs off; the heading is looked for again this often
	-- control.lua: period at which an open window of missing items is refreshed (gui.refresh_all)
config.medium_delay = 180 -- (3s)
	-- ghost_control.attempt_one_ghost: cooldown of a ghost that failed to revive
config.idle_delay = 300 -- (5s) long on purpose during development, so idle waits are easy to see; lower to 60-120 before release
	-- movement.maneuver_tick: longest a maneuver may last, its single try; past it the car asks for a path (movement.request_path), then is stuck
	-- control.lua: wait before an idle car looks for a new task or a garage
	-- ghost_control.go_idle, travel.handle_empty: a wait set as already elapsed, so that the car decides on the next tick
config.long_delay = 600 -- (10s)
	-- ghost_control.proceed: a batch waits this long for missing items before the clusters lacking them go back to the pending pool
	-- control.lua: period at which parked cars are repaired (garage_control.repair_parked_cars)
	-- control.lua: period of the fallback scan of pending clusters
	-- travel.stuck_tick: wait before a stuck car tries its leg again
	-- travel.is_leg_too_long: margin added to the expected duration of a leg

-- Measurements that need not happen every tick (the cars nearby, the closest
-- charger) are repeated this often, offset per car. Raise it if the mod slows
-- the game down: every player gets the same behaviour.
config.slow_check_interval = 6 -- (0.1s)

-- The two ways a car abandons its task, each with its own delay:
config.unreachable_abandon_delay = 3600 -- (60s) a car that has found no way to recharge for this long abandons its task:
	-- its batch goes back to the pending pool (see travel.mark_unreachable)
config.stuck_abandon_delay = 1800 -- (30s) a car that is out of stuck retries waits this long for the player, then abandons its task:
	-- its ghosts are released and must be selected again (see travel.stuck_tick, ghost_control.abandon)

-- ============================================================
-- Construction (see ghost.lua)
-- ============================================================

config.cluster_radius = 10 -- max distance between two neighbouring ghosts of a cluster
config.build_interval = 6 -- ticks between two build attempts, so a batch visibly goes up one entity at a time
config.max_revive_attempts = 3 -- failed attempts on a ghost before it goes back to the pending pool
config.step_back_distance = 30 -- how far a car backs away when every ghost left is on a retry cooldown.
	-- Must stay above arrival_distance, or the car would count as arrived without moving.
config.chest_group_radius = 1.5 -- supply chests this close to each other form one group: reaching one gives access to all

-- ============================================================
-- Fuel and charging (see charge.lua, travel.lua)
-- ============================================================

config.full_charge_duration = 900 -- (15s) time to fill an empty tank; the transfer per tick is derived from it and the tank capacity
config.fuel_per_tile = 1500 -- rough cost of driving one tile, only used to decide whether a trip needs a charging detour.
	-- This is not the game's consumption model: calibrate it in game.
config.fuel_safety_margin = 1.4 -- multiplier on that estimate, to cover detours and estimation error
config.max_charge_detours = 5 -- consecutive charging detours before the destination is reported unreachable
config.critical_fuel_ratio = 0.1 -- below this fraction of a full tank a car drops everything to recharge.
	-- Also the charge of a new car, and the level an empty car must be back to before it resumes (see travel.handle_empty).
config.pre_park_fuel_ratio = 0.9 -- an idle car below this fraction tops up before it parks
config.max_charger_users = 4 -- cars that can use the same charger at once

-- ============================================================
-- Stuck detection (see travel.is_leg_too_long)
-- ============================================================

config.stuck_min_speed = 0.1 -- lowest average speed expected over a leg; bounds how long the leg may last
config.max_stuck_retries = 3 -- times a car retries a stuck leg before it abandons its task (a leg to a charger is retried without limit)

-- ============================================================
-- Garage (see park.lua)
-- ============================================================

config.garage_exit_radius = 8 -- how far around a garage to look for a free spot to release a car
config.garage_exit_precision = 0.25 -- step of that search
config.garage_repair_rate = 0.01 -- fraction of its health a parked car recovers every long_delay (free for now)

-- ============================================================
-- Consistency checks
-- ============================================================
-- Relations between the values above that the code relies on. A value that
-- breaks one stops the mod from loading, with the message, instead of making
-- the cars misbehave in game.

assert(config.maneuver_probe.start > config.car_size.length,
	"config.maneuver_probe.start must be above config.car_size.length: the car would detect itself")
assert(config.car_size.length / 2 < config.car_size.width,
	"the maneuver probes are half a car length apart: that must stay below config.car_size.width")
assert(config.speed.stopped < config.speed.slow and config.speed.slow < config.speed.fast,
	"config.speed must go up from stopped to slow to fast")
assert(config.high_speed_density.enter < config.high_speed_density.leave,
	"config.high_speed_density.enter must be below config.high_speed_density.leave")
assert(config.step_back_distance > config.arrival_distance,
	"config.step_back_distance must be above config.arrival_distance: the car would arrive without moving")

-- The first sample point of a heading must lie beyond the car's own box, or the
-- car would detect itself.
local car_reach = config.car_size.length / 2 + math.sqrt((config.car_size.length / 2) ^ 2 + (config.car_size.width / 2) ^ 2)
assert(config.lookahead_start >= car_reach,
	"config.lookahead_start must be above half the car length plus its half diagonal: the first sample point would overlap the car")
assert(config.precision_lookahead_start >= car_reach,
	"config.precision_lookahead_start must be above half the car length plus its half diagonal: the first sample point would overlap the car")

return config
