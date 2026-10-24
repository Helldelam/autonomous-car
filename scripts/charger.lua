local util = require("util")
local config = require("config")
local _utils = require("scripts._utils")

-- Chargers: fuel estimates, the charger a car can reach, charging; posts and arcs drawn around them.
local charger_control = {}

-- High estimate for `distance` tiles in a straight line (config.fuel_estimate).
local function compute_fuel_for_distance(distance)
	local estimate = config.fuel_estimate
	local near = math.min(distance, estimate.near_distance)
	return estimate.fixed + near * estimate.near_per_tile + (distance - near) * estimate.far_per_tile
end

function charger_control.compute_fuel_to_reach(car, position)
	return compute_fuel_for_distance(util.distance(car.position, position))
end

-- Fuel to keep on arrival: the way to the closest charger (free places ignored) plus the critical level.
function charger_control.compute_fuel_reserve(car, position)
	local reserve = config.critical_fuel_ratio * _utils.get_fuel_capacity(car)
	local charger = _utils.find_closest("chargers", position, nil, "charger", car.surface)
	if charger then
		reserve = reserve + compute_fuel_for_distance(util.distance(position, charger.position))
	end
	return reserve
end

-- The way there plus the reserve: a trip never ends out of reach of a charger.
function charger_control.compute_fuel_needed(car, position)
	return charger_control.compute_fuel_to_reach(car, position) + charger_control.compute_fuel_reserve(car, position)
end

-- Closest charger to `target_position` (default: the car) with a free place, within reach
-- (batteries included); nil if none.
function charger_control.find_charger(car, target_position)
	local remaining_fuel = _utils.get_reachable_fuel(car)
	return _utils.find_closest("chargers", target_position or car.position, function(charger, id)
		return storage.charger_data[id].users < _utils.get_upgrade(charger.force, "chargers")
			and remaining_fuel >= charger_control.compute_fuel_to_reach(car, charger.position)
	end, "charger", car.surface)
end

-- Buffer: a full tank per place, plus half a tank.
function charger_control.update_buffer(charger)
	local size = (_utils.get_upgrade(charger.force, "chargers") + 0.5) * prototypes.item[config.names.fuel].fuel_value
	if charger.electric_buffer_size ~= size then
		charger.electric_buffer_size = size
	end
end

-- Every long_delay per charger: buffer and posts follow the research.
function charger_control.update_buffers(tick)
	for id, charger in pairs(storage.chargers) do
		if charger.valid then
			if _utils.is_slow_check_due(charger, tick, config.long_delay) then
				charger_control.update_buffer(charger)
				charger_control.update_posts(charger)
			end
		else
			_utils.release_entity("charger", id)
		end
	end
end

-- Every tick while charging; full: frees the place and starts the next task.
function charger_control.charging_tick(car, charger)
	local car_data = storage.car_data[car.unit_number]

	if not (charger and charger.valid) then
		car_data.charging.active = false
		car_data.charging.charger = nil
		_utils.start_waiting(car_data)
		return
	end

	local transfer = _utils.get_fuel_capacity(car) / config.full_charge_duration * _utils.get_upgrade(car.force, "charge_speed")
	if charger.energy > transfer then
		_utils.set_fuel(car, _utils.get_fuel(car) + transfer)
		charger.energy = charger.energy - transfer
		storage.charger_data[charger.unit_number].transferred = storage.charger_data[charger.unit_number].transferred + transfer -- power signal (circuit.lua)
	end

	if _utils.get_fuel_ratio(car) >= 1 then
		local charger_data = storage.charger_data[charger.unit_number]
		charger_data.users = charger_data.users - 1
		car_data.charging.active = false
		car_data.charging.charger = nil
		_utils.raise_next_task(car)
	end
end

function charger_control.alert_no_charger(car)
	_utils.alert_once(storage.car_data[car.unit_number].alerts, "no_charger", car.force, car,
		{"autonomous-car-messages.alert-no-charger"},
		config.names.car)
end

-- ============================================================
-- Posts and arcs
-- ============================================================
-- One post per place (2, 4, 8 with the research), drawn when built and when the places change; an
-- arc on the post of each charging car, every short_delay. charger_data.posts = {post, shadow,
-- support} in the order of config.charger_visual.posts; storage.charger_arcs[car id] = {charger_id, slot, object}.

local visual = config.charger_visual

-- Past the first layout, the posts split.
local function get_layout(count)
	return count > #visual.posts and visual.split_posts or visual.posts
end

local function destroy_post(post)
	post.post.destroy()
	post.shadow.destroy()
	if post.support then
		post.support.destroy()
	end
end

local function remove_post(posts)
	destroy_post(table.remove(posts))
end

function charger_control.update_posts(charger)
	local posts = storage.charger_data[charger.unit_number].posts
	local count = math.min(_utils.get_upgrade(charger.force, "chargers"), #visual.split_posts)
	local layout = get_layout(count)
	if get_layout(#posts) ~= layout then -- the posts split (or merge): all redrawn
		while #posts > 0 do
			remove_post(posts)
		end
	end
	while #posts < count do
		local place = layout[#posts + 1]
		local post = rendering.draw_sprite{
			sprite = config.names.charger_post,
			target = {x = charger.position.x + place.x, y = charger.position.y + place.y - visual.post_height / 2},
			surface = charger.surface,
			render_layer = "higher-object-under",
		}
		local shadow = rendering.draw_sprite{
			sprite = config.names.charger_post_shadow,
			target = {x = charger.position.x + place.x + visual.shadow.x, y = charger.position.y + place.y + visual.shadow.y},
			surface = charger.surface,
			render_layer = "object",
		}
		-- 8 places: a support per corner (first four slots), the top left sprite mirrored
		local support
		if layout == visual.split_posts and #posts < #visual.posts then
			local corner = visual.posts[#posts + 1]
			local side_x, side_y = corner.x < 0 and -1 or 1, corner.y < -0.5 and -1 or 1
			support = rendering.draw_sprite{
				sprite = config.names.charger_support .. (side_y < 0 and "_t" or "_b") .. (side_x < 0 and "l" or "r"),
				target = {x = charger.position.x + corner.x + side_x * visual.support.x, y = charger.position.y + corner.y + side_y * visual.support.y},
				surface = charger.surface,
				render_layer = "cargo-hatch", -- above the body, under the posts
			}
		end
		posts[#posts + 1] = {post = post, shadow = shadow, support = support}
	end
	while #posts > count do
		remove_post(posts)
	end
end

-- The arcs of a charger that is gone end in refresh_arcs.
function charger_control.release_posts(charger_data)
	for _, post in pairs(charger_data.posts) do
		destroy_post(post)
	end
end

local function end_arc(car_id)
	storage.charger_arcs[car_id].object.destroy()
	storage.charger_arcs[car_id] = nil
end

-- Every short_delay: ends the arcs of the cars no longer charging, starts one on the first free
-- post for each charging car.
function charger_control.refresh_arcs(tick)
	if tick % config.short_delay ~= 0 then
		return
	end

	local used = {} -- [charger id][slot] = true
	for car_id, arc in pairs(storage.charger_arcs) do
		local car_data = storage.car_data[car_id]
		local charger = storage.chargers[arc.charger_id]
		if car_data and car_data.charging.active and charger and charger.valid
			and car_data.charging.charger == charger and arc.slot <= #storage.charger_data[arc.charger_id].posts then
			used[arc.charger_id] = used[arc.charger_id] or {}
			used[arc.charger_id][arc.slot] = true
		else
			end_arc(car_id)
		end
	end

	for car_id in pairs(storage.cars) do
		local charging = storage.car_data[car_id].charging
		local charger = charging.active and charging.charger
		if charger and charger.valid and not storage.charger_arcs[car_id] then
			local id = charger.unit_number
			local taken = used[id] or {}
			used[id] = taken
			for slot = 1, #storage.charger_data[id].posts do
				if not taken[slot] then
					taken[slot] = true
					local place = get_layout(#storage.charger_data[id].posts)[slot]
					storage.charger_arcs[car_id] = {charger_id = id, slot = slot, object = rendering.draw_animation{
						animation = config.names.charger_arc,
						target = {x = charger.position.x + place.x, y = charger.position.y + place.y - visual.tip},
						surface = charger.surface,
						render_layer = "higher-object-above",
					}}
					break
				end
			end
		end
	end
end

return charger_control
