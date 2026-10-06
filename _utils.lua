-- Shared helpers: car fuel, deque, alerts, entity cleanup and the next-task event.
local _utils = {}

-- ============================================================
-- Fuel
-- ============================================================
-- The car is electric in spirit. Its burner has no fuel slot and always burns
-- one hidden fuel item: burner.remaining_burning_fuel is the charge, and the
-- fuel value of that item is the tank capacity.

local FUEL_ITEM = "electric_cars_fuel"

-- Puts the fuel item in the car's burner. Without it the burner ignores any
-- write to remaining_burning_fuel.
function _utils.set_fuel_item(car)
	car.burner.currently_burning = FUEL_ITEM
end

-- Tank capacity. A burner that ran dry loses its fuel item, so this also puts
-- it back: call it before writing the charge.
function _utils.fuel_capacity(car)
	local burner = car.burner
	if not burner.currently_burning then
		burner.currently_burning = FUEL_ITEM
	end
	return burner.currently_burning.name.fuel_value
end

-- Charge left in the tank.
function _utils.remaining_fuel(car)
	return car.burner.remaining_burning_fuel
end

-- ============================================================
-- Deque
-- ============================================================
-- Double-ended queue: its values sit at indices head to tail - 1 of `items`.

_utils.deque = {}

function _utils.deque.new()
	return {head = 0, tail = 0, items = {}}
end

function _utils.deque.length(deque)
	return deque.tail - deque.head
end

function _utils.deque.push_front(deque, value)
	deque.head = deque.head - 1
	deque.items[deque.head] = value
end

function _utils.deque.push_back(deque, value)
	deque.items[deque.tail] = value
	deque.tail = deque.tail + 1
end

-- The deque must not be empty.
function _utils.deque.pop_front(deque)
	local value = deque.items[deque.head]
	deque.items[deque.head] = nil
	deque.head = deque.head + 1
	if _utils.deque.length(deque) == 0 then
		deque.head = 0
		deque.tail = 0
	end
	return value
end

-- ============================================================
-- Alerts
-- ============================================================

-- Prints `message` to a force and pins it on `target` as a map alert.
function _utils.alert(force, target, message, icon)
	force.print(message)
	for _, player in pairs(force.players) do
		player.add_custom_alert(target, icon, message, true)
	end
end

-- Same, but only once: `flags[key]` remembers that the alert was raised, until
-- alert_reset clears it. Keeps a retry loop from repeating the same alert.
function _utils.alert_once(flags, key, force, target, message, icon)
	if flags[key] then
		return
	end
	flags[key] = true
	_utils.alert(force, target, message, icon)
end

function _utils.alert_reset(flags, key)
	flags[key] = nil
end

-- ============================================================
-- Entity cleanup
-- ============================================================
-- control.lua registers one handler per kind of tracked entity ("car",
-- "charger", "garage", "chest"). Any module that finds a stale entity releases
-- it through here, without depending on the modules its cleanup needs.

local release_handlers = {}

function _utils.register_release_handler(kind, handler)
	release_handlers[kind] = handler
end

function _utils.release_entity(kind, id)
	release_handlers[kind](id)
end

-- ============================================================
-- Next-task event
-- ============================================================

-- Tells control.lua that a car finished its current step (it arrived, or it is
-- fully charged) and should start its next task. This is an event rather than
-- a call because control.lua sits above every other module.
function _utils.raise_next_task(car)
	script.raise_event(prototypes.custom_event.autonomous_car_next_task, {entity = car})
end

return _utils
