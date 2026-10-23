local config = require("config")

-- While a player drags the ghost selector, a line next to the cursor tells how many ghosts
-- (entity and tile), entities marked for deconstruction and entities marked for upgrade the
-- rectangle holds (pre-selection events, see send_pre_selection_events in
-- prototypes/ghost_selector.lua). The game counts them (count_entities_filtered), whatever the size
-- of the rectangle. Unlike the selection itself, the count includes what a robot network covers and
-- what a car has already: the message at the end of the selection gives what the cars took.
local selection_preview = {}

local OFFSET = {1, 1} -- tiles from the cursor

-- Takes the line of a player away.
function selection_preview.hide(event)
	local text = storage.selection_previews[event.player_index]
	if text then
		if text.valid then
			text.destroy()
		end
		storage.selection_previews[event.player_index] = nil
	end
end

-- The rectangle of a player changed (or the selection started): draws the line anew. It lasts
-- config.long_delay ticks, in case the game does not report the end of the selection (it only
-- reports pre-selection events "best effort").
function selection_preview.show(event)
	if event.item ~= config.names.ghost_selector then
		return
	end
	selection_preview.hide(event)
	local player = game.get_player(event.player_index)
	local surface, area = event.surface, event.area
	storage.selection_previews[event.player_index] = rendering.draw_text{
		text = {"autonomous-car-messages.selection-preview",
			surface.count_entities_filtered{area = area, type = {"entity-ghost", "tile-ghost"}, force = player.force},
			surface.count_entities_filtered{area = area, to_be_deconstructed = true},
			surface.count_entities_filtered{area = area, to_be_upgraded = true, force = player.force}},
		surface = surface, target = {type = "cursor", offset = OFFSET}, players = {player},
		color = {1, 1, 1}, scale_with_zoom = true, time_to_live = config.long_delay,
	}
end

return selection_preview
