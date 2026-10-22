local config = require("config")
local _utils = require("scripts._utils")
local names = config.names

-- What shows around a charger: a post for every place it has (2, 4 or 8 with the research), and an
-- arc at the tip of the post a car charges on. The sprite of the charger has no post; the script
-- draws them (render objects, nothing to do per tick): the posts when the charger is built and when
-- its number of places changes (charger_control.update_buffers), the arcs every config.short_delay
-- from the state of the cars. charger_data.posts = {post, shadow, support} render objects, in the order of
-- config.charger_visual.posts; storage.charger_arcs[car id] = {charger_id, slot, object}.
local charger_visual = {}

local settings = config.charger_visual

-- Places of the posts for a charger with `count` places: past the first layout, the posts split.
local function get_layout(count)
	return count > #settings.posts and settings.split_posts or settings.posts
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

-- Draws or removes posts so that the charger has one for each of its places.
function charger_visual.update_posts(charger)
	local posts = storage.charger_data[charger.unit_number].posts
	local count = math.min(_utils.get_upgrade(charger.force, "chargers"), #settings.split_posts)
	local layout = get_layout(count)
	if get_layout(#posts) ~= layout then -- the posts move when they split (or merge again)
		while #posts > 0 do
			remove_post(posts)
		end
	end
	while #posts < count do
		local place = layout[#posts + 1]
		local post = rendering.draw_sprite{
			sprite = names.charger_post,
			target = {x = charger.position.x + place.x, y = charger.position.y + place.y - settings.post_height / 2},
			surface = charger.surface,
			render_layer = "higher-object-under",
		}
		-- a post also casts a shadow, to the right
		local shadow = rendering.draw_sprite{
			sprite = names.charger_post_shadow,
			target = {x = charger.position.x + place.x + settings.shadow.x, y = charger.position.y + place.y + settings.shadow.y},
			surface = charger.surface,
			render_layer = "object",
		}
		-- only the split layout (8 places) has supports, one per corner (carried by the first four slots),
		-- drawn for the top left corner and mirrored for the others
		local support
		if layout == settings.split_posts and #posts < #settings.posts then
			local corner = settings.posts[#posts + 1]
			local side_x, side_y = corner.x < 0 and -1 or 1, corner.y < -0.5 and -1 or 1
			support = rendering.draw_sprite{
				sprite = names.charger_support .. (side_y < 0 and "_t" or "_b") .. (side_x < 0 and "l" or "r"),
				target = {x = charger.position.x + corner.x + side_x * settings.support.x, y = charger.position.y + corner.y + side_y * settings.support.y},
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

-- Forgets the posts of a charger that is gone (its arcs end in refresh).
function charger_visual.release(charger_data)
	for _, post in pairs(charger_data.posts) do
		destroy_post(post)
	end
end

local function end_arc(car_id)
	storage.charger_arcs[car_id].object.destroy()
	storage.charger_arcs[car_id] = nil
end

-- Called every tick; every config.short_delay, ends the arcs of the cars that stopped charging and
-- starts one for each car that charges without one, on the first free post of its charger.
function charger_visual.refresh(tick)
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
						animation = names.charger_arc,
						target = {x = charger.position.x + place.x, y = charger.position.y + place.y - settings.tip},
						surface = charger.surface,
						render_layer = "higher-object-above",
					}}
					break
				end
			end
		end
	end
end

return charger_visual
