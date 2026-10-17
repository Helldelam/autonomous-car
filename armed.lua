local config = require("config")
local _utils = require("_utils")

-- Armed cars. A car cannot be told to shoot by script (its shooting_state is for
-- characters only) and has nobody aboard, so a hidden turret (config.names.turret)
-- follows each car once the armed car technology is researched and fires for it.
-- The ammo slot of the car is the source of truth: the turret holds a copy, and
-- what it fires is taken from the slot.
local armed = {}

local function destroy_turret(car_data)
	if car_data.turret and car_data.turret.valid then
		car_data.turret.destroy()
	end
	car_data.turret = nil
	car_data.turret_ammo = nil
end

-- Makes the turret of a car match its state: created when the force has the
-- technology, moved onto the car, its ammo set to the content of the ammo slot
-- (less what it fired since the last call). A car that is not armed or has no ammo
-- has no turret (an empty turret shows a red warning icon).
function armed.update(car, car_data)
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

	-- What the turret fired since the last call leaves the slot of the car.
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
		destroy_turret(car_data) -- the turret fired its last magazine
	elseif inventory.get_item_count{name = ammo.name, quality = ammo.quality} ~= ammo.count then
		inventory.clear()
		inventory.insert{name = ammo.name, quality = ammo.quality, count = ammo.count}
		car_data.turret_ammo = ammo
	else
		car_data.turret_ammo = ammo
	end
end

-- Removes the turret of a car that is gone or parked.
function armed.release(car_data)
	destroy_turret(car_data)
end

return armed
