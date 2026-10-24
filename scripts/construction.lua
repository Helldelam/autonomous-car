local util = require("util")
local config = require("config")
local _utils = require("scripts._utils")
local garage_control = require("scripts.garage")
local travel = require("scripts.travel")
local chest_control = require("scripts.chest")

-- Construction: tracking targets ("ghosts": entity or tile ghosts, entities marked for deconstruction
-- or upgrade), clusters, assignment, batches. One mode per batch; phases in PHASE order, a batch
-- collects at once but leaves for its site once no earlier phase is left on its surface.
--
-- Pending cluster: {ghosts = {ghost, ...}}, one type, fits a trunk. car_data.construction (batch):
--   ghosts          [id] = target still to do, all clusters
--   items_needed    [item key] = count still to collect
--   clusters        {ghosts = {[id] = {items = load, needs = needs}}, items, needs}; entries of done
--                   ghosts stay, items and needs are kept up to date. needs: to collect; load: slots
--                   reserved, needs plus the worst case of what mining or replacing gives back
--   site            entry being built, nil before the first stop
--   missing_since   tick the wait for missing items began
--   alerted_items   alert_once flags
--   failed_attempts [id] = {count, retry_tick}
--   mode            "build", "landfill", "deconstruct", "upgrade" or "network"
--   blocked_since   tick the wait for an earlier phase began
-- Every function is on the table: any order of calls, counted by the harness.
local ghost_control = {}

-- ============================================================
-- Tracking
-- ============================================================

-- unit_number, or surface, name and position (trees, rocks).
function ghost_control.get_id(ghost)
	return ghost.unit_number or (ghost.surface.index .. ":" .. ghost.name .. "@" .. ghost.position.x .. "," .. ghost.position.y)
end

local function is_on_water(entity)
	return entity.surface.get_tile(entity.position).collides_with("player")
end

-- One of the eight tiles around is land: the car stops there (revive needs no reach).
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

-- landfill: tile ghost on water; network: roboport ghost (last).
function ghost_control.get_target_mode(entity)
	if entity.type == "tile-ghost" then
		return is_on_water(entity) and "landfill" or "build"
	elseif entity.type == "entity-ghost" then
		return entity.ghost_type == "roboport" and "network" or "build"
	end
	return entity.to_be_deconstructed() and "deconstruct" or "upgrade"
end

-- A mode waits for every lower number.
local PHASE = {deconstruct = 1, landfill = 2, upgrade = 3, build = 3, network = 4}

-- Ghosts revived with an item.
local REVIVES = {build = true, landfill = true, network = true}

-- A ghost; marked for deconstruction and minable, or a cliff; marked for an upgrade to another
-- entity or quality that an item places.
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

-- From the first valid ghost (a mark cancelled later does not change it).
local function get_mode(ghosts)
	for _, ghost in pairs(ghosts) do
		if ghost.valid then
			return ghost_control.get_target_mode(ghost)
		end
	end
	return nil
end

-- Unless in a robot network or tracked already; true if newly tracked.
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
	-- only on_object_destroyed reports every way a ghost goes; without unit_number, by registration
	local registration = script.register_on_object_destroyed(ghost)
	if not ghost.unit_number then
		storage.target_by_registration[registration] = id
	end
	return true
end

-- Entry holding `id`, built or not.
local function find_cluster(construction, id)
	for _, entry in ipairs(construction.clusters) do
		if entry.ghosts[id] then
			return entry
		end
	end
	return nil
end

local function add_counts(into, counts)
	for key, count in pairs(counts) do
		into[key] = (into[key] or 0) + count
	end
end

-- A count that reaches 0 is dropped.
local function remove_counts(from, counts)
	for key, count in pairs(counts) do
		local left = (from[key] or 0) - count
		from[key] = left > 0 and left or nil
	end
end

-- A ghost gone unbuilt: its items are no longer needed (those collected: deposited at the end).
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

-- Out of its car's batch, which ends with its last ghost.
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
	if construction.ghosts[id] then -- not revived by the car itself
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

-- Alone, not before very_long_delay (else handed at once to car after car).
function ghost_control.requeue_ghost(ghost)
	storage.ghost_to_car[ghost_control.get_id(ghost)] = nil
	if ghost.valid then
		table.insert(storage.pending_clusters, {ghosts = {ghost}, not_before = game.tick + config.very_long_delay})
	end
end

local function is_cluster_ready(cluster)
	return not cluster.not_before or game.tick >= cluster.not_before
end

-- ============================================================
-- Clusters
-- ============================================================

-- Item key and count that place `prototype`, or nil.
function ghost_control.get_place_item(prototype, quality)
	local items = prototype.items_to_place_this
	if items and items[1] then
		return _utils.make_item_key(items[1].name, quality), items[1].count or 1
	end
	return nil
end

function ghost_control.get_ghost_item(ghost)
	-- a tile ghost has no quality
	return ghost_control.get_place_item(ghost.ghost_prototype, ghost.type == "entity-ghost" and ghost.quality or nil)
end

-- Mined into the trunk: the worst case of its products and its inventories (not belt items).
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

-- Items of its insert plan (modules...); equipment grids ignored.
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

-- To collect: the ghost's item and requests, the upgrade's item, or a cliff explosive.
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

-- Slots reserved: the needs plus what mining or replacing gives back.
function ghost_control.compute_load(ghost)
	if REVIVES[ghost_control.get_target_mode(ghost)] then
		return ghost_control.compute_needs(ghost)
	end
	local load = compute_yield(ghost)
	add_counts(load, ghost_control.compute_needs(ghost))
	return load
end

-- Slots a ghost adds to `items` (same items share stacks), and its load.
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

-- Grid of cells of cluster_radius: neighbours in the 3 × 3 cells around. A group: order (all its
-- ghosts, seeds from the end), cells ([key] = unclustered ghosts), slot and key ([ghost] = index in its
-- cell, cell key), taken ([ghost] = not in the grid), left (in the grid), next_seed (first that did
-- not fit the last cluster).
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

-- Within cluster_radius, closest first.
local function find_neighbours(group, ghost)
	local neighbours, distances = {}, {}
	local position = ghost.position
	local cell_x = math.floor(position.x / config.cluster_radius)
	local cell_y = math.floor(position.y / config.cluster_radius)
	for dx = -1, 1 do
		for dy = -1, 1 do
			local cell = group.cells[get_cell_key(cell_x + dx, cell_y + dy)]
			if cell then
				for index = #cell, 1, -1 do -- backwards: a ghost taken out is replaced by the last, already seen
					local candidate = cell[index]
					if candidate.valid then
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

-- Clusters of one type (to mine, to upgrade, network together), fitting the cargo of `force`, grown
-- breadth-first from a seed; the first ghost that does not fit seeds the next. Phases register, grid,
-- cluster share selection_ghosts_per_tick; a cluster is never cut (a tick does twice the budget at
-- worst). step_selection runs every tick until true; job.count: targets newly tracked.
function ghost_control.start_selection(entities, force)
	return {
		phase = "register",
		entities = entities,
		index = 0, -- entities read, then ghosts of the group put in the grid
		count = 0,
		by_name = {}, -- [group name] = ghosts, a group per type
		capacity = _utils.get_upgrade(force, "cargo"),
		groups = {},
		group = 1, -- being put in the grid, then clustered
	}
end

-- Returns the budget left (0 while the phase goes on).
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

-- True when its clusters all exist.
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
				break -- cannot happen
			end
			take_from_grid(group, seed)

			local cluster = {}
			if seed.valid then
				local items = {}
				local slots = 0
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

-- And the valid count; invalid ghosts are removed; nil, 0 if none.
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

-- On the map or parked.
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

-- A pending cluster caches centroid, mode, surface and slots, measured on first use and renewed by
-- refresh_cluster (stale values only change the pairing order); refreshed before it goes to a car.

-- Drops gone ghosts, caches; returns the centroid and the valid count (nil, 0 if none).
local function refresh_cluster(cluster)
	local centroid, count = ghost_control.compute_centroid(cluster.ghosts)
	cluster.centroid = centroid
	cluster.mode = centroid and get_mode(cluster.ghosts) or nil
	local _, ghost = next(cluster.ghosts)
	cluster.surface = ghost and ghost.surface or nil
	return centroid, count
end

local function get_cluster_centroid(cluster)
	if not cluster.centroid then
		refresh_cluster(cluster)
	end
	return cluster.centroid
end

local function get_cluster_mode(cluster)
	if not cluster.mode then
		refresh_cluster(cluster)
	end
	return cluster.mode
end

local function get_cluster_phase(cluster)
	local mode = get_cluster_mode(cluster)
	return mode and PHASE[mode]
end

local function get_cluster_surface(cluster)
	if not cluster.surface then
		refresh_cluster(cluster)
	end
	return cluster.surface
end

-- {car, x, y, surface} of the waiting cars without batch or visit, trunk empty, fuel not critical;
-- once per assignment pass.
function ghost_control.list_available_cars()
	local available = {}
	for id, car in pairs(storage.cars) do
		if car.valid then
			local car_data = storage.car_data[id]
			if car_data.waiting.active and not car_data.construction and not storage.chest_visits[id]
				and _utils.is_cargo_empty(car)
				and not travel.is_fuel_critical(car) then
				local position = car.position
				table.insert(available, {car = car, x = position.x, y = position.y, surface = car.surface})
			end
		end
	end
	return available
end

-- The closest of `available` (taken out), else one released by the closest garage; nil if none.
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

	local garage = _utils.find_closest("garages", centroid, garage_control.can_release_car, nil, surface)
	if garage then
		return garage_control.release_car(garage)
	end

	return nil
end

-- Earliest phase, then closest; true if the car got one.
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
		-- emptied: dropped, next one
	end
end

-- A pass from `start` (every long_delay), selection_ghosts_per_tick ghosts per tick
-- (storage.refresh_index): empty clusters dropped, caches renewed.
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

-- Every pending cluster to the available cars, earliest phase first; the scan starts over after each
-- assignment (fill_batch takes clusters along). After a selection and every long_delay (also catches a
-- car put in a garage by hand). Nothing during a selection. At most assignments_per_tick per tick
-- (storage.assignment_backlog: on_tick calls again); clusters waiting for a garage exit are offered
-- again at storage.assignment_wake_tick. Returns [mode] = cars that got a batch.
function ghost_control.retry_pending_clusters()
	local assigned = {}
	if storage.selection_job then
		return assigned
	end
	-- budget shared by every call of the tick
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
						local mode = cluster.mode --[[@as string]]
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
	-- left clusters may wait for a garage's exit window to reopen
	storage.assignment_wake_tick = #storage.pending_clusters > 0 and garage_control.get_next_release_tick() or nil
	return assigned
end

local function count_items_slots(items)
	local slots = 0
	for key, count in pairs(items) do
		local prototype = prototypes.item[_utils.split_item_key(key)]
		slots = slots + math.ceil(count / (prototype and prototype.stack_size or 1))
	end
	return slots
end

local function count_cluster_slots(cluster)
	local load = {}
	for _, ghost in pairs(cluster.ghosts) do
		add_counts(load, ghost_control.compute_load(ghost))
	end
	return count_items_slots(load)
end

-- The entry keeps each ghost's load and needs (a gone entity cannot tell them).
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

-- The closest pending clusters of its mode that fit (slots summed per cluster, never shared).
function ghost_control.fill_batch(car)
	local construction = storage.car_data[car.unit_number].construction
	local mode = construction.mode
	local reserved = 0
	for _, entry in ipairs(construction.clusters) do
		reserved = reserved + count_items_slots(entry.items)
	end
	local capacity = _utils.get_upgrade(car.force, "cargo")
	local function get_slots(cluster) -- counted once, after a refresh
		if not cluster.slots then
			refresh_cluster(cluster)
			cluster.slots = count_cluster_slots(cluster)
		end
		return cluster.slots
	end

	-- centroid kept as a sum
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
		local centroid, count = refresh_cluster(cluster) -- emptied: dropped
		if centroid then
			reserved = reserved + get_slots(cluster)
			add_cluster(car.unit_number, construction, cluster)
			sum_x, sum_y = sum_x + centroid.x * count, sum_y + centroid.y * count
			count_in_batch = count_in_batch + count
		end
	end
end

-- New batch, plus the clusters that fit, then proceed.
function ghost_control.assign_cluster(car, cluster)
	local car_data = storage.car_data[car.unit_number]
	car_data.construction = {
		ghosts = {}, items_needed = {}, clusters = {}, site = nil, missing_since = nil,
		alerted_items = {}, failed_attempts = {}, mode = get_mode(cluster.ghosts),
	}
	add_cluster(car.unit_number, car_data.construction, cluster)
	car_data.flee.count = 0
	car_data.waiting.active = false

	ghost_control.fill_batch(car)

	ghost_control.proceed(car)
end

-- ============================================================
-- Supply chests
-- ============================================================

-- The chest and the supply chests within chest_group_radius: reaching one reaches all.
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

-- Whose group holds one of the items.
function ghost_control.find_supply_chest(car, items_needed)
	return _utils.find_closest("supply_chests", car.position, function(chest)
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

-- The clusters whose items are not all on board go back, if another is complete (items given in
-- the order the clusters were added). True if some went back.
local function release_unsupplied_clusters(construction)
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

	-- what the others still lack; items on board stay
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

-- A tracked target of an earlier phase on the surface (a cancelled mark does not count).
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

-- After long_delay, with an earlier cluster pending for lack of a car, the batch goes back and the
-- car may take that cluster once unloaded.
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

-- 1 strongest; an item not listed ranks 0 (never swapped away).
local function get_ammo_rank(name)
	for rank, item in ipairs(config.ammo_items) do
		if item == name then
			return rank
		end
	end
	return 0
end

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

-- Room for the whole stack.
local function can_store(group, ammo)
	for _, member in pairs(group) do
		local inventory = member.get_inventory(defines.inventory.chest)
		if inventory.can_insert{name = ammo.name, quality = ammo.quality, count = ammo.count} then
			return true
		end
	end
	return false
end

-- {name, quality, wanted, insert} per slot not full: batteries, and once armed ammo (the strongest of
-- the group if the slot is empty or weaker, `swap`: the weaker goes back first; else the same type).
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

-- Whose group holds something the battery or ammo slot lacks.
function ghost_control.find_restock_chest(car)
	return _utils.find_closest("supply_chests", car.position, function(chest)
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

-- Next step of a batch: finish, site (items on board, no earlier phase), supply chest, or wait with
-- an alert (after long_delay the clusters lacking items go back). On assignment, after each chest,
-- from end_wait.
function ghost_control.proceed(car)
	local car_data = storage.car_data[car.unit_number]
	local construction = car_data.construction
	if not construction then
		return
	end

	-- out of a garage: restock first; kept until the chest is reached (a charger detour cancels the trip)
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

-- The slot's ammo into the group; false (ammo kept) if it does not all fit.
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

-- Arrival for collect, deposit or restock: the group's hatches open, the car waits transfer_delay
-- (waiting, out of the batches), then update_chest_visits transfers.
function ghost_control.start_chest_visit(car, chest, task_type)
	if not (chest and chest.valid) then -- as at an empty chest
		ghost_control.end_chest_visit(car, chest, task_type)
		return
	end
	local group = ghost_control.find_chest_group(chest)
	for _, member in pairs(group) do
		chest_control.open_hatch(member)
	end
	local ready = game.tick + config.chest_door.transfer_delay
	storage.chest_visits[car.unit_number] = {car = car, chest = chest, group = group, task = task_type, ready = ready}
	_utils.start_waiting(storage.car_data[car.unit_number], ready - config.idle_delay)
end

function ghost_control.end_chest_visit(car, chest, task_type)
	if task_type == "collect" then
		ghost_control.collect_items(car, chest)
	elseif task_type == "deposit" then
		ghost_control.deposit_items(car, chest)
	else
		ghost_control.restock(car, chest)
	end
end

-- Every tick; a car no longer waiting (danger, empty battery) gets no transfer.
function ghost_control.update_chest_visits(tick)
	for id, visit in pairs(storage.chest_visits) do
		if tick >= visit.ready then
			storage.chest_visits[id] = nil
			local car = visit.car
			if car.valid then
				local car_data = storage.car_data[id]
				if car_data.waiting.active and not car_data.moving.active then
					car_data.waiting.active = false -- as on arrival
					ghost_control.end_chest_visit(car, visit.chest, visit.task)
				end
			end
			for _, member in pairs(visit.group) do
				chest_control.close_hatch(member)
			end
		end
	end
end

-- Fills the battery and ammo slots (compute_restock), then end_wait next tick.
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
				if count > 0 then -- remove needs a positive count
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

-- What is still needed, from the whole group.
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

-- Closest ghost off cooldown (of `cluster` if given), and whether any valid one is left (nothing left
-- vs all on cooldown or elsewhere); invalid ones are removed. Choosing where to go, a landfill batch
-- takes only ghosts next to land (the whole cluster is built from there).
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

-- Insert plan from the trunk; a refused item stays (deposited at the end).
local function insert_requests(trunk, entity, plans)
	for _, plan in pairs(plans) do
		local name = plan.id.name
		local key = _utils.make_item_key(type(name) == "string" and name or name.name, plan.id.quality)
		for _, position in pairs(plan.items.in_inventory or {}) do
			local inventory = entity.get_inventory(position.inventory)
			local stack = inventory and inventory[position.stack + 1] -- 0-based
			local count = position.count or 1
			if stack and not stack.valid_for_read and stack.set_stack(_utils.make_stack(key, count)) then
				trunk.remove(_utils.make_stack(key, count))
			end
		end
	end
end

-- False if it failed (often the car itself in the way).
function ghost_control.revive_ghost(car, ghost)
	local key = ghost_control.get_ghost_item(ghost)
	if not key then
		return true -- no item places it: done, not retried forever
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

	local collided, entity, proxy = ghost.revive{raise_revive = true}
	if not collided then
		return false
	end
	trunk.remove(_utils.make_stack(key, 1))
	if entity and entity.valid then
		insert_requests(trunk, entity, plans)
	end
	if proxy and proxy.valid then
		proxy.destroy() -- requests delivered by the car
	end
	return true
end

-- Into the trunk; a cliff is destroyed with a cliff explosive. False if it failed (trunk full); no
-- longer marked: done.
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

-- What does not fit is spilled (the batch reserves the room).
local function give_to_trunk(car, trunk, stack)
	local inserted = trunk.insert(stack)
	if inserted < stack.count then
		car.surface.spill_item_stack{position = car.position, stack = {name = stack.name, quality = stack.quality, count = stack.count - inserted}}
	end
end

-- apply_upgrade (settings and contents kept) with the new item from the trunk; the old item and the
-- contents that did not follow go through a buffer sized like the old inventories (apply_upgrade
-- destroys what its buffer cannot take), then to the trunk. False: nothing changed; no longer
-- marked: done.
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

	local slots = #(entity.prototype.mineable_properties.products or {})
	for index = 1, entity.get_max_inventory_index() do
		local inventory = entity.get_inventory(index)
		if inventory then
			slots = slots + #inventory
		end
	end
	local leftovers = game.create_inventory(slots)
	local replacement = entity.apply_upgrade(nil, leftovers)
	if replacement then
		trunk.remove(_utils.make_stack(key, item_count))
		for _, stack in pairs(leftovers.get_contents()) do
			give_to_trunk(car, trunk, stack)
		end
	end
	leftovers.destroy()
	return replacement ~= nil
end

-- The nearest ready ghost of the site: "built", "failed" (cooldown of failures × medium_delay, back
-- to the pool after max_revive_attempts), "none" (none ready in the site) or "empty" (batch done).
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

-- Every ghost left on cooldown: the car itself often blocks them, it backs off step_back_distance.
function ghost_control.step_back(car)
	local angle = 2 * math.pi * car.orientation
	local waypoint = {
		position = {
			x = car.position.x - math.sin(angle) * config.step_back_distance,
			y = car.position.y + math.cos(angle) * config.step_back_distance,
		},
		valid = true,
	}
	travel.begin_leg(car, waypoint)
end

-- Landfill without any ghost next to land: nowhere to stop.
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

-- The nearest ready ghost sets the site; building on arrival. All on cooldown: step back.
function ghost_control.go_to_site(car)
	local construction = storage.car_data[car.unit_number].construction
	local ghost, any_valid = ghost_control.find_nearest_ready_ghost(car)
	if ghost then
		construction.site = find_cluster(construction, ghost_control.get_id(ghost))
		-- may recharge first: also between two clusters
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

-- A ghost every build_interval / build speed; none ready: go_to_site (next cluster or step back).
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

-- Room for one of the trunk's items.
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

-- A return chest first, then any other.
function ghost_control.find_chest_with_room(car)
	local trunk = car.get_inventory(defines.inventory.car_trunk)
	local function has_room(chest)
		return can_group_store(ghost_control.find_chest_group(chest), trunk)
	end
	return _utils.find_closest("supply_chests", car.position, function(chest)
		return chest.name == config.names.return_chest and has_room(chest)
	end, "chest", car.surface) or _utils.find_closest("supply_chests", car.position, has_room, "chest", car.surface)
end

-- To the nearest chest with room (none: alert, end_wait tries again). True if the car left.
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

-- Into the group (return chests first); the rest to the next chest with room.
function ghost_control.deposit_items(car, chest)
	local trunk = car.get_inventory(defines.inventory.car_trunk)
	if chest and chest.valid then
		local group = {}
		for _, member in pairs(ghost_control.find_chest_group(chest)) do
			table.insert(group, member.name == config.names.return_chest and 1 or #group + 1, member)
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

-- A pending cluster, else end_wait next tick.
function ghost_control.go_idle(car)
	if ghost_control.try_assign_pending(car) then
		return
	end
	_utils.start_waiting(storage.car_data[car.unit_number], game.tick - config.idle_delay)
end

-- Complete or not; then leftovers or idle.
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

-- After the final stuck wait, or `message` (shore, danger): the ghosts are released (to select
-- again), then the usual end of a batch.
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
