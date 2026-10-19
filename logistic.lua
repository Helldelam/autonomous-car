local config = require("config")
local _utils = require("_utils")

-- Link with the logistic network: what the batches of the cars still lack is requested by the
-- delivery chests (requester chests), whose robots fill them; the cars then collect it as from
-- any supply chest (ghost.lua). The return chests (active providers) need no code here: the cars
-- deposit in them first (ghost_control.find_chest_with_room).
local logistic_control = {}

-- TODO: transport tasks (delivery and pick-up) between a remote supply chest and an interface chest. See "À faire" in CLAUDE.md.
-- Items of the supply chests of a surface other than the delivery chest `delivery`, by item key.
-- The return chests do not count: the robots are emptying them.
local function count_other_supply(delivery, keys)
	local held = {}
	for id, chest in pairs(storage.supply_chests) do
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

-- Called every config.medium_delay ticks. Each car with a batch counts for its closest delivery
-- chest on its surface; a chest without such car requests nothing.
function logistic_control.update_requests()
	local needs = {}
	local any = false
	for id, chest in pairs(storage.supply_chests) do
		if chest.valid and chest.name == config.names.delivery_chest then
			needs[id] = {}
			any = true
		end
	end
	if not any then
		return
	end

	for id, car in pairs(storage.cars) do
		local construction = car.valid and storage.car_data[id].construction
		if construction and next(construction.items_needed) then
			local delivery = _utils.find_closest(storage.supply_chests, car.position, function(chest)
				return chest.name == config.names.delivery_chest
			end, "chest", car.surface)
			if delivery then
				local total = needs[delivery.unit_number]
				for key, count in pairs(construction.items_needed) do
					total[key] = (total[key] or 0) + count
				end
			end
		end
	end

	for id, needed in pairs(needs) do
		local chest = storage.supply_chests[id]
		if chest and chest.valid then
			set_requests(chest, needed)
		end
	end
end

return logistic_control
