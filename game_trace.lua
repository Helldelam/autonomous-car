local config = require("config")
local util = require("util")

-- Trace of the cars written from a real game, to analyse a behaviour seen there
-- (console command /car-trace). Lines go to script-output/autonomous-car-trace.txt in the
-- Factorio user folder: a sample of each moving car every SAMPLE_INTERVAL ticks, and an
-- EVENT line whenever one of its flags changes. It only reads the state in storage.
local game_trace = {}

local FILE = "autonomous-car-trace.txt"
local SAMPLE_INTERVAL = config.short_delay / 2
local WATCHED = { -- flags whose change is an event: name = function(car_data) returning a printable value
	moving = function(data) return data.moving.active end,
	mode = function(data) return data.mode end,
	maneuver = function(data) return data.maneuver.active end,
	clearing = function(data) return data.maneuver.clearing end,
	path = function(data) return data.path.active end,
	pending = function(data) return data.path.pending end,
	result = function(data) return data.path.result end, -- answer of the pathfinder: found or none
	goal = function(data) return data.path.goal and string.format("%.1f,%.1f", data.path.goal.x, data.path.goal.y) end,
	u_turn = function(data) return data.path.u_turn ~= nil end,
	brake = function(data) return data.emergency_brake.active end,
	stuck = function(data) return data.stuck.active end,
	requests = function(data) return data.path.count end,
	guided = function(data) return data.path.guided_count end,
}

local function write(line)
	helpers.write_file(FILE, line .. "\n", true)
end

-- Starts or stops the trace; `car_id` (a unit number) restricts it to one car.
function game_trace.toggle(player, car_id)
	if storage.game_trace and not car_id then
		storage.game_trace = nil
		player.print("Car trace off (" .. FILE .. " in script-output).")
		return
	end
	storage.game_trace = {car_id = car_id, last = {}}
	write("TRACE start tick " .. game.tick .. (car_id and (" car " .. car_id) or " all cars"))
	player.print("Car trace on: " .. FILE .. " in script-output of the Factorio user folder.")
end

local function describe_target(car, car_data)
	local path = car_data.path
	local waypoint = path.active and path.waypoints and path.waypoints[path.index]
	if not waypoint then
		return "-"
	end
	return string.format("%d/%d(%.1f,%.1f)d%.1f%s", path.index, #path.waypoints, waypoint.x, waypoint.y,
		util.distance(car.position, waypoint), waypoint.axis_x and "G" or "")
end

-- Called every tick for each car, after it has been updated.
function game_trace.record(car, car_data, tick)
	local trace = storage.game_trace
	if not trace or (trace.car_id and trace.car_id ~= car.unit_number) then
		return
	end
	local id = car.unit_number
	local last = trace.last[id]
	local first = not last -- the first look at a car only records its flags
	if first then
		last = {}
		trace.last[id] = last
	end
	for name, read in pairs(WATCHED) do
		local value = read(car_data)
		if last[name] ~= value then
			if not first then
				write(string.format("EVENT %d car %d %s %s -> %s", tick, id, name, tostring(last[name]), tostring(value)))
			end
			last[name] = value
		end
	end

	if not car_data.moving.active or (tick + id) % SAMPLE_INTERVAL ~= 0 then
		return
	end
	local destination = car_data.moving.destination
	local info = car_data.trace_info or {}
	write(string.format(
		"%d car %d pos %.1f,%.1f ori %.3f spd %.3f mode %s dest %s %.1f,%.1f d %.1f wp %s near_built %s line_clear %s zone %s dens %s open %s",
		tick, id, car.position.x, car.position.y, car.orientation, car.speed, tostring(car_data.mode),
		destination.name or "waypoint", destination.position.x, destination.position.y, util.distance(car.position, destination.position),
		describe_target(car, car_data), tostring(car_data.near_built), tostring(car_data.line_clear),
		tostring(info.in_zone), info.density and string.format("%.3f", info.density) or "-", tostring(info.way_open)))
end

return game_trace
