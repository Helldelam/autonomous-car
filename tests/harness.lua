
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

local FLAG_NAMES = {"moving", "charging", "parking", "building", "stuck", "waiting", "empty", "maneuver", "emergency_brake", "high_speed", "precision_mode", "slowing", "path"}
local BUILT_NAMES = {"wooden-chest", "stone-furnace", "small-electric-pole", "steel-chest", "car"}

local T -- state of the scenario being run (see `use`): set before any of its code runs
local states = {}
local scenarios = {}

-- Makes `name` the current scenario: its code reads and writes T.
local function use(name)
	if not states[name] then
		states[name] = {name = name, chargers = {}, clusters = {}, surfaces = {}}
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

-- `fuel_ratio` overrides the charge a new car starts with.
local function make_car(surface, x, y, orientation, fuel_ratio)
	local car = make(surface, names.car, x, y)
	car.orientation = orientation
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
-- (chargers and garages). This file is the only list of scenarios: run.ps1 reads
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
		if t == 6500 then
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
		make_ghost(s, "wooden-chest", 80.5, 40.5)
		T.wall = s.create_entity{name = "stone-wall", position = {80.5, -40.5}, force = "player"}
		make_ghost(s, "stone-furnace", 81, -41)
	end,
	events = function(t)
		local inventory = T.chest.get_inventory(defines.inventory.chest)
		if t == 3900 or t == 7900 then
			local stack = T.garage.get_inventory(defines.inventory.chest).find_item_stack(names.car)
			if stack then
				out(string.format("EVENT parked car health %.3f at %d", stack.health, t))
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
-- ended in a script error in charge.lua).
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
local function course_origin(index)
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

-- `course`: {obstacles = function(s, cx, cy), car = {dx, dy, orientation}, chest = {dx, dy}};
-- the ghost is by default 4 tiles east and 3 south of the chest (`ghost = {dx, dy}`).
local function build_courses(courses, chunks)
	local s = new_surface({{0, 0}}, chunks or 11)
	make(s, names.charger, 0, 0)
	T.courses = courses
	for index, course in ipairs(courses) do
		local cx, cy = course_origin(index)
		course.obstacles(s, cx, cy)
		make_car(s, cx + course.car[1], cy + course.car[2], course.car[3], 1)
		local chest_x, chest_y = cx + course.chest[1] + 0.5, cy + course.chest[2] + 0.5
		fill(make(s, names.chest, chest_x, chest_y), {["wooden-chest"] = 20})
		local ghost = course.ghost or {4, 3}
		make_ghost(s, "wooden-chest", chest_x + ghost[1], chest_y + ghost[2])
	end
end

local function select_courses(t)
	if t == 100 then
		for index, course in ipairs(T.courses) do
			local cx, cy = course_origin(index)
			local ghost = course.ghost or {4, 3}
			local x, y = cx + course.chest[1] + 0.5 + ghost[1], cy + course.chest[2] + 0.5 + ghost[2]
			select_ghosts(x - 2, y - 2, x + 2, y + 2)
		end
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

-- Trees between the car and its chest, 60 tiles of forest to cross; three cars start
-- before it, three inside it. Three densities.
scenarios["forest"] = {
	ticks = 9000,
	category = "movement",
	setup = function()
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
		build_courses{forest(3, false), forest(3, true), forest(2, false), forest(2, true), forest(1.5, false), forest(1.5, true)}
	end,
	events = select_courses,
}

-- Cars that have just driven into the edge of a forest: a few tiles in, boxed in by trees
-- on all sides but a small clearing. Three go on across the forest (facing in, or
-- turned away), three have their supply chest behind them, outside.
scenarios["forest-edge"] = {
	ticks = 9000,
	category = "movement",
	setup = function()
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
		build_courses{edge(3, 2, 0.25, false), edge(2, 2, 0.25, false), edge(1.5, 2, 0.25, false),
			edge(2, 2, 0.25, true), edge(1.5, 5, 0.25, false), edge(1.5, 2, 0.75, true)}
	end,
	events = select_courses,
}

-- The same deeper in the forest (4 to 12 tiles) and at more realistic densities, facing
-- the forest, sideways to it, or turned away.
scenarios["forest-depth"] = {
	ticks = 9000,
	category = "movement",
	setup = function()
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
		build_courses{edge(2, 4, 0, false), edge(2, 8, 0.25, false), edge(2, 8, 0.75, true),
			edge(2.5, 8, 0.25, false), edge(3, 12, 0.25, false), edge(2, 12, 0.75, true)}
	end,
	events = select_courses,
}

-- A copse of 30 x 30 tiles on the straight way between the car and its chest, with open
-- ground all around: the car should go round it rather than into it. Three densities,
-- facing the copse or turned away.
scenarios["copse"] = {
	ticks = 9000,
	category = "movement",
	setup = function()
		local function copse(spacing, orientation)
			return {
				obstacles = function(s, cx, cy) plant(s, cx + 30, cy - 15, cx + 60, cy + 15, spacing) end,
				car = {0, 0, orientation}, chest = {90, 0},
			}
		end
		build_courses{copse(3, 0.25), copse(3, 0.75), copse(2, 0.25), copse(2, 0.75), copse(1.5, 0.25), copse(1.5, 0.75)}
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

-- A car with a completely empty battery: it does nothing and alerts the player
-- (flag `empty`, alert battery_empty) and is not given the ghost selected at
-- t = 200. Its battery is refilled at t = 3000: it should resume and build it.
scenarios["empty-battery"] = {
	ticks = 8000,
	category = "robustness",
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, names.charger, 0, 0)
		make(s, names.garage, 20, -10)
		T.chest = make(s, names.chest, 0.5, 30.5)
		fill(T.chest, {["wooden-chest"] = 20})
		T.car = make_car(s, 5, 10, 0, 0)
		make_ghost(s, "wooden-chest", 40.5, 40.5)
	end,
	events = function(t)
		if t == 200 then
			select_ghosts(35, 35, 45, 45)
		end
		if t == 3000 then
			_utils.set_fuel(T.car, _utils.get_fuel_capacity(T.car) * 0.5)
			out("EVENT battery refilled")
		end
	end,
}

-- Two idle cars side by side, one at 14 % charge with the only charger 800 tiles away
-- (under its critical level, out of reach), one full. A ghost is selected at t = 200:
-- the full car must get the batch, the low one none (EVENT lines at t = 1500).
scenarios["critical-no-batch"] = {
	ticks = 2000,
	category = "energy",
	setup = function()
		local s = new_surface({{0, 0}, {800, 0}}, 3)
		make(s, names.charger, 800, 0)
		T.chest = make(s, names.chest, 0.5, 20.5)
		fill(T.chest, {["wooden-chest"] = 20})
		T.low = make_car(s, 5, 0, 0, 0.14)
		T.full = make_car(s, 5, 6, 0, 1)
		make_ghost(s, "wooden-chest", 30.5, 30.5)
	end,
	events = function(t)
		if t == 200 then
			select_ghosts(25, 25, 35, 35)
		end
		if t == 1500 then
			out("EVENT low car " .. (storage.car_data[T.low.unit_number].construction and "GOT a batch (wrong)" or "has no batch (expected)"))
			out("EVENT full car " .. (storage.car_data[T.full.unit_number].construction and "has a batch (expected)" or "has no batch (batch already built or lost)"))
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
			if ghost.type == "entity-ghost" then
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

-- Marked trees, rocks and buildings (with contents) far from any robot network:
-- the car mines them all and unloads the yield in the supply chest. Setup lines
-- tell whether trees and rocks have a unit_number.
scenarios["deconstruct"] = {
	ticks = 9000,
	category = "construction",
	setup = function()
		T.marked = {}
		local s = new_surface({{0, 0}}, 6)
		make(s, names.charger, 0, 0)
		make(s, names.garage, 20, -10)
		T.chest = make(s, names.chest, 0.5, 30.5)
		T.cars = {make_car(s, 10, 10, 0.1)}
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
	end,
	events = function(t)
		if t == 200 then
			select_all(50, 50, 100, 100)
		end
		watch_batches()
		if t == 8500 then
			report_supply("end")
		end
	end,
}

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
	out("SETUP " .. name .. " -> " .. target .. " ordered=" .. tostring(ordered) .. " marked=" .. tostring(entity.to_be_upgraded()))
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

local function report_upgrade(label)
	local replaced = 0
	for _, entity in pairs(T.marked) do
		if not entity.valid then
			replaced = replaced + 1
		end
	end
	local function count(name)
		return #T.surface.find_entities_filtered{name = name, force = "player"}
	end
	local modules_in_machines = 0
	for _, machine in pairs(T.surface.find_entities_filtered{name = "assembling-machine-2"}) do
		modules_in_machines = modules_in_machines + machine.get_module_inventory().get_item_count("speed-module-3")
	end
	out("EVENT " .. label .. ": " .. replaced .. "/" .. #T.marked .. " replaced; iron-chest=" .. count("iron-chest")
		.. " wooden-chest=" .. count("wooden-chest") .. " steel-chest=" .. count("steel-chest")
		.. " assembling-machine-2=" .. count("assembling-machine-2") .. " assembling-machine-3=" .. count("assembling-machine-3")
		.. "; iron-plate in the world=" .. count_item_everywhere("iron-plate") .. " (3720 at the start)"
		.. ", speed-module-3 in the world=" .. count_item_everywhere("speed-module-3") .. " (8 at the start), in the machines=" .. modules_in_machines)
end

-- Entities marked for upgrade, far from any robot network: wooden chests to iron
-- chests, a full steel chest to a smaller iron chest (the overflow must end in the
-- trunk, then in the supply chest), assembling machines 3 holding four speed
-- modules to machines 2 (two slots). Nothing may be lost: the plates and modules
-- of the world are counted at the end.
scenarios["upgrade"] = {
	ticks = 9000,
	category = "construction",
	setup = function()
		T.marked = {}
		local s = new_surface({{0, 0}}, 6)
		make(s, names.charger, 0, 0)
		make(s, names.garage, 20, -10)
		T.chest = make(s, names.chest, 0.5, 30.5)
		fill(T.chest, {["iron-chest"] = 10, ["assembling-machine-2"] = 5})
		T.cars = {make_car(s, 10, 10, 0.1)}
		for i = 0, 3 do
			mark_upgrade(s, "wooden-chest", "iron-chest", 60.5 + 2 * i, 60.5, {name = "iron-plate", count = 30})
		end
		mark_upgrade(s, "steel-chest", "iron-chest", 60.5, 70.5, {name = "iron-plate", count = 3600})
		for i = 0, 1 do
			mark_upgrade(s, "assembling-machine-3", "assembling-machine-2", 61.5 + 4 * i, 80.5, nil, {name = "speed-module-3", count = 4})
		end
		out("EVENT start: plates=" .. count_item_everywhere("iron-plate") .. " modules=" .. count_item_everywhere("speed-module-3"))
	end,
	events = function(t)
		if t == 200 then
			select_all(50, 50, 100, 100)
		end
		watch_batches()
		if t == 8500 then
			report_upgrade("end")
		end
	end,
}

-- Builds the world of the mixed scenarios: ghosts to build and entities to mine,
-- `overlap` or not. Apart: wooden chests on the east side, marked trees on the
-- west side, 120 tiles from each other. Overlapping: stone furnace ghosts on
-- marked wooden chests, and wooden chest ghosts on marked trees.
local function build_mixed(car_count, overlap)
	T.marked = {}
	T.ghosts = {}
	local s = new_surface({{0, 0}}, 6)
	make(s, names.charger, 0, 0)
	make(s, names.charger, 0, 60)
	make(s, names.garage, 20, -10)
	T.chest = make(s, names.chest, 0.5, 30.5)
	fill(T.chest, {["wooden-chest"] = 40, ["stone-furnace"] = 20})
	T.cars = {}
	for index = 1, car_count do
		T.cars[index] = make_car(s, 10 + 6 * index, 10, 0.1)
	end
	if overlap then
		for i = 0, 5 do
			mark(s, "wooden-chest", 60.5 + 4 * i, 60.5, {name = "iron-plate", count = 10})
			T.ghosts[#T.ghosts + 1] = make_ghost(s, "stone-furnace", 61 + 4 * i, 61)
		end
		for i = 0, 3 do
			mark(s, "tree-01", 60.5 + 4 * i, 80.5)
			T.ghosts[#T.ghosts + 1] = make_ghost(s, "wooden-chest", 60.5 + 4 * i, 80.5)
		end
		-- More to mine, 120 tiles away: the car that takes the marked entities stays busy
		-- there while the other one tries the ghosts, which are still covered.
		for i = 0, 9 do
			mark(s, "tree-01", -60 - 3 * i, 60)
		end
	else
		for i = 0, 7 do
			T.ghosts[#T.ghosts + 1] = make_ghost(s, "wooden-chest", 60.5 + 2 * i, 60.5)
		end
		for i = 0, 5 do
			mark(s, "tree-01", -60 - 3 * i, 60)
		end
	end
end

local function report_mixed(label)
	out("EVENT " .. label .. ": " .. count_valid(T.ghosts) .. "/" .. #T.ghosts .. " ghosts left, "
		.. count_valid(T.marked) .. "/" .. #T.marked .. " marked entities left")
end

-- Ghosts and marked entities selected together, far apart, one car then two:
-- a batch never mixes both (EVENT lines say MIXED if it does), and everything
-- gets done, one mode after the other when there is a single car.
scenarios["mixed-apart-single"] = {
	ticks = 14000,
	category = "construction",
	setup = function()
		build_mixed(1, false)
	end,
	events = function(t)
		if t == 200 then
			select_all(-100, 40, 100, 80)
		end
		watch_batches()
		if t == 13500 then
			report_mixed("end")
		end
	end,
}

scenarios["mixed-apart"] = {
	ticks = 14000,
	category = "construction",
	setup = function()
		build_mixed(2, false)
	end,
	events = function(t)
		if t == 200 then
			select_all(-100, 40, 100, 80)
		end
		watch_batches()
		if t == 13500 then
			report_mixed("end")
		end
	end,
}

-- Ghosts on top of the entities that must go first (furnaces over marked
-- chests, chests over marked trees), two cars. Without an ordering rule the
-- ghosts fail to revive until the cars have mined what is in the way, then go
-- through the retry cycle (alert, back to the pending pool).
scenarios["mixed-overlap"] = {
	ticks = 16000,
	category = "construction",
	setup = function()
		build_mixed(2, true)
	end,
	events = function(t)
		if t == 200 then
			select_all(-100, 50, 100, 100)
		end
		watch_batches()
		if t == 3000 or t == 8000 then
			report_mixed("t=" .. t)
		end
		if t == 15500 then
			report_mixed("end")
		end
	end,
}

-- A wall with a gate on the straight way between a supply chest and a ghost: the
-- car can only build the ghost if it gets through the gate. The car has no
-- can_open_gates: movement.open_gates asks the gate to open as it approaches.
scenarios["gate"] = {
	ticks = 4000,
	category = "movement",
	setup = function()
		local s = new_surface({{0, 0}}, 10)
		make(s, names.charger, 0, 0)
		make(s, names.garage, 20, -10)
		T.chest = make(s, names.chest, 0.5, 30.5)
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

-- Does a gate open by itself for a car? It does not (the control for the gate
-- scenario, which the mod solves with open_gates). An untracked car (the mod does
-- not drive it) is driven straight at a gate by the scenario itself, once with
-- the gate on a wall and once without any gate, for comparison. Lines GATE-TEST
-- give its x position every 10 ticks, for 400 ticks: the wall is at x = 20.5.
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
			parked = parked + garage.get_inventory(defines.inventory.chest).get_item_count(names.car)
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
	_utils = _utils, ["_utils.deque"] = _utils.deque, gui = gui,
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
