-- Remnants of an entity: a copy of the corpse `source` with the image `filename`; `edit` may change the
-- copy. The entity's icon must be set already.
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
		(animation.layers and animation.layers[1] or animation).filename = filename -- the first layer when there are several
	end
	if edit then
		edit(corpse, animations)
	end
	entity.corpse = corpse.name
	data:extend{corpse}
end
