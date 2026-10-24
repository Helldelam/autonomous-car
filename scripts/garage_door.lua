local config = require("config")
local names = config.names

-- Door of a garage that slides up when a car goes in or out. The sprite of the garage (a container
-- has no animation) keeps the closed door; while the door moves, the script draws on top of it
-- a dark interior and the door itself (graphics/garage/door.png, a sprite per step cut by prototypes/garage.lua):
-- the door slides up and what goes above its original top edge is cut off, like a rigid shutter rolling
-- into its housing. Nothing else is drawn, so the garage never changes or shakes; a closed door leaves no render
-- object. storage.garage_doors[garage id] = {garage, step (0 closed, move_ticks open), hold_until (tick),
-- interior, door (render objects)}; only the garages that are moving are listed.
local garage_door = {}

local settings = config.garage_door

-- Draws the door after `step` ticks of opening: the image without the rows above the top edge, its top edge staying where it is.
local function place(door)
	local position = door.garage.position
	door.door.sprite = names.garage_door .. "_" .. door.step
	door.door.target = {
		x = position.x + settings.x,
		y = position.y + settings.top + (settings.rows - settings.hidden_rows(door.step)) / 64 / 2,
	}
end

local function destroy(id)
	local door = storage.garage_doors[id]
	if door then
		door.interior.destroy()
		door.door.destroy()
		storage.garage_doors[id] = nil
	end
end

-- Opens the door of `garage`, holds it open for settings.hold ticks, then closes it.
function garage_door.open(garage)
	local door = storage.garage_doors[garage.unit_number]
	if not door then
		local position = garage.position
		local target = {x = position.x + settings.x, y = position.y + settings.top + settings.height / 2}
		door = {
			garage = garage,
			step = 0,
			interior = rendering.draw_sprite{sprite = names.garage_interior, target = target, surface = garage.surface,
				render_layer = "object"},
			door = rendering.draw_sprite{sprite = names.garage_door .. "_0", target = target, surface = garage.surface,
				render_layer = "cargo-hatch"}, -- above the interior (and above a car beside the garage)
		}
		storage.garage_doors[garage.unit_number] = door
	end
	door.hold_until = game.tick + settings.move_ticks + settings.hold
end

-- Called every tick: moves the doors that are moving, each by one step.
function garage_door.update(tick)
	for id, door in pairs(storage.garage_doors) do
		if not door.garage.valid then
			destroy(id)
		else
			local open = tick < door.hold_until
			local step = open and math.min(settings.move_ticks, door.step + 1) or math.max(0, door.step - 1)
			if step ~= door.step then
				door.step = step
				place(door)
			elseif step == 0 and not open then
				destroy(id)
			end
		end
	end
end

-- Forgets the door of a garage that is gone.
function garage_door.release(id)
	destroy(id)
end

return garage_door
