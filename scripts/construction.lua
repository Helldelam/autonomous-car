local util = require("util")
local config = require("config")
local _utils = require("scripts._utils")
local garage_control = require("scripts.garage")
local travel = require("scripts.travel")

-- Construction: tracking ghosts, grouping them into clusters, assigning the
-- clusters to cars, and running a batch on a car.
--
-- A "ghost" here is any target a car works on: an entity ghost or a tile ghost
-- to build, an entity marked for deconstruction to mine, or an entity marked for
-- upgrade to replace. A batch does one thing, never two (get_mode). Targets are
-- keyed by get_id: trees and rocks have no unit_number.
--
-- Work has an order (PHASE): first entities are mined, then water is filled in
-- (the "landfill" mode: tile ghosts on water), then entities are built and
-- replaced, last the ghosts that extend the logistic network (the "network"
-- mode: roboports). A batch fetches its items at once, but waits
-- before driving to its site until nothing of an earlier phase is left on its
-- surface (is_waiting_for_phase).
--
-- A cluster is a group of ghosts of one type (or of entities to mine) that fits
-- in a single car trunk:
--   {ghosts = {ghost, ...}}
-- Once assigned to a car it becomes the batch of that car, car_data.construction.
-- A batch holds one cluster, or several when the trunk has room for them: their
-- slots are counted cluster by cluster, two clusters never share a slot. The car
-- builds one cluster at a time, from where it stops (its site), then drives to
-- the next.
--   ghosts          [id] = ghost still to build (or entity to mine), all clusters together
--   items_needed    [item key] = count still to collect, all clusters together (empty
--                   when mining); an item key is a name and a quality (_utils.make_item_key)
--   clusters        list of {ghosts = {[id] = {items = load, needs = needs}},
--                   items = load, needs = needs}, with load and needs as {[item key] = count}:
--                   those of a ghost that has been built or has gone away stay in `ghosts`, only
--                   `items` and `needs` are kept up to date. The needs of a ghost are the item to
--                   collect for it; its load reserves trunk slots: the needs plus the worst case
--                   of what mining it or replacing it gives back
--   site            the entry of `clusters` the car is building, or nil before its first stop
--   missing_since   tick the batch began waiting for items no supply chest holds, or nil
--   alerted_items   alert_once flags of the missing-item alerts
--   failed_attempts [id] = {count, retry_tick} of a ghost that failed to revive
--   mode            "build", "landfill", "deconstruct", "upgrade" or "network": what the whole batch does
--   blocked_since   tick the batch began waiting for an earlier phase, or nil
--
-- control.lua enters through register_ghost, on_ghost_destroyed, start_selection, step_selection,
-- is_any_car_present, retry_pending_clusters, try_assign_pending, proceed,
-- collect_items, deposit_items, deposit_leftovers, building_tick and abandon.
-- The other functions are steps of those: they sit on the table too, so that
-- they can call one another in any order and be counted by the test harness.
local ghost_control = {}

-- ============================================================
-- Tracking
-- ============================================================

-- TODO: building a whole mine from a selected resource patch, without ghosts. See "À faire" in CLAUDE.md.
-- Key of a ghost in the tables of this module: its unit_number, or for an entity
-- that has none (trees, rocks) its surface, name and position.
function ghost_control.get_id(ghost)
	return ghost.unit_number or (ghost.surface.index .. ":" .. ghost.name .. "@" .. ghost.position.x .. "," .. ghost.position.y)
end

-- True if the tile under the entity cannot be walked on: water, to be filled in.
local function is_on_water(entity)
	return entity.surface.get_tile(entity.position).collides_with("player")
end

-- True if one of the eight tiles around a tile ghost is land: the car can stop
-- there and build the ghost, which needs no reach.
local function is_next_to_land(ghost)
	local surface, position = ghost.surface, ghost.position
	for dx = -1, 1 do
		for dy = -1, 1 do
			if (dx ~= 0 or dy ~= 0) and not surface.get_tile(position.x + dx, position.y + dy).collides_with("player") then
				return true
			end
		end
	end
	return false
end

-- What a car does with a tracked entity: "build" a ghost ("landfill" for a tile
-- ghost on water, "network" for a ghost that extends the logistic network, built
-- last), "deconstruct" an entity marked for deconstruction, otherwise "upgrade"
-- it (a mark that the player cancelled does not change the mode of the batch it is in).
function ghost_control.get_target_mode(entity)
	if entity.type == "tile-ghost" then
		return is_on_water(entity) and "landfill" or "build"
	elseif entity.type == "entity-ghost" then
		return entity.ghost_type == "roboport" and "network" or "build"
	end
	return entity.to_be_deconstructed() and "deconstruct" or "upgrade"
end

-- The order of the work: a mode waits for every mode of a lower number.
local PHASE = {deconstruct = 1, landfill = 2, upgrade = 3, build = 3, network = 4}

-- The modes whose targets are ghosts that a car revives with an item.
local REVIVES = {build = true, landfill = true, network = true}

-- True if cars can work on the entity: a ghost, an entity marked for
-- deconstruction that can be mined or a cliff (which needs its cliff explosive), or
-- an entity marked for an upgrade to another entity (or quality) that an item places.
function ghost_control.is_target(entity)
	if entity.type == "entity-ghost" or entity.type == "tile-ghost" then
		return true
	elseif entity.to_be_deconstructed() then
		return entity.minable or entity.type == "cliff"
	elseif entity.to_be_upgraded() then
		local target, quality = entity.get_upgrade_target()
		return target ~= nil and (target.name ~= entity.name or (quality ~= nil and quality.name ~= entity.quality.name))
			and ghost_control.get_place_item(target, quality) ~= nil
	end
	return false
end

-- What a batch does with its ghosts (see get_target_mode), from the first valid
-- one. nil if there is none.
local function get_mode(ghosts)
	for _, ghost in pairs(ghosts) do
		if ghost.valid then
			return ghost_control.get_target_mode(ghost)
		end
	end
	return nil
end

-- Starts tracking a ghost or an entity marked for deconstruction or upgrade, unless it lies
-- inside a robot network (robots will do that one) or is tracked already: it is
-- then with a car or in the pending pool, and must not be queued twice. Returns
-- true if it is newly tracked.
function ghost_control.register_ghost(ghost)
	if not ghost.valid or not ghost_control.is_target(ghost) then
		return false
	end
	local id = ghost_control.get_id(ghost)
	if storage.ghosts[id] then
		return false
	end
	if ghost.surface.find_logistic_network_by_position(ghost.position, ghost.force) then
		return false
	end
	storage.ghosts[id] = ghost
	-- A ghost can go away in many ways (built by anyone, cancelled, destroyed),
	-- which only on_object_destroyed reports reliably. It reports an entity
	-- without a unit_number by its registration number only.
	local registration = script.register_on_object_destroyed(ghost)
	if not ghost.unit_number then
		storage.target_by_registration[registration] = id
	end
	return true
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

-- Adds `counts` ([item key] = count) to the counts `into`.
local function add_counts(into, counts)
	for key, count in pairs(counts) do
		into[key] = (into[key] or 0) + count
	end
end

-- Removes `counts` ([item key] = count) from the counts `from`; a count that reaches 0 is dropped.
local function remove_counts(from, counts)
	for key, count in pairs(counts) do
		local left = (from[key] or 0) - count
		from[key] = left > 0 and left or nil
	end
end

-- A ghost of the batch that nobody built is gone: its items are no longer
-- needed. The batch stops waiting for those it has not collected yet; those it
-- has are a surplus, deposited at the end of the batch. (The load only reserves
-- trunk slots; the needs are what has to be collected.)
local function drop_ghost_items(construction, id)
	local entry = find_cluster(construction, id)
	if not entry then
		return
	end
	local record = entry.ghosts[id]
	remove_counts(entry.items, record.items)
	remove_counts(entry.needs, record.needs)
	remove_counts(construction.items_needed, record.needs)
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

-- Puts one ghost back in the pending pool, as a cluster of its own. No car takes
-- it before config.very_long_delay (`not_before`): a ghost that failed several
-- times would otherwise be handed at once to another car, and then to a third.
function ghost_control.requeue_ghost(ghost)
	storage.ghost_to_car[ghost_control.get_id(ghost)] = nil
	if ghost.valid then
		table.insert(storage.pending_clusters, {ghosts = {ghost}, not_before = game.tick + config.very_long_delay})
	end
end

-- True if a pending cluster may be given to a car now.
local function is_cluster_ready(cluster)
	return not cluster.not_before or game.tick >= cluster.not_before
end

-- ============================================================
-- Clusters
-- ============================================================

-- Key (see _utils.make_item_key) and count of the item that places an entity
-- prototype of the given quality (a name, a LuaQualityPrototype or nil for
-- normal), or nil if none does.
function ghost_control.get_place_item(prototype, quality)
	local items = prototype.items_to_place_this
	if items and items[1] then
		return _utils.make_item_key(items[1].name, quality), items[1].count or 1
	end
	return nil
end

-- Key and count of the item that builds a ghost, or nil if no item places it.
function ghost_control.get_ghost_item(ghost)
	-- A tile ghost has no quality.
	return ghost_control.get_place_item(ghost.ghost_prototype, ghost.type == "entity-ghost" and ghost.quality or nil)
end

-- What an entity marked for deconstruction puts in the trunk when mined
-- ([item key] = count): the worst case of its products (a tree's wood, a
-- rock's stone and coal) and what its inventories hold. Items on a belt are not counted.
local function compute_yield(entity)
	local yield = {}
	local function add(key, count)
		yield[key] = (yield[key] or 0) + count
	end
	if entity.type == "item-entity" then
		add(_utils.make_item_key(entity.stack.name, entity.stack.quality), entity.stack.count)
		return yield
	elseif entity.type == "cliff" then
		return yield -- destroyed, gives nothing
	end
	local products = entity.prototype.mineable_properties.products
	for _, product in pairs(products or {}) do
		if product.type == "item" then
			add(_utils.make_item_key(product.name, entity.quality), product.amount_max or product.amount or 0)
		end
	end
	for index = 1, entity.get_max_inventory_index() do
		local inventory = entity.get_inventory(index)
		if inventory then
			add_counts(yield, _utils.get_contents(inventory))
		end
	end
	return yield
end

-- The items an entity ghost requests besides its own, placed in inventory slots
-- (modules, and whatever else the blueprint puts in): [item key] = count. Equipment
-- grids are not handled.
local function compute_requests(ghost)
	local requests = {}
	if ghost.type ~= "entity-ghost" then
		return requests
	end
	for _, plan in pairs(ghost.insert_plan) do
		local count = 0
		for _, position in pairs(plan.items.in_inventory or {}) do
			count = count + (position.count or 1)
		end
		if count > 0 then
			local name = plan.id.name
			local key = _utils.make_item_key(type(name) == "string" and name or name.name, plan.id.quality)
			requests[key] = (requests[key] or 0) + count
		end
	end
	return requests
end

-- What the car must collect to work on a ghost ([item key] = count): the item
-- that builds it and the items it requests (modules), that places the entity an
-- upgrade turns it into, or the cliff explosive that destroys a cliff. Nothing to mine.
function ghost_control.compute_needs(ghost)
	local key, count
	local mode = ghost_control.get_target_mode(ghost)
	if REVIVES[mode] then
		key, count = ghost_control.get_ghost_item(ghost)
		local needs = compute_requests(ghost)
		if key then
			needs[key] = (needs[key] or 0) + count
		end
		return needs
	elseif ghost.type == "cliff" then
		key, count = ghost.prototype.cliff_explosive_prototype, 1
	elseif mode == "upgrade" then
		local target, quality = ghost.get_upgrade_target()
		if target then
			key, count = ghost_control.get_place_item(target, quality or ghost.quality)
		end
	end
	return key and {[key] = count} or {}
end

-- What a ghost puts in the trunk ([item key] = count), to reserve its slots:
-- the needs, plus what mining the entity or replacing it gives back.
function ghost_control.compute_load(ghost)
	if REVIVES[ghost_control.get_target_mode(ghost)] then
		return ghost_control.compute_needs(ghost)
	end
	local load = compute_yield(ghost)
	add_counts(load, ghost_control.compute_needs(ghost))
	return load
end

-- Trunk slots a ghost would add to a cluster that already holds `items`
-- ([item key] = count). Slots are rounded on the running total of each item,
-- so ghosts with the same item share its stacks. Also returns the load of the ghost.
local function count_extra_slots(items, ghost)
	local load = ghost_control.compute_load(ghost)
	local extra = 0
	for key, count in pairs(load) do
		local prototype = prototypes.item[_utils.split_item_key(key)]
		local stack_size = prototype and prototype.stack_size or 1
		local before = items[key] or 0
		extra = extra + math.ceil((before + count) / stack_size) - math.ceil(before / stack_size)
	end
	return extra, load
end

-- The ghosts a group still has to cluster sit in a grid of square cells of
-- config.cluster_radius: the neighbours of a ghost are in the 3 x 3 cells around it,
-- whatever the size of the selection. A group is
--   order  all its ghosts, the seeds are taken from the end
--   cells  [cell key] = array of the ghosts of the cell that are not in a cluster yet
--   slot, key  [ghost] = its index in its cell, and the key of its cell
--   taken  [ghost] = true when it is not in the grid
--   left   number of ghosts in the grid
--   next_seed  the first ghost that did not fit in the last cluster
local function get_cell_key(x, y)
	return (x + 32768) * 65536 + (y + 32768)
end

local function insert_in_grid(group, ghost, key)
	local cell = group.cells[key]
	if not cell then
		cell = {}
		group.cells[key] = cell
	end
	cell[#cell + 1] = ghost
	group.slot[ghost], group.key[ghost], group.taken[ghost] = #cell, key, nil
	group.left = group.left + 1
end

local function take_from_grid(group, ghost)
	local cell = group.cells[group.key[ghost]]
	local index, last = group.slot[ghost], cell[#cell]
	cell[index] = last
	group.slot[last] = index
	cell[#cell] = nil
	group.taken[ghost] = true
	group.left = group.left - 1
end

-- The ghosts of the grid within config.cluster_radius of a ghost, closest first.
local function find_neighbours(group, ghost)
	local neighbours, distances = {}, {}
	local position = ghost.position
	local cell_x = math.floor(position.x / config.cluster_radius)
	local cell_y = math.floor(position.y / config.cluster_radius)
	for dx = -1, 1 do
		for dy = -1, 1 do
			local cell = group.cells[get_cell_key(cell_x + dx, cell_y + dy)]
			if cell then
				for index = #cell, 1, -1 do -- backwards: a ghost taken out is replaced by the last one, already seen
					local candidate = cell[index]
					if candidate.valid then -- checked at use: a ghost may be gone since the selection
						local distance = util.distance(position, candidate.position)
						if distance <= config.cluster_radius then
							table.insert(neighbours, candidate)
							distances[candidate] = distance
						end
					else
						take_from_grid(group, candidate)
					end
				end
			end
		end
	end
	table.sort(neighbours, function(a, b)
		return distances[a] < distances[b]
	end)
	return neighbours
end

-- Splits ghosts into clusters: one ghost type per cluster (all the entities to
-- mine, or to upgrade, or the ghosts that extend the logistic network, together),
-- small enough for the trunk of a car of `force` (config.upgrades.cargo slots). A cluster grows
-- breadth-first from a seed ghost, nearest neighbours first, so it stays compact.
-- The first ghost that no longer fits becomes the seed of the next cluster, so
-- clusters tile the selected area.
-- A big selection is handled over several ticks, in three phases (`job.phase`) that share
-- the budget of config.selection_ghosts_per_tick ghosts per tick: "register" (start tracking the
-- selected entities and sort them by ghost type), "grid" (put them in the grids) and "cluster"
-- (puts the finished clusters in storage.pending_clusters). Once the budget is spent, no new
-- cluster is started; one never stops halfway, and holds at most that many ghosts, so a tick
-- clusters twice the budget at worst.
-- start_selection returns the job, step_selection (called every tick until it returns true)
-- runs it; `job.count` is then the number of targets newly tracked.
function ghost_control.start_selection(entities, force)
	return {
		phase = "register",
		entities = entities,
		index = 0, -- entities read so far, then ghosts of the group put in the grid
		count = 0, -- entities newly tracked
		by_name = {}, -- [group name] = array of ghosts, one group per ghost type
		capacity = _utils.get_upgrade(force, "cargo"), -- trunk slots of the cars of the force that selected them
		groups = {}, -- grids of the groups, see above
		group = 1, -- the group being put in the grid, then clustered
	}
end

-- Starts tracking the selected entities (as far as the budget allows) and sorts them by group.
-- Returns the budget left, which is 0 when the phase is not over.
local function register_selection(job, budget)
	local entities = job.entities
	while job.index < #entities and budget > 0 do
		job.index = job.index + 1
		budget = budget - 1
		local ghost = entities[job.index]
		if ghost_control.register_ghost(ghost) then
			job.count = job.count + 1
			local mode = ghost_control.get_target_mode(ghost)
			local name = (mode == "build" or mode == "landfill") and ("ghost " .. ghost.ghost_name) or mode
			job.by_name[name] = job.by_name[name] or {}
			table.insert(job.by_name[name], ghost)
		end
	end
	if job.index >= #entities then
		job.phase, job.index = "grid", 0
		for _, order in pairs(job.by_name) do
			table.insert(job.groups, {order = order, cells = {}, slot = {}, key = {}, taken = {}, left = 0})
		end
		job.by_name, job.entities = nil, nil
	end
	return budget
end

-- Puts the ghosts of the groups in their grid, as far as the budget allows.
local function fill_grids(job, budget)
	while job.group <= #job.groups do
		local group = job.groups[job.group]
		local order = group.order
		while job.index < #order do
			if budget <= 0 then
				return 0
			end
			job.index = job.index + 1
			budget = budget - 1
			local ghost = order[job.index]
			if ghost.valid then
				local position = ghost.position
				insert_in_grid(group, ghost, get_cell_key(
					math.floor(position.x / config.cluster_radius), math.floor(position.y / config.cluster_radius)))
			else
				group.taken[ghost] = true -- gone since the selection
			end
		end
		job.group, job.index = job.group + 1, 0
	end
	job.phase, job.group = "cluster", 1
	return budget
end

-- Runs a selection as far as this tick's budget allows. True when its clusters all exist.
function ghost_control.step_selection(job)
	local budget = config.selection_ghosts_per_tick
	if job.phase == "register" then
		budget = register_selection(job, budget)
	end
	if job.phase == "grid" then
		budget = fill_grids(job, budget)
	end
	if job.phase ~= "cluster" then
		return false
	end
	while job.group <= #job.groups do
		local group = job.groups[job.group]
		while group.left > 0 do
			if budget <= 0 then
				return false
			end
			local seed = group.next_seed
			if not seed or group.taken[seed] then
				repeat
					seed = table.remove(group.order)
				until not seed or not group.taken[seed]
			end
			group.next_seed = nil
			if not seed then
				break -- nothing left to take (cannot happen)
			end
			take_from_grid(group, seed)

			local cluster = {}
			if seed.valid then
				local items = {}
				local slots = 0
				-- Adds a ghost to the cluster if its item still fits in the trunk.
				local function try_add(ghost)
					local delta, load = count_extra_slots(items, ghost)
					if #cluster >= config.selection_ghosts_per_tick or slots + delta > job.capacity then
						return false
					end
					table.insert(cluster, ghost)
					slots = slots + delta
					add_counts(items, load)
					return true
				end

				try_add(seed)
				local frontier = _utils.deque.new()
				_utils.deque.push_back(frontier, seed)
				while _utils.deque.length(frontier) > 0 do
					local current = _utils.deque.pop_front(frontier)

					for _, neighbour in ipairs(find_neighbours(group, current)) do
						take_from_grid(group, neighbour)
						if try_add(neighbour) then
							_utils.deque.push_back(frontier, neighbour)
						else
							group.next_seed = group.next_seed or neighbour
							insert_in_grid(group, neighbour, group.key[neighbour]) -- left for a later cluster
						end
					end
				end
				table.insert(storage.pending_clusters, {ghosts = cluster})
			end
			budget = budget - math.max(#cluster, 1)
		end
		job.group = job.group + 1
	end
	return true
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
function ghost_control.is_any_car_present()
	if next(storage.cars) ~= nil then
		return true
	end
	for _, garage in pairs(storage.garages) do
		if garage.valid and garage_control.has_parked_car(garage) then
			return true
		end
	end
	return false
end

-- A pending cluster keeps what the assignment asks again and again: its centroid, mode,
-- surface and trunk slots (nothing is added to a cluster once it is pending). They are
-- measured on first use and renewed by refresh_cluster, so a ghost that has gone since can
-- make them a little stale, which only changes the order in which clusters and cars are
-- paired. Before a cluster is given to a car, refresh_cluster drops its gone ghosts.

-- Measures the cluster again: drops its invalid ghosts and caches centroid, mode and
-- surface. Returns the centroid and the number of valid ghosts (nil, 0 if none is left).
local function refresh_cluster(cluster)
	local centroid, count = ghost_control.compute_centroid(cluster.ghosts)
	cluster.centroid = centroid
	cluster.mode = centroid and get_mode(cluster.ghosts) or nil
	local _, ghost = next(cluster.ghosts)
	cluster.surface = ghost and ghost.surface or nil
	return centroid, count
end

-- Centroid of a cluster, or nil if it holds no valid ghost.
local function get_cluster_centroid(cluster)
	if not cluster.centroid then
		refresh_cluster(cluster)
	end
	return cluster.centroid
end

-- What a cluster does with its ghosts (see get_target_mode), or nil.
local function get_cluster_mode(cluster)
	if not cluster.mode then
		refresh_cluster(cluster)
	end
	return cluster.mode
end

-- Phase (see PHASE) of a cluster, or nil if it holds no valid ghost.
local function get_cluster_phase(cluster)
	local mode = get_cluster_mode(cluster)
	return mode and PHASE[mode]
end

-- Surface of a cluster (its ghosts are all on one), or nil if it holds no ghost.
local function get_cluster_surface(cluster)
	if not cluster.surface then
		refresh_cluster(cluster)
	end
	return cluster.surface
end

-- The waiting cars that can take a batch, as an array of {car, x, y, surface}: no batch,
-- an empty trunk (one still carrying leftovers first unloads them, see end_wait in
-- control.lua) and a fuel that is not critical (a car stopped for lack of a charger would
-- keep the batch without being able to move). Made once per assignment pass instead of
-- once per cluster; the cars wait, so their position is kept.
function ghost_control.list_available_cars()
	local available = {}
	for id, car in pairs(storage.cars) do
		if car.valid then
			local car_data = storage.car_data[id]
			if car_data.waiting.active and not car_data.construction
				and _utils.is_cargo_empty(car)
				and not travel.is_fuel_critical(car) then
				local position = car.position
				table.insert(available, {car = car, x = position.x, y = position.y, surface = car.surface})
			end
		end
	end
	return available
end

-- Finds a car for a cluster: the closest of `available` (see list_available_cars;
-- the car is taken out of it), otherwise a car released from the closest garage that
-- holds one. Returns nil if there is none, or if the cluster has no valid ghost left.
function ghost_control.find_available_car(cluster, available)
	local centroid = get_cluster_centroid(cluster)
	if not centroid then
		return nil
	end
	local surface = get_cluster_surface(cluster)

	local best_index, best_distance
	for index, entry in ipairs(available) do
		if entry.surface == surface then
			local distance = util.distance(centroid, entry)
			if not best_index or distance < best_distance then
				best_index, best_distance = index, distance
			end
		end
	end
	if best_index then
		return table.remove(available, best_index).car
	end

	local garage = _utils.find_closest(storage.garages, centroid, garage_control.can_release_car, nil, surface)
	if garage then
		return garage_control.release_car(garage)
	end

	return nil
end

-- Gives the pending cluster of the earliest phase, and the closest in it, to a
-- car that just became free. Returns true if the car got one.
function ghost_control.try_assign_pending(car)
	if storage.car_data[car.unit_number].construction
		or not _utils.is_cargo_empty(car)
		or travel.is_fuel_critical(car) then
		return false
	end

	while true do
		local best_index, best_distance, best_phase
		for index, cluster in pairs(storage.pending_clusters) do
			local centroid = get_cluster_centroid(cluster)
			if centroid and is_cluster_ready(cluster) and get_cluster_surface(cluster) == car.surface then
				local distance = util.distance(car.position, centroid)
				local phase = get_cluster_phase(cluster)
				if not best_index or phase < best_phase or (phase == best_phase and distance < best_distance) then
					best_index = index
					best_distance = distance
					best_phase = phase
				end
			end
		end
		if not best_index then
			return false
		end

		local cluster = table.remove(storage.pending_clusters, best_index)
		local _, count = refresh_cluster(cluster)
		if count > 0 then
			ghost_control.assign_cluster(car, cluster)
			return true
		end
		-- Every ghost of it is gone: it is dropped, and the next best one is looked for.
	end
end

-- Looks again at the pending clusters, config.selection_ghosts_per_tick ghosts per tick (the
-- ghosts of a big pool are many to read): drops the empty clusters and renews the caches.
-- A pass starts every config.long_delay (`start`) and goes on over the next ticks until the
-- last cluster, kept in storage.refresh_index.
function ghost_control.refresh_pending_clusters(start)
	local pending = storage.pending_clusters
	local index = storage.refresh_index
	if start then
		index = 1
	end
	if not index then
		return
	end
	local budget = config.selection_ghosts_per_tick
	while budget > 0 and index <= #pending do
		local _, count = refresh_cluster(pending[index])
		if count == 0 then
			table.remove(pending, index)
		else
			index = index + 1
		end
		budget = budget - math.max(count, 1)
	end
	storage.refresh_index = index <= #pending and index or nil
end

-- Offers every pending cluster to the available cars, earliest phase first. A
-- car takes other pending clusters along (see fill_batch), so the scan starts
-- over after each assignment. Clusters with no valid ghost left are
-- dropped. Called when the player selects ghosts and every config.long_delay as
-- a fallback: that also notices a car that a player put in a garage by hand
-- (see garage_control.update_inventories), for which there is no event. Returns the
-- number of cars that got a batch, by batch mode ([mode] = count). Nothing is
-- given out while a selection is being clustered (storage.selection_job). At most
-- config.assignments_per_tick cars get one per tick (filling a batch reads
-- every ghost): then storage.assignment_backlog is set, and on_tick calls again on the
-- next ticks (a cluster is refreshed when it is picked, as its ghosts may have gone
-- meanwhile; refresh_pending_clusters renews the others over time). A garage lets
-- out at most config.garage_exit.exits cars per config.medium_delay: the clusters
-- that wait for it are offered again at storage.assignment_wake_tick.
function ghost_control.retry_pending_clusters()
	local assigned = {}
	if storage.selection_job then
		return assigned -- the clusters are still being made: the batches are filled once all exist
	end
	-- The budget is shared by every call of the tick.
	if storage.assignment_tick ~= game.tick then
		storage.assignment_tick, storage.assignment_count = game.tick, 0
	end
	local budget = config.assignments_per_tick - storage.assignment_count
	storage.assignment_backlog = budget <= 0
	if budget <= 0 then
		return assigned
	end
	local available = ghost_control.list_available_cars()
	for phase = 1, PHASE.network do -- network is the last phase
		local index = 1
		while index <= #storage.pending_clusters do
			local cluster = storage.pending_clusters[index]
			if get_cluster_phase(cluster) ~= phase or not is_cluster_ready(cluster) then
				index = index + 1
			else
				local car = ghost_control.find_available_car(cluster, available)
				if car then
					table.remove(storage.pending_clusters, index)
					local _, count = refresh_cluster(cluster)
					if count > 0 then
						local mode = cluster.mode --[[@as string]] -- the cluster has a valid ghost
						ghost_control.assign_cluster(car, cluster)
						assigned[mode] = (assigned[mode] or 0) + 1
						budget = budget - 1
						storage.assignment_count = storage.assignment_count + 1
						if budget == 0 then
							storage.assignment_backlog = true
							return assigned
						end
					end
					index = 1
				else
					index = index + 1 -- another cluster may be on a surface that has a car
				end
			end
		end
	end
	-- Clusters left for lack of a car may wait for a garage whose window of exits is full:
	-- on_tick looks again when the first of them reopens, not only every long_delay.
	storage.assignment_wake_tick = #storage.pending_clusters > 0 and garage_control.get_next_release_tick() or nil
	return assigned
end

-- Trunk slots a set of items ([item key] = count) takes.
local function count_items_slots(items)
	local slots = 0
	for key, count in pairs(items) do
		local prototype = prototypes.item[_utils.split_item_key(key)]
		slots = slots + math.ceil(count / (prototype and prototype.stack_size or 1))
	end
	return slots
end

-- Trunk slots the load of a cluster takes (see compute_load).
local function count_cluster_slots(cluster)
	local load = {}
	for _, ghost in pairs(cluster.ghosts) do
		add_counts(load, ghost_control.compute_load(ghost))
	end
	return count_items_slots(load)
end

-- Adds a cluster to the batch of a car. The entry remembers the load and the
-- needs of each ghost: once a ghost is gone, its entity cannot tell any more
-- (see drop_ghost_items). `items` is the load of the cluster, `needs` what it
-- must collect.
local function add_cluster(car_id, construction, cluster)
	local entry = {ghosts = {}, items = {}, needs = {}}
	for _, ghost in pairs(cluster.ghosts) do
		local id = ghost_control.get_id(ghost)
		local record = {items = ghost_control.compute_load(ghost), needs = ghost_control.compute_needs(ghost)}
		add_counts(entry.items, record.items)
		add_counts(entry.needs, record.needs)
		construction.ghosts[id] = ghost
		entry.ghosts[id] = record
		storage.ghost_to_car[id] = car_id
	end
	add_counts(construction.items_needed, entry.needs)
	table.insert(construction.clusters, entry)
end

-- Adds to the batch of a car the closest pending clusters of its mode that still
-- fit in its trunk. Each cluster keeps its own slots: the slots of the batch are the sum of
-- the slots of its clusters, never shared.
function ghost_control.fill_batch(car)
	local construction = storage.car_data[car.unit_number].construction
	local mode = construction.mode
	local reserved = 0
	for _, entry in ipairs(construction.clusters) do
		reserved = reserved + count_items_slots(entry.items)
	end
	local capacity = _utils.get_upgrade(car.force, "cargo")
	-- Slots of a pending cluster, counted once (they come from the loads of its ghosts,
	-- which a refresh drops with the ghosts that have gone).
	local function get_slots(cluster)
		if not cluster.slots then
			refresh_cluster(cluster)
			cluster.slots = count_cluster_slots(cluster)
		end
		return cluster.slots
	end

	-- Centroid of the batch, kept as a sum so that adding a cluster does not measure every ghost again.
	local origin, count_in_batch = ghost_control.compute_centroid(construction.ghosts)
	if not origin then
		return
	end
	local sum_x, sum_y = origin.x * count_in_batch, origin.y * count_in_batch
	local surface = car.surface

	while true do
		origin = {x = sum_x / count_in_batch, y = sum_y / count_in_batch}
		local best_index, best_distance
		for index, cluster in ipairs(storage.pending_clusters) do
			local centroid = get_cluster_centroid(cluster)
			if centroid and is_cluster_ready(cluster) and get_cluster_surface(cluster) == surface
				and get_cluster_mode(cluster) == mode
				and reserved + get_slots(cluster) <= capacity then
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
		-- Its ghosts may have gone since the caches were made: an empty cluster is dropped.
		local centroid, count = refresh_cluster(cluster)
		if centroid then
			reserved = reserved + get_slots(cluster)
			add_cluster(car.unit_number, construction, cluster)
			sum_x, sum_y = sum_x + centroid.x * count, sum_y + centroid.y * count
			count_in_batch = count_in_batch + count
		end
	end
end

-- Makes a cluster the batch of a car, adds the pending clusters that fit next
-- to it, and gets the car going.
function ghost_control.assign_cluster(car, cluster)
	local car_data = storage.car_data[car.unit_number]
	car_data.construction = {
		ghosts = {}, items_needed = {}, clusters = {}, site = nil, missing_since = nil,
		alerted_items = {}, failed_attempts = {}, mode = get_mode(cluster.ghosts),
	}
	add_cluster(car.unit_number, car_data.construction, cluster)
	car_data.flee.count = 0 -- a new batch: the flights of the last one are forgotten
	car_data.waiting.active = false

	ghost_control.fill_batch(car)

	ghost_control.proceed(car)
end

-- ============================================================
-- Supply chests
-- ============================================================

-- A chest and every supply chest on its surface within config.chest_group_radius of it:
-- reaching one of them gives access to all.
function ghost_control.find_chest_group(chest)
	local group = {chest}
	for id, other in pairs(storage.supply_chests) do
		if other.valid then
			if other ~= chest and other.surface == chest.surface and util.distance(chest.position, other.position) <= config.chest_group_radius then
				table.insert(group, other)
			end
		else
			_utils.release_entity("chest", id)
		end
	end
	return group
end

local function can_group_supply(group, items)
	for _, chest in pairs(group) do
		local inventory = chest.get_inventory(defines.inventory.chest)
		for key in pairs(items) do
			if _utils.get_item_count(inventory, key) > 0 then
				return true
			end
		end
	end
	return false
end

-- Closest supply chest whose group holds at least one of the needed items, or nil.
function ghost_control.find_supply_chest(car, items_needed)
	return _utils.find_closest(storage.supply_chests, car.position, function(chest)
		return can_group_supply(ghost_control.find_chest_group(chest), items_needed)
	end, "chest", car.surface)
end

-- ============================================================
-- Running a batch
-- ============================================================

local function alert_missing_items(car, construction)
	for key in pairs(construction.items_needed) do
		local item_name, quality = _utils.split_item_key(key)
		local item_text = prototypes.item[item_name].localised_name
		local message = quality
			and {"autonomous-car-messages.alert-missing-item-quality", item_text, prototypes.quality[quality].localised_name}
			or {"autonomous-car-messages.alert-missing-item", item_text}
		_utils.alert_once(construction.alerted_items, key, car.force, car, message, item_name)
	end
end

local function alert_build_failed(car, ghost)
	_utils.alert(car.force, ghost,
		{"autonomous-car-messages.alert-build-failed", config.max_revive_attempts}, config.names.car)
end

-- Puts back in the pending pool the clusters of a batch whose items are not all
-- on board, when at least one other cluster is complete: that one can be built
-- meanwhile. Items are given to the clusters in order, which is also the order
-- they were added in. Returns true if clusters went back.
local function release_unsupplied_clusters(construction)
	-- What is on board for the needs of the clusters, and what is left of it as it is given out.
	local on_board, left = {}, {}
	for _, entry in ipairs(construction.clusters) do
		add_counts(on_board, entry.needs)
	end
	for key, count in pairs(on_board) do
		on_board[key] = count - (construction.items_needed[key] or 0)
		left[key] = on_board[key]
	end

	local supplied, unsupplied = {}, {}
	for _, entry in ipairs(construction.clusters) do
		local complete = true
		for key, count in pairs(entry.needs) do
			local given = math.min(count, left[key])
			left[key] = left[key] - given
			complete = complete and given == count
		end
		table.insert(complete and supplied or unsupplied, entry)
	end
	if #supplied == 0 or #unsupplied == 0 then
		return false
	end

	for _, entry in ipairs(unsupplied) do
		travel.requeue_cluster(construction, entry)
	end
	construction.clusters = supplied

	-- What the remaining clusters still lack; the items already on board stay there.
	local remaining = {}
	for _, entry in ipairs(supplied) do
		add_counts(remaining, entry.needs)
	end
	construction.items_needed = {}
	for key, count in pairs(remaining) do
		local lacking = count - (on_board[key] or 0)
		if lacking > 0 then
			construction.items_needed[key] = lacking
		end
	end
	return true
end

-- True if a target of an earlier phase than the batch is left on the surface of
-- the car, in a batch or in the pending pool. A target whose mark was cancelled
-- (is_target) does not count.
local function is_waiting_for_phase(car, construction)
	local phase = PHASE[construction.mode]
	for _, target in pairs(storage.ghosts) do
		if target.valid and target.surface == car.surface and ghost_control.is_target(target)
			and PHASE[ghost_control.get_target_mode(target)] < phase then
			return true
		end
	end
	return false
end

-- The batch has its items but must wait for an earlier phase. If it has waited
-- config.long_delay and an earlier cluster is pending (no car was free for it),
-- the batch goes back to the pending pool, and the car, free again, can take that
-- cluster after unloading.
local function wait_for_phase(car, car_data)
	local construction = car_data.construction
	construction.blocked_since = construction.blocked_since or game.tick
	if game.tick - construction.blocked_since >= config.long_delay then
		for _, cluster in pairs(storage.pending_clusters) do
			local phase = get_cluster_phase(cluster)
			if phase and phase < PHASE[construction.mode] and get_cluster_surface(cluster) == car.surface then
				travel.requeue_construction(car_data)
				break
			end
		end
	end
	_utils.start_waiting(car_data)
end

-- Position of an ammo item in config.ammo_items (1 = strongest); an item not in the
-- list ranks first, so a car never swaps it away.
local function get_ammo_rank(name)
	for rank, item in ipairs(config.ammo_items) do
		if item == name then
			return rank
		end
	end
	return 0
end

-- Strongest ammo of config.ammo_items held by the chests of `group`, or nil.
local function find_best_ammo(group)
	for _, name in ipairs(config.ammo_items) do
		for _, member in pairs(group) do
			if member.get_inventory(defines.inventory.chest).get_item_count{name = name, quality = "normal"} > 0 then
				return name
			end
		end
	end
	return nil
end

-- True if the chests of `group` have room for the whole stack `ammo` ({name, quality, count}).
local function can_store(group, ammo)
	for _, member in pairs(group) do
		local inventory = member.get_inventory(defines.inventory.chest)
		if inventory.can_insert{name = ammo.name, quality = ammo.quality, count = ammo.count} then
			return true
		end
	end
	return false
end

-- What a car may take from the supply chests of `group` to refill its battery slot
-- and, once armed, its ammo slot: a list of {name, quality, wanted, insert} for the
-- slots that are not full. The ammo is the strongest type the group holds when the
-- slot is empty or holds a weaker type (`swap`: the weaker ammo goes back to the
-- chest first), else the type already in the slot.
local function compute_restock(car, group)
	local wanted = {}
	local batteries = prototypes.item[config.battery_item].stack_size - _utils.get_battery_count(car)
	if batteries > 0 then
		table.insert(wanted, {name = config.battery_item, quality = "normal", wanted = batteries, insert = function(count)
			return _utils.insert_batteries(car, count)
		end})
	end
	if _utils.is_armed(car) then
		local ammo = _utils.get_ammo(car)
		local best = find_best_ammo(group)
		local swap = false
		if best and (not ammo or (ammo.name ~= best and get_ammo_rank(best) < get_ammo_rank(ammo.name) and can_store(group, ammo))) then
			swap = ammo ~= nil
			ammo = {name = best, quality = "normal", count = 0}
		end
		if ammo then
			local missing = prototypes.item[ammo.name].stack_size - ammo.count
			if missing > 0 then
				table.insert(wanted, {name = ammo.name, quality = ammo.quality, wanted = missing, swap = swap, insert = function(count)
					return _utils.insert_ammo(car, ammo, count)
				end})
			end
		end
	end
	return wanted
end

-- Closest supply chest whose group holds something the car's battery or ammo slot
-- lacks, or nil (also nil when both are full).
function ghost_control.find_restock_chest(car)
	return _utils.find_closest(storage.supply_chests, car.position, function(chest)
		local group = ghost_control.find_chest_group(chest)
		for _, item in pairs(compute_restock(car, group)) do
			for _, member in pairs(group) do
				if member.get_inventory(defines.inventory.chest).get_item_count{name = item.name, quality = item.quality} > 0 then
					return true
				end
			end
		end
		return false
	end, "chest", car.surface)
end

-- Decides the next step of a car's batch: end it if no ghost is left, drive to
-- the site once every item is on board and no earlier phase is left (wait
-- otherwise), otherwise fetch items from a supply chest, or wait with an alert
-- if no chest holds any. After config.long_delay
-- of that wait the clusters still lacking items go back to the pending pool and
-- the car builds the others. Called on assignment, after each chest stop, and
-- by the waiting loop of control.lua.
function ghost_control.proceed(car)
	local car_data = storage.car_data[car.unit_number]
	local construction = car_data.construction
	if not construction then
		return
	end

	-- A car that has just left its garage first tops up its batteries and ammo, if a chest has
	-- some (restock then goes on with the batch through end_wait). The flag stays up until the
	-- car reaches the chest: a car leaving with a low tank is sent to a charger first, which
	-- cancels this trip (travel.handle_critical_fuel), and it comes back here afterwards.
	if car_data.just_left_garage then
		local chest = ghost_control.find_restock_chest(car)
		if chest then
			if travel.set_destination(car, chest, {type = "restock"}) then
				return
			end
		end
		car_data.just_left_garage = false
	end

	if next(construction.ghosts) == nil then
		ghost_control.finish(car)
	elseif next(construction.items_needed) == nil then
		construction.missing_since = nil
		if is_waiting_for_phase(car, construction) then
			wait_for_phase(car, car_data)
		else
			construction.blocked_since = nil
			ghost_control.go_to_site(car)
		end
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

-- Puts the ammo of the car's slot into the chests of `group` to make room for a
-- stronger type. Returns false (and keeps the ammo) when the chests cannot take it all.
local function swap_ammo_back(car, group)
	local ammo = _utils.remove_ammo(car)
	if not ammo then
		return true
	end
	local remaining = ammo.count
	for _, member in pairs(group) do
		if remaining > 0 then
			remaining = remaining - member.get_inventory(defines.inventory.chest).insert{name = ammo.name, quality = ammo.quality, count = remaining}
		end
	end
	if remaining > 0 then
		_utils.insert_ammo(car, ammo, remaining)
		return false
	end
	return true
end

-- "restock" task: the car reached the supply chest `chest`. Takes as many batteries
-- and as much ammo as its slots hold (see compute_restock), then goes on (the car is
-- idle and about to park: its wait is already over, end_wait sends it to its garage).
function ghost_control.restock(car, chest)
	storage.car_data[car.unit_number].just_left_garage = false
	if chest and chest.valid then
		local group = ghost_control.find_chest_group(chest)
		for _, item in pairs(compute_restock(car, group)) do
			if item.swap and not swap_ammo_back(car, group) then
				item.wanted = 0
			end
			for _, member in pairs(group) do
				if item.wanted <= 0 then
					break
				end
				local inventory = member.get_inventory(defines.inventory.chest)
				local count = math.min(item.wanted, inventory.get_item_count{name = item.name, quality = item.quality})
				if count > 0 then -- a chest of the group without the item is skipped (remove needs a positive count)
					local taken = inventory.remove{name = item.name, quality = item.quality, count = count}
					local inserted = item.insert(taken)
					if inserted < taken then
						inventory.insert{name = item.name, quality = item.quality, count = taken - inserted}
					end
					item.wanted = item.wanted - inserted
				end
			end
		end
	end
	_utils.start_waiting(storage.car_data[car.unit_number], game.tick - config.idle_delay)
end

-- "collect" task: the car reached the supply chest `chest`. Takes what it still
-- needs from the whole group of that chest, then decides the next step.
function ghost_control.collect_items(car, chest)
	local construction = storage.car_data[car.unit_number].construction

	if construction and chest and chest.valid then
		local trunk = car.get_inventory(defines.inventory.car_trunk)
		for _, member in pairs(ghost_control.find_chest_group(chest)) do
			local inventory = member.get_inventory(defines.inventory.chest)
			for key, needed in pairs(construction.items_needed) do
				local available = _utils.get_item_count(inventory, key)
				if available > 0 then
					local inserted = trunk.insert(_utils.make_stack(key, math.min(available, needed)))
					if inserted > 0 then
						inventory.remove(_utils.make_stack(key, inserted))
						local remaining = needed - inserted
						construction.items_needed[key] = remaining > 0 and remaining or nil
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
-- cluster, "elsewhere"). Invalid ghosts are removed from the batch. Without a
-- cluster (choosing where to go), a landfill batch only considers the tile
-- ghosts next to land: the car stops there, and builds the whole cluster from
-- that stop.
function ghost_control.find_nearest_ready_ghost(car, cluster)
	local construction = storage.car_data[car.unit_number].construction
	local best, best_distance
	local any_valid = false
	local needs_land = not cluster and construction.mode == "landfill"

	for id, ghost in pairs(construction.ghosts) do
		if ghost.valid then
			any_valid = true
			local attempt = construction.failed_attempts[id]
			if (not cluster or cluster.ghosts[id]) and (not attempt or game.tick >= attempt.retry_tick)
					and (not needs_land or is_next_to_land(ghost)) then
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

-- Puts the items of the insert plan of a revived ghost in its inventories, taking
-- them from the trunk. A slot that does not take its item leaves it in the trunk
-- (a surplus, deposited at the end of the batch).
local function insert_requests(trunk, entity, plans)
	for _, plan in pairs(plans) do
		local name = plan.id.name
		local key = _utils.make_item_key(type(name) == "string" and name or name.name, plan.id.quality)
		for _, position in pairs(plan.items.in_inventory or {}) do
			local inventory = entity.get_inventory(position.inventory)
			local stack = inventory and inventory[position.stack + 1] -- 0-based in the plan
			local count = position.count or 1
			if stack and not stack.valid_for_read and stack.set_stack(_utils.make_stack(key, count)) then
				trunk.remove(_utils.make_stack(key, count))
			end
		end
	end
end

-- Builds a ghost with an item from the car trunk. Returns false if the revive
-- failed, usually because something - often the car itself - is in the way.
function ghost_control.revive_ghost(car, ghost)
	local key = ghost_control.get_ghost_item(ghost)
	if not key then
		return true -- no item places this ghost: count it as done, so it is not retried forever
	end

	local trunk = car.get_inventory(defines.inventory.car_trunk)
	if _utils.get_item_count(trunk, key) <= 0 then
		return false
	end
	local requests = compute_requests(ghost)
	for request, count in pairs(requests) do
		if _utils.get_item_count(trunk, request) < count then
			return false
		end
	end
	local plans = ghost.type == "entity-ghost" and ghost.insert_plan or {}

	-- revive() returns nil when it fails.
	local collided, entity, proxy = ghost.revive{raise_revive = true}
	if not collided then
		return false
	end
	trunk.remove(_utils.make_stack(key, 1))
	if entity and entity.valid then
		insert_requests(trunk, entity, plans)
	end
	if proxy and proxy.valid then
		proxy.destroy() -- the car delivered the requests itself
	end
	return true
end

-- Mines an entity marked for deconstruction into the car trunk; a cliff is
-- destroyed instead, using one cliff explosive of the trunk (no explosion is shown).
-- Returns false if that failed, usually because the items do not fit in the trunk
-- (or the explosive is missing). An entity that is no longer marked counts as done.
function ghost_control.deconstruct_entity(car, entity)
	if not entity.to_be_deconstructed() then
		return true
	end
	if entity.type == "cliff" then
		local trunk = car.get_inventory(defines.inventory.car_trunk)
		local key = entity.prototype.cliff_explosive_prototype
		if _utils.get_item_count(trunk, key) < 1 then
			return false
		end
		trunk.remove(_utils.make_stack(key, 1))
		entity.destroy{raise_destroy = true}
		return true
	end
	return entity.mine{inventory = car.get_inventory(defines.inventory.car_trunk), raise_destroyed = true}
end

-- Items held by all the inventories of an entity: [name .. "/" .. quality] =
-- {name, quality, count}. Fluids and item data other than quality are ignored.
local function count_contents(entity)
	local contents = {}
	for index = 1, entity.get_max_inventory_index() do
		local inventory = entity.get_inventory(index)
		if inventory then
			for _, item in pairs(inventory.get_contents()) do
				local key = item.name .. "/" .. item.quality
				contents[key] = contents[key] or {name = item.name, quality = item.quality, count = 0}
				contents[key].count = contents[key].count + item.count
			end
		end
	end
	return contents
end

-- Puts a stack ({name, quality, count}) in the trunk of the car; what does not
-- fit is spilled next to the car rather than lost (the batch reserves the room, so
-- this should not happen).
local function give_to_trunk(car, trunk, stack)
	local inserted = trunk.insert(stack)
	if inserted < stack.count then
		car.surface.spill_item_stack{position = car.position, stack = {name = stack.name, quality = stack.quality, count = stack.count - inserted}}
	end
end

-- Replaces an entity marked for upgrade by the entity it is marked to become
-- (LuaEntity.apply_upgrade: it moves the settings and as much of the contents as
-- the new entity holds, and destroys the rest, as does the old entity's item: the
-- test probe-upgrade of 2026-10-10 showed neither in the world). The item of the
-- new entity comes from the trunk, and the trunk receives the item of the old
-- entity and the contents that did not follow. Returns false if the trunk has no
-- such item or the upgrade did not happen: nothing has changed then. An entity that
-- is no longer marked counts as done.
function ghost_control.upgrade_entity(car, entity)
	if not entity.to_be_upgraded() then
		return true
	end
	local target, quality = entity.get_upgrade_target()
	local key, item_count = ghost_control.get_place_item(target, quality or entity.quality)
	local trunk = car.get_inventory(defines.inventory.car_trunk)
	if _utils.get_item_count(trunk, key) < item_count then
		return false
	end

	local before = count_contents(entity)
	local old_quality = entity.quality.name
	local products = entity.prototype.mineable_properties.products
	local replacement = entity.apply_upgrade()
	if not replacement then
		return false
	end

	trunk.remove(_utils.make_stack(key, item_count))
	-- What mining the old entity gives (a product has `amount`, or `amount_min` and
	-- `amount_max`: compute_yield reserved the same count).
	for _, product in pairs(products or {}) do
		if product.type == "item" then
			give_to_trunk(car, trunk, {name = product.name, quality = old_quality, count = product.amount or product.amount_max or 1})
		end
	end
	for name_quality, kept in pairs(count_contents(replacement)) do
		if before[name_quality] then
			before[name_quality].count = before[name_quality].count - kept.count
		end
	end
	for _, lost in pairs(before) do
		if lost.count > 0 then
			give_to_trunk(car, trunk, lost)
		end
	end
	return true
end

-- Tries to build one ghost (or mine or upgrade one entity): the nearest one of
-- the cluster the car is at that is not on a retry cooldown. Returns:
--   "built"   the ghost was placed (or the entity mined or upgraded)
--   "failed"  the revive failed: the ghost is put on cooldown for
--             config.medium_delay, or sent back to the pending pool after
--             config.max_revive_attempts failures
--   "none"    no ghost of this cluster is ready: it is done, or what is left is on cooldown
--   "empty"   the batch has no ghost left
function ghost_control.attempt_one_ghost(car)
	local construction = storage.car_data[car.unit_number].construction
	local ghost, any_valid = ghost_control.find_nearest_ready_ghost(car, construction.site)
	if not ghost then
		return any_valid and "none" or "empty"
	end

	local id = ghost_control.get_id(ghost)
	local done
	if REVIVES[construction.mode] then
		done = ghost_control.revive_ghost(car, ghost)
	elseif construction.mode == "deconstruct" then
		done = ghost_control.deconstruct_entity(car, ghost)
	else
		done = ghost_control.upgrade_entity(car, ghost)
	end
	if done then
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
		construction.failed_attempts[id] = {count = count, retry_tick = game.tick + count * config.medium_delay}
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

-- True if the batch fills water in and none of its tile ghosts is next to land:
-- the car has nowhere to stop.
local function is_stranded(construction)
	if construction.mode ~= "landfill" then
		return false
	end
	for _, ghost in pairs(construction.ghosts) do
		if ghost.valid and is_next_to_land(ghost) then
			return false
		end
	end
	return true
end

-- Sends the car to the nearest ghost it can try right now, whatever its
-- cluster: that cluster becomes the site the car builds. Building starts on
-- arrival ("building" task), never on the way. If every ghost left is on
-- cooldown the car steps back instead.
function ghost_control.go_to_site(car)
	local construction = storage.car_data[car.unit_number].construction
	local ghost, any_valid = ghost_control.find_nearest_ready_ghost(car)
	if ghost then
		construction.site = find_cluster(construction, ghost_control.get_id(ghost))
		-- Recharges first if the car could not get back to a charger afterwards: this
		-- is also what lets it recharge between two clusters.
		travel.set_destination(car, ghost, {type = "building"})
	elseif any_valid then
		if is_stranded(construction) then
			ghost_control.abandon(car, {"autonomous-car-messages.alert-abandoned-shore"})
		else
			ghost_control.step_back(car)
		end
	else
		ghost_control.finish(car)
	end
end

-- Called every tick while the car is stopped at its site: tries one ghost of the
-- site every config.build_interval ticks (more or less with the build speed research), so the batch goes up one entity at a
-- time. When none of them is ready, the car goes on to the next cluster, or steps
-- back if only ghosts on cooldown are left (see go_to_site).
function ghost_control.building_tick(car, tick)
	local car_data = storage.car_data[car.unit_number]
	if tick < car_data.building.next_attempt_tick then
		return
	end
	car_data.building.next_attempt_tick = tick + config.build_interval / _utils.get_upgrade(car.force, "build_speed")

	local construction = car_data.construction
	if not construction or next(construction.ghosts) == nil then
		ghost_control.finish(car)
	elseif ghost_control.attempt_one_ghost(car) == "none" then
		ghost_control.go_to_site(car)
	end
end

-- True if a group of supply chests has room for at least one of the items of
-- `trunk`.
local function can_group_store(group, trunk)
	for key in pairs(_utils.get_cargo_contents(trunk)) do
		for _, chest in pairs(group) do
			if chest.get_inventory(defines.inventory.chest).can_insert(_utils.make_stack(key, 1)) then
				return true
			end
		end
	end
	return false
end

-- Closest supply chest whose group has room for something the car carries, or nil. A return
-- chest (emptied by the logistic robots) comes first, then any other.
function ghost_control.find_chest_with_room(car)
	local trunk = car.get_inventory(defines.inventory.car_trunk)
	local function has_room(chest)
		return can_group_store(ghost_control.find_chest_group(chest), trunk)
	end
	return _utils.find_closest(storage.supply_chests, car.position, function(chest)
		return chest.name == config.names.return_chest and has_room(chest)
	end, "chest", car.surface) or _utils.find_closest(storage.supply_chests, car.position, has_room, "chest", car.surface)
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
	if _utils.is_cargo_empty(car) then
		_utils.alert_reset(car_data.alerts, "supply_full")
		return false
	end
	local chest = ghost_control.find_chest_with_room(car)
	if not chest then
		_utils.alert_once(car_data.alerts, "supply_full", car.force, car,
			{"autonomous-car-messages.alert-supply-full"},
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
		local group = {}
		for _, member in pairs(ghost_control.find_chest_group(chest)) do
			table.insert(group, member.name == config.names.return_chest and 1 or #group + 1, member) -- the return chests first
		end
		for _, member in ipairs(group) do
			local inventory = member.get_inventory(defines.inventory.chest)
			for key, count in pairs(_utils.get_cargo_contents(trunk)) do
				local inserted = inventory.insert(_utils.make_stack(key, count))
				if inserted > 0 then
					trunk.remove(_utils.make_stack(key, inserted))
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
	car_data.just_left_garage = false
	travel.cancel_trip(car_data)
	car_data.charge_detour_count = 0

	if not ghost_control.deposit_leftovers(car) then
		ghost_control.go_idle(car)
	end
end

-- The car abandons its task after its final stuck wait (see travel.stuck_tick),
-- or because it cannot reach its batch (go_to_site); `message` replaces the alert
-- text of the first case.
-- Its batch is abandoned completely: the ghosts are neither queued nor assigned again, so the
-- player has to select them again if the car can reach them now. The car then
-- heads back to base through the usual end of a batch: it deposits its items,
-- then waits, which sends it to charge if needed and to a garage.
function ghost_control.abandon(car, message)
	local car_data = storage.car_data[car.unit_number]
	local construction = car_data.construction

	_utils.alert(car.force, car,
		message or {"autonomous-car-messages.alert-abandoned-stuck"},
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
