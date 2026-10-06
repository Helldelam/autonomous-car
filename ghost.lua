local util = require("util")
local config = require("config")
local _utils = require("_utils")
local garage_control = require("park")
local travel = require("travel")

-- Construction: tracking ghosts, grouping them into clusters, assigning the
-- clusters to cars, and running a batch on a car.
--
-- A cluster is a group of ghosts of one type that fits in a single car trunk:
--   {ghosts = {ghost, ...}}
-- Once assigned to a car it becomes the batch of that car, car_data.construction:
--   ghosts          [unit_number] = ghost still to build
--   items_needed    [item name] = count still to collect
--   alerted_items   alert_once flags of the missing-item alerts
--   failed_attempts [unit_number] = {count, retry_tick} of a ghost that failed to revive
local ghost_control = {}

-- ============================================================
-- Tracking
-- ============================================================

-- Starts tracking a ghost, unless it lies inside a robot network: robots will
-- build that one.
function ghost_control.register_ghost(ghost)
	if not ghost.valid then
		return
	end
	if ghost.surface.find_logistic_network_by_position(ghost.position, ghost.force) then
		return
	end
	storage.ghosts[ghost.unit_number] = ghost
	-- A ghost can go away in many ways (built by anyone, cancelled, destroyed),
	-- which only on_object_destroyed reports reliably.
	script.register_on_object_destroyed(ghost)
end

-- A tracked ghost is gone, whatever the reason: drops it from the batch of its
-- car, and ends that batch if it was the last ghost.
function ghost_control.on_ghost_destroyed(id)
	if not storage.ghosts[id] then
		return
	end
	storage.ghosts[id] = nil

	local car_id = storage.ghost_to_car[id]
	if not car_id then
		return
	end
	storage.ghost_to_car[id] = nil

	local car_data = storage.car_data[car_id]
	local construction = car_data and car_data.construction
	if not construction then
		return
	end
	construction.ghosts[id] = nil
	construction.failed_attempts[id] = nil
	-- items_needed is left as is: at worst the car carries one item too many,
	-- which it deposits at the end of the batch.
	if next(construction.ghosts) == nil then
		local car = storage.cars[car_id]
		if car and car.valid then
			ghost_control.finish(car)
		end
	end
end

-- Puts one ghost back in the pending pool, as a cluster of its own.
function ghost_control.requeue_ghost(ghost)
	storage.ghost_to_car[ghost.unit_number] = nil
	if ghost.valid then
		table.insert(storage.pending_clusters, {ghosts = {ghost}})
	end
end

-- ============================================================
-- Clusters
-- ============================================================

-- Name and count of the item that builds a ghost, or nil if no item places it.
function ghost_control.ghost_item(ghost)
	local items = ghost.ghost_prototype.items_to_place_this
	if items and items[1] then
		return items[1].name, items[1].count or 1
	end
	return nil
end

-- Trunk slots a ghost would add to a cluster that already needs `items`
-- ([item name] = count). Slots are rounded on the running total of each item,
-- so ghosts built from the same item share its stacks. Also returns the item
-- and count of the ghost.
local function extra_slots(items, ghost)
	local item_name, count = ghost_control.ghost_item(ghost)
	if not item_name then
		return 0, nil, 0
	end
	local prototype = prototypes.item[item_name]
	local stack_size = prototype and prototype.stack_size or 1
	local before = items[item_name] or 0
	local after = before + count
	return math.ceil(after / stack_size) - math.ceil(before / stack_size), item_name, count
end

local function neighbours_of(ghost, candidates)
	local neighbours = {}
	for _, candidate in pairs(candidates) do
		if util.distance(ghost.position, candidate.position) <= config.cluster_radius then
			table.insert(neighbours, candidate)
		end
	end
	return neighbours
end

local function remove_value(list, value)
	for index, other in pairs(list) do
		if other == value then
			table.remove(list, index)
			return true
		end
	end
	return false
end

-- Splits ghosts into clusters: one ghost type per cluster, small enough for a
-- car trunk (config.car_inventory_size slots). A cluster grows breadth-first
-- from a seed ghost, nearest neighbours first, so it stays compact. The first
-- ghost that no longer fits becomes the seed of the next cluster, so clusters
-- tile the selected area.
function ghost_control.build_clusters(ghosts)
	local by_name = {}
	for _, ghost in pairs(ghosts) do
		local name = ghost.ghost_name
		by_name[name] = by_name[name] or {}
		table.insert(by_name[name], ghost)
	end

	local clusters = {}
	for _, remaining in pairs(by_name) do
		local next_seed = nil

		while #remaining > 0 do
			local seed
			if next_seed and remove_value(remaining, next_seed) then
				seed = next_seed
			else
				seed = table.remove(remaining)
			end
			next_seed = nil

			local cluster = {seed}
			local items = {}
			local slots = 0
			do
				local delta, item_name, count = extra_slots(items, seed)
				slots = slots + delta
				if item_name then
					items[item_name] = (items[item_name] or 0) + count
				end
			end

			local frontier = _utils.deque.new()
			_utils.deque.push_back(frontier, seed)
			while _utils.deque.length(frontier) > 0 do
				local current = _utils.deque.pop_front(frontier)

				local neighbours = neighbours_of(current, remaining)
				table.sort(neighbours, function(a, b)
					return util.distance(current.position, a.position) < util.distance(current.position, b.position)
				end)

				for _, neighbour in pairs(neighbours) do
					if remove_value(remaining, neighbour) then
						local delta, item_name, count = extra_slots(items, neighbour)
						if slots + delta <= config.car_inventory_size then
							table.insert(cluster, neighbour)
							slots = slots + delta
							if item_name then
								items[item_name] = (items[item_name] or 0) + count
							end
							_utils.deque.push_back(frontier, neighbour)
						else
							next_seed = next_seed or neighbour
							table.insert(remaining, neighbour) -- left for a later cluster
						end
					end
				end
			end

			table.insert(clusters, {ghosts = cluster})
		end
	end

	return clusters
end

-- Centroid of a set of ghosts (array or map) and the number of valid ones.
-- Invalid ghosts are removed from the table. Returns nil, 0 if none is left.
function ghost_control.compute_centroid(ghosts)
	local sum_x, sum_y, count = 0, 0, 0
	for key, ghost in pairs(ghosts) do
		if ghost.valid then
			sum_x = sum_x + ghost.position.x
			sum_y = sum_y + ghost.position.y
			count = count + 1
		else
			ghosts[key] = nil
		end
	end
	if count == 0 then
		return nil, 0
	end
	return {x = sum_x / count, y = sum_y / count}, count
end

-- ============================================================
-- Assignment
-- ============================================================

-- True if at least one car exists, on the map or parked in a garage.
function ghost_control.any_car_exists()
	if next(storage.cars) ~= nil then
		return true
	end
	for _, garage in pairs(storage.garages) do
		if garage.valid and garage.get_inventory(defines.inventory.chest).find_item_stack("autonomous_car") then
			return true
		end
	end
	return false
end

-- Finds a car for a cluster: the closest waiting car without a batch,
-- otherwise a car released from the closest garage that holds one. Returns nil
-- if there is none, or if the cluster has no valid ghost left.
function ghost_control.find_available_car(cluster)
	local centroid = ghost_control.compute_centroid(cluster.ghosts)
	if not centroid then
		return nil
	end

	local best_car, best_distance
	for id, car in pairs(storage.cars) do
		if car.valid and storage.car_data[id].waiting.active and not storage.car_data[id].construction then
			local distance = util.distance(car.position, centroid)
			if not best_car or distance < best_distance then
				best_car = car
				best_distance = distance
			end
		end
	end
	if best_car then
		return best_car
	end

	local best_garage
	for _, garage in pairs(storage.garages) do
		if garage.valid and garage.get_inventory(defines.inventory.chest).find_item_stack("autonomous_car") then
			local distance = util.distance(garage.position, centroid)
			if not best_garage or distance < best_distance then
				best_garage = garage
				best_distance = distance
			end
		end
	end
	if best_garage then
		return garage_control.release_car(best_garage)
	end

	return nil
end

-- Gives the closest pending cluster to a car that just became free. Returns
-- true if the car got one.
function ghost_control.try_assign_pending(car)
	if storage.car_data[car.unit_number].construction then
		return false
	end

	local best_index, best_distance
	for index, cluster in pairs(storage.pending_clusters) do
		local centroid = ghost_control.compute_centroid(cluster.ghosts)
		if centroid then
			local distance = util.distance(car.position, centroid)
			if not best_index or distance < best_distance then
				best_index = index
				best_distance = distance
			end
		end
	end
	if not best_index then
		return false
	end

	ghost_control.assign_cluster(car, table.remove(storage.pending_clusters, best_index))
	return true
end

-- Fallback scan, run every config.long_delay: offers every pending cluster to
-- the available cars again. It is also what notices a car that a player put in
-- a garage by hand, for which there is no event. Clusters with no valid ghost
-- left are dropped.
function ghost_control.retry_pending_clusters()
	local still_pending = {}
	for _, cluster in pairs(storage.pending_clusters) do
		local _, count = ghost_control.compute_centroid(cluster.ghosts)
		if count > 0 then
			local car = ghost_control.find_available_car(cluster)
			if car then
				ghost_control.assign_cluster(car, cluster)
			else
				table.insert(still_pending, cluster)
			end
		end
	end
	storage.pending_clusters = still_pending
end

-- Makes a cluster the batch of a car and gets the car going.
function ghost_control.assign_cluster(car, cluster)
	local id = car.unit_number
	local ghosts, items_needed = {}, {}

	for _, ghost in pairs(cluster.ghosts) do
		ghosts[ghost.unit_number] = ghost
		storage.ghost_to_car[ghost.unit_number] = id
		local item_name, count = ghost_control.ghost_item(ghost)
		if item_name then
			items_needed[item_name] = (items_needed[item_name] or 0) + count
		end
	end

	local car_data = storage.car_data[id]
	car_data.construction = {ghosts = ghosts, items_needed = items_needed, alerted_items = {}, failed_attempts = {}}
	car_data.waiting.active = false

	ghost_control.proceed(car)
end

-- ============================================================
-- Supply chests
-- ============================================================

-- A chest and every supply chest within config.chest_group_radius of it:
-- reaching one of them gives access to all.
function ghost_control.chest_group(chest)
	local group = {chest}
	for id, other in pairs(storage.supply_chests) do
		if other.valid then
			if other ~= chest and util.distance(chest.position, other.position) <= config.chest_group_radius then
				table.insert(group, other)
			end
		else
			_utils.release_entity("chest", id)
		end
	end
	return group
end

local function group_holds_any(group, items)
	for _, chest in pairs(group) do
		local inventory = chest.get_inventory(defines.inventory.chest)
		for item_name in pairs(items) do
			if inventory.get_item_count(item_name) > 0 then
				return true
			end
		end
	end
	return false
end

-- Closest supply chest whose group holds at least one of the needed items, or nil.
function ghost_control.find_supply_chest(car, items_needed)
	local best, best_distance
	for id, chest in pairs(storage.supply_chests) do
		if chest.valid then
			if group_holds_any(ghost_control.chest_group(chest), items_needed) then
				local distance = util.distance(car.position, chest.position)
				if not best or distance < best_distance then
					best = chest
					best_distance = distance
				end
			end
		else
			_utils.release_entity("chest", id)
		end
	end
	return best
end

-- Closest supply chest, or nil.
function ghost_control.find_nearest_chest(car)
	local best, best_distance
	for id, chest in pairs(storage.supply_chests) do
		if chest.valid then
			local distance = util.distance(car.position, chest.position)
			if not best or distance < best_distance then
				best = chest
				best_distance = distance
			end
		else
			_utils.release_entity("chest", id)
		end
	end
	return best
end

-- ============================================================
-- Running a batch
-- ============================================================

local function alert_missing_items(car, construction)
	for item_name in pairs(construction.items_needed) do
		_utils.alert_once(construction.alerted_items, item_name, car.force, car,
			"An autonomous car is missing item '" .. item_name .. "' to complete a construction, waiting for supply.",
			{type = "item", name = item_name})
	end
end

local function alert_build_failed(car, ghost)
	_utils.alert(car.force, ghost,
		"An autonomous car could not build an entity after " .. config.max_revive_attempts
			.. " attempts and gave up on it; it has been put back in the general queue.",
		{type = "item", name = "autonomous_car"})
end

-- Decides the next step of a car's batch: end it if no ghost is left, drive to
-- the site once every item is on board, otherwise fetch items from a supply
-- chest, or wait with an alert if no chest holds any. Called on assignment,
-- after each chest stop, and by the waiting loop of control.lua.
function ghost_control.proceed(car)
	local car_data = storage.car_data[car.unit_number]
	local construction = car_data.construction
	if not construction then
		return
	end

	if next(construction.ghosts) == nil then
		ghost_control.finish(car)
	elseif next(construction.items_needed) == nil then
		ghost_control.go_to_site(car)
	else
		local chest = ghost_control.find_supply_chest(car, construction.items_needed)
		if chest then
			travel.set_destination(car, chest, {type = "collect"})
		else
			alert_missing_items(car, construction)
			car_data.waiting.active = true
			car_data.waiting.since = game.tick
		end
	end
end

-- "collect" task: the car reached a supply chest. Takes what it still needs
-- from the whole group of that chest, then decides the next step.
function ghost_control.collect_items(car)
	local car_data = storage.car_data[car.unit_number]
	local chest = car_data.moving.destination
	local construction = car_data.construction

	if construction and chest and chest.valid then
		local trunk = car.get_inventory(defines.inventory.car_trunk)
		for _, member in pairs(ghost_control.chest_group(chest)) do
			local inventory = member.get_inventory(defines.inventory.chest)
			for item_name, needed in pairs(construction.items_needed) do
				local available = inventory.get_item_count(item_name)
				if available > 0 then
					local inserted = trunk.insert{name = item_name, count = math.min(available, needed)}
					if inserted > 0 then
						inventory.remove{name = item_name, count = inserted}
						local remaining = needed - inserted
						construction.items_needed[item_name] = remaining > 0 and remaining or nil
					end
				end
			end
		end
	end

	car_data.moving.active = false
	car_data.moving.destination = nil
	ghost_control.proceed(car)
end

-- Closest ghost of the car's batch that is not on a retry cooldown, or nil.
-- Also returns whether any valid ghost is left at all, which tells "nothing
-- left" from "everything left is on cooldown". Invalid ghosts are removed from
-- the batch.
function ghost_control.nearest_ready_ghost(car)
	local construction = storage.car_data[car.unit_number].construction
	local best, best_distance
	local any_valid = false

	for id, ghost in pairs(construction.ghosts) do
		if ghost.valid then
			any_valid = true
			local attempt = construction.failed_attempts[id]
			if not attempt or game.tick >= attempt.retry_tick then
				local distance = util.distance(car.position, ghost.position)
				if not best or distance < best_distance then
					best = ghost
					best_distance = distance
				end
			end
		else
			construction.ghosts[id] = nil
			construction.failed_attempts[id] = nil
			storage.ghost_to_car[id] = nil
		end
	end

	return best, any_valid
end

-- Builds a ghost with an item from the car trunk. Returns false if the revive
-- failed, usually because something - often the car itself - is in the way.
function ghost_control.revive_ghost(car, ghost)
	local item_name = ghost_control.ghost_item(ghost)
	if not item_name then
		return true -- no item places this ghost: count it as done, so it is not retried forever
	end

	local trunk = car.get_inventory(defines.inventory.car_trunk)
	if trunk.get_item_count(item_name) <= 0 then
		return false
	end

	-- revive() returns nil when it fails.
	if ghost.revive{raise_revive = true} then
		trunk.remove{name = item_name, count = 1}
		return true
	end
	return false
end

-- Tries to build one ghost: the nearest one that is not on a retry cooldown.
-- Returns:
--   "built"   the ghost was placed
--   "failed"  the revive failed: the ghost is put on cooldown for
--             config.medium_delay, or sent back to the pending pool after
--             config.max_revive_attempts failures
--   "none"    every ghost left is on cooldown
--   "empty"   the batch has no ghost left
function ghost_control.attempt_one_ghost(car)
	local construction = storage.car_data[car.unit_number].construction
	local ghost, any_valid = ghost_control.nearest_ready_ghost(car)
	if not ghost then
		return any_valid and "none" or "empty"
	end

	local id = ghost.unit_number
	if ghost_control.revive_ghost(car, ghost) then
		construction.ghosts[id] = nil
		construction.failed_attempts[id] = nil
		return "built"
	end

	local attempt = construction.failed_attempts[id]
	local count = (attempt and attempt.count or 0) + 1
	if count >= config.max_revive_attempts then
		alert_build_failed(car, ghost)
		construction.ghosts[id] = nil
		construction.failed_attempts[id] = nil
		ghost_control.requeue_ghost(ghost)
	else
		construction.failed_attempts[id] = {count = count, retry_tick = game.tick + config.medium_delay}
	end
	return "failed"
end

-- Drives the car config.step_back_distance straight back. Used when every
-- ghost left is on a retry cooldown: the car itself is often what blocks them,
-- so it moves away instead of retrying from the same spot.
function ghost_control.step_back(car)
	local angle = 2 * math.pi * car.orientation
	-- A plain table stands in for the destination entity: a leg only reads
	-- its `position` and `valid`.
	local waypoint = {
		position = {
			x = car.position.x - math.sin(angle) * config.step_back_distance,
			y = car.position.y + math.cos(angle) * config.step_back_distance,
		},
		valid = true,
	}
	travel.begin_leg(car, waypoint)
end

-- Sends the car to the nearest ghost it can try right now. Building starts on
-- arrival ("building" task), never on the way. If every ghost left is on
-- cooldown the car steps back instead.
function ghost_control.go_to_site(car)
	local ghost, any_valid = ghost_control.nearest_ready_ghost(car)
	if ghost then
		travel.begin_leg(car, ghost, {type = "building"})
	elseif any_valid then
		ghost_control.step_back(car)
	else
		ghost_control.finish(car)
	end
end

-- Called every tick while the car is stopped at its site: tries one ghost every
-- config.build_interval ticks, so the batch goes up one entity at a time.
function ghost_control.building_tick(car, tick)
	local car_data = storage.car_data[car.unit_number]
	if tick < car_data.building.next_attempt_tick then
		return
	end
	car_data.building.next_attempt_tick = tick + config.build_interval

	local construction = car_data.construction
	if not construction or next(construction.ghosts) == nil then
		ghost_control.finish(car)
	elseif ghost_control.attempt_one_ghost(car) == "none" then
		ghost_control.step_back(car)
	end
end

-- Sends the car to the nearest supply chest if its trunk is not empty.
-- Leftovers happen when a ghost is given up on or disappears during a batch.
-- Returns true if the car left for a chest ("deposit" task).
function ghost_control.deposit_leftovers(car)
	if car.get_inventory(defines.inventory.car_trunk).is_empty() then
		return false
	end
	local chest = ghost_control.find_nearest_chest(car)
	if not chest then
		return false
	end
	travel.set_destination(car, chest, {type = "deposit"})
	return true
end

-- "deposit" task: the car reached a supply chest. Unloads its trunk into it,
-- then goes idle.
function ghost_control.deposit_items(car)
	local car_data = storage.car_data[car.unit_number]
	local chest = car_data.moving.destination

	if chest and chest.valid then
		local inventory = chest.get_inventory(defines.inventory.chest)
		local trunk = car.get_inventory(defines.inventory.car_trunk)
		-- get_contents() returns an array of {name, count, quality} records.
		for _, item in pairs(trunk.get_contents()) do
			local inserted = inventory.insert{name = item.name, count = item.count}
			if inserted > 0 then
				trunk.remove{name = item.name, count = inserted}
			end
		end
	end

	car_data.moving.active = false
	car_data.moving.destination = nil
	ghost_control.go_idle(car)
end

-- The car has nothing left to do: gives it a pending cluster, or hands it to
-- the waiting loop of control.lua, which sends it to a garage.
function ghost_control.go_idle(car)
	if ghost_control.try_assign_pending(car) then
		return
	end
	local car_data = storage.car_data[car.unit_number]
	car_data.waiting.active = true
	car_data.waiting.since = game.tick - config.idle_delay -- already elapsed: handled on the next tick
end

-- Ends the batch of a car, complete or not: clears its construction state,
-- then deposits leftover items or goes idle.
function ghost_control.finish(car)
	local car_data = storage.car_data[car.unit_number]
	car_data.construction = nil
	car_data.building.active = false
	car_data.moving.active = false
	car_data.moving.destination = nil
	car_data.tasks = _utils.deque.new()

	if not ghost_control.deposit_leftovers(car) then
		ghost_control.go_idle(car)
	end
end

-- The car abandons its task after its final stuck wait (see travel.stuck_tick).
-- Its batch is abandoned completely: the ghosts are neither queued nor assigned again, so the
-- player has to select them again if the car can reach them now. The car then
-- heads back to base through the usual end of a batch: it deposits its items,
-- then waits, which sends it to charge if needed and to a garage.
function ghost_control.abandon(car)
	local car_data = storage.car_data[car.unit_number]
	local construction = car_data.construction

	_utils.alert(car.force, car,
		"An autonomous car ABANDONED its task because it stayed stuck: select the ghosts again if the way is clear now.",
		{type = "item", name = "autonomous_car"})

	if construction then
		for id in pairs(construction.ghosts) do
			storage.ghost_to_car[id] = nil
			storage.ghosts[id] = nil
		end
	end
	ghost_control.finish(car)
end

return ghost_control
