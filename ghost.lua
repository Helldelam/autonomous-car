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
-- Once assigned to a car it becomes the batch of that car, car_data.construction.
-- A batch holds one cluster, or several when the trunk has room for them: their
-- slots are counted cluster by cluster, two clusters never share a slot. The car
-- builds one cluster at a time, from where it stops (its site), then drives to
-- the next.
--   ghosts          [unit_number] = ghost still to build, all clusters together
--   items_needed    [item name] = count still to collect, all clusters together
--   clusters        list of {ghosts = {[unit_number] = {item = name, count = n}},
--                   items = {[item name] = count}}: the items of a ghost that has
--                   been built or has gone away stay in `ghosts`, only `items` is kept up to date
--   site            the entry of `clusters` the car is building, or nil before its first stop
--   missing_since   tick the batch began waiting for items no supply chest holds, or nil
--   alerted_items   alert_once flags of the missing-item alerts
--   failed_attempts [unit_number] = {count, retry_tick} of a ghost that failed to revive
--
-- control.lua enters through register_ghost, on_ghost_destroyed, build_clusters,
-- any_car_exists, retry_pending_clusters, try_assign_pending, proceed,
-- collect_items, deposit_items, deposit_leftovers, building_tick and abandon.
-- The other functions are steps of those: they sit on the table too, so that
-- they can call one another in any order and be counted by the test harness.
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

-- The cluster of a batch that holds the ghost `id` (built or not), or nil.
local function find_cluster(construction, id)
	for _, entry in ipairs(construction.clusters) do
		if entry.ghosts[id] then
			return entry
		end
	end
	return nil
end

-- A ghost of the batch that nobody built is gone: its items are no longer
-- needed. The batch stops waiting for those it has not collected yet; those it
-- has are a surplus, deposited at the end of the batch.
local function drop_ghost_items(construction, id)
	local entry = find_cluster(construction, id)
	local record = entry and entry.ghosts[id]
	if not (record and record.item) then
		return
	end
	local left = (entry.items[record.item] or 0) - record.count
	entry.items[record.item] = left > 0 and left or nil
	local needed = (construction.items_needed[record.item] or 0) - record.count
	construction.items_needed[record.item] = needed > 0 and needed or nil
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
	-- A ghost the car revived itself has already left the batch, and used its item.
	if construction.ghosts[id] then
		drop_ghost_items(construction, id)
	end
	construction.ghosts[id] = nil
	construction.failed_attempts[id] = nil
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

-- TODO: build last the ghosts that extend the native construction network. See "À faire" in CLAUDE.md.
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

			local cluster = {}
			local items = {}
			local slots = 0
			-- Adds a ghost to the cluster if its item still fits in the trunk.
			local function try_add(ghost)
				local delta, item_name, count = extra_slots(items, ghost)
				if slots + delta > config.car_inventory_size then
					return false
				end
				table.insert(cluster, ghost)
				slots = slots + delta
				if item_name then
					items[item_name] = (items[item_name] or 0) + count
				end
				return true
			end

			try_add(seed)
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
						if try_add(neighbour) then
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
		if garage.valid and garage_control.find_parked_car(garage) then
			return true
		end
	end
	return false
end

-- Surface of a cluster (its ghosts are all on one), or nil if it holds no ghost.
local function cluster_surface(cluster)
	local _, ghost = next(cluster.ghosts)
	return ghost and ghost.valid and ghost.surface or nil
end

-- Finds a car for a cluster: the closest waiting car without a batch and with
-- an empty trunk (one still carrying leftovers first unloads them, see
-- end_wait in control.lua), otherwise a car released from the closest garage
-- that holds one. Returns nil if there is none, or if the cluster has no valid
-- ghost left.
function ghost_control.find_available_car(cluster)
	local centroid = ghost_control.compute_centroid(cluster.ghosts)
	if not centroid then
		return nil
	end
	local surface = cluster_surface(cluster)

	local car = _utils.closest(storage.cars, centroid, function(car, id)
		local car_data = storage.car_data[id]
		return car_data.waiting.active and not car_data.construction
			and car.get_inventory(defines.inventory.car_trunk).is_empty()
	end, nil, surface)
	if car then
		return car
	end

	local garage = _utils.closest(storage.garages, centroid, garage_control.find_parked_car, nil, surface)
	if garage then
		return garage_control.release_car(garage)
	end

	return nil
end

-- Gives the closest pending cluster to a car that just became free. Returns
-- true if the car got one.
function ghost_control.try_assign_pending(car)
	if storage.car_data[car.unit_number].construction
		or not car.get_inventory(defines.inventory.car_trunk).is_empty() then
		return false
	end

	local best_index, best_distance
	for index, cluster in pairs(storage.pending_clusters) do
		local centroid = ghost_control.compute_centroid(cluster.ghosts)
		if centroid and cluster_surface(cluster) == car.surface then
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

-- Offers every pending cluster to the available cars, in order, until one finds
-- none. A car takes other pending clusters along (see fill_batch), so the scan
-- starts over after each assignment. Clusters with no valid ghost left are
-- dropped. Called when the player selects ghosts and every config.long_delay as
-- a fallback: that also notices a car that a player put in a garage by hand,
-- for which there is no event. Returns the number of cars that got a batch.
function ghost_control.retry_pending_clusters()
	local assigned = 0
	local index = 1
	while index <= #storage.pending_clusters do
		local cluster = storage.pending_clusters[index]
		local _, count = ghost_control.compute_centroid(cluster.ghosts)
		if count == 0 then
			table.remove(storage.pending_clusters, index)
		else
			local car = ghost_control.find_available_car(cluster)
			if car then
				table.remove(storage.pending_clusters, index)
				ghost_control.assign_cluster(car, cluster)
				assigned = assigned + 1
				index = 1
			else
				index = index + 1 -- another cluster may be on a surface that has a car
			end
		end
	end
	return assigned
end

-- Trunk slots a set of items ([item name] = count) takes.
local function items_slots(items)
	local slots = 0
	for item_name, count in pairs(items) do
		local prototype = prototypes.item[item_name]
		slots = slots + math.ceil(count / (prototype and prototype.stack_size or 1))
	end
	return slots
end

-- Items ([item name] = count) that build the ghosts of a cluster.
local function cluster_items(cluster)
	local items = {}
	for _, ghost in pairs(cluster.ghosts) do
		local item_name, count = ghost_control.ghost_item(ghost)
		if item_name then
			items[item_name] = (items[item_name] or 0) + count
		end
	end
	return items
end

-- Adds a cluster to the batch of a car. The entry remembers the item of each
-- ghost: once a ghost is gone, its entity cannot tell any more (see drop_ghost_items).
local function add_cluster(car_id, construction, cluster)
	local entry = {ghosts = {}, items = cluster_items(cluster)}
	for _, ghost in pairs(cluster.ghosts) do
		local item_name, count = ghost_control.ghost_item(ghost)
		construction.ghosts[ghost.unit_number] = ghost
		entry.ghosts[ghost.unit_number] = {item = item_name, count = count}
		storage.ghost_to_car[ghost.unit_number] = car_id
	end
	for item_name, count in pairs(entry.items) do
		construction.items_needed[item_name] = (construction.items_needed[item_name] or 0) + count
	end
	table.insert(construction.clusters, entry)
end

-- Adds to the batch of a car the closest pending clusters that still fit in its
-- trunk. Each cluster keeps its own slots: the slots of the batch are the sum of
-- the slots of its clusters, never shared.
function ghost_control.fill_batch(car)
	local construction = storage.car_data[car.unit_number].construction
	local reserved = 0
	for _, entry in ipairs(construction.clusters) do
		reserved = reserved + items_slots(entry.items)
	end

	while true do
		local origin = ghost_control.compute_centroid(construction.ghosts)
		if not origin then
			return
		end
		local best_index, best_distance
		for index, cluster in ipairs(storage.pending_clusters) do
			local centroid = ghost_control.compute_centroid(cluster.ghosts)
			if centroid and cluster_surface(cluster) == car.surface
				and reserved + items_slots(cluster_items(cluster)) <= config.car_inventory_size then
				local distance = util.distance(origin, centroid)
				if not best_index or distance < best_distance then
					best_index, best_distance = index, distance
				end
			end
		end
		if not best_index then
			return
		end
		local cluster = table.remove(storage.pending_clusters, best_index)
		reserved = reserved + items_slots(cluster_items(cluster))
		add_cluster(car.unit_number, construction, cluster)
	end
end

-- Makes a cluster the batch of a car, adds the pending clusters that fit next
-- to it, and gets the car going.
function ghost_control.assign_cluster(car, cluster)
	local car_data = storage.car_data[car.unit_number]
	car_data.construction = {
		ghosts = {}, items_needed = {}, clusters = {}, site = nil, missing_since = nil,
		alerted_items = {}, failed_attempts = {},
	}
	add_cluster(car.unit_number, car_data.construction, cluster)
	car_data.waiting.active = false

	ghost_control.fill_batch(car)
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
	return _utils.closest(storage.supply_chests, car.position, function(chest)
		return group_holds_any(ghost_control.chest_group(chest), items_needed)
	end, "chest", car.surface)
end

-- ============================================================
-- Running a batch
-- ============================================================

local function alert_missing_items(car, construction)
	for item_name in pairs(construction.items_needed) do
		_utils.alert_once(construction.alerted_items, item_name, car.force, car,
			"An autonomous car is missing item '" .. item_name .. "' to complete a construction, waiting for supply.",
			item_name)
	end
end

local function alert_build_failed(car, ghost)
	_utils.alert(car.force, ghost,
		"An autonomous car could not build an entity after " .. config.max_revive_attempts
			.. " attempts and gave up on it; it has been put back in the general queue.",
		config.names.car)
end

-- Puts back in the pending pool the clusters of a batch whose items are not all
-- on board, when at least one other cluster is complete: that one can be built
-- meanwhile. Items are given to the clusters in order, which is also the order
-- they were added in. Returns true if clusters went back.
local function release_unsupplied_clusters(construction)
	local total, on_board = {}, {}
	for _, entry in ipairs(construction.clusters) do
		for item_name, count in pairs(entry.items) do
			total[item_name] = (total[item_name] or 0) + count
		end
	end
	for item_name, count in pairs(total) do
		on_board[item_name] = count - (construction.items_needed[item_name] or 0)
	end

	local supplied, unsupplied = {}, {}
	local left = {}
	for item_name, count in pairs(on_board) do
		left[item_name] = count
	end
	for _, entry in ipairs(construction.clusters) do
		local complete = true
		for item_name, count in pairs(entry.items) do
			local given = math.min(count, left[item_name])
			left[item_name] = left[item_name] - given
			complete = complete and given == count
		end
		table.insert(complete and supplied or unsupplied, entry)
	end
	if #supplied == 0 or #unsupplied == 0 then
		return false
	end

	for _, entry in ipairs(unsupplied) do
		local ghosts = {}
		for id in pairs(entry.ghosts) do
			local ghost = construction.ghosts[id]
			if ghost and ghost.valid then
				table.insert(ghosts, ghost)
			end
			construction.ghosts[id] = nil
			construction.failed_attempts[id] = nil
			storage.ghost_to_car[id] = nil
		end
		if #ghosts > 0 then
			table.insert(storage.pending_clusters, {ghosts = ghosts})
		end
	end
	construction.clusters = supplied

	-- What the remaining clusters still lack; the items already on board stay there.
	local remaining = {}
	for _, entry in ipairs(supplied) do
		for item_name, count in pairs(entry.items) do
			remaining[item_name] = (remaining[item_name] or 0) + count
		end
	end
	construction.items_needed = {}
	for item_name, count in pairs(remaining) do
		local lacking = count - (on_board[item_name] or 0)
		if lacking > 0 then
			construction.items_needed[item_name] = lacking
		end
	end
	return true
end

-- Decides the next step of a car's batch: end it if no ghost is left, drive to
-- the site once every item is on board, otherwise fetch items from a supply
-- chest, or wait with an alert if no chest holds any. After config.long_delay
-- of that wait the clusters still lacking items go back to the pending pool and
-- the car builds the others. Called on assignment, after each chest stop, and
-- by the waiting loop of control.lua.
function ghost_control.proceed(car)
	local car_data = storage.car_data[car.unit_number]
	local construction = car_data.construction
	if not construction then
		return
	end

	if next(construction.ghosts) == nil then
		ghost_control.finish(car)
	elseif next(construction.items_needed) == nil then
		construction.missing_since = nil
		ghost_control.go_to_site(car)
	else
		local chest = ghost_control.find_supply_chest(car, construction.items_needed)
		if chest then
			construction.missing_since = nil
			travel.set_destination(car, chest, {type = "collect"})
			return
		end

		alert_missing_items(car, construction)
		construction.missing_since = construction.missing_since or game.tick
		if game.tick - construction.missing_since >= config.long_delay
			and release_unsupplied_clusters(construction) then
			construction.missing_since = nil
			ghost_control.proceed(car)
			return
		end
		_utils.start_waiting(car_data)
	end
end

-- "collect" task: the car reached the supply chest `chest`. Takes what it still
-- needs from the whole group of that chest, then decides the next step.
function ghost_control.collect_items(car, chest)
	local construction = storage.car_data[car.unit_number].construction

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

	ghost_control.proceed(car)
end

-- Closest ghost of the car's batch that is not on a retry cooldown, or nil. With
-- a `cluster` (an entry of construction.clusters), only that cluster's ghosts
-- are considered. Also returns whether any valid ghost is left in the batch,
-- which tells "nothing left" from "everything left is on cooldown" (or, with a
-- cluster, "elsewhere"). Invalid ghosts are removed from the batch.
function ghost_control.nearest_ready_ghost(car, cluster)
	local construction = storage.car_data[car.unit_number].construction
	local best, best_distance
	local any_valid = false

	for id, ghost in pairs(construction.ghosts) do
		if ghost.valid then
			any_valid = true
			local attempt = construction.failed_attempts[id]
			if (not cluster or cluster.ghosts[id]) and (not attempt or game.tick >= attempt.retry_tick) then
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

-- TODO: let cars destroy and replace entities marked for deconstruction or upgrade. See "À faire" in CLAUDE.md.
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

-- Tries to build one ghost: the nearest one of the cluster the car is at that is
-- not on a retry cooldown. Returns:
--   "built"   the ghost was placed
--   "failed"  the revive failed: the ghost is put on cooldown for
--             config.medium_delay, or sent back to the pending pool after
--             config.max_revive_attempts failures
--   "none"    no ghost of this cluster is ready: it is done, or what is left is on cooldown
--   "empty"   the batch has no ghost left
function ghost_control.attempt_one_ghost(car)
	local construction = storage.car_data[car.unit_number].construction
	local ghost, any_valid = ghost_control.nearest_ready_ghost(car, construction.site)
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

-- Sends the car to the nearest ghost it can try right now, whatever its
-- cluster: that cluster becomes the site the car builds. Building starts on
-- arrival ("building" task), never on the way. If every ghost left is on
-- cooldown the car steps back instead.
function ghost_control.go_to_site(car)
	local construction = storage.car_data[car.unit_number].construction
	local ghost, any_valid = ghost_control.nearest_ready_ghost(car)
	if ghost then
		construction.site = find_cluster(construction, ghost.unit_number)
		-- Recharges first if the car could not get back to a charger afterwards: this
		-- is also what lets it recharge between two clusters.
		travel.set_destination(car, ghost, {type = "building"})
	elseif any_valid then
		ghost_control.step_back(car)
	else
		ghost_control.finish(car)
	end
end

-- Called every tick while the car is stopped at its site: tries one ghost of the
-- site every config.build_interval ticks, so the batch goes up one entity at a
-- time. When none of them is ready, the car goes on to the next cluster, or steps
-- back if only ghosts on cooldown are left (see go_to_site).
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
		ghost_control.go_to_site(car)
	end
end

-- True if a group of supply chests has room for at least one of the items of
-- `trunk`.
local function group_has_room_for(group, trunk)
	for _, item in pairs(trunk.get_contents()) do -- an array of {name, count, quality} records
		for _, chest in pairs(group) do
			if chest.get_inventory(defines.inventory.chest).can_insert{name = item.name, count = 1} then
				return true
			end
		end
	end
	return false
end

-- Closest supply chest whose group has room for something the car carries, or nil.
function ghost_control.find_chest_with_room(car)
	local trunk = car.get_inventory(defines.inventory.car_trunk)
	return _utils.closest(storage.supply_chests, car.position, function(chest)
		return group_has_room_for(ghost_control.chest_group(chest), trunk)
	end, "chest", car.surface)
end

-- Sends the car to the nearest supply chest that has room if its trunk is not
-- empty; alerts the player when none has (the car then keeps its items, and the
-- waiting loop of control.lua tries again). Leftovers happen when a ghost is
-- given up on or disappears during a batch. Returns true if the car left for a
-- chest ("deposit" task), false if there was nothing to deposit, no chest to
-- deposit in, or the car could not set off (see travel.set_destination): it is
-- then back in the waiting loop.
function ghost_control.deposit_leftovers(car)
	local car_data = storage.car_data[car.unit_number]
	if car.get_inventory(defines.inventory.car_trunk).is_empty() then
		_utils.alert_reset(car_data.alerts, "supply_full")
		return false
	end
	local chest = ghost_control.find_chest_with_room(car)
	if not chest then
		_utils.alert_once(car_data.alerts, "supply_full", car.force, car,
			"The supply chests are full (or there is none): an autonomous car cannot empty its trunk. Make room in a chest.",
			config.names.car)
		return false
	end
	return travel.set_destination(car, chest, {type = "deposit"})
end

-- "deposit" task: the car reached the supply chest `chest`. Unloads its trunk
-- into it and the chests next to it. What does not fit goes to the next chest
-- with room; with none left the car goes idle with its items (see
-- deposit_leftovers).
function ghost_control.deposit_items(car, chest)
	local trunk = car.get_inventory(defines.inventory.car_trunk)
	if chest and chest.valid then
		for _, member in pairs(ghost_control.chest_group(chest)) do
			local inventory = member.get_inventory(defines.inventory.chest)
			for _, item in pairs(trunk.get_contents()) do
				local inserted = inventory.insert{name = item.name, count = item.count}
				if inserted > 0 then
					trunk.remove{name = item.name, count = inserted}
				end
			end
		end
	end

	if ghost_control.deposit_leftovers(car) then
		return
	end
	ghost_control.go_idle(car)
end

-- The car has nothing left to do: gives it a pending cluster, or hands it to
-- the waiting loop of control.lua, which sends it to a garage.
function ghost_control.go_idle(car)
	if ghost_control.try_assign_pending(car) then
		return
	end
	_utils.start_waiting(storage.car_data[car.unit_number], game.tick - config.idle_delay) -- already elapsed: handled on the next tick
end

-- Ends the batch of a car, complete or not: clears its construction state,
-- then deposits leftover items or goes idle.
function ghost_control.finish(car)
	local car_data = storage.car_data[car.unit_number]
	car_data.construction = nil
	travel.cancel_trip(car_data)
	car_data.charge_detour_count = 0

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
		config.names.car)

	if construction then
		for id in pairs(construction.ghosts) do
			storage.ghost_to_car[id] = nil
			storage.ghosts[id] = nil
		end
	end
	ghost_control.finish(car)
end

return ghost_control
