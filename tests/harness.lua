
-- ============================================================================
-- TEST HARNESS - temporary development aid, to be removed with the tests/ folder
-- ============================================================================
-- tests/run.ps1 appends this file to a temporary copy of control.lua, after lines
-- that define SCENARIOS (the names of the scenarios to run, separated by commas)
-- and TICKS (a duration for all of them, or nil), and runs the result in Factorio's
-- benchmark mode. Scenarios of the same category run together in one game, each
-- on its own surface and with its own trace. The mod itself never loads it. Being part of the control.lua chunk, it
-- can use that file's locals: on_area_selected, names and the modules (which
-- a Lua language server reading this file alone would report as undefined).
---@diagnostic disable: undefined-global
--
-- Output, in script-output/:
--   trace-<scenario>.txt  one line per car every 10 ticks, plus SETUP, EVENT,
--                 SELECT, BATCH (clusters of a car's batch, each time it changes)
--                 and SUMMARY lines, and the GATE-TEST lines of gate-manual
--   coverage.txt  how many times each module function was called (all scenarios)
--
-- Car line:
--   tick id x y orientation speed fuel FLAGS a<acceleration> d<direction>
--   f<friction> t<queued tasks> g<ghosts left> i<item types missing>
--   k<charge detours>,<stuck retries> dst<destination x,y> [alerts raised]
-- FLAGS has one digit per name of FLAG_NAMES, in that order. g and i are -1
-- when the car has no batch. tests/show.ps1 decodes these lines, and reads
-- FLAG_NAMES from the line below.

local FLAG_NAMES = {"moving", "charging", "parking", "building", "stuck", "waiting", "empty", "maneuver", "emergency_brake", "fast", "slow", "slowing", "path"}
local BUILT_NAMES = {"wooden-chest", "stone-furnace", "small-electric-pole", "steel-chest", "car"}

local T -- state of the scenario being run (see `use`): set before any of its code runs
local states = {}
local scenarios = {}

-- Makes `name` the current scenario: its code reads and writes T.
local function use(name)
	if not states[name] then
		states[name] = {name = name, chargers = {}, clusters = {}, paths_seen = {}, brakes_seen = {}, health_seen = {}, surfaces = {}}
	end
	T = states[name]
end

-- ============================================================
-- Helpers
-- ============================================================

local function out(line)
	helpers.write_file("trace-" .. T.name .. ".txt", line .. "\n", true)
end

-- Creates the flat test surface, generated around each chunk centre given. Lab
-- tiles have no friction of their own, which makes the cars much faster than on
-- the grass they are tuned on in game: the ground is laid with grass.
local function new_surface(centres, radius)
	local surface = game.create_surface("test-" .. T.name)
	surface.generate_with_lab_tiles = true
	for _, centre in pairs(centres) do
		surface.request_to_generate_chunks(centre, radius)
	end
	surface.force_generate_chunk_requests()
	for _, centre in pairs(centres) do
		local tiles = {}
		local half = radius * 32 + 16
		for x = centre[1] - half, centre[1] + half - 1 do
			for y = centre[2] - half, centre[2] + half - 1 do
				tiles[#tiles + 1] = {name = "grass-1", position = {x, y}}
			end
		end
		surface.set_tiles(tiles, false)
	end
	T.surface = surface
	T.surfaces[surface.index] = true
	return surface
end

-- Builds an entity the way a script would, so that the mod tracks it.
local function make(surface, name, x, y)
	local entity = surface.create_entity{name = name, position = {x, y}, force = "player", raise_built = true}
	if not entity then
		out("SETUP could not create " .. name .. " at " .. x .. "," .. y)
	elseif name == names.charger then
		table.insert(T.chargers, entity)
	end
	return entity
end

-- Researches a technology for a force (the mod clears its research cache on research events).
local function research(force, name)
	force.technologies[name].researched = true
	_utils.clear_research_cache(force)
end

-- Small random shifts, to check that a result does not hang on exact positions:
-- -Set "test_jitter=<seed>" (0 or nothing: none) moves every car by up to
-- test_jitter_size tiles and turns it by a hundredth of a turn, and
-- -Set "test_door_shift=1" moves every door by up to one tile along its wall. The
-- numbers are a function of the seed and of the order of the calls in the scenario.
local function jitter(range)
	local seed = config.test_jitter or 0
	if seed == 0 then
		return 0
	end
	T.jitter_state = ((T.jitter_state or (seed * 7919 + 1)) * 16807) % 2147483647
	return (T.jitter_state / 2147483647 * 2 - 1) * range
end

-- `fuel_ratio` overrides the charge a new car starts with.
local function make_car(surface, x, y, orientation, fuel_ratio)
	local size = config.test_jitter_size or 0.3
	local car = make(surface, names.car, x + jitter(size), y + jitter(size))
	car.orientation = orientation + jitter(0.01)
	if fuel_ratio then
		_utils.set_fuel(car, _utils.get_fuel_capacity(car) * fuel_ratio)
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
	on_area_selected{item = names.ghost_selector, player_index = 1, entities = ghosts, tick = game.tick}
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
-- Each scenario has a `setup` function, an optional `events(t)` function,
-- called every tick with the number of ticks since the setup, an optional
-- `ticks`, the time it runs when it needs less than the default of 22000, and a
-- `category`: the scenarios of a category run together, in one game. Pick the
-- category by what the scenario checks: movement (driving around obstacles),
-- robustness (stuck cars, failures, empty battery), construction, energy
-- (chargers and garages), doors (walls and gates). This file is the only list of scenarios: run.ps1 reads
-- their names, `ticks` and `category` from the lines below. Keep the form
-- scenarios["name"] = { followed by those lines.

-- Driving, charging and parking, on open ground, around obstacles and on
-- natural terrain. Also: a destination destroyed on the way, a critically
-- low car with no charger in reach, and cars on two surfaces (a car must only
-- pick the chargers and garages of its own surface).
scenarios["basics"] = {
	category = "energy",
	setup = function()
		local s = new_surface({{10000, 0}, {11000, 0}, {11000, 1000}, {12000, 0}}, 6)

		-- Open ground: five cars that charge, then park. Two of them start side
		-- by side and head for the same charger: they must not collide.
		make(s, names.charger, 10000, 0)
		make(s, names.garage, 10040, 0)
		make_car(s, 9920, 20, 0)
		make_car(s, 9950, -60, 0.25)
		make_car(s, 10020, 70, 0.6)
		make_car(s, 9900, -2, 0.25)
		make_car(s, 9900, 2, 0.25)

		-- A wall and trees between two cars and their charger.
		make(s, names.charger, 11000, 0)
		make(s, names.garage, 11040, 0)
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
		make(s, names.garage, 11010, 1000)
		make_car(s, 11000, 1000, 0.3, 0.01)

		-- Chargers and a garage that get destroyed while the car needs them.
		T.charger1 = make(s, names.charger, 12000, 0)
		T.charger2 = make(s, names.charger, 12060, 0)
		T.garage1 = make(s, names.garage, 12030, 20)
		make_car(s, 11950, 0, 0.75)

		-- Natural terrain: the starting area of nauvis.
		local nauvis = game.surfaces.nauvis
		T.surfaces[nauvis.index] = true
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
		make_on_nauvis(names.charger, 10, 10)
		make_on_nauvis(names.garage, -30, 20)
		for _, spot in pairs{{90, 60, 0.4}, {-100, -70, 0.8}, {60, -110, 0.1}} do
			local car = make_on_nauvis(names.car, spot[1], spot[2])
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
			make(T.surface, names.charger, 12010, -10)
		end
		if t == 3000 then
			make(T.surface, names.charger, 11005, 1008)
		end
		if t == 3500 and T.garage1.valid then
			T.garage1.die()
			out("EVENT garage1 died")
		end
		if t == 4600 then
			make(T.surface, names.garage, 12020, 30)
		end
	end,
}

-- A full construction run with three cars: several ghost types, a cluster too
-- large for one trunk, several clusters on one car (BATCH lines), items that
-- arrive late (the steel chest cluster goes back to the pending pool while the
-- others are built), recharging between clusters, a ghost destroyed during its
-- batch, and a second selection.
scenarios["construction"] = {
	category = "construction",
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, names.charger, 0, 0)
		make(s, names.charger, -10, 20)
		make(s, names.garage, 20, -10)
		T.chest = make(s, names.chest, 0.5, 30.5)
		fill(T.chest, {["wooden-chest"] = 60, ["stone-furnace"] = 20})
		fill(make(s, names.chest, 1.5, 30.5), {["small-electric-pole"] = 30, ["wooden-chest"] = 10})
		fill(make(s, names.chest, -30.5, 40.5), {["car"] = 45})
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
-- before the car gets there (the car should look for another one), a car that
-- reaches its garage with a loaded trunk (it cannot park), a garage out of
-- range with no charger, a car destroyed with a batch, and no garage left at
-- all.
scenarios["failures"] = {
	category = "robustness",
	setup = function()
		local s = new_surface({{0, 0}, {3000, 3000}, {3500, 3000}}, 10)
		make(s, names.charger, 0, 0)
		make(s, names.garage, 20, -10)
		T.chest = make(s, names.chest, 0.5, 30.5)
		fill(T.chest, {["wooden-chest"] = 20})
		make_car(s, 10, 10, 0.1)
		for i = 0, 4 do
			make_ghost(s, "wooden-chest", -60.5 - 2 * i, 100.5)
		end

		make(s, names.charger, -150, 0)
		T.car2 = make_car(s, -100, 60, 0.3)

		make(s, names.charger, 190, -180)
		T.garage3 = make(s, names.garage, 200, -200)
		T.car3 = make_car(s, 180, -150, 0.6)

		make(s, names.charger, -190, -180)
		T.garage4 = make(s, names.garage, -200, -200)
		T.car4 = make_car(s, -180, -150, 0.9)

		make(s, names.garage, 3500, 3000)
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
			local cars = storage.garage_data[T.garage3.unit_number].cars
			for _ = #cars + 1, garage_control.get_capacity(T.garage3) do
				table.insert(cars, {quality = "normal", health = 1, fuel = 1})
			end
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
			for _, garage in pairs(T.surface.find_entities_filtered{name = names.garage}) do
				garage.die()
			end
			out("EVENT all garages died")
		end
		if t == 15010 then
			make_car(T.surface, 30, 30, 0.2)
		end
	end,
}

-- One car, one garage, one supply chest, two ghosts one after the other:
--  1. The car (damaged, to watch the slow repair in the garage: EVENT health
--     lines) parks, is released at t = 4000 for an ordinary ghost and should build
--     it. When this scenario was written the car stayed stuck against the garage.
--  2. At t = 8000 a furnace ghost that cannot be built (a wall sits on it) is
--     selected: failed revives, cooldown, step back, the ghost sent back to the
--     pending pool. The chest is filled up while the car carries the furnace, so
--     the leftover cannot be deposited: alert supply_full, the car keeps it and
--     takes no new batch. The chest is emptied at t = 13000, the car deposits and
--     the ghost goes round again until the wall is removed at t = 17000.
scenarios["garage-exit"] = {
	category = "energy",
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, names.charger, 0, 0)
		T.garage = make(s, names.garage, 30, 0)
		T.chest = make(s, names.chest, 0.5, 30.5)
		fill(T.chest, {["wooden-chest"] = 20, ["stone-furnace"] = 1})
		T.car = make_car(s, -20, -20, 0)
		T.car.health = T.car.max_health / 2
		T.garage.get_inventory(defines.inventory.chest).insert{name = config.repair_kit, count = 2} -- the repair needs packs
		make_ghost(s, "wooden-chest", 80.5, 40.5)
		T.wall = s.create_entity{name = "stone-wall", position = {80.5, -40.5}, force = "player"}
		make_ghost(s, "stone-furnace", 81, -41)
	end,
	events = function(t)
		local inventory = T.chest.get_inventory(defines.inventory.chest)
		if t == 3900 or t == 7900 then
			local parked = storage.garage_data[T.garage.unit_number].cars[1]
			if parked then
				local kit = T.garage.get_inventory(defines.inventory.chest)[4] -- the first repair pack slot
				out(string.format("EVENT parked car health %.3f at %d, repair packs %d (durability %.0f)", parked.health, t,
					kit.valid_for_read and kit.count or 0, kit.valid_for_read and kit.durability or 0))
			else
				for _, car in pairs(storage.cars) do
					out(string.format("EVENT car health %.3f of %.3f at %d", car.health, car.max_health, t))
				end
			end
		end
		if t == 4000 then
			select_ghosts(70, 30, 90, 50)
		end
		if t == 8000 then
			select_ghosts(75, -50, 90, -30)
		end
		if t > 8000 and not T.chest_filled then
			for _, car in pairs(storage.cars) do
				if car.valid and car.get_inventory(defines.inventory.car_trunk).get_item_count("stone-furnace") > 0 then
					T.chest_filled = true
					while inventory.insert{name = "iron-plate", count = 100} > 0 do end
					out("EVENT chest filled at " .. t)
				end
			end
		end
		if t == 13000 then
			local plates = inventory.get_item_count("iron-plate")
			if plates > 0 then
				inventory.remove{name = "iron-plate", count = plates}
			end
			out("EVENT chest emptied (" .. plates .. " plates)")
		end
		if t == 17000 and T.wall.valid then
			T.wall.destroy()
			out("EVENT wall removed")
		end
	end,
}

-- A car on its way to a charger is given a batch whose only ghost cannot be
-- built. It must not be available for a batch on its way (it used to be, and
-- its queued "charging" task was then run on arrival from its step back, which
-- ended in a script error in scripts/charger.lua).
scenarios["stale-task"] = {
	category = "robustness",
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, names.charger, -150, 0)
		make(s, names.garage, -160, 0)
		T.chest = make(s, names.chest, 0.5, 30.5)
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

-- Four cars walled in, for the maneuver in a closed space and the stuck escalation:
--   car A  has a batch and an opening of 3 tiles is made in its ring at t = 600 (an opening
--          of 1 tile is not a valid exit for a car, which needs 3 to find its way): it should
--          get out through it and build
--   car D  is like car A, but its opening is made at t = 300, while it is still manoeuvring
--          (before it asks for a path): it should find the opening and build, without any stuck
--   car B  has a batch and is never freed: it ends stuck and abandons its batch, with
--          retries of its leg if it can still cross the room, without any once it is blocked both ways
--          (blocked both ways at one spot, see movement.back_off)
--   car C  is walled in with a low tank and a charger out of reach of its walls:
--          its leg to the charger is retried without limit and never abandoned
-- The ghosts of B are not built, and must not be assigned again after the abandon.
scenarios["sealed"] = {
	category = "robustness",
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, names.charger, 0, 0)
		T.chest = make(s, names.chest, 70.5, 0.5)
		fill(T.chest, {["wooden-chest"] = 20})

		T.ring_a = wall_ring(s, 50.5, 50.5)
		make_car(s, 50.5, 50.5, 0, 1)
		make_ghost(s, "wooden-chest", 90.5, 50.5)

		T.ring_b = wall_ring(s, 50.5, -50.5)
		make_car(s, 50.5, -50.5, 0, 1)
		make_ghost(s, "wooden-chest", 90.5, -50.5)

		wall_ring(s, -50.5, 0.5)
		make_car(s, -50.5, 0.5, 0, 0.05)

		T.ring_d = wall_ring(s, 50.5, 110.5)
		make_car(s, 50.5, 110.5, 0, 1)
		make_ghost(s, "wooden-chest", 90.5, 110.5)
	end,
	events = function(t)
		if t == 100 then
			select_ghosts(85, 45, 95, 55)
			select_ghosts(85, -55, 95, -45)
			select_ghosts(85, 105, 95, 115)
		end
		if t == 300 then
			for dy = -1, 1 do
				T.ring_d["3," .. dy].destroy()
			end
			out("EVENT wall of car D opened")
		end
		if t == 600 then
			for dy = -1, 1 do
				T.ring_a["3," .. dy].destroy()
			end
			out("EVENT wall of car A opened")
		end
	end,
}

-- Cars in a dead end made of walls: a corridor 4 tiles wide and 16 long, closed at
-- its west end and open (4 tiles) at its east end, with the ghost and the supply
-- chest behind the closed end. The cars have to get out of the corridor and round
-- the walls: the maneuvers alone do not see that far, the last attempt asks the
-- pathfinder (flag `path` in the trace). Three starts: facing the closed end,
-- facing a side wall, and facing the opening.
scenarios["u-corridor"] = {
	ticks = 9000,
	category = "movement",
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, names.charger, 0, 0)
		T.starts = {{x = 2, o = 0.75}, {x = 6, o = 0}, {x = 10, o = 0.25}}
		for index, start in ipairs(T.starts) do
			local cx, cy = 100, index * 40 - 100
			for x = -1, 16 do
				s.create_entity{name = "stone-wall", position = {cx + x + 0.5, cy - 0.5}, force = "player"}
				s.create_entity{name = "stone-wall", position = {cx + x + 0.5, cy + 4.5}, force = "player"}
			end
			for y = 0, 3 do
				s.create_entity{name = "stone-wall", position = {cx - 0.5, cy + y + 0.5}, force = "player"}
			end
			make_car(s, cx + start.x, cy + 2, start.o, 1)
			fill(make(s, names.chest, cx - 8.5, cy - 4.5), {["wooden-chest"] = 20})
			make_ghost(s, "wooden-chest", cx - 8.5, cy + 2.5)
		end
	end,
	events = function(t)
		if t == 100 then
			for index = 1, #T.starts do
				local cy = index * 40 - 100
				select_ghosts(88, cy, 94, cy + 5)
			end
		end
	end,
}

-- Twenty cars, each in its own closed room 16 tiles long whose only exit, 3 tiles wide,
-- is in the middle of its north wall (inside the U, not at its end): the cars start at
-- twenty places and orientations, and have to leave the room to reach a supply chest and
-- a ghost outside, to the north. The number of chests built is the number of cars that
-- got out and finished (SUMMARY), BATCH lines give the tick each finished. u-side rooms
-- are 4 tiles wide, u-narrow ones 3.
local ROOM_STARTS = {
	{x = 2, o = 0.75}, {x = 4, o = 0}, {x = 6, o = 0.25}, {x = 8, o = 0.5}, {x = 10, o = 0.125},
	{x = 12, o = 0.625}, {x = 14, o = 0.875}, {x = 15, o = 0.25}, {x = 3, o = 0.5}, {x = 11, o = 0},
	{x = 1.5, o = 0.375}, {x = 3.5, o = 0.5}, {x = 5, o = 0.125}, {x = 7, o = 0.75}, {x = 9, o = 0.875},
	{x = 10.5, o = 0.25}, {x = 12.5, o = 0.625}, {x = 13.5, o = 0}, {x = 14.5, o = 0.5}, {x = 6.5, o = 0.75},
}

local function room_origin(index)
	return 100 + 40 * math.floor((index - 1) / 10), ((index - 1) % 10 + 1) * 30 - 170
end

local function build_rooms(width)
	local s = new_surface({{0, 0}}, 10)
	make(s, names.charger, 0, 0)
	for index, start in ipairs(ROOM_STARTS) do
		local cx, cy = room_origin(index)
		for x = -1, 16 do
			if x < 7 or x > 9 then
				s.create_entity{name = "stone-wall", position = {cx + x + 0.5, cy - 0.5}, force = "player"}
			end
			s.create_entity{name = "stone-wall", position = {cx + x + 0.5, cy + width + 0.5}, force = "player"}
		end
		for y = 0, width - 1 do
			s.create_entity{name = "stone-wall", position = {cx - 0.5, cy + y + 0.5}, force = "player"}
			s.create_entity{name = "stone-wall", position = {cx + 16.5, cy + y + 0.5}, force = "player"}
		end
		local lane = width / 2 + (index % 2 == 0 and -0.6 or 0.6) * (width - 2) / 2
		make_car(s, cx + start.x, cy + lane, start.o, 1)
		fill(make(s, names.chest, cx + 13.5, cy - 10.5), {["wooden-chest"] = 20})
		make_ghost(s, "wooden-chest", cx + 3.5, cy - 10.5)
	end
end

local function select_rooms(t)
	if t == 100 then
		for index = 1, #ROOM_STARTS do
			local cx, cy = room_origin(index)
			select_ghosts(cx + 1, cy - 12, cx + 6, cy - 9)
		end
	end
end

scenarios["u-side"] = {
	ticks = 6000,
	category = "movement",
	setup = function() build_rooms(4) end,
	events = select_rooms,
}

scenarios["u-narrow"] = {
	ticks = 6000,
	category = "movement",
	setup = function() build_rooms(3) end,
	events = select_rooms,
}

-- Open ground, no obstacle: twelve cars turned every 30 degrees, a supply chest and a
-- ghost to the east of each. The cars that face away have to turn around before they
-- drive. BATCH lines give the tick each finished.
scenarios["turn-around"] = {
	ticks = 4000,
	category = "movement",
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, names.charger, 0, 0)
		T.turns = 12
		for index = 1, T.turns do
			local cx, cy = 100, index * 20 - 140
			make_car(s, cx, cy, (index - 1) / T.turns, 1)
			fill(make(s, names.chest, cx + 8.5, cy - 3.5), {["wooden-chest"] = 20})
			make_ghost(s, "wooden-chest", cx + 16.5, cy - 3.5)
		end
	end,
	events = function(t)
		if t == 100 then
			for index = 1, T.turns do
				local cy = index * 20 - 140
				select_ghosts(112, cy - 6, 120, cy)
			end
		end
	end,
}

-- A wall 40 tiles long between each car and its supply chest and ghost: the straight way
-- is shut, the car has to find that it must go round, which the steering alone does not
-- (it follows the wall or stops in front of it). Eight cars at different distances along
-- the wall.
scenarios["long-wall"] = {
	ticks = 8000,
	category = "movement",
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, names.charger, 0, 0)
		T.offsets = {-15, -8, -3, 0, 3, 8, 15, 0}
		for index, offset in ipairs(T.offsets) do
			local cx, cy = 100 + 100 * math.floor((index - 1) / 4), ((index - 1) % 4) * 100 - 150
			for y = -20, 20 do
				s.create_entity{name = "stone-wall", position = {cx + 10.5, cy + y + 0.5}, force = "player"}
			end
			make_car(s, cx, cy + offset, 0.25, 1)
			fill(make(s, names.chest, cx + 20.5, cy + 0.5), {["wooden-chest"] = 20})
			make_ghost(s, "wooden-chest", cx + 24.5, cy + 3.5)
		end
	end,
	events = function(t)
		if t == 100 then
			for index = 1, #T.offsets do
				local cx, cy = 100 + 100 * math.floor((index - 1) / 4), ((index - 1) % 4) * 100 - 150
				select_ghosts(cx + 22, cy, cx + 27, cy + 7)
			end
		end
	end,
}

-- The end of a 41-tile wall: eight cars beside it, the supply chest just past its end, 5 to
-- 10 tiles from them (around config.arrival_distance), and the ghost further on. The car
-- has to go round the corner of the wall without turning in circles along it.
scenarios["wall-corner"] = {
	ticks = 6000,
	category = "movement",
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, names.charger, 0, 0)
		T.offsets = {10, 14, 17, 19, 10, 14, 17, 19}
		for index, offset in ipairs(T.offsets) do
			local cx, cy = 100 + 100 * math.floor((index - 1) / 4), ((index - 1) % 4) * 100 - 150
			for y = -20, 20 do
				s.create_entity{name = "stone-wall", position = {cx + 10.5, cy + y + 0.5}, force = "player"}
			end
			make_car(s, cx + 7, cy + offset, index <= 4 and 0.25 or 0, 1)
			fill(make(s, names.chest, cx + 13.5, cy + 22.5), {["wooden-chest"] = 20})
			make_ghost(s, "wooden-chest", cx + 18.5, cy + 25.5)
		end
	end,
	events = function(t)
		if t == 100 then
			for index = 1, #T.offsets do
				local cx, cy = 100 + 100 * math.floor((index - 1) / 4), ((index - 1) % 4) * 100 - 150
				select_ghosts(cx + 16, cy + 23, cx + 21, cy + 28)
			end
		end
	end,
}

-- Obstacle courses: each course is a car, an obstacle field between it and its supply
-- chest, and a ghost behind the chest. The number of chests built (SUMMARY) is the
-- number of cars that got through; BATCH lines give the tick each finished.
-- Course i sits at x = 60, y = (i - 1) * 100 - 250, so six courses fit a scenario (see T.spread).
local seed = 12345
local function random()
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end

-- `T.spread`: two columns of three, 250 tiles apart, for courses longer than 100 tiles.
-- `T.grid`: columns of six courses, 200 tiles apart, a charger at the top of each.
local function course_origin(index)
	if T.origin then
		return T.origin[1], T.origin[2]
	end
	if T.grid then
		return 60 + 200 * math.floor((index - 1) / 6), ((index - 1) % 6) * 100 - 250
	end
	if T.spread then
		return 60 + 160 * ((index - 1) % 2), math.floor((index - 1) / 2) * 250 - 250
	end
	return 60, (index - 1) * 100 - 250
end

local function wall_at(s, x, y)
	s.create_entity{name = "stone-wall", position = {x, y}, force = "player"}
end

-- A line of wall tiles between two points (axis aligned).
local function wall_line(s, x1, y1, x2, y2)
	for x = x1, x2 do
		for y = y1, y2 do
			wall_at(s, x + 0.5, y + 0.5)
		end
	end
end

-- `course`: {obstacles = function(s, cx, cy), car = {dx, dy, orientation, fuel_ratio}, chest = {dx, dy}};
-- the ghost is by default 4 tiles east and 3 south of the chest (`ghost = {dx, dy}`).
-- A course with several of them has `cars`, `chests` and `ghosts` lists instead (all offsets
-- from the course origin, ghosts included): then it counts as done when all its ghosts are built.
local function get_course_ghosts(index, course)
	local cx, cy = course_origin(index)
	local list = {}
	if course.ghosts then
		for _, g in ipairs(course.ghosts) do
			list[#list + 1] = {cx + g[1] + 0.5, cy + g[2] + 0.5}
		end
	else
		local ghost = course.ghost or {4, 3}
		list[1] = {cx + course.chest[1] + 0.5 + ghost[1], cy + course.chest[2] + 0.5 + ghost[2]}
	end
	return list
end

local function build_courses(courses, chunks)
	local s = new_surface(T.origin and {{T.origin[1] + 40, T.origin[2]}} or T.grid and {{60, 0}, {260, 0}, {460, 0}, {660, 0}} or {{0, 0}}, chunks or 11)
	make(s, names.charger, 0, 0)
	if T.grid then
		for column = 0, 3 do
			make(s, names.charger, 40 + 200 * column, 0)
		end
	end
	T.courses = courses
	T.done = {}
	for index, course in ipairs(courses) do
		local cx, cy = course_origin(index)
		course.obstacles(s, cx, cy)
		for _, car in ipairs(course.cars or {course.car}) do
			make_car(s, cx + car[1], cy + car[2], car[3], car[4] or 1)
		end
		for _, chest in ipairs(course.chests or {course.chest}) do
			fill(make(s, names.chest, cx + chest[1] + 0.5, cy + chest[2] + 0.5), {["wooden-chest"] = 20})
		end
		for _, g in ipairs(get_course_ghosts(index, course)) do
			make_ghost(s, "wooden-chest", g[1], g[2])
		end
	end
end

local function count_course_ghosts(index, course)
	local number = 0
	for _, g in ipairs(get_course_ghosts(index, course)) do
		number = number + #T.surface.find_entities_filtered{type = "entity-ghost", area = {{g[1] - 1, g[2] - 1}, {g[1] + 1, g[2] + 1}}}
	end
	return number
end

local function select_courses(t)
	if t == 100 then
		for index, course in ipairs(T.courses) do
			for _, g in ipairs(get_course_ghosts(index, course)) do
				select_ghosts(g[1] - 2, g[2] - 2, g[1] + 2, g[2] + 2)
			end
		end
	end
	if t > 100 and t % 100 == 0 then -- the tick each course had all its ghosts built
		for index, course in ipairs(T.courses) do
			if not T.done[index] and count_course_ghosts(index, course) == 0 then
				T.done[index] = t
				out("DONE " .. index .. " " .. t)
			end
		end
	end
	if t == 3800 or t == 8800 then -- which courses did not end with their ghosts built
		local left = {}
		for index, course in ipairs(T.courses) do
			if count_course_ghosts(index, course) > 0 then
				left[#left + 1] = index
			end
		end
		out("EVENT courses with their ghost left: " .. table.concat(left, ","))
	end
end

-- Trees on a jittered grid of the given spacing over a rectangle.
local function plant(s, x1, y1, x2, y2, spacing)
	local failed = 0
	for x = x1, x2, spacing do
		for y = y1, y2, spacing do
			local tree = s.create_entity{name = "tree-01", position = {x + (random() - 0.5) * spacing * 0.6,
				y + (random() - 0.5) * spacing * 0.6}}
			if not tree then failed = failed + 1 end
		end
	end
	if failed > 0 then out("SETUP " .. failed .. " trees not created") end
end

-- Furnaces (2x2) on a grid whose lanes between them are `lane` tiles wide.
local function build_factory(s, x1, y1, x2, y2, lane)
	for x = x1, x2, 2 + lane do
		for y = y1, y2, 2 + lane do
			s.create_entity{name = "stone-furnace", position = {x + 1, y + 1}, force = "player"}
		end
	end
end

-- A perfect maze of n x n cells, `pitch` tiles apart (walls on the grid lines).
local function build_maze(s, x0, y0, n, pitch)
	local open = {} -- open["x,yE"] / open["x,yS"]: the passage east or south of a cell
	local seen = {["1,1"] = true}
	local stack = {{1, 1}}
	while #stack > 0 do
		local cx, cy = stack[#stack][1], stack[#stack][2]
		local options = {}
		for _, d in ipairs{{1, 0, "E", cx, cy}, {0, 1, "S", cx, cy}, {-1, 0, "E", cx - 1, cy}, {0, -1, "S", cx, cy - 1}} do
			local nx, ny = cx + d[1], cy + d[2]
			if nx >= 1 and ny >= 1 and nx <= n and ny <= n and not seen[nx .. "," .. ny] then
				table.insert(options, {nx, ny, d[3], d[4], d[5]})
			end
		end
		if #options == 0 then
			table.remove(stack)
		else
			local o = options[math.floor(random() * #options) + 1]
			open[o[4] .. "," .. o[5] .. o[3]] = true
			seen[o[1] .. "," .. o[2]] = true
			table.insert(stack, {o[1], o[2]})
		end
	end
	local size = n * pitch
	wall_line(s, x0, y0, x0 + size, y0)
	wall_line(s, x0, y0 + size, x0 + size, y0 + size)
	wall_line(s, x0, y0, x0, y0 + size)
	wall_line(s, x0 + size, y0, x0 + size, y0 + size)
	for cx = 1, n do
		for cy = 1, n do
			if cx < n and not open[cx .. "," .. cy .. "E"] then
				wall_line(s, x0 + cx * pitch, y0 + (cy - 1) * pitch, x0 + cx * pitch, y0 + cy * pitch)
			end
			if cy < n and not open[cx .. "," .. cy .. "S"] then
				wall_line(s, x0 + (cx - 1) * pitch, y0 + cy * pitch, x0 + cx * pitch, y0 + cy * pitch)
			end
		end
	end
end

-- Forests, 24 courses on a large map (four columns of six):
--  1-6   trees between the car and its chest, 60 tiles of forest to cross; three cars start
--        before it, three inside it, three densities
--  7-12  cars that have just driven into the edge of a forest: a few tiles in, boxed in by
--        trees on all sides but a small clearing; three go on across the forest (facing in,
--        or turned away), three have their supply chest behind them, outside
--  13-18 the same deeper in the forest (4 to 12 tiles) and at more realistic densities,
--        facing the forest, sideways to it, or turned away
--  19-24 a copse of 30 x 30 tiles on the straight way between the car and its chest, with
--        open ground all around: the car should go round it rather than into it; three
--        densities, facing the copse or turned away
scenarios["forests"] = {
	ticks = 9000,
	category = "movement",
	setup = function()
		T.grid = true
		local function forest(spacing, inside)
			return {
				obstacles = function(s, cx, cy)
					plant(s, cx + 10, cy - 20, cx + 70, cy + 20, spacing)
					if inside then -- room for the car where it starts
						for _, tree in pairs(s.find_entities_filtered{type = "tree", position = {cx + 35, cy}, radius = 3}) do
							tree.destroy()
						end
					end
				end,
				car = {inside and 35 or 0, 0, 0}, chest = {90, 0},
			}
		end
		local function edge(spacing, depth, orientation, behind)
			return {
				obstacles = function(s, cx, cy)
					plant(s, cx + 10, cy - 20, cx + 70, cy + 20, spacing)
					for _, tree in pairs(s.find_entities_filtered{type = "tree", position = {cx + 10 + depth, cy}, radius = 2.4}) do
						tree.destroy()
					end
				end,
				car = {10 + depth, 0, orientation}, chest = {behind and -30 or 90, 0},
			}
		end
		local function copse(spacing, orientation)
			return {
				obstacles = function(s, cx, cy) plant(s, cx + 30, cy - 15, cx + 60, cy + 15, spacing) end,
				car = {0, 0, orientation}, chest = {90, 0},
			}
		end
		build_courses{
			forest(3, false), forest(3, true), forest(2, false), forest(2, true), forest(1.5, false), forest(1.5, true),
			edge(3, 2, 0.25, false), edge(2, 2, 0.25, false), edge(1.5, 2, 0.25, false),
			edge(2, 2, 0.25, true), edge(1.5, 5, 0.25, false), edge(1.5, 2, 0.75, true),
			edge(2, 4, 0, false), edge(2, 8, 0.25, false), edge(2, 8, 0.75, true),
			edge(2.5, 8, 0.25, false), edge(3, 12, 0.25, false), edge(2, 12, 0.75, true),
			copse(3, 0.25), copse(3, 0.75), copse(2, 0.25), copse(2, 0.75), copse(1.5, 0.25), copse(1.5, 0.75),
		}
	end,
	events = select_courses,
}

-- A field of furnaces with lanes between them to cross, from outside and from inside.
scenarios["factory"] = {
	ticks = 9000,
	category = "movement",
	setup = function()
		local function factory(lane, inside)
			-- Inside, the car starts in the lane crossing of the fourth column and row.
			local x, y = 12 + 3 * (2 + lane) + lane / 2, -18 + 3 * (2 + lane) + lane / 2
			return {
				obstacles = function(s, cx, cy) build_factory(s, cx + 10, cy - 20, cx + 70, cy + 20, lane) end,
				car = {inside and x or 0, inside and y or 0, 0}, chest = {90, 0},
			}
		end
		build_courses{factory(4, false), factory(4, true), factory(3, false), factory(3, true), factory(6, false), factory(6, true)}
	end,
	events = select_courses,
}

-- A wall 200 tiles long with no gate across the road: the car has to go round, a hundred
-- tiles one way or the other. Cars start facing it, along it, and away from it.
scenarios["huge-wall"] = {
	ticks = 14000,
	category = "movement",
	setup = function()
		T.spread = true
		local function huge(orientation)
			return {
				obstacles = function(s, cx, cy) wall_line(s, cx + 30, cy - 100, cx + 30, cy + 100) end,
				car = {0, 0, orientation}, chest = {60, 0},
			}
		end
		build_courses({huge(0.25), huge(0.5), huge(0.75), huge(0), huge(0.125), huge(0.375)}, 14)
	end,
	events = select_courses,
}

-- A wall with turrets (2x2) built along its near side: the car cannot slip along the wall,
-- and has to go round the whole row.
scenarios["wall-turrets"] = {
	ticks = 12000,
	category = "movement",
	setup = function()
		local function turrets(length, orientation)
			return {
				obstacles = function(s, cx, cy)
					wall_line(s, cx + 30, cy - length, cx + 30, cy + length)
					for y = -length, length - 2, 3 do
						s.create_entity{name = "gun-turret", position = {cx + 28, cy + y + 1}, force = "player"}
					end
				end,
				car = {0, 0, orientation}, chest = {60, 0},
			}
		end
		build_courses({turrets(30, 0.25), turrets(30, 0.5), turrets(60, 0.25), turrets(60, 0.75), turrets(15, 0.25), turrets(15, 0)}, 12)
	end,
	events = select_courses,
}

-- An L-shaped corridor, 60 and 40 tiles long, with the supply chest at its end: 4, 6 and 8
-- tiles wide, two cars each (starting inside the first leg, turned differently).
scenarios["l-corridor"] = {
	ticks = 9000,
	category = "movement",
	setup = function()
		local function corridor(width, orientation)
			local w = width
			return {
				obstacles = function(s, cx, cy)
					wall_line(s, cx - 2, cy - 3, cx + 60 + w, cy - 3)
					wall_line(s, cx - 2, cy - 3 + w, cx + 60, cy - 3 + w)
					wall_line(s, cx - 2, cy - 3, cx - 2, cy - 3 + w)
					wall_line(s, cx + 60 + w, cy - 3, cx + 60 + w, cy + 45)
					wall_line(s, cx + 60, cy - 3 + w, cx + 60, cy + 41)
					wall_line(s, cx + 60, cy + 41, cx + 60 + w, cy + 41)
				end,
				car = {2, -3 + w / 2, orientation}, chest = {60 + w / 2 - 1, 34}, ghost = {0, 3},
			}
		end
		build_courses{corridor(4, 0.25), corridor(4, 0.625), corridor(6, 0.25), corridor(6, 0.625), corridor(8, 0.25), corridor(8, 0.625)}
	end,
	events = select_courses,
}

-- Walls thrown at random over a field 60 tiles long: three densities, two cars each.
scenarios["scatter"] = {
	ticks = 9000,
	category = "movement",
	setup = function()
		local function scatter(count, orientation)
			return {
				obstacles = function(s, cx, cy)
					for _ = 1, count do
						local x, y = math.floor(cx + 8 + random() * 62), math.floor(cy - 25 + random() * 50)
						wall_line(s, x, y, x + math.floor(random() * 4), y + math.floor(random() * 4))
					end
				end,
				car = {0, 0, orientation}, chest = {90, 0},
			}
		end
		build_courses{scatter(40, 0), scatter(40, 0.5), scatter(100, 0), scatter(100, 0.5), scatter(200, 0), scatter(200, 0.5)}
	end,
	events = select_courses,
}

-- Mazes, corridors 7 tiles wide: the maneuver has no chance of finding the way, only the
-- pathfinder can. The car starts in the top left cell, chest and ghost are in the bottom
-- right one. Sizes 3, 5 and 7 cells, two mazes each.
scenarios["maze"] = {
	ticks = 14000,
	category = "movement",
	setup = function()
		local function maze(n)
			local pitch = 8
			return {
				obstacles = function(s, cx, cy) build_maze(s, cx, cy, n, pitch) end,
				car = {pitch / 2, pitch / 2, 0.25}, chest = {(n - 1) * pitch + 2, (n - 1) * pitch + 2},
			}
		end
		build_courses{maze(3), maze(3), maze(5), maze(5), maze(7), maze(7)}
	end,
	events = select_courses,
}

-- A car with 5 batteries is idle: just before parking it goes to the supply chest for batteries, which
-- holds 300 (it takes what its slot lacks, 195), then parks and keeps them aside (EVENT garage: 200).
-- It leaves again for the ghost selected at t = 4000, with 200 at once, at a critical charge: it charges first,
-- then restocks at the chest, then builds (EVENT lines every 100 ticks).
scenarios["batteries-garage"] = {
	ticks = 7000,
	category = "robustness",
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, names.charger, 0, 0)
		T.garage = make(s, names.garage, 20, -10)
		T.chest = make(s, names.chest, 0.5, 30.5)
		fill(T.chest, {["wooden-chest"] = 20, battery = 300})
		make(s, names.chest, 2.5, 30.5) -- a chest of the group without batteries
		T.car = make_car(s, 10, 10, 0, 1)
		_utils.insert_batteries(T.car, 5)
		make_ghost(s, "wooden-chest", 40.5, 40.5)
		T.surface = s
		T.cars = {T.car}
	end,
	events = function(t)
		if t == 3500 then
			out("EVENT garage t=" .. t .. ": batteries kept " .. tostring(storage.garage_data[T.garage.unit_number].cars[1].batteries)
				.. ", car valid " .. tostring(T.car.valid))
		end
		if t == 4000 then
			-- Leaves at a critical charge: it goes to the charger first, which cancels its trip to the
			-- chest, and must still restock afterwards (batteries in the car back to 200 by t = 5500).
			storage.garage_data[T.garage.unit_number].cars[1].fuel = 0.05
			select_ghosts(35, 35, 45, 45)
		end
		-- The car list of the garage: a car item put in the car slot is taken into the list
		-- (health and tag kept), handed out as an item that carries its state, taken back, and
		-- given in the buffer of a mined garage.
		if t == 6000 then
			local cars = storage.garage_data[T.garage.unit_number].cars
			table.insert(cars, 1, {quality = "normal", health = 0.5, fuel = 0.7, batteries = 3, ammo = {name = "firearm-magazine", quality = "normal", count = 4}})
			-- Two slots are not enough for the car, its batteries and its ammo: refused, nothing taken.
			local small = game.create_inventory(2)
			local inventory = game.create_inventory(3)
			local count = #cars
			out("EVENT list: two slots, handed out " .. tostring(garage_control.hand_out_car(T.garage, {get_main_inventory = function() return small end}, 1))
				.. ", cars " .. count .. " -> " .. #cars .. ", items in the inventory " .. small.get_item_count())
			out("EVENT list: three slots, handed out " .. tostring(garage_control.hand_out_car(T.garage, {get_main_inventory = function() return inventory end}, 1))
				.. ", cars " .. count .. " -> " .. #cars)
			local stack = inventory.find_item_stack(names.car)
			out(string.format("EVENT item: %s health %.2f fuel %.2f, batteries %d, magazines %d", stack.name, stack.health,
				stack.get_tag("state").fuel, inventory.get_item_count("battery"), inventory.get_item_count("firearm-magazine")))
			T.garage.get_inventory(defines.inventory.chest)[1].set_stack(stack)
			small.destroy()
			inventory.destroy()
		elseif t == 6100 then
			local cars = storage.garage_data[T.garage.unit_number].cars
			local entry = cars[#cars]
			out(string.format("EVENT list: car slot taken, %d cars, last health %.2f fuel %.2f batteries %s, slot empty %s", #cars,
				entry.health, entry.fuel, tostring(entry.batteries), tostring(not T.garage.get_inventory(defines.inventory.chest)[1].valid_for_read)))
			-- The battery slot refills a parked car up to a stack (200): 197 of 200 go in, 3 stay.
			local slots = T.garage.get_inventory(defines.inventory.chest)
			slots[2].set_stack{name = "battery", count = 200}
			out("EVENT load: moved " .. tostring(garage_control.load_car(T.garage, #cars)) .. ", car batteries " .. entry.batteries
				.. ", left in the slot " .. slots[2].count .. ", ammo slot filter " .. tostring(slots.get_filter(3) and slots.get_filter(3).name))
			-- A buffer of one slot, a player inventory of one slot: the first car goes to the buffer or
			-- the player, the others to the ground (with their batteries and ammo as separate items).
			local buffer, inventory = game.create_inventory(1), game.create_inventory(1)
			local player = {get_main_inventory = function() return inventory end}
			garage_control.return_cars(T.garage, buffer, player)
			local given, tagged = 0, 0
			for _, source in pairs{buffer, inventory} do
				for slot = 1, #source do
					if source[slot].valid_for_read then
						given = given + 1
						tagged = tagged + (source[slot].get_tag("state") and 1 or 0)
					end
				end
			end
			local ground = T.garage.surface.find_entities_filtered{name = "item-on-ground", position = T.garage.position, radius = 10}
			out("EVENT buffer: " .. given .. " cars given, " .. tagged .. " with state, " .. #ground .. " on the ground, for " .. #cars .. " in the list")
			buffer.destroy()
			inventory.destroy()
			for _, item in pairs(ground) do
				item.destroy()
			end
		end
		if t >= 4000 and t <= 5500 and t % 100 == 0 then
			local count, x, y = "none", 0, 0
			for _, car in pairs(storage.cars) do
				if car.valid then
					count, x, y = _utils.get_battery_count(car), car.position.x, car.position.y
				end
			end
			out(string.format("EVENT t=%d: batteries in the car %s at %.0f,%.0f, in the chest %d", t, tostring(count), x, y,
				T.chest.get_inventory(defines.inventory.chest).get_item_count("battery")))
		end
	end,
}

-- Emergency batteries on a long way to the only charger, 2000 tiles away. Two cars at 14 % charge
-- (under the critical level): car 1 carries 3 batteries, which lets it reach the charger
-- (the estimate of the trip is above its tank, not above tank plus batteries), car 2 none
-- and stays where it is. EVENT lines every 1000 ticks: charge, batteries left, position.
scenarios["batteries-trip"] = {
	ticks = 30000,
	category = "robustness",
	setup = function()
		local strip = {}
		for x = 0, 2400, 280 do
			strip[#strip + 1] = {x, 0}
		end
		local s = new_surface(strip, 4)
		make(s, names.charger, 2000, 0)
		T.cars = {make_car(s, 5, 0, 0.25, 0.14), make_car(s, 5, 8, 0.25, 0.14)}
		_utils.insert_batteries(T.cars[1], 3)
		T.surface = s
	end,
	events = function(t)
		if t % 2000 == 0 then
			local parts = {}
			for index, car in ipairs(T.cars) do
				if car.valid then
					parts[#parts + 1] = string.format("car %d: charge %.3f, batteries %d, x %.0f", index,
						_utils.get_fuel_ratio(car), _utils.get_battery_count(car), car.position.x)
				end
			end
			out("EVENT t=" .. t .. " " .. table.concat(parts, " | "))
		end
	end,
}

-- Emergency use of the batteries, EVENT lines for each car (charge, batteries, battery_empty alert):
-- car 1 at 2 % (under battery_trigger_ratio) with 2 batteries burns one at once; car 2 at 0 % with
-- none is empty, alerts and stays still until a battery is put in at t = 600, then resumes; car 3 at
-- 0 % with a battery burns it first and never alerts; car 4 at 3 % with 3 batteries, 400 tiles from
-- the charger, burns a battery on the way when its charge falls under the trigger. Also checks the
-- battery slot of the trunk (see below).
scenarios["batteries-emergency"] = {
	ticks = 9000,
	category = "robustness",
	setup = function()
		local strip = {}
		for x = 0, 1200, 280 do
			strip[#strip + 1] = {x, 0}
		end
		local s = new_surface(strip, 4)
		make(s, names.charger, 0, -20)
		make(s, names.charger, 1000, 0)
		T.cars = {make_car(s, 5, 0, 0.25, 0.02), make_car(s, 5, 8, 0.25, 0), make_car(s, 5, 16, 0.25, 0),
			make_car(s, 600, 0, 0.25, 0.03)}
		_utils.insert_batteries(T.cars[1], 2)
		_utils.insert_batteries(T.cars[3], 1)
		_utils.insert_batteries(T.cars[4], 3)
		T.surface = s
	end,
	events = function(t)
		if t == 600 then
			_utils.insert_batteries(T.cars[2], 1)
		end
		-- Battery slot of car 3 (see _utils.set_trunk_limits): the trunk takes 40 slots of 50
		-- chests; at t = 110 its filter is cleared and a chest put in it (the player could do it),
		-- and control.lua must have put the filter back and moved the chest out by t = 130 (slow_check_interval).
		local trunk = T.cars[3].valid and T.cars[3].get_inventory(defines.inventory.car_trunk)
		if trunk and t == 100 then
			local inserted = trunk.insert{name = "wooden-chest", count = 10000}
			trunk.remove{name = "wooden-chest", count = inserted}
			out("EVENT filled " .. inserted .. " chests in a trunk of " .. #trunk .. " slots (2000 chests in 41 slots expected)")
		end
		if trunk and t == 110 then
			trunk.set_filter(#trunk, nil)
			trunk[#trunk].set_stack{name = "wooden-chest", count = 5}
		end
		if trunk and (t == 110 or t == 130) then
			local filter, stack = trunk.get_filter(#trunk), trunk[#trunk]
			out("EVENT slot t=" .. t .. ": filter " .. tostring(filter and filter.name) .. " holds "
				.. (stack.valid_for_read and (stack.name .. " x" .. stack.count) or "nothing")
				.. ", chests in the cargo " .. trunk.get_item_count("wooden-chest"))
		end
		if t == 20 or t == 500 or t == 700 or (t >= 1000 and t % 1000 == 0) then
			local parts = {}
			for index, car in ipairs(T.cars) do
				if car.valid then
					parts[#parts + 1] = string.format("car %d: charge %.3f, batteries %d, alert %s, x %.0f", index,
						_utils.get_fuel_ratio(car), _utils.get_battery_count(car),
						tostring(storage.car_data[car.unit_number].alerts.battery_empty or false), car.position.x)
				end
			end
			out("EVENT t=" .. t .. " " .. table.concat(parts, " | "))
		end
	end,
}

-- The car of the scenario now standing on its surface (a garage gives a new entity back), or nil.
local function current_car()
	return T.surface.find_entities_filtered{name = names.car, limit = 1}[1]
end

-- Armed cars (the research is done at setup). Area A: an idle car (full tank, 10 batteries,
-- 5 firearm magazines) takes batteries and ammo from a supply chest (300 batteries, 100 firearm and 20
-- uranium magazines, and an empty chest in the group) just before parking: it swaps its firearm
-- magazines for the stronger uranium ones. EVENT t=3500 gives what the garage keeps aside for it
-- (batteries 200, uranium x20, 105 firearm magazines back in the chest), then the ghost selected at
-- t = 4000 sends it out again; 100 more uranium magazines were put in the chest at t = 3600, so
-- on leaving the garage it stops at the chest first (ammo 100, all the chest had), then goes to the site with a turret
-- (EVENT lines every 100 ticks).
scenarios["armed"] = {
	ticks = 7000,
	category = "robustness",
	setup = function()
		research(game.forces.player, "military")
		local s = new_surface({{0, 0}}, 6)
		make(s, names.charger, 0, 0)
		T.garage = make(s, names.garage, 20, -10)
		T.chest = make(s, names.chest, 0.5, 30.5)
		fill(T.chest, {["wooden-chest"] = 20, battery = 300, ["firearm-magazine"] = 100, ["uranium-rounds-magazine"] = 20})
		make(s, names.chest, 2.5, 30.5)
		make_ghost(s, "wooden-chest", 40.5, 40.5)
		T.car = make_car(s, 10, 10, 0, 1)
		_utils.insert_batteries(T.car, 10)
		_utils.insert_ammo(T.car, {name = "firearm-magazine", quality = "normal"}, 5)
		T.surface = s
		T.cars = {T.car}
	end,
	events = function(t)
		if t == 3500 then
			local parked = storage.garage_data[T.garage.unit_number].cars[1]
			local ammo = parked.ammo
			out("EVENT garage t=" .. t .. ": batteries kept " .. tostring(parked.batteries) .. ", ammo kept "
				.. tostring(ammo and ammo.name) .. " x" .. tostring(ammo and ammo.count) .. ", chest firearm magazines "
				.. T.chest.get_item_count("firearm-magazine") .. ", car valid " .. tostring(T.car.valid))
		end
		if t == 3600 then
			T.chest.insert{name = "uranium-rounds-magazine", count = 100} -- stock arrives while the car is parked
		end
		if t == 4000 then
			select_ghosts(35, 35, 45, 45)
		end
		if t % 100 == 0 and t >= 1000 then
			local car = current_car()
			if car then
				local ammo = _utils.get_ammo(car)
				local turret = storage.car_data[car.unit_number].turret
				out(string.format("EVENT t=%d car at %.0f,%.0f: batteries %d, magazines %s, turret %s", t, car.position.x, car.position.y,
					_utils.get_battery_count(car), tostring(ammo and ammo.count), tostring(turret ~= nil and turret.valid)))
			end
		end
	end,
}

-- Research: a force without any research gets cars with 20 cargo slots and no gun, garages of
-- 30 cars with no repair pack slot, chargers for 2 cars; the researches change all that on
-- the existing entities. EVENT lines before (t = 300) and after (t = 700) the research: cargo
-- slots a stack of iron plates can fill (the battery slot and the hidden slots refuse it),
-- cars and repair packs a garage takes, buffer of the charger in tank units, cars per charger
-- and hidden turrets on the surface.
scenarios["technologies"] = {
	ticks = 800,
	category = "robustness",
	setup = function()
		T.force = game.forces["test-research"] or game.create_force("test-research")
		local s = new_surface({{0, 0}}, 6)
		T.surface = s
		T.car = s.create_entity{name = names.car, position = {0, 0}, force = T.force, raise_built = true}
		T.garage = s.create_entity{name = names.garage, position = {20, 0}, force = T.force, raise_built = true}
		T.charger = s.create_entity{name = names.charger, position = {-20, 0}, force = T.force, raise_built = true}
		T.cars = {T.car}
	end,
	events = function(t)
		local function report(label)
			local trunk = T.car.get_inventory(defines.inventory.car_trunk)
			local filled = 0
			for _ = 1, #trunk do
				if trunk.insert{name = "iron-plate", count = 100} > 0 then
					filled = filled + 1
				end
			end
			trunk.remove{name = "iron-plate", count = 100 * #trunk}
			local garage = T.garage.get_inventory(defines.inventory.chest)
			local cars = garage_control.get_capacity(T.garage)
			local kits = garage.insert{name = config.repair_kit, count = 1}
			if kits > 0 then
				garage.remove{name = config.repair_kit, count = kits}
			end
			local ammo_slot = T.car.get_inventory(defines.inventory.car_ammo)
			local ammo = ammo_slot.insert{name = "firearm-magazine", count = 1}
			if ammo > 0 then
				ammo_slot.remove{name = "firearm-magazine", count = ammo}
			end
			out(string.format("EVENT t=%d %s: cargo slots %d, ammo slot takes %d, garage cars %d, repair packs %d, charger buffer %.1f tanks for %d cars, speeds charge %.1f build %.1f, turrets %d",
				t, label, filled, ammo, cars, kits, T.charger.electric_buffer_size / prototypes.item[names.fuel].fuel_value,
				_utils.get_upgrade(T.force, "chargers"), _utils.get_upgrade(T.force, "charge_speed"), _utils.get_upgrade(T.force, "build_speed"),
				#T.surface.find_entities_filtered{name = names.turret}))
		end
		if t == 300 then
			report("no research")
			research(T.force, names.technology)
			research(T.force, names.repair_technology)
			research(T.force, "military")
			for _, key in ipairs{"cargo", "garage", "chargers", "charge_speed", "build_speed"} do
				research(T.force, names.technology .. "_" .. key .. "_1")
			end
		elseif t == 500 then
			-- The ammo slot opens once the cars have noticed the research (slow check).
			_utils.insert_ammo(T.car, {name = "firearm-magazine", quality = "normal"}, 5)
		elseif t == 700 then
			report("level 1, repair and military")
		end
	end,
}

-- Armed car defending itself: an idle car with 60 magazines (no garage on the surface, so it
-- stays put) is attacked by four small biters (firearm rounds are weak against medium ones) from t = 1000; its turret must kill them, and what
-- it fires comes out of the car's ammo slot (EVENT lines every 100 ticks).
scenarios["armed-defense"] = {
	ticks = 3000,
	category = "robustness",
	setup = function()
		research(game.forces.player, "military")
		local s = new_surface({{0, 0}}, 6)
		T.surface = s
		T.car = make_car(s, 0, 0, 0, 1)
		_utils.insert_ammo(T.car, {name = "firearm-magazine", quality = "normal"}, 60)
		T.cars = {T.car}
		T.biters = {}
	end,
	events = function(t)
		if t == 1000 then
			for i = 1, 4 do
				local biter = T.surface.create_entity{name = "small-biter", position = {20, -6 + 4 * i}, force = "enemy"}
				biter.commandable.set_command{type = defines.command.attack, target = T.car, distraction = defines.distraction.none}
				T.biters[i] = biter
			end
		end
		if t % 100 == 0 and t >= 1000 then
			local alive = 0
			for _, biter in pairs(T.biters) do
				if biter.valid then
					alive = alive + 1
				end
			end
			local car = current_car()
			local ammo = car and _utils.get_ammo(car)
			out(string.format("EVENT t=%d biters alive %d, car health %s, magazines %s", t, alive,
				car and string.format("%.0f", car.health) or "dead", tostring(ammo and ammo.count)))
		end
	end,
}

-- Armed cars with different ammo against two medium biters each: three cars 200 tiles apart
-- (firearm, piercing and uranium magazines). EVENT lines every 100 ticks: biters alive, car health
-- and magazines left per car; the first EVENT gives the force's bonuses (the hidden turret gets the
-- ammo damage and gun speed bonuses, but not the "gun-turret" attack bonus, tied to the turret name).
scenarios["armed-ammo"] = {
	ticks = 2500,
	category = "robustness",
	setup = function()
		research(game.forces.player, "military")
		local s = new_surface({{0, 0}, {200, 0}, {400, 0}}, 6)
		T.surface = s
		T.ammo_names = {"firearm-magazine", "piercing-rounds-magazine", "uranium-rounds-magazine"}
		T.cars = {}
		T.biters = {}
		for index, ammo_name in ipairs(T.ammo_names) do
			local car = make_car(s, 200 * (index - 1), 0, 0, 1)
			_utils.insert_ammo(car, {name = ammo_name, quality = "normal"}, 60)
			T.cars[index] = car
			T.biters[index] = {}
		end
	end,
	events = function(t)
		if t == 1000 then
			local force = game.forces.player
			out(string.format("EVENT bonuses: bullet damage %.2f, gun speed %.2f, hidden turret attack %.2f, gun turret attack %.2f",
				force.get_ammo_damage_modifier("bullet"), force.get_gun_speed_modifier("bullet"),
				force.get_turret_attack_modifier(names.turret), force.get_turret_attack_modifier("gun-turret")))
			for index, car in ipairs(T.cars) do
				for i = 1, 2 do
					local biter = T.surface.create_entity{name = "medium-biter", position = {200 * (index - 1) + 20, -2 + 4 * i}, force = "enemy"}
					biter.commandable.set_command{type = defines.command.attack, target = car, distraction = defines.distraction.none}
					T.biters[index][i] = biter
				end
			end
		end
		if t % 100 == 0 and t >= 1000 then
			local parts = {}
			for index, car in ipairs(T.cars) do
				local alive = 0
				for _, biter in pairs(T.biters[index]) do
					if biter.valid then
						alive = alive + 1
					end
				end
				local ammo = car.valid and _utils.get_ammo(car)
				parts[#parts + 1] = string.format("%s: biters %d, health %s, ammo %s", T.ammo_names[index]:sub(1, 5), alive,
					car.valid and string.format("%.0f", car.health) or "dead", tostring(ammo and ammo.count))
			end
			out("EVENT t=" .. t .. " " .. table.concat(parts, " | "))
		end
	end,
}

-- Fleeing from the enemy. Car 1 (west) has a ghost to build 30 tiles from a small worm; a charger
-- lies on the far side of the car, away from the worm (garage and charger positions below): each time
-- the car comes within 40 tiles of the worm it must flee to the charger, wait there, come back, and
-- after config.flee.max_count (3) flights abandon its batch at the 4th (EVENT lines: flee count,
-- batch, position; the ghost must stay unbuilt). `flee-open`: the only chargers are behind
-- the worm or past config.flee.max_refuge_distance: no refuge, so each time the car drives 150 tiles straight away
-- from the worm (EVENT lines: position far from the worm while fleeing), comes back, and abandons after 3 flights.
scenarios["flee"] = {
	ticks = 14000,
	category = "robustness",
	setup = function()
		local s = new_surface({{0, 0}}, 6)
		T.surface = s
		-- West: car at the origin, ghost 80 tiles east, worm 30 tiles beyond it, charger and garage behind the car.
		T.refuge = make(s, names.charger, 30, -30)
		make(s, names.garage, -40, 10)
		T.chest = make(s, names.chest, 0.5, 20.5)
		fill(T.chest, {["wooden-chest"] = 20})
		s.create_entity{name = "small-worm-turret", position = {110, 0}, force = "enemy"}
		make_ghost(s, "wooden-chest", 80.5, 0.5)
		T.car = make_car(s, 0, 0, 0.25, 1)
		T.cars = {T.car}
	end,
	events = function(t)
		if t == 100 then
			select_ghosts(75, -5, 85, 5)
		end
		if t >= 200 and t % 200 == 0 and current_car() then
			local car = current_car()
			local data = storage.car_data[car.unit_number]
			local built = #T.surface.find_entities_filtered{name = "wooden-chest", position = {80.5, 0.5}, radius = 2}
			out(string.format("EVENT t=%d flights %d%s, batch %s, at %.0f,%.0f | chests built %d", t, data.flee.count,
				data.flee.active and " (fleeing)" or "", tostring(data.construction ~= nil), car.position.x, car.position.y, built))
		end
	end,
}

scenarios["flee-open"] = {
	ticks = 14000,
	category = "robustness",
	setup = function()
		local s = new_surface({{0, 0}, {150, 50}, {230, 0}}, 6)
		T.surface = s
		-- The worm lies between the car and the only charger (to the west).
		make(s, names.charger, -40, 0)
		make(s, names.charger, 230, 0) -- away from the worm but too far to be a refuge
		T.chest = make(s, names.chest, 0.5, 20.5)
		fill(T.chest, {["wooden-chest"] = 20})
		s.create_entity{name = "small-worm-turret", position = {0, 0}, force = "enemy"}
		make_ghost(s, "wooden-chest", 30.5, 0.5)
		T.car = make_car(s, 30, 10, 0.25, 1)
		T.cars = {T.car}
	end,
	events = function(t)
		if t == 100 then
			select_ghosts(25, -5, 35, 5)
		end
		if t >= 200 and t % 200 == 0 and current_car() then
			local car = current_car()
			local data = storage.car_data[car.unit_number]
			local built = #T.surface.find_entities_filtered{name = "wooden-chest", position = {30.5, 0.5}, radius = 2}
			out(string.format("EVENT t=%d flights %d%s, batch %s, at %.0f,%.0f | chests built %d", t, data.flee.count,
				data.flee.active and " (fleeing)" or "", tostring(data.construction ~= nil), car.position.x, car.position.y, built))
		end
	end,
}

-- Two idle cars side by side, one at 14 % charge with the only charger 800 tiles away
-- (under its critical level, out of reach), one full. A ghost is selected at t = 200:
-- the full car must get the batch, the low one none (EVENT lines at t = 1500).
-- 1600 tiles away (too far for their charger checks), a car at 17 % charge
-- with a charger beside it is given a ghost 150 tiles away at t = 300: enough
-- for the leg to the supply chest, not for the one to the site, so it must
-- detour to the charger in between (travel.detour_to_charger), then build it.
scenarios["critical-no-batch"] = {
	ticks = 5000,
	category = "energy",
	setup = function()
		local s = new_surface({{0, 0}, {800, 0}, {0, 1600}, {150, 1600}}, 3)
		make(s, names.charger, 800, 0)
		T.chest = make(s, names.chest, 0.5, 20.5)
		fill(T.chest, {["wooden-chest"] = 20})
		T.low = make_car(s, 5, 0, 0, 0.14)
		T.full = make_car(s, 5, 6, 0, 1)
		make_ghost(s, "wooden-chest", 30.5, 30.5)

		T.detour_charger = make(s, names.charger, -10, 1600)
		fill(make(s, names.chest, 0.5, 1620.5), {["wooden-chest"] = 5})
		T.detour = make_car(s, 0, 1600, 0, 0.17)
		T.detour_ghost = make_ghost(s, "wooden-chest", 150.5, 1600.5)
	end,
	events = function(t)
		if t == 200 then
			select_ghosts(25, 25, 35, 35)
		end
		if t == 300 then
			select_ghosts(140, 1590, 160, 1610)
		end
		if t == 1500 then
			out("EVENT low car " .. (storage.car_data[T.low.unit_number].construction and "GOT a batch (wrong)" or "has no batch (expected)"))
			out("EVENT full car " .. (storage.car_data[T.full.unit_number].construction and "has a batch (expected)" or "has no batch (batch already built or lost)"))
		end
		local detour_data = T.detour.valid and storage.car_data[T.detour.unit_number]
		if detour_data and not T.detour_seen and heading_to(T.detour, T.detour_charger) and detour_data.charge_detour_count > 0 then
			T.detour_seen = true
			out(string.format("EVENT detour car heads for the charger at %d, fuel %.2f, %s", t, _utils.get_fuel_ratio(T.detour),
				detour_data.construction and "batch kept (expected)" or "no batch (wrong)"))
		end
		if not T.detour_built and not T.detour_ghost.valid then
			T.detour_built = true
			out("EVENT detour ghost built at " .. t .. (T.detour_seen and " after the detour (expected)" or " without a detour (wrong)"))
		end
		if t == 4800 and not T.detour_built then
			out("EVENT detour ghost not built (wrong)")
		end
	end,
}

-- Signals of the link of a garage or a charger (circuit.lua), as one line.
local function read_link(data)
	local link = data.link
	if not (link and link.valid) then
		return "no link"
	end
	local parts = {}
	local section = link.get_or_create_control_behavior().get_section(1)
	for _, filter in pairs(section and section.filters or {}) do
		parts[#parts + 1] = filter.value.name .. "=" .. filter.min
	end
	table.sort(parts)
	return table.concat(parts, " ")
end

-- Circuit links (circuit.lua). A garage with two parked cars (health 0.5 and 1, charge 0.8 and 0.6)
-- puts on its link: cars 2, free places = capacity - 2, health 75, charge 70. A charger (its buffer
-- is set by hand, not refilled by the harness) shows its charge in %, the cars using it and the power
-- drawn: at t = 600 the buffer gains 3 MJ as if the network had fed it, and the next link refresh
-- (30 ticks) shows 6000 kW. A third car charges at t = 1000: users 1. Mining the garage and the charger removes their links.
scenarios["circuit-links"] = {
	ticks = 2500,
	category = "energy",
	setup = function()
		local s = new_surface({{0, 0}}, 4)
		T.garage = make(s, names.garage, 20, 0)
		local cars = storage.garage_data[T.garage.unit_number].cars
		cars[1] = {quality = "normal", health = 0.5, fuel = 0.8}
		cars[2] = {quality = "normal", health = 1, fuel = 0.6}
		T.charger = s.create_entity{name = names.charger, position = {0, 0}, force = "player", raise_built = true}
		T.charger.energy = 3e7
		T.car = make_car(s, 10, 0, 0.25, 0.3)
		T.surface = s
		T.cars = {T.car}
	end,
	events = function(t)
		if t == 300 then
			out("EVENT garage link: " .. read_link(storage.garage_data[T.garage.unit_number]) .. " (capacity "
				.. garage_control.get_capacity(T.garage) .. ")")
			out("EVENT charger link: " .. read_link(storage.charger_data[T.charger.unit_number]))
			out("EVENT garage has a circuit connector: " .. tostring(T.garage.get_wire_connector(defines.wire_connector_id.circuit_red, true) ~= nil)
				.. ", link entities: " .. #T.surface.find_entities_filtered{name = names.link})
		end
		if t == 600 then
			T.charger.energy = T.charger.energy + 3e6
		end
		if (t >= 610 and t <= 700 and t % 30 == 10) or t == 1200 or t == 1500 then
			out("EVENT t=" .. t .. " charger link: " .. read_link(storage.charger_data[T.charger.unit_number]))
		end
		if t == 2000 then
			local garage_data = storage.garage_data[T.garage.unit_number]
			local charger_data = storage.charger_data[T.charger.unit_number]
			local garage_link, charger_link = garage_data.link, charger_data.link
			T.garage.die()
			T.charger.die()
			out("EVENT after removal: garage link valid " .. tostring(garage_link.valid) .. ", charger link valid " .. tostring(charger_link.valid))
		end
	end,
}

-- Logistic interface (logistic.lua). A supply chest holds 2 wooden chests, a delivery chest and a
-- return chest stand apart. A car takes a batch of 5 wooden chest ghosts: after it took the 2, the
-- delivery chest requests the 3 left (EVENT t=600); the robots are played at t = 700 by 3 wooden
-- chests put in the delivery chest, and the car finishes (EVENT ghosts left). A second, idle car
-- carries 10 iron plates: it deposits them in the return chest although the plain chest is closer.
scenarios["logistic-interface"] = {
	ticks = 4000,
	category = "construction",
	setup = function()
		local s = new_surface({{0, 0}}, 4)
		T.plain = make(s, names.chest, 0.5, 20.5)
		fill(T.plain, {["wooden-chest"] = 2})
		T.delivery = make(s, names.delivery_chest, 10.5, 20.5)
		T.return_chest = make(s, names.return_chest, 40.5, 20.5)
		for i = 0, 4 do
			make_ghost(s, "wooden-chest", 30.5 + i * 2, 30.5)
		end
		T.car = make_car(s, 5, 0, 0.25, 1)
		T.idle = make_car(s, 5, 10, 0.25, 1)
		T.idle.get_inventory(defines.inventory.car_trunk).insert{name = "iron-plate", count = 10}
		T.surface = s
		T.cars = {T.car, T.idle}
	end,
	events = function(t)
		if t == 100 then
			select_ghosts(25, 25, 45, 35)
		end
		if t == 600 then
			local parts = {}
			local section = T.delivery.get_logistic_sections().get_section(1)
			for _, filter in pairs(section and section.filters or {}) do
				parts[#parts + 1] = filter.value.name .. " x" .. filter.min
			end
			out("EVENT t=600 delivery requests: " .. table.concat(parts, ", ") .. " (expected wooden-chest x3)")
		end
		if t == 700 then
			fill(T.delivery, {["wooden-chest"] = 3}) -- the robots
		end
		if t == 3500 then
			local ghosts = #T.surface.find_entities_filtered{type = "entity-ghost"}
			out("EVENT ghosts left " .. ghosts .. " (expected 0), plates in the return chest "
				.. T.return_chest.get_inventory(defines.inventory.chest).get_item_count("iron-plate")
				.. ", in the plain chest " .. T.plain.get_inventory(defines.inventory.chest).get_item_count("iron-plate") .. " (expected 10 and 0)")
		end
	end,
}

-- A car that arrives beside a rail drives off the rails before it acts (movement.start_retreat):
-- the chest at the rails is the destination of a collection, the ghosts next to them a chantier.
-- A second builder far from the rails must not leave its path. Each car samples its distance to
-- the closest rail whenever it is still after a build (the end report gives the shortest).
scenarios["rails"] = {
	ticks = 3000,
	category = "construction",
	setup = function()
		local s = new_surface({{0, 0}}, 3)
		for x = 0, 48, 2 do
			s.create_entity{name = "straight-rail", position = {x, 20}, direction = defines.direction.east, force = "player"}
		end
		T.chest = make(s, names.chest, 20.5, 22.5) -- beside the rails
		fill(T.chest, {["wooden-chest"] = 6})
		for i = 0, 2 do
			make_ghost(s, "wooden-chest", 30.5 + i * 2, config.test_rails_ghost_y or 22.5) -- next to the rails; -Set "test_rails_ghost_y=21.5" puts them against the line, where they are never built (checked 2026-10-20), whatever the rail margin
			make_ghost(s, "wooden-chest", 30.5 + i * 2, 5.5) -- far from the rails
		end
		T.builder = make_car(s, 5, 10, 0.25, 1)
		T.surface = s
		T.cars = {T.builder}
		T.closest = math.huge
	end,
	events = function(t)
		local car = T.builder
		if t == 100 then
			select_ghosts(25, 0, 40, 30)
		end
		if car.valid and t % 30 == 0 and car.speed == 0 and t > 100 then
			local data = storage.car_data[car.unit_number]
			if data and data.building.active then
				local rail = T.surface.find_entities_filtered{type = "straight-rail", position = car.position, radius = 12, limit = 1}[1]
				if rail then
					T.closest = math.min(T.closest, math.abs(car.position.y - rail.position.y))
				end
			end
		end
		if t == 2800 then
			local ghosts = #T.surface.find_entities_filtered{type = "entity-ghost"}
			out("EVENT ghosts left " .. ghosts .. " (expected 0), closest building stop to a rail line: "
				.. (T.closest < math.huge and string.format("%.1f", T.closest) or "none") .. " tiles (expected 1.5 or more)")
		end
	end,
}

-- Entities marked for deconstruction. `name` is a tree, a rock or any building; a
-- building gets `items` in its first inventory. The mod's get_id key is reported
-- at setup: it tells whether trees and rocks have a unit_number.
local function mark(surface, name, x, y, items)
	local entity = surface.create_entity{name = name, position = {x, y}, force = "player"}
	if not entity then
		out("SETUP could not create " .. name .. " at " .. x .. "," .. y)
		return nil
	end
	if items then
		entity.get_inventory(1).insert(items)
	end
	entity.order_deconstruction("player")
	table.insert(T.marked, entity)
	if not T.seen_names then
		T.seen_names = {}
	end
	if not T.seen_names[name] then
		T.seen_names[name] = true
		out("SETUP " .. name .. " unit_number=" .. tostring(entity.unit_number) .. " type=" .. entity.type
			.. " minable=" .. tostring(entity.minable) .. " marked=" .. tostring(entity.to_be_deconstructed()))
	end
	return entity
end

-- Stands in for dragging the selector over an area: the game hands over every
-- deconstructable entity there, the mod keeps the ghosts and the marked ones.
local function select_all(x1, y1, x2, y2)
	local entities = T.surface.find_entities_filtered{area = {{x1, y1}, {x2, y2}}}
	out("SELECT " .. game.tick .. " " .. #entities .. " entities")
	on_area_selected{item = names.ghost_selector, player_index = 1, entities = entities, tick = game.tick}
end

local function count_valid(list)
	local count = 0
	for _, entity in pairs(list) do
		if entity.valid then
			count = count + 1
		end
	end
	return count
end

-- What the batch of a car holds: ghosts to build and marked entities to mine.
local function describe_batch(car)
	local construction = storage.car_data[car.unit_number].construction
	if not construction then
		return "no batch"
	end
	local ghosts, marked = 0, 0
	for _, ghost in pairs(construction.ghosts) do
		if ghost.valid then
			if (ghost.type == "entity-ghost" or ghost.type == "tile-ghost") then
				ghosts = ghosts + 1
			else
				marked = marked + 1
			end
		end
	end
	return ghosts .. " ghosts + " .. marked .. " marked" .. ((ghosts > 0 and marked > 0) and " (MIXED, wrong)" or "")
end

-- Logs the batch of each car of T.cars when it changes.
local function watch_batches()
	T.last_batch = T.last_batch or {}
	for index, car in pairs(T.cars) do
		if car.valid then
			local text = describe_batch(car)
			if T.last_batch[index] ~= text then
				T.last_batch[index] = text
				out("EVENT t=" .. game.tick .. " car " .. index .. " batch: " .. text)
			end
		end
	end
end

local function report_supply(label)
	local parts = {}
	for _, item in pairs(T.chest.get_inventory(defines.inventory.chest).get_contents()) do
		parts[#parts + 1] = item.name .. "=" .. item.count
	end
	table.sort(parts)
	out("EVENT " .. label .. ": " .. count_valid(T.marked) .. "/" .. #T.marked .. " marked entities left; supply chest holds "
		.. table.concat(parts, ", "))
end

-- Marks an entity for upgrade to `target`, after filling its first inventory (or,
-- for a machine, its module slots) with `items`.
local function mark_upgrade(surface, name, target, x, y, items, modules)
	local entity = surface.create_entity{name = name, position = {x, y}, force = "player"}
	if not entity then
		out("SETUP could not create " .. name .. " at " .. x .. "," .. y)
		return nil
	end
	if items then
		entity.get_inventory(defines.inventory.chest).insert(items)
	end
	if modules then
		entity.get_module_inventory().insert(modules)
	end
	local ordered = entity.order_upgrade{force = "player", target = target}
	out("SETUP " .. name .. " -> " .. (type(target) == "table" and (target.name .. "/" .. target.quality) or target) .. " ordered=" .. tostring(ordered) .. " marked=" .. tostring(entity.to_be_upgraded()))
	table.insert(T.marked, entity)
	return entity
end

-- Total of an item in every player entity of the surface (chests, machines, cars).
local function count_item_everywhere(item_name)
	local total = 0
	for _, entity in pairs(T.surface.find_entities_filtered{force = "player"}) do
		for index = 1, entity.get_max_inventory_index() do
			local inventory = entity.get_inventory(index)
			if inventory then
				total = total + inventory.get_item_count(item_name)
			end
		end
	end
	return total
end

-- The order of the work. Groups, in phase order: entities to mine, then ghosts
-- and entities to upgrade, last the roboport ghosts (network mode). Logs each
-- change of a group, and PHASE VIOLATION when a group makes progress while an
-- earlier one is not finished.
local function watch_phases(groups)
	T.group_left = T.group_left or {}
	for index, list in ipairs(groups) do
		local left = count_valid(list)
		local before = T.group_left[index]
		if before ~= left then
			if before and left < before then
				for earlier = 1, index - 1 do
					if count_valid(groups[earlier]) > 0 then
						out("EVENT PHASE VIOLATION t=" .. game.tick .. ": group " .. index .. " progressed, group " .. earlier .. " not done")
						break
					end
				end
			end
			if before == nil or left == 0 or before == #list then
				out("EVENT t=" .. game.tick .. " group " .. index .. ": " .. left .. "/" .. #list .. " left")
			end
			T.group_left[index] = left
		end
	end
end

-- Everything the cars can do, at once, on one large map (three cars, five
-- chargers), in separate areas:
--   east,  y 50..100   to mine: trees, rocks, chests holding plates, a furnace
--   west,  y 50..100   to upgrade: chests, a full steel chest to a smaller
--                      iron chest, machines 3 with four modules to machines 2
--   east,  y -100..-50 ghosts on top of entities to mine (furnaces over chests,
--                      chests over trees)
--   west,  y -100..-50 plain ghosts: wooden chests, concrete tiles, roboports
--   north, y -45..-25  two ponds: landfill ghosts across the first one (40 tiles, the shore
--                      is next to some of them; wooden chest ghosts on two of them wait for
--                      the fill), landfill ghosts only in the middle of the second one
--                      (out of reach: the batch must be abandoned with an alert)
-- Order of the work (see PHASE in construction.lua): the groups below are in phase
-- order and a group must not progress while an earlier one is not finished
-- (PHASE VIOLATION). Nothing may be lost either: plates and modules are counted
-- in the world at the end.
local function build_work()
	local s = new_surface({{0, 0}}, 8)
	for _, x in pairs({-100, 0, 100}) do
		make(s, names.charger, x, 0)
	end
	make(s, names.charger, 0, 60)
	make(s, names.charger, 0, -60)
	make(s, names.garage, 20, -10)
	T.chest = make(s, names.chest, 0.5, 30.5)
	fill(T.chest, {["wooden-chest"] = 60, ["stone-furnace"] = 20, ["iron-chest"] = 10, ["assembling-machine-2"] = 5,
		["roboport"] = 4, ["concrete"] = 100, ["landfill"] = 100})
	T.cars = {}
	for index = 1, 3 do
		T.cars[index] = make_car(s, 10 + 6 * index, 10, 0.1)
	end

	-- Phase 1: to mine.
	T.marked = {}
	for i = 0, 3 do
		for j = 0, 2 do
			mark(s, "tree-01", 60 + 3 * i, 60 + 3 * j)
		end
	end
	mark(s, "big-rock", 80, 60)
	mark(s, "huge-rock", 86, 68)
	for i = 0, 4 do
		mark(s, "wooden-chest", 60.5 + 2 * i, 80.5, {name = "iron-plate", count = 50})
	end
	mark(s, "stone-furnace", 71, 91, {name = "coal", count = 20})
	for i = 0, 7 do -- a wall
		mark(s, "stone-wall", 90.5 + i, 95.5)
	end
	for i = 0, 5 do
		mark(s, "wooden-chest", 60.5 + 4 * i, -60.5, {name = "iron-plate", count = 10})
	end
	for i = 0, 3 do
		mark(s, "tree-01", 60.5 + 4 * i, -80.5)
	end
	T.mine = T.marked

	-- Phase 2: water to fill in.
	local water = {}
	for x = 40, 51 do
		for y = -45, -34 do
			water[#water + 1] = {name = "water", position = {x, y}}
		end
	end
	for x = 70, 85 do
		for y = -45, -30 do
			water[#water + 1] = {name = "water", position = {x, y}}
		end
	end
	s.set_tiles(water, false)
	T.landfill = {}
	for x = 40, 46 do
		for y = -42, -38 do
			T.landfill[#T.landfill + 1] = s.create_entity{name = "tile-ghost", inner_name = "landfill", position = {x, y},
				force = "player", expires = false}
		end
	end
	T.stranded = {}
	for x = 76, 79 do
		for y = -40, -36 do
			T.stranded[#T.stranded + 1] = s.create_entity{name = "tile-ghost", inner_name = "landfill", position = {x, y},
				force = "player", expires = false}
		end
	end

	-- Phase 3: to build and to upgrade.
	T.build = {}
	for i = 0, 1 do -- on tiles that are still water
		local ghost = make_ghost(s, "wooden-chest", 43.5 + i, -39.5)
		if ghost then
			T.build[#T.build + 1] = ghost
		end
	end
	for i = 0, 5 do
		T.build[#T.build + 1] = make_ghost(s, "stone-furnace", 61 + 4 * i, -60)
	end
	for i = 0, 3 do
		T.build[#T.build + 1] = make_ghost(s, "wooden-chest", 60.5 + 4 * i, -80.5)
	end
	for i = 0, 7 do
		T.build[#T.build + 1] = make_ghost(s, "wooden-chest", -140.5 + 2 * i, -60.5)
	end
	for i = 0, 7 do
		for j = 0, 3 do
			T.build[#T.build + 1] = s.create_entity{name = "tile-ghost", inner_name = "concrete", position = {-140 + i, -70 + j},
				force = "player", expires = false}
		end
	end
	T.marked = {}
	for i = 0, 3 do
		mark_upgrade(s, "wooden-chest", "iron-chest", -140.5 + 2 * i, 60.5, {name = "iron-plate", count = 30})
	end
	mark_upgrade(s, "steel-chest", "iron-chest", -140.5, 70.5, {name = "iron-plate", count = 3600})
	for i = 0, 1 do
		mark_upgrade(s, "assembling-machine-3", "assembling-machine-2", -139.5 + 4 * i, 80.5, nil, {name = "speed-module-3", count = 4})
	end
	T.upgrades = T.marked
	for _, entity in pairs(T.upgrades) do
		T.build[#T.build + 1] = entity
	end

	-- Phase 4: roboports.
	T.network = {}
	for i = 0, 1 do
		T.network[#T.network + 1] = make_ghost(s, "roboport", -140 + 8 * i, -90)
	end
	out("EVENT start: plates=" .. count_item_everywhere("iron-plate") .. " modules=" .. count_item_everywhere("speed-module-3"))
end

local function report_work(label)
	local function count(name)
		return #T.surface.find_entities_filtered{name = name, force = "player"}
	end
	local modules_in_machines = 0
	for _, machine in pairs(T.surface.find_entities_filtered{name = "assembling-machine-2"}) do
		modules_in_machines = modules_in_machines + machine.get_module_inventory().get_item_count("speed-module-3")
	end
	local replaced = 0
	for _, entity in pairs(T.upgrades) do
		if not entity.valid then
			replaced = replaced + 1
		end
	end
	local tiles = T.surface.count_tiles_filtered{name = "concrete", area = {{-150, -80}, {-130, -60}}}
	out("EVENT " .. label .. ": mine " .. count_valid(T.mine) .. "/" .. #T.mine .. " left, build+upgrade "
		.. count_valid(T.build) .. "/" .. #T.build .. " left, network " .. count_valid(T.network) .. "/" .. #T.network .. " left")
	out("EVENT " .. label .. ": " .. replaced .. "/" .. #T.upgrades .. " replaced; iron-chest=" .. count("iron-chest")
		.. " steel-chest=" .. count("steel-chest") .. " assembling-machine-2=" .. count("assembling-machine-2")
		.. " assembling-machine-3=" .. count("assembling-machine-3") .. " wooden-chest=" .. count("wooden-chest")
		.. " stone-furnace=" .. count("stone-furnace") .. " roboport=" .. count("roboport") .. " concrete tiles=" .. tiles .. " (32 expected)")
	out("EVENT " .. label .. ": landfill tiles in the first pond=" .. T.surface.count_tiles_filtered{name = "landfill", area = {{40, -45}, {52, -34}}}
		.. " (35 expected), in the second=" .. T.surface.count_tiles_filtered{name = "landfill", area = {{70, -45}, {86, -30}}}
		.. " (0 expected, batch abandoned)")
	out("EVENT " .. label .. ": iron-plate in the world=" .. count_item_everywhere("iron-plate")
		.. " (start value above, plus 250+60 from the chests mined), speed-module-3=" .. count_item_everywhere("speed-module-3")
		.. " (8 at the start), in the machines=" .. modules_in_machines)
	report_supply(label)
end

scenarios["work"] = {
	ticks = 22000,
	category = "construction",
	setup = function()
		build_work()
	end,
	events = function(t)
		if t == 200 then
			select_all(-160, -110, 110, 110)
		end
		watch_batches()
		watch_phases({T.mine, T.landfill, T.build, T.network})
		if t == 21500 then
			report_work("end")
		end
	end,
}

-- World of phases-single: a car, trees to mine, ghosts to build.
local function build_single_car()
	local s = new_surface({{0, 0}}, 6)
	make(s, names.charger, 0, 0)
	make(s, names.charger, 0, 60)
	make(s, names.garage, 20, -10)
	T.chest = make(s, names.chest, 0.5, 30.5)
	T.cars = {make_car(s, 16, 10, 0.1)}
	T.marked = {}
	for i = 0, 5 do
		mark(s, "tree-01", -60 - 3 * i, 60)
	end
	T.mine = T.marked
	T.build = {}
	for i = 0, 7 do
		T.build[#T.build + 1] = make_ghost(s, "wooden-chest", 60.5 + 2 * i, 60.5)
	end
	T.network = {}
end

local function report_phases(label)
	out("EVENT " .. label .. ": mine " .. count_valid(T.mine) .. "/" .. #T.mine .. " left, build+upgrade "
		.. count_valid(T.build) .. "/" .. #T.build .. " left")
end

-- One car, busy with a batch that lacks its items, when the trees are selected:
-- no car is free for them. Once the batch has its items it must wait for the
-- trees, and after long_delay give its batch back so that the car mines them
-- first (EVENT lines of the batches), then builds the ghosts.
scenarios["phases-single"] = {
	ticks = 16000,
	category = "construction",
	setup = function()
		build_single_car()
	end,
	events = function(t)
		if t == 1500 then
			select_all(50, 50, 100, 70)
		end
		if t == 1800 then
			select_all(-100, 50, -50, 70)
		end
		if t == 4000 then
			fill(T.chest, {["wooden-chest"] = 40})
			out("EVENT supply chest filled")
		end
		watch_batches()
		watch_phases({T.mine, T.build})
		if t == 15500 then
			report_phases("end")
		end
	end,
}

-- Two assembling machines are ghosts that request modules (insert_plan): the first two
-- speed modules (both slots), the second a productivity module the chest does not hold
-- until t = 3000. Both are one cluster, which waits for all its items: nothing is built at t = 1500
-- (EVENT), then both machines are built with their modules in the slots and no item request
-- proxy left (EVENT at t = 5000).
scenarios["modules"] = {
	ticks = 6000,
	category = "construction",
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, names.charger, 0, 0)
		make(s, names.garage, 20, -10)
		T.chest = make(s, names.chest, 0.5, 30.5)
		fill(T.chest, {["assembling-machine-2"] = 2, ["speed-module"] = 5})
		make_car(s, 10, 10, 0, 1)
		T.ghosts = {}
		for index, module in ipairs{"speed-module", "productivity-module"} do
			local ghost = s.create_entity{name = "entity-ghost", inner_name = "assembling-machine-2",
				position = {40.5 + 10 * index, 40.5}, force = "player", expires = false}
			local slots = {{inventory = defines.inventory.crafter_modules, stack = 0}}
			if index == 1 then
				slots[2] = {inventory = defines.inventory.crafter_modules, stack = 1}
			end
			ghost.insert_plan = {{id = {name = module}, items = {in_inventory = slots}}}
			T.ghosts[index] = ghost
		end
		T.surface = s
	end,
	events = function(t)
		if t == 200 then
			select_ghosts(40, 35, 70, 45)
		end
		if t == 3000 then
			fill(T.chest, {["productivity-module"] = 1})
		end
		if t == 1500 or t == 5000 then
			local parts = {}
			for _, machine in pairs(T.surface.find_entities_filtered{name = "assembling-machine-2"}) do
				local modules = machine.get_module_inventory()
				parts[#parts + 1] = string.format("machine at %.0f: modules %d, proxies %d", machine.position.x,
					modules and #modules - modules.count_empty_stacks() or -1,
					#T.surface.find_entities_filtered{name = "item-request-proxy", position = machine.position, radius = 3})
			end
			out("EVENT t=" .. t .. " " .. #T.surface.find_entities_filtered{name = "entity-ghost"} .. " ghosts left; " .. table.concat(parts, " | "))
		end
	end,
}

-- Three cliffs and a tree are marked for deconstruction; the chest holds two cliff
-- explosives, one short for the cliffs (a cluster waits for all its items). The car must
-- fetch them, mine the tree, give the cliffs back to the pending pool, and destroy all three
-- once the third explosive is added at tick 5000 (EVENT lines).
scenarios["cliffs"] = {
	ticks = 9000,
	category = "construction",
	setup = function()
		local s = new_surface({{0, 0}}, 6)
		make(s, names.charger, 0, 0)
		make(s, names.garage, 20, -10)
		T.chest = make(s, names.chest, 0.5, 30.5)
		fill(T.chest, {["cliff-explosives"] = 2})
		T.cars = {make_car(s, 16, 10, 0.1)}
		T.surface = s
		T.marked = {}
		-- Cliffs can only be marked once the force has researched the cliff explosives.
		game.forces.player.technologies["cliff-explosives"].researched = true
		for i = 0, 2 do
			local cliff = s.create_entity{name = "cliff", position = {40 + 5 * i, 60}, cliff_orientation = "west-to-east", force = "player"}
			if cliff then
				local ordered = cliff.order_deconstruction("player")
				out("SETUP cliff ordered=" .. tostring(ordered) .. " marked=" .. tostring(cliff.to_be_deconstructed()) .. " minable=" .. tostring(cliff.minable) .. " type=" .. cliff.type)
				table.insert(T.marked, cliff)
			else
				out("SETUP cliff NOT created")
			end
		end
		mark(s, "tree-01", 60, 60)
		T.mine = T.marked
	end,
	events = function(t)
		if t == 300 then
			select_all(30, 50, 70, 70)
		end
		if t == 5000 then
			fill(T.chest, {["cliff-explosives"] = 1})
			out("EVENT third explosive added")
		end
		watch_batches()
		if t == 1700 or t == 2200 or t == 2500 or t == 3500 then
			local valid = {}
			for index, entity in ipairs(T.marked) do
				valid[index] = entity.valid and "valid" or "gone"
			end
			out("EVENT t=" .. t .. " marked " .. table.concat(valid, " ") .. ", chest explosives " .. T.chest.get_inventory(defines.inventory.chest).get_item_count("cliff-explosives"))
		end
		if t == 4500 or t == 8500 then
			out("EVENT t=" .. t .. " marked left " .. count_valid(T.mine) .. "/" .. #T.mine)
		end
	end,
}

-- The only car is parked in its garage when a roboport ghost (network mode, the last
-- phase) is selected: it must come out and build it. retry_pending_clusters used to
-- scan the phases 1 to 3 only, so the car stayed in the garage (EVENT lines).
scenarios["network-parked"] = {
	ticks = 12000,
	category = "construction",
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, names.charger, 0, 0)
		T.garage = make(s, names.garage, 30, 0)
		T.chest = make(s, names.chest, 0.5, 30.5)
		fill(T.chest, {["roboport"] = 2})
		T.cars = {make_car(s, -20, -20, 0)}
		T.surface = s
		make_ghost(s, "roboport", 80, 40)
	end,
	events = function(t)
		if t == 2900 then
			out("EVENT car parked: " .. tostring(garage_control.has_parked_car(T.garage)))
		end
		if t == 3000 then
			select_all(70, 30, 90, 50)
		end
		watch_batches()
		if t == 6000 or t == 11500 then
			out("EVENT roboports built at " .. t .. ": " .. #T.surface.find_entities_filtered{name = "roboport"})
		end
	end,
}

-- ============================================================
-- Doors: walls with gates (category "doors")
-- ============================================================
-- Every course has a car, a supply chest and a ghost, as the obstacle courses above, and
-- the car has to get through a gate to reach them. The walls of one column of courses
-- join into a single wall 600 tiles long: the way round is far, the gate is the way.
-- Lines DONE <course> <tick> of the trace give the tick each course had its ghosts built.

-- Gates are 1 tile wide; an opening of 3 tiles is three gates side by side ("wide").
-- An opening of 1 tile is too small for a car (owner's decision, 2026-10-11, see
-- "Problèmes connus" in CLAUDE.md): the scenarios build only 3-tile openings unless
-- this is true, which brings back the 1-tile variants for a new try.
local ONE_TILE_DOORS = false
local door_widths = ONE_TILE_DOORS and {false, true} or {true}
local function make_gate(s, tx, ty, direction, force)
	local gate = s.create_entity{name = "gate", position = {tx + 0.5, ty + 0.5},
		direction = direction or defines.direction.east, force = force or "player"}
	if not gate then
		out("SETUP gate NOT created at " .. tx .. "," .. ty)
	end
	return gate
end

-- Replaces the wall at tile (tx, ty) by a gate.
local function wall_to_gate(s, tx, ty, direction, force)
	for _, wall in pairs(s.find_entities_filtered{name = "stone-wall", position = {tx + 0.5, ty + 0.5}, radius = 0.4}) do
		wall.destroy()
	end
	return make_gate(s, tx, ty, direction, force)
end

-- A door at row ty of a wall that runs north-south in column tx, crossed from west to east.
local function door_ns(s, tx, ty, wide, force)
	ty = ty + math.floor(jitter((config.test_door_shift or 0) + 0.5) + 0.5)
	wide = wide or not ONE_TILE_DOORS
	for dy = wide and -1 or 0, wide and 1 or 0 do
		wall_to_gate(s, tx, ty + dy, defines.direction.east, force)
	end
end

-- A door at column tx of a wall that runs east-west in row ty.
local function door_ew(s, tx, ty, wide, force)
	tx = tx + math.floor(jitter((config.test_door_shift or 0) + 0.5) + 0.5)
	wide = wide or not ONE_TILE_DOORS
	for dx = wide and -1 or 0, wide and 1 or 0 do
		wall_to_gate(s, tx + dx, ty, defines.direction.north, force)
	end
end

-- Puts up to `count` entities at random places of a box, none within `clear` tiles (on both axes)
-- of the point (kx, ky). `size` is 2 for a furnace (placed on a tile corner), 1 otherwise.
local function scatter_entities(s, name, size, count, x1, y1, x2, y2, kx, ky, clear)
	local made, tries = 0, 0
	while made < count and tries < count * 30 do
		tries = tries + 1
		local x, y = x1 + random() * (x2 - x1), y1 + random() * (y2 - y1)
		if not (math.abs(x - kx) < clear and math.abs(y - ky) < clear) then
			local shift = size == 2 and 0 or 0.5
			if s.create_entity{name = name, position = {math.floor(x) + shift, math.floor(y) + shift}, force = "player"} then
				made = made + 1
			end
		end
	end
end

-- Trees removed around a point.
local function clear_trees(s, x, y, radius)
	for _, tree in pairs(s.find_entities_filtered{type = "tree", position = {x, y}, radius = radius}) do
		tree.destroy()
	end
end

-- The wall of a course: 100 tiles, joined to the walls of the courses above and below.
local function course_wall(s, cx, cy, offset_x)
	wall_line(s, cx + offset_x, cy - 50, cx + offset_x, cy + 49)
end

-- A wall 40 tiles east of the car, a gate `offset` tiles off the line to the chest.
local function wall_course(offset, wide)
	return {
		obstacles = function(s, cx, cy)
			course_wall(s, cx, cy, 40)
			door_ns(s, cx + 40, cy + offset, wide)
		end,
		car = {0, 0, 0.25}, chest = {90, 0},
	}
end

-- The car in a walled room of 24 x 24 tiles whose only exit is a gate in the east wall.
local function room_course(offset, orientation, wide)
	return {
		obstacles = function(s, cx, cy)
			wall_line(s, cx - 12, cy - 12, cx + 12, cy - 12)
			wall_line(s, cx - 12, cy + 12, cx + 12, cy + 12)
			wall_line(s, cx - 12, cy - 11, cx - 12, cy + 11)
			wall_line(s, cx + 12, cy - 11, cx + 12, cy + 11)
			door_ns(s, cx + 12, cy + offset, wide)
		end,
		car = {0, 0, orientation}, chest = {90, 0},
	}
end

-- Crossing walls through gates, 24 courses (four columns of six); 13-24 repeat 1-12 with
-- an opening of three gates side by side (the 3 tiles advised to the player) instead of one.
--  1-6   a straight wall 40 tiles east of the car, with the gate at 0, 3, -3, 8, -8 and 15
--        tiles off the line to the chest; the car faces the wall
--  7-12  the car in a walled room of 24 x 24 tiles whose only exit is the gate in the east
--        wall (at 0, 0, 0, 0, 8 and -8 tiles off the centre), starting facing east, west,
--        north, south, west and east: the exit is behind or beside the car in half of them
scenarios["gates"] = {
	ticks = 9000,
	category = "doors",
	setup = function()
		T.grid = true
		local courses = {}
		for _, wide in ipairs(door_widths) do
			for _, offset in ipairs{0, 3, -3, 8, -8, 15} do
				courses[#courses + 1] = wall_course(offset, wide)
			end
			for _, room in ipairs{{0, 0.25}, {0, 0.75}, {0, 0}, {0, 0.5}, {8, 0.75}, {-8, 0.25}} do
				courses[#courses + 1] = room_course(room[1], room[2], wide)
			end
		end
		build_courses(courses)
	end,
	events = select_courses,
}

-- A wall with a gate on the straight way between a supply chest and a ghost, and no other way:
-- the wall is 600 tiles long. The car can only build the ghost if it gets through the gate.
-- The car has no can_open_gates: movement.open_gates asks the gate to open as it approaches.
scenarios["gate"] = {
	ticks = 9000,
	category = "doors",
	setup = function()
		local s = new_surface({{0, 0}}, 14)
		make(s, names.charger, 0, 0)
		make(s, names.garage, 20, -10)
		T.chest = make(s, names.chest, 0.5, 30.5)
		fill(T.chest, {["wooden-chest"] = 20})
		make_car(s, -20, -20, 0)
		wall_line(s, 60, -300, 60, 299)
		door_ns(s, 60, 38) -- 3 tiles wide, see ONE_TILE_DOORS
		out("SETUP gate")
		make_ghost(s, "wooden-chest", 80.5, 40.5)
	end,
	events = function(t)
		if t == 100 then
			select_ghosts(70, 30, 90, 50)
		end
		if t > 100 and t % 100 == 0 and not T.done and #T.surface.find_entities_filtered{type = "entity-ghost", area = {{70, 30}, {90, 50}}} == 0 then
			T.done = t
			out("DONE 1 " .. t)
		end
	end,
}

-- Things standing about near the gate: scattered buildings, poles, a sparse forest, a dense patch
-- of trees 4 tiles past the gate or 1.5 tiles past it ("patch-near": the car has to turn at once, along
-- the wall), two rows of furnaces, a bit of everything.
-- Courses 1-7, then the same seven with a 3-tile opening (8-14), the gate off the line to the chest
-- by 0, 6, -6, 3, -3, 9 and -9 tiles.
local function clutter_course(kind, offset, wide)
	return {
		obstacles = function(s, cx, cy)
			course_wall(s, cx, cy, 40)
			door_ns(s, cx + 40, cy + offset, wide)
			local gx, gy = cx + 40.5, cy + offset + 0.5
			if kind == "furnaces" then
				scatter_entities(s, "stone-furnace", 2, 8, gx - 20, gy - 20, gx - 2, gy + 20, gx, gy, 3)
				scatter_entities(s, "stone-furnace", 2, 8, gx + 2, gy - 20, gx + 20, gy + 20, gx, gy, 3)
			elseif kind == "poles" then
				scatter_entities(s, "small-electric-pole", 1, 16, gx - 12, gy - 12, gx - 1, gy + 12, gx, gy, 2)
				scatter_entities(s, "small-electric-pole", 1, 16, gx + 1, gy - 12, gx + 12, gy + 12, gx, gy, 2)
			elseif kind == "trees" then
				plant(s, gx - 18, gy - 18, gx + 18, gy + 18, 5)
				clear_trees(s, gx, gy, 3)
			elseif kind == "patch" then
				plant(s, gx + 4, gy - 4, gx + 11, gy + 4, 1.6)
			elseif kind == "patch-near" then
				plant(s, gx + 1.5, gy - 4, gx + 8.5, gy + 4, 1.6)
			elseif kind == "rows" then
				for y = gy - 16, gy + 16, 4 do
					if math.abs(y - gy) > 2.5 then
						s.create_entity{name = "stone-furnace", position = {gx - 8, math.floor(y)}, force = "player"}
						s.create_entity{name = "stone-furnace", position = {gx + 8, math.floor(y)}, force = "player"}
					end
				end
			else -- mixed
				scatter_entities(s, "wooden-chest", 1, 6, gx - 15, gy - 15, gx + 15, gy + 15, gx, gy, 2.5)
				scatter_entities(s, "small-electric-pole", 1, 10, gx - 15, gy - 15, gx + 15, gy + 15, gx, gy, 2.5)
				plant(s, gx - 15, gy - 15, gx + 15, gy + 15, 6)
				clear_trees(s, gx, gy, 3)
			end
		end,
		car = {0, 0, 0.25}, chest = {90, 0},
	}
end

scenarios["doors-clutter"] = {
	ticks = 9000,
	category = "doors",
	setup = function()
		T.grid = true
		local courses = {}
		for _, wide in ipairs(door_widths) do
			for index, kind in ipairs{"furnaces", "poles", "trees", "patch", "patch-near", "rows", "mixed"} do
				courses[#courses + 1] = clutter_course(kind, ({0, 6, -6, 3, -3, 9, -9})[index], wide)
			end
		end
		build_courses(courses)
	end,
	events = select_courses,
}

-- Several cars through the same gate, one after the other and in both directions. Each car has
-- a ghost of its own, more than a cluster radius from the others (so each is a batch of its
-- own), 12 tiles apart along the wall; the cars start 2.5 tiles apart, all facing east.
--  1-2  4 and 8 cars, one gate    3-4  4 and 8 cars, three gates
--  5-6  4 cars on each side of the wall, each side with its own ghosts and its supply chest on
--       the other side, so that the cars cross in both directions: one gate, three gates
local function traffic_course(count, wide, both_ways)
	local cars, ghosts, chests = {}, {}, {{90, 0}}
	for i = 1, count do
		cars[#cars + 1] = {0, (i - (count + 1) / 2) * 2.5, 0.25}
		ghosts[#ghosts + 1] = {95, (i - (count + 1) / 2) * 12}
	end
	if both_ways then
		for i = 1, count do
			cars[#cars + 1] = {80, (i - (count + 1) / 2) * 2.5, 0.75}
			ghosts[#ghosts + 1] = {-15, (i - (count + 1) / 2) * 12}
		end
		chests = {{90, 0}, {-30, 0}}
	end
	return {
		obstacles = function(s, cx, cy)
			course_wall(s, cx, cy, 40)
			door_ns(s, cx + 40, cy, wide)
		end,
		cars = cars, chests = chests, ghosts = ghosts,
	}
end

-- Several walls one behind the other, each with a 3-tile gate ("Portes qui se suivent" in
-- CLAUDE.md). A scenario of its own for each case (a car takes any ghost of its surface), named
-- series-<walls>w-sp<tiles between walls>-<f|b><a|s>: the car crosses from the west (f) or from the
-- east (b), through gates in line (a) or alternately 0, 4, -4, 4, -4 tiles off the line (s). The
-- walls are inside a closed box, so the only way is through the gates.
local function series_course(count, spacing, back, staggered)
	local offsets = staggered and {0, 4, -4, 4, -4} or {0, 0, 0, 0, 0}
	local last = 40 + (count - 1) * spacing
	local course = {
		obstacles = function(s, cx, cy)
			wall_line(s, cx - 30, cy - 50, cx + last + 70, cy - 50)
			wall_line(s, cx - 30, cy + 50, cx + last + 70, cy + 50)
			wall_line(s, cx - 30, cy - 49, cx - 30, cy + 49)
			wall_line(s, cx + last + 70, cy - 49, cx + last + 70, cy + 49)
			for i = 1, count do
				local x = 40 + (i - 1) * spacing
				course_wall(s, cx, cy, x)
				door_ns(s, cx + x, cy + offsets[i])
			end
		end,
	}
	if back then
		course.car = {last + 40, 0, 0.75}
		course.chest = {-10, 0}
	else
		course.car = {0, 0, 0.25}
		course.chest = {last + 50, 0}
	end
	return course
end

local function series_scenario(count, spacing, back, staggered)
	return function()
		T.origin = {60, 0}
		build_courses({series_course(count, spacing, back, staggered)}, 4)
	end
end

scenarios["series-5w-sp3-fa"] = {
	ticks = 6000,
	category = "doors",
	setup = series_scenario(5, 3, false, false),
	events = select_courses,
}

scenarios["series-5w-sp3-ba"] = {
	ticks = 6000,
	category = "doors",
	setup = series_scenario(5, 3, true, false),
	events = select_courses,
}

scenarios["series-5w-sp3-fs"] = {
	ticks = 6000,
	category = "doors",
	setup = series_scenario(5, 3, false, true),
	events = select_courses,
}

scenarios["series-5w-sp3-bs"] = {
	ticks = 6000,
	category = "doors",
	setup = series_scenario(5, 3, true, true),
	events = select_courses,
}

scenarios["series-5w-sp6-fa"] = {
	ticks = 6000,
	category = "doors",
	setup = series_scenario(5, 6, false, false),
	events = select_courses,
}

scenarios["series-5w-sp6-ba"] = {
	ticks = 6000,
	category = "doors",
	setup = series_scenario(5, 6, true, false),
	events = select_courses,
}

scenarios["series-5w-sp6-fs"] = {
	ticks = 6000,
	category = "doors",
	setup = series_scenario(5, 6, false, true),
	events = select_courses,
}

scenarios["series-5w-sp6-bs"] = {
	ticks = 6000,
	category = "doors",
	setup = series_scenario(5, 6, true, true),
	events = select_courses,
}

scenarios["series-3w-sp10-fs"] = {
	ticks = 6000,
	category = "doors",
	setup = series_scenario(3, 10, false, true),
	events = select_courses,
}

scenarios["series-3w-sp10-bs"] = {
	ticks = 6000,
	category = "doors",
	setup = series_scenario(3, 10, true, true),
	events = select_courses,
}

scenarios["series-5w-sp10-fs"] = {
	ticks = 6000,
	category = "doors",
	setup = series_scenario(5, 10, false, true),
	events = select_courses,
}

scenarios["series-5w-sp10-bs"] = {
	ticks = 6000,
	category = "doors",
	setup = series_scenario(5, 10, true, true),
	events = select_courses,
}

scenarios["series-3w-sp15-fs"] = {
	ticks = 6000,
	category = "doors",
	setup = series_scenario(3, 15, false, true),
	events = select_courses,
}

scenarios["series-3w-sp15-bs"] = {
	ticks = 6000,
	category = "doors",
	setup = series_scenario(3, 15, true, true),
	events = select_courses,
}

scenarios["doors-traffic"] = {
	ticks = 12000,
	category = "doors",
	setup = function()
		T.grid = true
		local courses = {
			traffic_course(4, true), traffic_course(8, true), traffic_course(4, true, true),
		}
		if ONE_TILE_DOORS then
			table.insert(courses, traffic_course(4, false))
			table.insert(courses, traffic_course(8, false))
			table.insert(courses, traffic_course(4, false, true))
		end
		build_courses(courses)
	end,
	events = select_courses,
}

-- A walled base of 80 x 48 tiles split in two rooms by a wall with a door, with doors to the
-- outside west, east and north. Supply chest, garage and charger in different places, the car
-- inside or outside, a few buildings about (not many). `spec`:
--   wide    all doors 3 tiles wide, otherwise 1 tile
--   cars, chests, ghosts   as courses (from the corner of the course: x 0 is the west wall,
--           x 80 the east wall, y 0 the middle)
--   garage, charger        {dx, dy}
--   buildings   number of furnaces, chests and poles scattered inside
local function base_course(spec)
	return {
		obstacles = function(s, cx, cy)
			wall_line(s, cx, cy - 24, cx + 80, cy - 24)
			wall_line(s, cx, cy + 24, cx + 80, cy + 24)
			wall_line(s, cx, cy - 23, cx, cy + 23)
			wall_line(s, cx + 80, cy - 23, cx + 80, cy + 23)
			wall_line(s, cx + 40, cy - 23, cx + 40, cy + 23)
			door_ns(s, cx, cy - 8, spec.wide or not ONE_TILE_DOORS)
			door_ns(s, cx + 80, cy + 10, spec.wide or not ONE_TILE_DOORS)
			door_ns(s, cx + 40, cy + 2, spec.wide or not ONE_TILE_DOORS)
			door_ew(s, cx + 20, cy - 24, spec.wide or not ONE_TILE_DOORS)
			if spec.buildings then
				scatter_entities(s, "stone-furnace", 2, spec.buildings, cx + 3, cy - 21, cx + 77, cy + 21, cx + 40, cy + 2, 3)
				scatter_entities(s, "wooden-chest", 1, spec.buildings, cx + 3, cy - 21, cx + 77, cy + 21, cx + 40, cy + 2, 3)
				scatter_entities(s, "small-electric-pole", 1, spec.buildings, cx + 3, cy - 21, cx + 77, cy + 21, cx + 40, cy + 2, 3)
			end
			if spec.garage then
				make(s, names.garage, cx + spec.garage[1], cy + spec.garage[2])
			end
			if spec.charger then
				make(s, names.charger, cx + spec.charger[1], cy + spec.charger[2])
			end
		end,
		cars = spec.cars, chests = spec.chests, ghosts = spec.ghosts,
	}
end

-- One base per scenario (a car may go anywhere on its surface, so bases would take each other's work):
--  1-2  car and garage in the west room, chest and charger in the east room, ghost outside east
--       (3-tile doors, then 1-tile doors)
--  3    car outside west, chest in the east room, ghost in the west room (1-tile doors)
--  4    a car nearly out of charge in the east room, the charger in the west room (3-tile doors)
--  5    1-tile doors, four buildings of each kind about, a car at 40 % charge, ghost north outside
--  6    two cars (one at 30 % charge), two ghosts (north and south outside), 3-tile doors, buildings
local base_specs = {
	{wide = true, cars = {{10, 5, 0.25}}, chests = {{60, -10}}, garage = {10, -15}, charger = {70, 15}, ghosts = {{95, 0}}},
	{wide = false, cars = {{10, 5, 0.25}}, chests = {{60, -10}}, garage = {10, -15}, charger = {70, 15}, ghosts = {{95, 0}}},
	{wide = false, cars = {{-15, 0, 0.25}}, chests = {{65, 0}}, garage = {-12, 14}, charger = {-10, -12}, ghosts = {{15, 10}}},
	{wide = true, cars = {{60, 0, 0.75, 0.12}}, chests = {{8, 0}}, charger = {8, -12}, ghosts = {{95, 10}}},
	{wide = false, cars = {{10, 0, 0.25, 0.4}}, chests = {{65, -8}}, garage = {10, 18}, charger = {30, -15}, ghosts = {{20, -40}},
		buildings = 4},
	{wide = true, cars = {{10, 5, 0.25}, {65, 5, 0.75, 0.3}}, chests = {{60, -10}, {15, 10}}, garage = {10, -18}, charger = {70, 15},
		ghosts = {{20, -40}, {60, 40}}, buildings = 4},
}

scenarios["doors-base-1"] = {
	ticks = 9000,
	category = "doors",
	setup = function()
		build_courses{base_course(base_specs[1])}
	end,
	events = select_courses,
}

scenarios["doors-base-2"] = {
	ticks = 9000,
	category = "doors",
	setup = function()
		build_courses{base_course(base_specs[2])}
	end,
	events = select_courses,
}

scenarios["doors-base-3"] = {
	ticks = 9000,
	category = "doors",
	setup = function()
		build_courses{base_course(base_specs[3])}
	end,
	events = select_courses,
}

scenarios["doors-base-4"] = {
	ticks = 9000,
	category = "doors",
	setup = function()
		build_courses{base_course(base_specs[4])}
	end,
	events = select_courses,
}

scenarios["doors-base-5"] = {
	ticks = 9000,
	category = "doors",
	setup = function()
		build_courses{base_course(base_specs[5])}
	end,
	events = select_courses,
}

scenarios["doors-base-6"] = {
	ticks = 9000,
	category = "doors",
	setup = function()
		build_courses{base_course(base_specs[6])}
	end,
	events = select_courses,
}

-- Rare situations at a door.
--  1    a gate two tiles from the corner of a room
--  2-3  two walls 6 tiles apart, a gate in each, 8 tiles off one another: 1 tile, then 3 tiles
--       (the walls are 600 tiles long: the 40-tile wall of every course is joined to the others)
--  4    a chest right against the exit of a 1-tile gate: no way out, nothing to build (EXPECTED NOT BUILT)
--  5    the same chest in front of the middle one of three gates: the side gates are free
--  6    a corridor of 3 tiles, 30 long, ends at the gate
--  7-8  the car 4 tiles from the gate, facing away from it: 1 tile, then 3 tiles
--  9    the nearest gate belongs to the enemy force (it never opens), a gate of the player 30 tiles off
--  10   the car 2 tiles from the wall, facing along it, the gate behind it
--  11   two gates 3 tiles apart
--  12-13  the gate 40 tiles off the line to the chest, along the wall: 1 tile, then 3 tiles
--  14   a lane 5 tiles wide and 20 long between two rows of furnaces, ending at a gate 3 tiles wide
local function odd_course(kind)
	local course = {car = {0, 0, 0.25}, chest = {90, 0}}
	course.obstacles = function(s, cx, cy)
		if kind == "corner" then
			wall_line(s, cx - 12, cy - 12, cx + 12, cy - 12)
			wall_line(s, cx - 12, cy + 12, cx + 12, cy + 12)
			wall_line(s, cx - 12, cy - 11, cx - 12, cy + 11)
			wall_line(s, cx + 12, cy - 11, cx + 12, cy + 11)
			door_ns(s, cx + 12, cy + 9, false)
		elseif kind == "airlock" or kind == "airlock-wide" then
			course_wall(s, cx, cy, 34)
			course_wall(s, cx, cy, 40)
			door_ns(s, cx + 34, cy, kind == "airlock-wide")
			door_ns(s, cx + 40, cy + 8, kind == "airlock-wide")
		elseif kind == "blocked" or kind == "blocked-side" then
			course_wall(s, cx, cy, 40)
			door_ns(s, cx + 40, cy, kind == "blocked-side")
			make(s, "wooden-chest", cx + 41.5, cy + 0.5)
		elseif kind == "corridor" then
			course_wall(s, cx, cy, 40)
			wall_line(s, cx + 10, cy - 2, cx + 39, cy - 2)
			wall_line(s, cx + 10, cy + 2, cx + 39, cy + 2)
			door_ns(s, cx + 40, cy, false)
		elseif kind == "behind" or kind == "behind-wide" then
			course_wall(s, cx, cy, 40)
			door_ns(s, cx + 40, cy, kind == "behind-wide")
			course.car = {36, 0, 0.75}
		elseif kind == "enemy" then
			course_wall(s, cx, cy, 40)
			door_ns(s, cx + 40, cy, false, "enemy")
			door_ns(s, cx + 40, cy + 30, false)
		elseif kind == "alongside" then
			course_wall(s, cx, cy, 40)
			door_ns(s, cx + 40, cy + 10, false)
			course.car = {37.8, 0, 0}
		elseif kind == "far" or kind == "far-wide" then
			course_wall(s, cx, cy, 40)
			door_ns(s, cx + 40, cy + 40, kind == "far-wide")
		elseif kind == "lane" then
			course_wall(s, cx, cy, 40)
			door_ns(s, cx + 40, cy, true)
			for x = cx + 20, cx + 38, 2 do
				make(s, "stone-furnace", x + 1, cy - 3)
				make(s, "stone-furnace", x + 1, cy + 3)
			end
		else -- "double"
			course_wall(s, cx, cy, 40)
			door_ns(s, cx + 40, cy, false)
			door_ns(s, cx + 40, cy + 3, false)
		end
	end
	return course
end

scenarios["doors-odd"] = {
	ticks = 9000,
	category = "doors",
	setup = function()
		T.grid = true
		local courses = {}
		for _, kind in ipairs{"corner", "airlock", "airlock-wide", "blocked", "blocked-side", "corridor", "behind", "behind-wide",
			"enemy", "alongside", "double", "far", "far-wide", "lane"} do
			if ONE_TILE_DOORS or kind == "airlock-wide" or not (kind == "airlock" or kind == "behind" or kind == "far") then
				courses[#courses + 1] = odd_course(kind)
			end
		end
		build_courses(courses)
		for _, x in ipairs{100, 300, 500} do -- the wall of every course joined into one, without a way round
			wall_line(T.surface, x, -300, x, 299)
		end
	end,
	events = select_courses,
}

-- Does a gate open by itself for a car? It does not (the control for the gate
-- scenario, which the mod solves with open_gates). An untracked car (the mod does
-- not drive it) is driven straight at a gate by the scenario itself, once with
-- the gate on a wall and once without any gate, for comparison. Lines GATE-TEST
-- give its x position every 10 ticks, for 400 ticks: the wall is at x = 20.5.
-- A base in a plain, as in the owner's game (2026-10-11): a walled box 100 x 70 tiles with doors
-- 4 tiles wide in three of its four walls (the west wall has none): near the north-west corner,
-- in the middle of the east wall and near the south-east corner. Eight cars start 150 to 190
-- tiles away all round, facing the base, and have to get to the chests and ghosts inside.
-- Lines INSIDE <car> <tick> give the tick each car first stood in the base, DONE 1 <tick> the
-- tick all the ghosts were built.
local function door4_ns(s, tx, ty)
	for dy = -2, 1 do
		wall_to_gate(s, tx, ty + dy, defines.direction.east)
	end
end

local function door4_ew(s, tx, ty)
	for dx = -2, 1 do
		wall_to_gate(s, tx + dx, ty, defines.direction.north)
	end
end

local plain_base_course = {
	obstacles = function(s, cx, cy)
		wall_line(s, cx - 50, cy - 35, cx + 50, cy - 35)
		wall_line(s, cx - 50, cy + 35, cx + 50, cy + 35)
		wall_line(s, cx - 50, cy - 34, cx - 50, cy + 34)
		wall_line(s, cx + 50, cy - 34, cx + 50, cy + 34)
		door4_ew(s, cx - 40, cy - 35)
		door4_ns(s, cx + 50, cy)
		door4_ew(s, cx + 40, cy + 35)
		make(s, names.charger, cx - 5, cy - 28)
		make(s, names.garage, cx + 25, cy - 28)
	end,
	cars = {
		{-150, 0, 0.25}, {150, 0, 0.75}, {0, -150, 0.5}, {0, 150, 0},
		{-120, -110, 0.375}, {120, 110, 0.875}, {-120, 110, 0.125}, {120, -110, 0.625},
	},
	chests = {{-10, -10}, {10, 10}, {-30, 20}, {30, -20}},
	ghosts = {{0, 0}, {20, -15}, {-25, 15}, {35, 20}, {-35, -15}, {15, 25}},
}

scenarios["plain-base"] = {
	ticks = 9000,
	category = "doors",
	setup = function()
		build_courses({plain_base_course}, 15)
		T.inside = {}
	end,
	events = function(t)
		select_courses(t)
		if t % 30 == 0 then
			local cx, cy = course_origin(1)
			for _, car in pairs(storage.cars) do
				if car.valid and car.surface == T.surface and not T.inside[car.unit_number]
					and math.abs(car.position.x - cx) < 48 and math.abs(car.position.y - cy) < 33 then
					T.inside[car.unit_number] = t
					out("INSIDE " .. car.unit_number .. " " .. t)
				end
			end
		end
	end,
}

-- Fuel use against distance (see "Carburant" in CLAUDE.md): six lanes, one car each, a supply
-- chest 25, 50, 100, 200, 400 and 800 tiles away in a straight line, and a ghost next to it. The
-- fuel the car burns on the way is in the trace (7th column). `kind` sets the ground
-- between: open, scattered trees, or a field of furnaces (a built zone) before the chest.
local RANGE_LENGTHS = {25, 50, 100, 200, 400, 800}

local function build_range(kind)
	local centres = {}
	for x = 0, 900, 100 do
		centres[#centres + 1] = {x, 0}
	end
	local s = new_surface(centres, 4)
	T.range = {}
	for lane, length in ipairs(RANGE_LENGTHS) do
		local y = -50 + 20 * (lane - 1)
		local x0, x1 = 10, 10 + length
		make(s, names.charger, x0 - 6, y)
		make(s, names.charger, x1 + 8, y)
		make_car(s, x0, y, 0.25, 1)
		fill(make(s, names.chest, x1 + 0.5, y + 0.5), {["wooden-chest"] = 20})
		make_ghost(s, "wooden-chest", x1 + 4.5, y + 3.5)
		if kind == "trees" and length > 40 then
			plant(s, x0 + 15, y - 6, x1 - 15, y + 6, 8)
		elseif kind == "built" and length > 40 then
			build_factory(s, x1 - 30, y - 6, x1 - 10, y + 6, 4)
		end
		T.range[lane] = {x = x1 + 4.5, y = y + 3.5}
	end
end

local function select_range(t)
	if t == 100 then
		for _, g in pairs(T.range) do
			select_ghosts(g.x - 2, g.y - 2, g.x + 2, g.y + 2)
		end
	end
	if t > 100 and t % 100 == 0 then
		T.done = T.done or {}
		for lane, g in pairs(T.range) do
			if not T.done[lane] and #T.surface.find_entities_filtered{type = "entity-ghost", area = {{g.x - 1, g.y - 1}, {g.x + 1, g.y + 1}}} == 0 then
				T.done[lane] = t
				out("DONE " .. RANGE_LENGTHS[lane] .. " " .. t)
			end
		end
	end
end

scenarios["range-open"] = {
	ticks = 16000,
	category = "energy",
	setup = function()
		build_range("open")
	end,
	events = select_range,
}

scenarios["range-trees"] = {
	ticks = 16000,
	category = "energy",
	setup = function()
		build_range("trees")
	end,
	events = select_range,
}

scenarios["range-built"] = {
	ticks = 16000,
	category = "energy",
	setup = function()
		build_range("built")
	end,
	events = select_range,
}

-- Long fuel runs: four lanes of 1000, 1500, 2000 and 2500 tiles over one kind of ground, set by
-- -Set "test_tiles=<n>": 0 grass-1 (friction 1.6), 1 sand-1 (1.8), 2 dirt-1 (1.4), 3 stone-path
-- (1.1), 4 concrete (0.8), 5 a mix changing every 100 tiles. Run with -Set "fuel_estimate.near_per_tile=100" so
-- that the car does not detour for a charger: only what it burns is measured. -Set "test_long=1"
-- makes the lanes 5000, 8000 and 11000 tiles long (the fourth is a copy of the third).
local LONG_LENGTHS = {1000, 1500, 2000, 2500}
local LONG_TILES = {[0] = "grass-1", "sand-1", "dirt-1", "stone-path", "concrete"}
local LONG_MIX = {"sand-1", "grass-1", "concrete", "dirt-1", "stone-path"}

local function build_long()
	if config.test_long == 1 then
		LONG_LENGTHS[1], LONG_LENGTHS[2], LONG_LENGTHS[3], LONG_LENGTHS[4] = 5000, 8000, 11000, 11000
	end
	local centres = {}
	for x = 0, math.max(LONG_LENGTHS[3], LONG_LENGTHS[4]) + 400, 280 do
		centres[#centres + 1] = {x, 0}
	end
	local s = new_surface(centres, 4)
	local kind = config.test_tiles or 0
	T.range = {}
	for lane, length in ipairs(LONG_LENGTHS) do
		local y = -60 + 40 * (lane - 1)
		local x0, x1 = 10, 10 + length
		local tiles = {}
		for x = x0 - 8, x1 + 12 do
			local name = kind == 5 and LONG_MIX[math.floor((x - x0) / 100) % #LONG_MIX + 1] or LONG_TILES[kind]
			if name ~= "grass-1" then
				for dy = -6, 6 do
					tiles[#tiles + 1] = {name = name, position = {x, y + dy}}
				end
			end
		end
		s.set_tiles(tiles, false)
		make(s, names.charger, x0 - 6, y)
		make(s, names.charger, x1 + 8, y)
		make_car(s, x0, y, 0.25, 1)
		fill(make(s, names.chest, x1 + 0.5, y + 0.5), {["wooden-chest"] = 20})
		make_ghost(s, "wooden-chest", x1 + 4.5, y + 3.5)
		T.range[lane] = {x = x1 + 4.5, y = y + 3.5}
	end
end

scenarios["range-long"] = {
	ticks = 70000,
	category = "energy",
	setup = build_long,
	events = function(t)
		if t == 100 then
			for _, g in pairs(T.range) do
				select_ghosts(g.x - 2, g.y - 2, g.x + 2, g.y + 2)
			end
		end
		if t > 100 and t % 100 == 0 then
			T.done = T.done or {}
			for lane, g in pairs(T.range) do
				if not T.done[lane] and #T.surface.find_entities_filtered{type = "entity-ghost", area = {{g.x - 1, g.y - 1}, {g.x + 1, g.y + 1}}} == 0 then
					T.done[lane] = t
					out("DONE " .. LONG_LENGTHS[lane] .. " " .. t)
				end
			end
		end
	end,
}

scenarios["gate-manual"] = {
	ticks = 600,
	category = "movement",
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
				car = s.create_entity{name = names.car, position = {14, y}, force = "player"}
				car.orientation = 0.25
				_utils.set_fuel_item(car)
				_utils.set_fuel(car, _utils.get_fuel_capacity(car))
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

-- A garage in a small walled room, ringed by furnaces so close that no free spot is left within 3 tiles of its
-- centre, with a 3-tile door: three idle cars outside, at different distances, have to park in it. The
-- pathfinder must reach the garage itself (the goal is its centre).
scenarios["garage-room"] = {
	ticks = 4000,
	category = "doors",
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, names.charger, 0, 0)
		wall_line(s, 100, -10, 114, -10)
		wall_line(s, 100, 4, 114, 4)
		wall_line(s, 100, -9, 100, 3)
		wall_line(s, 114, -9, 114, 3)
		door_ew(s, 107, 4, true)
		make(s, names.garage, 107, -3)
		for _, offset in ipairs{{-4, -3}, {4, -3}, {0, -7}, {-4, 1}, {4, 1}} do
			make(s, "stone-furnace", 107 + offset[1], -3 + offset[2])
		end
		make_car(s, 107, 20, 0.5)
		make_car(s, 95, 12, 0.25)
		make_car(s, 125, 8, 0.75)
	end,
}

local function trace_cars(tick)
	-- A car found in no state by update_car: where it came from is in the trace just before.
	while (T.fallbacks_reported or 0) < #storage.idle_fallbacks do
		T.fallbacks_reported = (T.fallbacks_reported or 0) + 1
		local fallback = storage.idle_fallbacks[T.fallbacks_reported]
		if T.surfaces[fallback.surface] then
			out(string.format("EVENT NOSTATE car %d had no state at tick %d", fallback.car, fallback.tick))
		end
	end
	for id, car in pairs(storage.cars) do
		if car.valid and T.surfaces[car.surface.index] then
			local car_data = storage.car_data[id]
			local flags = ""
			for _, name in ipairs(FLAG_NAMES) do
				local flag = car_data[name]
				if name == "fast" or name == "slow" then
					flag = car_data.mode == name
				end
				if type(flag) == "table" then
					flag = flag.active
				end
				flags = flags .. (flag and "1" or "0")
			end

			-- A new path: its waypoints, to see where the car was sent (PATH line).
			local path = car_data.path
			if path.active and T.paths_seen[id] ~= path.waypoints then
				T.paths_seen[id] = path.waypoints
				local points = {}
				for _, w in ipairs(path.waypoints) do
					table.insert(points, string.format("%.1f,%.1f%s", w.x, w.y, w.axis_x and "G" or ""))
				end
				local destination = car_data.moving.destination
				destination = destination and destination.valid and destination.position
				out(string.format("PATH %d car %d goal=%s n=%d %s from=%.1f,%.1f to=%s", tick, id,
					path.goal and string.format("%.1f,%.1f", path.goal.x, path.goal.y) or "-", #points, table.concat(points, " "),
					car.position.x, car.position.y, destination and string.format("%.1f,%.1f", destination.x, destination.y) or "-"))
			end

			local health = car.health
			if T.health_seen[id] and health < T.health_seen[id] then
				out(string.format("HEALTH %d car %d %.1f -> %.1f speed=%.3f", tick, id, T.health_seen[id], health, car.speed))
			end
			T.health_seen[id] = health

			local brake = car_data.emergency_brake
			if brake.active and T.brakes_seen[id] ~= brake.since then
				T.brakes_seen[id] = brake.since
				out(string.format("EMERG %d car %d cause=%s path=%d speed=%.3f", tick, id, brake.cause or "-", path.active and 1 or 0, car.speed))
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
			local clusters = construction and #construction.clusters or 0
			if T.clusters[id] ~= clusters then
				T.clusters[id] = clusters
				out(string.format("BATCH %d car %d clusters=%d ghosts=%d", tick, id, clusters,
					construction and table_size(construction.ghosts) or 0))
			end
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
	local cars, parked, ghosts, pending = 0, 0, 0, 0
	for _, car in pairs(storage.cars) do
		if car.valid and T.surfaces[car.surface.index] then
			cars = cars + 1
		end
	end
	for _, garage in pairs(storage.garages) do
		if garage.valid and T.surfaces[garage.surface.index] then
			parked = parked + #storage.garage_data[garage.unit_number].cars
		end
	end
	for _, cluster in pairs(storage.pending_clusters) do
		local ghost = cluster.ghosts[1]
		if ghost and ghost.valid and T.surfaces[ghost.surface.index] then
			pending = pending + 1
		end
	end
	local users = {}
	for _, charger in pairs(T.chargers) do
		if charger.valid then
			table.insert(users, storage.charger_data[charger.unit_number].users)
		end
	end
	local built_counts = {}
	for _, name in ipairs(BUILT_NAMES) do
		built_counts[name] = 0
	end
	for index in pairs(T.surfaces) do
		local surface = game.get_surface(index)
		ghosts = ghosts + surface.count_entities_filtered{type = "entity-ghost"}
		for _, name in ipairs(BUILT_NAMES) do
			built_counts[name] = built_counts[name] + surface.count_entities_filtered{name = name}
		end
	end
	local built = {}
	for _, name in ipairs(BUILT_NAMES) do
		table.insert(built, name .. "=" .. built_counts[name])
	end
	out(string.format("SUMMARY %d cars=%d parked=%d ghosts=%d pending=%d charger_users=%s built: %s",
		tick, cars, parked, ghosts, pending, table.concat(users, ","), table.concat(built, " ")))
end

-- ============================================================
-- Coverage
-- ============================================================
-- Every module function is wrapped in a call counter.

local call_counts = {}
for module_name, module in pairs{
	movement = movement, travel = travel, charger_control = charger_control,
	garage_control = garage_control, ghost_control = ghost_control,
	_utils = _utils, ["_utils.deque"] = _utils.deque, gui = gui, garage_gui = garage_gui, car_gui = car_gui,
	circuit_control = circuit_control, logistic_control = logistic_control,
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

local running = {} -- the scenarios of this run, in the order given
for name in string.gmatch(SCENARIOS, "[^,]+") do
	if not scenarios[name] then
		error("unknown test scenario: " .. name)
	end
	table.insert(running, name)
end

script.on_nth_tick(1, function(event)
	local tick = event.tick

	if not T or not T.start_tick then
		-- The mod creates its storage on its first tick (see init_storage).
		if storage.cars then
			-- Full trunks (40 slots) for every scenario; "technologies" uses another force.
			-- The values of the first version of the mod: 40 cargo slots, 50 cars per garage,
			-- 4 cars per charger, charge and build speed 1, free garage repair (here with packs).
			-- -Set "test_research=<0, 1 or 2>": every improvement researched to that level instead
			-- (0: none, repair included).
			local force = game.forces.player
			if config.test_research then
				for key in pairs(config.upgrades) do
					for level = 1, config.test_research do
						research(force, names.technology .. "_" .. key .. "_" .. level)
					end
				end
				if config.test_research > 0 then
					research(force, names.repair_technology)
				end
			else
				for _, name in ipairs{"cargo_1", "cargo_2", "garage_1", "garage_2", "chargers_1", "charge_speed_1", "build_speed_1"} do
					research(force, names.technology .. "_" .. name)
				end
				research(force, names.repair_technology)
			end
			for _, name in ipairs(running) do
				use(name)
				seed = 12345 -- the same obstacles whatever the other scenarios of the run
				scenarios[name].setup()
				T.start_tick = tick
				out("SETUP " .. name .. " at tick " .. tick)
			end
		end
		return
	end

	for _, name in ipairs(running) do
		use(name)
		local t = tick - T.start_tick
		if t <= (TICKS or scenarios[name].ticks or 22000) then
			if t % 30 == 0 then
				-- Chargers are not wired to any power: keep their buffer full.
				for _, charger in pairs(T.chargers) do
					if charger.valid then
						charger.energy = 6e7
					end
				end
			end
			if scenarios[name].events then
				scenarios[name].events(t)
			end

			if tick % 10 == 0 then
				trace_cars(tick)
			end
			if tick % 300 == 0 then
				trace_summary(tick)
			end
		end
	end
	if tick % 500 == 0 then
		write_coverage()
	end
end)
