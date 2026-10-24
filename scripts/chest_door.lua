local config = require("config")
local names = config.names

-- Hatch of a supply chest that opens while a car uses it. The sprite of the chest keeps the closed
-- hatch; while it moves, the script draws on top of it a dark interior and the hatch itself
-- (graphics/chest/<colour>-door.png), squashed in width towards its hinges, on the left. A chest
-- may be used by several cars at once: it opens with the first and closes after the last (`users`).
-- storage.chest_doors[chest id] = {chest, scale (1 closed), users, interior, door (render objects)};
-- only the chests that are open or moving are listed.
local chest_door = {}

local settings = config.chest_door
local step = (1 - settings.open_scale) / settings.move_ticks -- scale change per tick

-- Puts the hatch at `scale` (1: closed), its hinges staying where they are.
local function place(door)
	local position = door.chest.position
	door.door.target = {
		x = position.x + settings.left + settings.width * door.scale / 2,
		y = position.y + settings.top + settings.height / 2,
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

-- A car comes to use `chest`: the hatch opens, and stays open until every car that came is done.
function chest_door.begin(chest)
	local id = chest.unit_number
	local door = storage.chest_doors[id]
	if not door then
		local position = chest.position
		local target = {x = position.x + settings.left + settings.width / 2, y = position.y + settings.top + settings.height / 2}
		door = {
			chest = chest,
			scale = 1,
			users = 0,
			interior = rendering.draw_sprite{sprite = names.chest_interior, target = target, surface = chest.surface,
				render_layer = "object"},
			door = rendering.draw_sprite{sprite = chest.name .. "_door", target = target, surface = chest.surface,
				render_layer = "cargo-hatch"}, -- above the interior
		}
		storage.chest_doors[id] = door
	end
	door.users = door.users + 1
end

-- A car is done with `chest` (or gone): the hatch closes once no car is left.
function chest_door.finish(chest)
	local door = chest.valid and storage.chest_doors[chest.unit_number]
	if door then
		door.users = math.max(0, door.users - 1)
	end
end

-- Called every tick: moves the hatches that are moving, each by one step.
function chest_door.update()
	for id, door in pairs(storage.chest_doors) do
		if not door.chest.valid then
			destroy(id)
		else
			local open = door.users > 0
			local scale = open and math.max(settings.open_scale, door.scale - step) or math.min(1, door.scale + step)
			if scale ~= door.scale then
				door.scale = scale
				place(door)
			elseif scale == 1 and not open then
				destroy(id)
			end
		end
	end
end

-- Forgets the hatch of a chest that is gone.
function chest_door.release(id)
	destroy(id)
end

return chest_door
