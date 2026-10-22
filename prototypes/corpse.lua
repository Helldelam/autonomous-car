-- Remnants of an entity of the mod: a copy of the corpse of the entity of the game it looks like, with
-- the remnants image of the mod (graphics/<entity>/remnants, made by the make_*.py scripts) in place of
-- the original. `edit` may change the copy (size and position of the image). The entity must have its
-- icon set already.
return function(entity, source, filename, edit)
	local corpse = table.deepcopy(data.raw.corpse[source])
	corpse.name = entity.name .. "_remnants"
	corpse.localised_name = {"remnant-name", {"entity-name." .. entity.name}}
	corpse.icons = nil
	corpse.icon = entity.icon
	corpse.subgroup = nil
	corpse.order = nil
	local animations = corpse.animation[1] and corpse.animation or {corpse.animation} -- one image, or a list of variations
	for _, animation in pairs(animations) do
		animation.filename = filename
	end
	if edit then
		edit(corpse, animations)
	end
	entity.corpse = corpse.name
	data:extend{corpse}
end
