local config = require("config")
local _utils = require("scripts._utils")

-- Armed cars: a script cannot make a car shoot, so after Military a hidden turret follows each car
-- and fires a copy of its ammo slot, which is the reference (what the turret fires leaves it).
local armed = {}

local function destroy_turret(car_data)
	if car_data.turret and car_data.turret.valid then
		car_data.turret.destroy()
	end
	car_data.turret = nil
	car_data.turret_ammo = nil
end

-- Every slow_check_interval: turret on the car with the ammo of the slot; none without Military or
-- ammo (an empty turret shows a warning icon).
function armed.update(car, car_data)
	-- the ammo slot cannot be hidden: locked before Military
	_utils.set_filters(car, car.get_inventory(defines.inventory.car_ammo), function()
		return not _utils.is_armed(car) and config.names.locked_slot or nil
	end)
	if not _utils.is_armed(car) or not _utils.get_ammo(car) then
		destroy_turret(car_data)
		return
	end

	local turret = car_data.turret
	if not (turret and turret.valid) then
		turret = car.surface.create_entity{name = config.names.turret, position = car.position, force = car.force}
		if not turret then
			return
		end
		turret.destructible = false
		car_data.turret = turret
		car_data.turret_ammo = nil
	else
		turret.teleport(car.position)
	end

	local inventory = turret.get_inventory(defines.inventory.turret_ammo)
	local ammo = _utils.get_ammo(car)

	-- what it fired since the last call leaves the slot
	local last = car_data.turret_ammo
	if last and ammo and last.name == ammo.name then
		local fired = last.count - inventory.get_item_count{name = last.name, quality = last.quality}
		if fired > 0 then
			local remaining = math.max(0, ammo.count - fired)
			car.get_inventory(defines.inventory.car_ammo)[1].count = remaining
			ammo = _utils.get_ammo(car)
		end
	end

	if not ammo then
		destroy_turret(car_data) -- last magazine fired
	elseif inventory.get_item_count{name = ammo.name, quality = ammo.quality} ~= ammo.count then
		inventory.clear()
		inventory.insert{name = ammo.name, quality = ammo.quality, count = ammo.count}
		car_data.turret_ammo = ammo
	else
		car_data.turret_ammo = ammo
	end
end

-- Car gone or parked.
function armed.release(car_data)
	destroy_turret(car_data)
end

return armed
