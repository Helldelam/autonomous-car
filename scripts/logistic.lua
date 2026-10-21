local config = require("config")
local _utils = require("scripts._utils")

-- Link with the logistic network: what the batches of the cars still lack is requested by the
-- delivery chests (requester chests), whose robots fill them; the cars then collect it as from
-- any supply chest (construction.lua). The return chests (active providers) need no code here: the cars
-- deposit in them first (ghost_control.find_chest_with_room).
local logistic_control = {}

-- Items of the supply chests of a surface other than the delivery chest `delivery`, by item key.
-- The return chests do not count: the robots are emptying them.
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

-- Puts the requests of a delivery chest: what it holds, plus what the cars that use it still lack
-- after counting everything the other supply chests of its surface hold.
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

-- Starts a pass (storage.logistic_job): the cars and the delivery chests to look at, and what the
-- cars need per chest. nil if there is no delivery chest.
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

-- Called every tick; a pass starts every config.medium_delay ticks and takes config.logistic_per_tick
-- cars, then as many chests, per tick. Each car with a batch counts for its closest delivery
-- chest on its surface; a chest without such car requests nothing.
function logistic_control.update_requests(tick)
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
			local total = delivery and job.needs[delivery.unit_number] -- not in the pass if built since it started
			if total then
				for key, count in pairs(construction.items_needed) do
					total[key] = (total[key] or 0) + count
				end
			end
		end
	end

	-- All the cars are counted: the chests get their requests.
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

return logistic_control
