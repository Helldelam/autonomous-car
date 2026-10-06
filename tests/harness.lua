
-- ============================================================================
-- TEST HARNESS - temporary development aid, to be removed with the tests/ folder
-- ============================================================================
-- tests/run.ps1 appends this file to a temporary copy of control.lua, after a
-- line that defines SCENARIO, and runs the result in Factorio's benchmark
-- mode. The mod itself never loads it. Being part of the control.lua chunk, it
-- can use that file's locals: on_area_selected and the modules.
--
-- Output, in script-output/:
--   trace.txt     one line per car every 10 ticks, plus SETUP, EVENT, SELECT
--                 and SUMMARY lines, and the GATE-TEST lines of gate-manual
--   coverage.txt  how many times each module function was called
--
-- Car line:
--   tick id x y orientation speed fuel FLAGS a<acceleration> d<direction>
--   f<friction> t<queued tasks> g<ghosts left> i<item types missing>
--   k<charge detours>,<stuck retries> dst<destination x,y> [alerts raised]
-- FLAGS has one digit per name of FLAG_NAMES, in that order. g and i are -1
-- when the car has no batch. tests/show.ps1 decodes these lines.

local FLAG_NAMES = {"moving", "charging", "parking", "building", "stuck", "waiting", "empty", "maneuver", "emergency_brake", "high_speed", "precision_mode"}
local BUILT_NAMES = {"wooden-chest", "stone-furnace", "small-electric-pole", "steel-chest", "car"}

local T = {chargers = {}} -- state of the running scenario
local scenarios = {}

-- ============================================================
-- Helpers
-- ============================================================

local function out(line)
	helpers.write_file("trace.txt", line .. "\n", true)
end

-- Creates the flat test surface, generated around each chunk centre given.
local function new_surface(centres, radius)
	local surface = game.create_surface("test")
	surface.generate_with_lab_tiles = true
	for _, centre in pairs(centres) do
		surface.request_to_generate_chunks(centre, radius)
	end
	surface.force_generate_chunk_requests()
	T.surface = surface
	return surface
end

-- Builds an entity the way a script would, so that the mod tracks it.
local function make(surface, name, x, y)
	local entity = surface.create_entity{name = name, position = {x, y}, force = "player", raise_built = true}
	if not entity then
		out("SETUP could not create " .. name .. " at " .. x .. "," .. y)
	elseif name == "autonomouscar_charging_station" then
		table.insert(T.chargers, entity)
	end
	return entity
end

-- `fuel_ratio` overrides the charge a new car starts with.
local function make_car(surface, x, y, orientation, fuel_ratio)
	local car = make(surface, "autonomous_car", x, y)
	car.orientation = orientation
	if fuel_ratio then
		car.burner.remaining_burning_fuel = _utils.fuel_capacity(car) * fuel_ratio
	end
	return car
end

local function make_ghost(surface, inner_name, x, y)
	return surface.create_entity{name = "entity-ghost", inner_name = inner_name, position = {x, y}, force = "player", expires = false}
end

-- A ghost that cannot be revived until T.wall is destroyed. The wall goes
-- first: building it on top of a ghost would remove the ghost.
local function make_blocked_ghost(surface, x, y)
	T.wall = surface.create_entity{name = "stone-wall", position = {x, y}, force = "player"}
	return make_ghost(surface, "wooden-chest", x, y)
end

local function fill(chest, items)
	local inventory = chest.get_inventory(defines.inventory.chest)
	for name, count in pairs(items) do
		inventory.insert{name = name, count = count}
	end
end

-- Stands in for a player dragging the ghost selector over an area.
local function select_ghosts(x1, y1, x2, y2)
	local ghosts = T.surface.find_entities_filtered{type = "entity-ghost", area = {{x1, y1}, {x2, y2}}}
	out("SELECT " .. game.tick .. " " .. #ghosts .. " ghosts")
	on_area_selected{item = "autonomous_car_ghost_selector", player_index = 1, entities = ghosts, tick = game.tick}
end

local function heading_to(car, target)
	if not (car.valid and target.valid) then
		return false
	end
	local moving = storage.car_data[car.unit_number].moving
	return moving.active and moving.destination == target
end

-- ============================================================
-- Scenarios
-- ============================================================
-- Each scenario has a `setup` function and an optional `events(t)` function,
-- called every tick with the number of ticks since the setup.

-- Driving, charging and parking, on open ground, around obstacles and on
-- natural terrain. Also: a destination destroyed on the way, and a critically
-- low car with no charger in reach.
scenarios["basics"] = {
	setup = function()
		-- The flat zones sit far from the origin, away from the nauvis zone
		-- below: cars pick chargers and garages by position only, whatever
		-- the surface.
		local s = new_surface({{10000, 0}, {11000, 0}, {11000, 1000}, {12000, 0}}, 6)

		-- Open ground: three cars that charge, then park.
		make(s, "autonomouscar_charging_station", 10000, 0)
		make(s, "autonomous_car_garage", 10040, 0)
		make_car(s, 9920, 20, 0)
		make_car(s, 9950, -60, 0.25)
		make_car(s, 10020, 70, 0.6)

		-- A wall and trees between two cars and their charger.
		make(s, "autonomouscar_charging_station", 11000, 0)
		make(s, "autonomous_car_garage", 11040, 0)
		for y = -20, 20 do
			s.create_entity{name = "stone-wall", position = {10970.5, y + 0.5}, force = "player"}
		end
		for i = 0, 20 do
			for j = -12, 12 do
				if (i * 7 + j * 13) % 5 == 0 then
					s.create_entity{name = "tree-01", position = {10975 + i, j}}
				end
			end
		end
		make_car(s, 10930, 0, 0.25)
		make_car(s, 10940, 30, 0.9)

		-- A critically low car: no charger in reach until one is built at t = 3000.
		make(s, "autonomous_car_garage", 11010, 1000)
		make_car(s, 11000, 1000, 0.3, 0.01)

		-- Chargers and a garage that get destroyed while the car needs them.
		T.charger1 = make(s, "autonomouscar_charging_station", 12000, 0)
		T.charger2 = make(s, "autonomouscar_charging_station", 12060, 0)
		T.garage1 = make(s, "autonomous_car_garage", 12030, 20)
		make_car(s, 11950, 0, 0.75)

		-- Natural terrain: the starting area of nauvis.
		local nauvis = game.surfaces.nauvis
		nauvis.request_to_generate_chunks({0, 0}, 8)
		nauvis.force_generate_chunk_requests()
		for _, enemy in pairs(nauvis.find_entities_filtered{force = "enemy"}) do
			enemy.destroy()
		end
		local function make_on_nauvis(name, x, y)
			local position = nauvis.find_non_colliding_position(name, {x, y}, 100, 1)
			if not position then
				out("SETUP no free spot on nauvis for " .. name .. " near " .. x .. "," .. y)
				return nil
			end
			return make(nauvis, name, position.x, position.y)
		end
		make_on_nauvis("autonomouscar_charging_station", 10, 10)
		make_on_nauvis("autonomous_car_garage", -30, 20)
		for _, spot in pairs{{90, 60, 0.4}, {-100, -70, 0.8}, {60, -110, 0.1}} do
			local car = make_on_nauvis("autonomous_car", spot[1], spot[2])
			if car then
				car.orientation = spot[3]
			end
		end
	end,
	events = function(t)
		if t == 400 then
			T.charger1.die()
			out("EVENT charger1 died")
		end
		if t == 1500 and T.charger2.valid then
			T.charger2.die()
			out("EVENT charger2 died")
		end
		if t == 2500 then
			make(T.surface, "autonomouscar_charging_station", 12010, -10)
		end
		if t == 3000 then
			make(T.surface, "autonomouscar_charging_station", 11005, 1008)
		end
		if t == 3500 and T.garage1.valid then
			T.garage1.die()
			out("EVENT garage1 died")
		end
		if t == 6500 then
			make(T.surface, "autonomous_car_garage", 12020, 30)
		end
	end,
}

-- A full construction run with three cars: several ghost types, a batch too
-- large for one trunk, items that arrive late, a ghost destroyed during its
-- batch, and a second selection.
scenarios["construction"] = {
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, "autonomouscar_charging_station", 0, 0)
		make(s, "autonomouscar_charging_station", -10, 20)
		make(s, "autonomous_car_garage", 20, -10)
		T.chest = make(s, "autonomous_car_chest", 0.5, 30.5)
		fill(T.chest, {["wooden-chest"] = 60, ["stone-furnace"] = 20})
		fill(make(s, "autonomous_car_chest", 1.5, 30.5), {["small-electric-pole"] = 30, ["wooden-chest"] = 10})
		fill(make(s, "autonomous_car_chest", -30.5, 40.5), {["car"] = 45})
		make_car(s, 10, 10, 0.1)
		make_car(s, -20, 5, 0.5)
		make_car(s, 5, -25, 0.8)

		for i = 0, 5 do
			for j = 0, 5 do
				make_ghost(s, "wooden-chest", 60.5 + 2 * i, 60.5 + 2 * j)
			end
		end
		for i = 0, 7 do
			make_ghost(s, "stone-furnace", 81 + 3 * i, 21)
		end
		for i = 0, 5 do
			make_ghost(s, "small-electric-pole", 50.5 + 4 * i, 100.5)
		end
		for i = 0, 3 do
			make_ghost(s, "steel-chest", 100.5 + 2 * i, 70.5) -- no steel chest in supply before t = 9000
		end
		make_ghost(s, "wooden-chest", 130.5, 130.5)
		-- 45 ghosts of an item that stacks to 1: more than one trunk can hold.
		for i = 0, 8 do
			for j = 0, 4 do
				make_ghost(s, "car", -60 - 4 * i, 80 + 4 * j)
			end
		end
		T.doomed_ghost = make_ghost(s, "stone-furnace", 81, 28)
	end,
	events = function(t)
		if t == 1500 then
			select_ghosts(-120, 0, 150, 150)
		end
		if t == 1700 and T.doomed_ghost.valid then
			T.doomed_ghost.destroy()
			out("EVENT ghost destroyed")
		end
		if t == 9000 then
			fill(T.chest, {["steel-chest"] = 10})
			out("EVENT steel chests supplied")
		end
		if t == 16000 then
			for i = 0, 9 do
				make_ghost(T.surface, "wooden-chest", 20.5 + 2 * i, -40.5)
			end
			select_ghosts(15, -50, 45, -30)
		end
	end,
}

-- Failure paths: a destination destroyed on the way, a garage that fills up
-- before the car gets there, a car that reaches its garage with a loaded
-- trunk, a garage out of range with no charger, a car destroyed with a batch,
-- and no garage left at all.
scenarios["failures"] = {
	setup = function()
		local s = new_surface({{0, 0}, {3000, 3000}, {3500, 3000}}, 10)
		make(s, "autonomouscar_charging_station", 0, 0)
		make(s, "autonomous_car_garage", 20, -10)
		T.chest = make(s, "autonomous_car_chest", 0.5, 30.5)
		fill(T.chest, {["wooden-chest"] = 20})
		make_car(s, 10, 10, 0.1)
		for i = 0, 4 do
			make_ghost(s, "wooden-chest", -60.5 - 2 * i, 100.5)
		end

		make(s, "autonomouscar_charging_station", -150, 0)
		T.car2 = make_car(s, -100, 60, 0.3)

		make(s, "autonomouscar_charging_station", 190, -180)
		T.garage3 = make(s, "autonomous_car_garage", 200, -200)
		T.car3 = make_car(s, 180, -150, 0.6)

		make(s, "autonomouscar_charging_station", -190, -180)
		T.garage4 = make(s, "autonomous_car_garage", -200, -200)
		T.car4 = make_car(s, -180, -150, 0.9)

		make(s, "autonomous_car_garage", 3500, 3000)
		make_car(s, 3000, 3000, 0, 0.12)
	end,
	events = function(t)
		if t == 200 and T.car2.valid then
			local destination = storage.car_data[T.car2.unit_number].moving.destination
			if destination and destination.valid then
				out("EVENT destination of car2 died: " .. destination.name)
				destination.die()
			end
		end
		if not T.garage3_filled and heading_to(T.car3, T.garage3) then
			T.garage3_filled = true
			T.garage3.get_inventory(defines.inventory.chest).insert{name = "wooden-chest", count = 50}
			out("EVENT garage3 filled at " .. game.tick)
		end
		if not T.car4_loaded and heading_to(T.car4, T.garage4) then
			T.car4_loaded = true
			T.car4.get_inventory(defines.inventory.car_trunk).insert{name = "iron-plate", count = 5}
			out("EVENT car4 loaded at " .. game.tick)
		end
		-- The batch goes to the only waiting car, the one that cannot move for
		-- lack of fuel: it ends up abandoning the batch, again and again.
		if t == 3000 then
			select_ghosts(-80, 90, -50, 110)
		end
		if t == 11100 then
			for id, car in pairs(storage.cars) do
				if car.valid and storage.car_data[id].construction then
					out("EVENT car " .. id .. " died with a batch")
					car.die()
					break
				end
			end
		end
		if t == 15000 then
			for _, garage in pairs(T.surface.find_entities_filtered{name = "autonomous_car_garage"}) do
				garage.die()
			end
			out("EVENT all garages died")
		end
		if t == 15010 then
			make_car(T.surface, 30, 30, 0.2)
		end
	end,
}

-- One waiting car, no garage, and a ghost that cannot be built until its wall
-- is removed at t = 12000: failed revives, cooldown, step back, the ghost sent
-- back to the pending pool, and the leftover item deposited.
scenarios["blocked-ghost"] = {
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, "autonomouscar_charging_station", 0, 0)
		T.chest = make(s, "autonomous_car_chest", 0.5, 30.5)
		fill(T.chest, {["wooden-chest"] = 20})
		make_car(s, -20, -20, 0)
		make_blocked_ghost(s, 80.5, 40.5)
	end,
	events = function(t)
		if t == 400 then
			select_ghosts(70, 30, 90, 50)
		end
		if t == 12000 and T.wall.valid then
			T.wall.destroy()
			out("EVENT wall removed")
		end
	end,
}

-- A parked car is released from its garage for one ordinary ghost. The ghost
-- should get built. When this scenario was written the car stayed stuck
-- against the garage and the ghost was never built.
scenarios["garage-exit"] = {
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, "autonomouscar_charging_station", 0, 0)
		make(s, "autonomous_car_garage", 30, 0)
		T.chest = make(s, "autonomous_car_chest", 0.5, 30.5)
		fill(T.chest, {["wooden-chest"] = 20})
		make_car(s, -20, -20, 0)
		make_ghost(s, "wooden-chest", 80.5, 40.5)
	end,
	events = function(t)
		if t == 2500 then
			select_ghosts(70, 30, 90, 50)
		end
	end,
}

-- A car on its way to a charger is given a batch whose only ghost cannot be
-- built. Its queued "charging" task stays in the queue and is run when the
-- car arrives from its step back. When this scenario was written that ended
-- in a script error in charge.lua.
scenarios["stale-task"] = {
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, "autonomouscar_charging_station", -150, 0)
		make(s, "autonomous_car_garage", -160, 0)
		T.chest = make(s, "autonomous_car_chest", 0.5, 30.5)
		fill(T.chest, {["wooden-chest"] = 20})
		-- Half a tank: enough not to be critical, too little to park without a top-up.
		make_car(s, 0, 0, 0.75, 0.5)
		make_blocked_ghost(s, 60.5, 60.5)
	end,
	events = function(t)
		if t == 100 then
			select_ghosts(50, 50, 70, 70)
		end
	end,
}

-- Walls all around a 5x5 room centred on (cx, cy): returns the walls, so that a
-- scenario can open one. The 3 tiles it takes to leave the centre are the ring.
local function wall_ring(surface, cx, cy)
	local walls = {}
	for dx = -3, 3 do
		for dy = -3, 3 do
			if math.max(math.abs(dx), math.abs(dy)) == 3 then
				walls[dx .. "," .. dy] = surface.create_entity{name = "stone-wall", position = {cx + dx, cy + dy}, force = "player"}
			end
		end
	end
	return walls
end

-- Three cars walled in, for the stuck escalation (maneuvers, retries, final stop,
-- abandon):
--   car A  has a batch and is freed at t = 2600, during its first stuck wait: its retry should work
--   car B  has a batch and is never freed: stuck again and again, then the batch is abandoned
--   car C  is walled in with a low tank and a charger out of reach of its walls:
--          its leg to the charger is retried without limit and never abandoned
-- The ghosts of B are not built, and must not be assigned again after the abandon.
scenarios["sealed"] = {
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, "autonomouscar_charging_station", 0, 0)
		T.chest = make(s, "autonomous_car_chest", 70.5, 0.5)
		fill(T.chest, {["wooden-chest"] = 20})

		T.ring_a = wall_ring(s, 50.5, 50.5)
		make_car(s, 50.5, 50.5, 0, 1)
		make_ghost(s, "wooden-chest", 90.5, 50.5)

		T.ring_b = wall_ring(s, 50.5, -50.5)
		make_car(s, 50.5, -50.5, 0, 1)
		make_ghost(s, "wooden-chest", 90.5, -50.5)

		wall_ring(s, -50.5, 0.5)
		make_car(s, -50.5, 0.5, 0, 0.05)
	end,
	events = function(t)
		if t == 100 then
			select_ghosts(85, 45, 95, 55)
			select_ghosts(85, -55, 95, -45)
		end
		if t == 2600 then
			T.ring_a["3,0"].destroy()
			out("EVENT wall of car A opened")
		end
	end,
}

-- A car with a completely empty battery: it does nothing and alerts the player
-- (flag `empty`, alert battery_empty) and is not given the ghost selected at
-- t = 200. Its battery is refilled at t = 3000: it should resume and build it.
scenarios["empty-battery"] = {
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, "autonomouscar_charging_station", 0, 0)
		make(s, "autonomous_car_garage", 20, -10)
		T.chest = make(s, "autonomous_car_chest", 0.5, 30.5)
		fill(T.chest, {["wooden-chest"] = 20})
		T.car = make_car(s, 5, 10, 0, 0)
		make_ghost(s, "wooden-chest", 40.5, 40.5)
	end,
	events = function(t)
		if t == 200 then
			select_ghosts(35, 35, 45, 45)
		end
		if t == 3000 then
			T.car.burner.remaining_burning_fuel = _utils.fuel_capacity(T.car) * 0.5
			out("EVENT battery refilled")
		end
	end,
}

-- A wall with a gate on the straight way between a supply chest and a ghost: the
-- car can only build the ghost if it gets through the gate. When this scenario
-- was written it did not: the gate stays shut for the car (see gate-manual),
-- which follows the wall without ever heading for the gate.
scenarios["gate"] = {
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, "autonomouscar_charging_station", 0, 0)
		make(s, "autonomous_car_garage", 20, -10)
		T.chest = make(s, "autonomous_car_chest", 0.5, 30.5)
		fill(T.chest, {["wooden-chest"] = 20})
		make_car(s, -20, -20, 0)
		for y = -60, 140 do
			if y ~= 38 then
				s.create_entity{name = "stone-wall", position = {60.5, y + 0.5}, force = "player"}
			end
		end
		T.gate = s.create_entity{name = "gate", position = {60.5, 38.5}, direction = defines.direction.east, force = "player"}
		out("SETUP gate " .. (T.gate and "created" or "NOT created"))
		make_ghost(s, "wooden-chest", 80.5, 40.5)
	end,
	events = function(t)
		if t == 100 then
			select_ghosts(70, 30, 90, 50)
		end
	end,
}

-- Does a gate open for an autonomous car at all? An untracked car (the mod does
-- not drive it) is driven straight at a gate by the scenario itself, once with
-- the gate on a wall and once without any gate, for comparison. Lines GATE-TEST
-- give its x position every 10 ticks: the wall is at x = 20.5.
scenarios["gate-manual"] = {
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		T.test_cars = {}
		for index, with_gate in ipairs{true, false, true} do
			local y = index * 20 + 0.5
			for dy = -4, 4 do
				if dy ~= 0 or not with_gate then
					s.create_entity{name = "stone-wall", position = {20.5, y + dy}, force = "player"}
				end
			end
			if with_gate then
				s.create_entity{name = "gate", position = {20.5, y}, direction = defines.direction.east, force = "player"}
			end
			-- The third is a character, walking at the same gate: the control, to know the gate works at all.
			local car
			if index == 3 then
				car = s.create_entity{name = "character", position = {14, y}, force = "player"}
			else
				car = s.create_entity{name = "autonomous_car", position = {14, y}, force = "player"}
				car.orientation = 0.25
				_utils.set_fuel_item(car)
				car.burner.remaining_burning_fuel = _utils.fuel_capacity(car)
			end
			T.test_cars[index] = car
		end
	end,
	events = function(t)
		for index, car in ipairs(T.test_cars) do
			if car.valid then
				if index == 3 then
					car.walking_state = {walking = true, direction = defines.direction.east}
				else
					car.riding_state = {acceleration = defines.riding.acceleration.accelerating, direction = defines.riding.direction.straight}
				end
				if t % 10 == 0 and t <= 400 then
					out(string.format("GATE-TEST %d %s x=%.2f", t, ({"car-gate", "car-no-gate", "character-gate"})[index], car.position.x))
				end
			end
		end
	end,
}

-- ============================================================
-- Trace
-- ============================================================

local function trace_cars(tick)
	for id, car in pairs(storage.cars) do
		if car.valid then
			local car_data = storage.car_data[id]
			local flags = ""
			for _, name in ipairs(FLAG_NAMES) do
				local flag = car_data[name]
				if type(flag) == "table" then
					flag = flag.active
				end
				flags = flags .. (flag and "1" or "0")
			end

			local alerts = {}
			for key in pairs(car_data.alerts) do
				table.insert(alerts, key)
			end
			table.sort(alerts)

			local destination = car_data.moving.destination
			local destination_text = "-"
			if destination and destination.valid then
				destination_text = string.format("%.3f,%.3f", destination.position.x, destination.position.y)
			end

			local construction = car_data.construction
			out(string.format("%d %d %.10f %.10f %.10f %.10f %.4f %s a%d d%d f%.6f t%d g%d i%d k%d,%d dst%s [%s]",
				tick, id, car.position.x, car.position.y, car.orientation, car.speed, car.burner.remaining_burning_fuel,
				flags, car.riding_state.acceleration, car.riding_state.direction, car.friction_modifier,
				_utils.deque.length(car_data.tasks),
				construction and table_size(construction.ghosts) or -1,
				construction and table_size(construction.items_needed) or -1,
				car_data.charge_detour_count, car_data.stuck_retry_count, destination_text, table.concat(alerts, ",")))
		end
	end
end

local function trace_summary(tick)
	local surface = T.surface
	local parked = 0
	for _, garage in pairs(storage.garages) do
		if garage.valid then
			parked = parked + garage.get_inventory(defines.inventory.chest).get_item_count("autonomous_car")
		end
	end
	local users = {}
	for _, charger in pairs(T.chargers) do
		if charger.valid then
			table.insert(users, storage.charger_data[charger.unit_number].users)
		end
	end
	local built = {}
	for _, name in ipairs(BUILT_NAMES) do
		table.insert(built, name .. "=" .. surface.count_entities_filtered{name = name})
	end
	out(string.format("SUMMARY %d cars=%d parked=%d ghosts=%d pending=%d charger_users=%s built: %s",
		tick, table_size(storage.cars), parked, surface.count_entities_filtered{type = "entity-ghost"},
		#storage.pending_clusters, table.concat(users, ","), table.concat(built, " ")))
end

-- ============================================================
-- Coverage
-- ============================================================
-- Every module function is wrapped in a call counter.

local call_counts = {}
for module_name, module in pairs{
	movement = movement, travel = travel, charger_control = charger_control,
	garage_control = garage_control, ghost_control = ghost_control,
	_utils = _utils, ["_utils.deque"] = _utils.deque,
} do
	for name, fn in pairs(module) do
		if type(fn) == "function" then
			local key = module_name .. "." .. name
			call_counts[key] = 0
			module[name] = function(...)
				call_counts[key] = call_counts[key] + 1
				return fn(...)
			end
		end
	end
end

local function write_coverage()
	local keys = {}
	for key in pairs(call_counts) do
		table.insert(keys, key)
	end
	table.sort(keys)
	local lines = {}
	for _, key in ipairs(keys) do
		table.insert(lines, string.format("%-40s %d", key, call_counts[key]))
	end
	helpers.write_file("coverage.txt", table.concat(lines, "\n") .. "\n", false)
end

-- ============================================================
-- Driver
-- ============================================================

local scenario = scenarios[SCENARIO]
if not scenario then
	error("unknown test scenario: " .. tostring(SCENARIO))
end

script.on_nth_tick(1, function(event)
	local tick = event.tick

	if not T.start_tick then
		-- The mod creates its storage on its first tick (see init_storage).
		if storage.cars then
			scenario.setup()
			T.start_tick = tick
			out("SETUP " .. SCENARIO .. " at tick " .. tick)
		end
		return
	end

	local t = tick - T.start_tick
	if t % 30 == 0 then
		-- Chargers are not wired to any power: keep their buffer full.
		for _, charger in pairs(T.chargers) do
			if charger.valid then
				charger.energy = 6e7
			end
		end
	end
	if scenario.events then
		scenario.events(t)
	end

	if tick % 10 == 0 then
		trace_cars(tick)
	end
	if tick % 300 == 0 then
		trace_summary(tick)
	end
	if tick % 500 == 0 then
		write_coverage()
	end
end)
