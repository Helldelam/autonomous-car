local config = require("config")
local util = require("util")

-- Debug drawing: for each player who has it on, the cars under the cursor or in
-- the opened window show where they go (destination, path), what they are doing
-- (mode, flags) and what their steering weighs. It only reads the state in storage
-- and draws; every drawing outlives its refresh by one tick, so none is kept.
local debug_view = {}

local COLORS = {
	destination = {r = 1, g = 0.85, b = 0.1},
	path = {r = 0.2, g = 0.9, b = 0.3},
	corridor = {r = 0.2, g = 0.6, b = 0.3, a = 0.5},
	waypoint = {r = 1, g = 1, b = 1},
	text = {r = 1, g = 1, b = 1},
}
local LIFETIME = config.slow_check_interval + 1
local TEXT_OFFSET = 2 -- tiles above the car

local function is_enabled(player)
	local setting = storage.debug_view and storage.debug_view[player.index]
	if setting == nil then
		return config.debug_view_default
	end
	return setting
end

-- The car of a tracked entity, or nil.
local function get_car(entity)
	if type(entity) == "userdata" and entity.object_name == "LuaEntity" and entity.valid and entity.name == config.names.car then
		return entity
	end
end

-- The ids of the active tick states of a car, then its other flags, as one line.
local STATES = {"moving", "charging", "parking", "building", "stuck", "waiting", "empty"}
local function describe_flags(car_data)
	local flags = {}
	for _, name in ipairs(STATES) do
		if car_data[name].active then
			flags[#flags + 1] = name
		end
	end
	local maneuver, path = car_data.maneuver, car_data.path
	if maneuver.active then
		flags[#flags + 1] = "maneuver:" .. (maneuver.clearing and "clearing" or maneuver.reason or "?")
	end
	if car_data.emergency_brake.active then
		flags[#flags + 1] = "brake:" .. (car_data.emergency_brake.cause or "?")
	end
	if path.pending then
		flags[#flags + 1] = "path pending"
	elseif path.active then
		flags[#flags + 1] = string.format("path %d/%d", path.index, #path.waypoints)
	end
	if car_data.near_built then
		flags[#flags + 1] = car_data.line_clear and "built (line clear)" or "built"
	end
	return table.concat(flags, " ")
end

local function describe_steering(steering)
	if not steering then
		return ""
	end
	return string.format("S %.2f (d %.2f)  R %.2f (d %.2f)  L %.2f (d %.2f)",
		steering.straight, steering.straight_density, steering.right, steering.right_density, steering.left, steering.left_density)
end

local function draw_car(player, car, car_data)
	local surface, players = car.surface, {player}
	local position = car.position

	local function draw_line(from, to, color, width, gap)
		rendering.draw_line{
			color = color, width = width, from = from, to = to, surface = surface, players = players,
			time_to_live = LIFETIME, gap_length = gap, dash_length = gap,
		}
	end
	local function draw_circle(center, radius, color, width)
		rendering.draw_circle{
			color = color, radius = radius, width = width, target = center, surface = surface, players = players,
			time_to_live = LIFETIME,
		}
	end

	local distance
	local destination = car_data.moving.active and car_data.moving.destination
	if destination and destination.valid then
		local target = destination.position
		distance = util.distance(position, target)
		draw_line(position, target, COLORS.destination, 2, 0.4)
		draw_circle(target, config.arrival_distance, COLORS.destination, 2)
	end

	local path = car_data.path
	if path.active and path.waypoints then
		local from = position
		for index = path.index, #path.waypoints do
			local waypoint = path.waypoints[index]
			draw_line(from, waypoint, COLORS.path, 3)
			draw_circle(waypoint, index == path.index and 0.8 or 0.3, COLORS.waypoint, 2)
			from = waypoint
		end

		-- The corridor around the followed segment (see steering_cost.path_deviation).
		local start = path.waypoints[path.index - 1] or path.origin
		local target = path.waypoints[path.index]
		local length = util.distance(start, target)
		if start and length > 1 then
			local px, py = -(target.y - start.y) / length * config.path.corridor, (target.x - start.x) / length * config.path.corridor
			for _, side in ipairs{1, -1} do
				draw_line({start.x + px * side, start.y + py * side}, {target.x + px * side, target.y + py * side}, COLORS.corridor, 1, 0.5)
			end
		end
	end

	rendering.draw_text{
		text = string.format("#%d  %s  v %.3f%s\n%s\n%s", car.unit_number, car_data.mode, car.speed,
			distance and string.format("  d %.1f", distance) or "", describe_flags(car_data), describe_steering(car_data.steering)),
		surface = surface, target = {position.x, position.y - TEXT_OFFSET}, color = COLORS.text, players = players,
		time_to_live = LIFETIME, alignment = "center", scale = 0.8,
	}
end

-- Called every config.slow_check_interval ticks.
function debug_view.refresh()
	for _, player in pairs(game.connected_players) do
		if is_enabled(player) then
			local selected, opened = get_car(player.selected), get_car(player.opened)
			if opened == selected then
				opened = nil -- one drawing for a car that is both
			end
			for _, car in pairs{selected, opened} do
				local car_data = storage.car_data[car.unit_number]
				if car_data then
					draw_car(player, car, car_data)
				end
			end
		end
	end
end

-- Shows or hides the drawing for a player, and moves the shortcut with it.
function debug_view.toggle(player)
	local enabled = not is_enabled(player)
	storage.debug_view = storage.debug_view or {}
	storage.debug_view[player.index] = enabled
	player.set_shortcut_toggled(config.names.debug_view_shortcut, enabled)
end

-- Puts the shortcut of a player (or of all) in the state the player has, or the default.
function debug_view.sync_shortcut(player)
	player.set_shortcut_toggled(config.names.debug_view_shortcut, is_enabled(player))
end

function debug_view.sync_shortcuts()
	for _, player in pairs(game.players) do
		debug_view.sync_shortcut(player)
	end
end

return debug_view
