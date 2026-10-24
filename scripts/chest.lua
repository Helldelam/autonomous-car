local config = require("config")
local _utils = require("scripts._utils")

-- Supply chests: the hatch drawn while cars use one, and the requests of the delivery chests.
-- Collecting and depositing are in construction.lua.
local chest_control = {}

-- ============================================================
-- Hatch
-- ============================================================
-- The game animates a logistic chest for robots and players only: for a car, an interior and the
-- hatch (<colour>-door.png), squashed towards its hinges on the left, are drawn over the closed
-- sprite. Open with the first car, closed after the last (`users`).
-- storage.chest_doors[id] = {chest, scale (1 closed), users, interior, door}; open or moving only.

local hatch = config.chest_door
local step = (1 - hatch.open_scale) / hatch.move_ticks -- scale change per tick

local function place(door)
	local position = door.chest.position
	door.door.target = {
		x = position.x + hatch.left + hatch.width * door.scale / 2,
		y = position.y + hatch.top + hatch.height / 2,
	}
	door.door.x_scale = door.scale
end

local function destroy(id)
	local door = storage.chest_doors[id]
	if door then
		door.interior.destroy()
		door.door.destroy()
		storage.chest_doors[id] = nil
	end
end

function chest_control.open_hatch(chest)
	local id = chest.unit_number
	local door = storage.chest_doors[id]
	if not door then
		local position = chest.position
		local target = {x = position.x + hatch.left + hatch.width / 2, y = position.y + hatch.top + hatch.height / 2}
		door = {
			chest = chest,
			scale = 1,
			users = 0,
			interior = rendering.draw_sprite{sprite = config.names.chest_interior, target = target, surface = chest.surface,
				render_layer = "object"},
			door = rendering.draw_sprite{sprite = chest.name .. "_door", target = target, surface = chest.surface,
				render_layer = "cargo-hatch"}, -- above the interior
		}
		storage.chest_doors[id] = door
	end
	door.users = door.users + 1
end

function chest_control.close_hatch(chest)
	local door = chest.valid and storage.chest_doors[chest.unit_number]
	if door then
		door.users = math.max(0, door.users - 1)
	end
end

-- Every tick: each moving hatch by one step.
function chest_control.update_hatches()
	for id, door in pairs(storage.chest_doors) do
		if not door.chest.valid then
			destroy(id)
		else
			local open = door.users > 0
			local scale = open and math.max(hatch.open_scale, door.scale - step) or math.min(1, door.scale + step)
			if scale ~= door.scale then
				door.scale = scale
				place(door)
			elseif scale == 1 and not open then
				destroy(id)
			end
		end
	end
end

function chest_control.release_hatch(id)
	destroy(id)
end

-- ============================================================
-- Delivery chests (requester)
-- ============================================================
-- Each requests what the cars it is closest to still lack, less what the other supply chests of
-- its surface hold; its robots fill it. Return chests need no code: cars deposit there first.

-- [item key] = count in the other supply chests of the surface (return chests excluded: emptied by robots).
local function count_other_supply(delivery, keys)
	local held = {}
	for _, chest in pairs(storage.supply_chests) do
		if chest.valid and chest ~= delivery and chest.surface == delivery.surface and chest.name ~= config.names.return_chest then
			local inventory = chest.get_inventory(defines.inventory.chest)
			for key in pairs(keys) do
				held[key] = (held[key] or 0) + _utils.get_item_count(inventory, key)
			end
		end
	end
	return held
end

local function set_requests(delivery, needed)
	local inventory = delivery.get_inventory(defines.inventory.chest)
	local other = count_other_supply(delivery, needed)
	local filters = {}
	for key, count in pairs(needed) do
		local held = _utils.get_item_count(inventory, key)
		local deficit = count - held - (other[key] or 0)
		if deficit > 0 then
			local name, quality = _utils.split_item_key(key)
			filters[#filters + 1] = {value = {type = "item", name = name, quality = quality or "normal", comparator = "="}, min = held + deficit}
		end
	end

	local sections = delivery.get_logistic_sections()
	local section = sections.get_section(1) or sections.add_section()
	section.filters = filters
end

-- storage.logistic_job: the cars and delivery chests of a pass; nil without delivery chest.
local function start_job()
	local needs, chests = {}, {}
	for id, chest in pairs(storage.supply_chests) do
		if chest.valid and chest.name == config.names.delivery_chest then
			needs[id] = {}
			chests[#chests + 1] = id
		end
	end
	if #chests == 0 then
		return nil
	end
	local cars = {}
	for id in pairs(storage.cars) do
		cars[#cars + 1] = id
	end
	return {needs = needs, cars = cars, chests = chests, index = 0}
end

-- A pass every medium_delay, logistic_per_tick cars then chests per tick.
function chest_control.update_requests(tick)
	if not storage.logistic_job and tick % config.medium_delay == 0 then
		storage.logistic_job = start_job()
	end
	local job = storage.logistic_job
	if not job then
		return
	end

	local budget = config.logistic_per_tick
	local cars = job.cars
	while job.index < #cars and budget > 0 do
		job.index = job.index + 1
		budget = budget - 1
		local id = cars[job.index]
		local car = storage.cars[id]
		local construction = car and car.valid and storage.car_data[id].construction
		if construction and next(construction.items_needed) then
			local delivery = _utils.find_closest("supply_chests", car.position, function(chest)
				return chest.name == config.names.delivery_chest
			end, "chest", car.surface)
			local total = delivery and job.needs[delivery.unit_number] -- nil if built since the pass began
			if total then
				for key, count in pairs(construction.items_needed) do
					total[key] = (total[key] or 0) + count
				end
			end
		end
	end

	while job.index >= #cars and budget > 0 do
		local id = table.remove(job.chests)
		if not id then
			storage.logistic_job = nil
			return
		end
		budget = budget - 1
		local chest = storage.supply_chests[id]
		if chest and chest.valid then
			set_requests(chest, job.needs[id])
		end
	end
end

return chest_control
