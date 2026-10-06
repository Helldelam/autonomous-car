-- Tuning constants, shared by the data stage (prototypes) and the control stage.
-- Units: durations in ticks (60 per second), distances in tiles, speeds in
-- tiles per tick, angles as a fraction of a full turn, energy in joules.
local config = {}

-- ============================================================
-- Steering (see movement.lua)
-- ============================================================
-- Each tick a moving car scores three headings - straight, slightly right and
-- slightly left - from sample points ahead of it, and steers to the cheapest.

config.lookahead_angle = 1 / 12 -- angle between the straight heading and each side heading; a maneuver uses it for its side headings too
config.lookahead_side_offset = 0.5 -- the straight heading is sampled along two lines, this far on each side of the car
config.lookahead_start = 1.5 -- distance of the first sample point
config.lookahead_length = 4 -- distance covered by the sample points beyond the first one
config.lookahead_speed_bonus = 2 -- extra look-ahead length at high speed
config.density_radius = 3 -- radius of the discs in which obstacle density is measured
config.density_lookahead_steps = 5 -- density is measured in discs 0 to N ahead of the car, laid end to end
config.arrival_distance = 6 -- a car this close to its destination has arrived and can act on it
config.rear_turn_min_angle = 0.33 -- a target further than this off the heading is behind the car, which starts a maneuver to turn around
config.rear_turn_max_speed = 0.2 -- that maneuver only starts below this speed
config.emergency_brake_lookahead = 3 -- an obstacle this far straight ahead triggers emergency braking, and keeps a maneuver from ending

-- ============================================================
-- Maneuver mode (see movement.lua)
-- ============================================================
-- Slow driving, forwards or backwards, to get out of a dense area or to turn
-- (almost) on the spot before setting off. It does not head for the destination:
-- it measures the free room along six headings (forward and backward, each
-- straight, left and right) every few ticks and steers the car along the roomiest.

config.maneuver_duration = 300 -- (5s) longest a single maneuver may last; past it the maneuver counts as failed
config.max_maneuver_attempts = 3 -- failed maneuvers in a row before the car is declared stuck
config.maneuver_arc_duration = 6 -- the car keeps one heading this long before the room around it is measured again
config.maneuver_probe_start = 1.5 -- distance of the first probe point: far enough that the car does not detect itself
config.maneuver_probe_length = 4 -- distance covered by the probe points beyond the first one
config.maneuver_exit_density = 0.08 -- a maneuver cannot end while the obstacle density around the car is above this
config.maneuver_exit_angle = 0.2 -- a maneuver started because the target was behind the car ends once it is this close to the heading
config.maneuver_min_travel = 2 -- a maneuver started by an obstacle or a lack of progress ends only once the car has moved this far

-- car.friction_modifier scales the friction of the car prototype: more friction
-- means a lower cruising speed. It is rebuilt from these factors every tick
-- (see movement.update_mode), so it cannot drift.
config.friction_base = 1
config.friction_high_speed_factor = 0.1 -- cruising in an open area
config.friction_precision_factor = 4 -- precision mode
config.friction_maneuver_factor = 10 -- maneuver mode: much slower than precision mode
config.friction_emergency_factor = 100 -- emergency braking, on top of the mode above

-- ============================================================
-- Precision mode (work in progress)
-- ============================================================
-- Slow driving with a finer look-ahead. For now it is on in dense areas only.

config.dense_area_threshold = 0.12 -- obstacle density above which precision mode turns on
config.precision_lookahead_side_offset = 0.4 -- replaces lookahead_side_offset
config.precision_lookahead_start = 1 -- replaces lookahead_start
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
	-- movement.drive: a car that stands still this long after a leg began or a maneuver ended has hit an obstacle
config.medium_delay = 180 -- (3s)
	-- ghost_control.attempt_one_ghost: cooldown of a ghost that failed to revive
	-- travel.stuck_reason: window over which progress is measured
config.idle_delay = 300 -- (5s) long on purpose during development, so idle waits are easy to see; lower to 60-120 before release
	-- control.lua: wait before an idle car looks for a new task or a garage
config.long_delay = 600 -- (10s)
	-- control.lua: period of the fallback scan of pending clusters
	-- travel.update_stuck: wait before a stuck car tries its leg again
	-- travel.stuck_reason: margin added to the expected duration of a leg

config.abandon_delay = 3600 -- (60s) a car that keeps failing the same goal for this long abandons its task (see travel.mark_unreachable)
config.give_up_delay = 1800 -- (30s) a car stuck for good waits this long for the player before it abandons its task (see travel.update_stuck)

-- ============================================================
-- Construction (see ghost.lua)
-- ============================================================

config.cluster_radius = 10 -- max distance between two neighbouring ghosts of a cluster
config.car_inventory_size = 40 -- trunk slots of the car; also the most a cluster can require
config.build_interval = 6 -- ticks between two build attempts, so a batch visibly goes up one entity at a time
config.max_revive_attempts = 3 -- failed attempts on a ghost before it goes back to the pending pool
config.step_back_distance = 30 -- how far a car backs away when every ghost left is on a retry cooldown.
	-- Must stay well above arrival_distance, or the car would count as arrived without moving.
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
-- Stuck detection (see travel.stuck_reason)
-- ============================================================

config.stuck_min_speed = 0.1 -- lowest average speed expected over a leg; bounds how long the leg may last
config.stuck_min_progress = 1 -- least distance a car must cover over one medium_delay; below it the car starts a maneuver
config.max_stuck_retries = 3 -- times a car retries a stuck leg before it gives up its task (a leg to a charger is retried without limit)

-- ============================================================
-- Garage (see park.lua)
-- ============================================================

config.garage_exit_radius = 8 -- how far around a garage to look for a free spot to release a car
config.garage_exit_precision = 0.25 -- step of that search

-- ============================================================
-- Prototype values
-- ============================================================

config.garage_inventory_size = 50
config.charger_buffer_capacity = "60MJ"
config.charger_input_flow_limit = "1600kW"

return config
