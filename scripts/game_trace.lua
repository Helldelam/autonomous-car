local config = require("config")
local util = require("util")

-- /car-trace, off by default: script-output/autonomous-car-trace.txt, on the machine of whoever ran it
-- (the server for its console), gets a sample of each moving car every SAMPLE_INTERVAL ticks and an
-- EVENT line when a flag changes. Read only.
local game_trace = {}

local FILE = "autonomous-car-trace.txt"
local SAMPLE_INTERVAL = config.short_delay / 2
local WATCHED = { -- name = function(car_data) returning a printable value
	moving = function(data) return data.moving.active end,
	mode = function(data) return data.mode end,
	maneuver = function(data) return data.maneuver.active end,
	clearing = function(data) return data.maneuver.clearing end,
	path = function(data) return data.path.active end,
	pending = function(data) return data.path.pending end,
	result = function(data) return data.path.result end, -- found or none
	goal = function(data) return data.path.goal and string.format("%.1f,%.1f", data.path.goal.x, data.path.goal.y) end,
	u_turn = function(data) return data.path.u_turn ~= nil end,
	brake = function(data) return data.emergency_brake.active end,
	stuck = function(data) return data.stuck.active end,
	requests = function(data) return data.path.count end,
	guided = function(data) return data.path.guided_count end,
}

local function write(line)
	helpers.write_file(FILE, line .. "\n", true, storage.game_trace.player_index)
end

-- `car_id`: one car only; `player`: nil from the server console.
function game_trace.toggle(player, car_id)
	local message
	if storage.game_trace and not car_id then
		storage.game_trace = nil
		message = {"autonomous-car-messages.trace-off", FILE}
	else
		storage.game_trace = {car_id = car_id, last = {}, player_index = player and player.index or 0} -- 0: the server
		write("TRACE start tick " .. game.tick .. (car_id and (" car " .. car_id) or " all cars"))
		message = {"autonomous-car-messages.trace-on", FILE}
	end
	if player then
		player.print(message)
	else
		log(message)
	end
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

-- Every tick per car, after its update.
function game_trace.record(car, car_data, tick)
	local trace = storage.game_trace
	if not trace or (trace.car_id and trace.car_id ~= car.unit_number) then
		return
	end
	local id = car.unit_number
	local last = trace.last[id]
	local first = not last -- only records the flags
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
