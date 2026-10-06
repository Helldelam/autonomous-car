-- Prototypes shared by the whole mod. Each entity has its own file in prototypes/.
data:extend{
	{
		type = "fuel-category",
		name = "autonomous_car_fuel"
	},
	{
		type = "item-subgroup",
		name = "autonomous_car",
		group = "logistics",
		order = "fa" -- next to transport
	},
	-- Hidden fuel item that stands for the car's battery (see the fuel helpers in _utils.lua).
	{
		type = "item",
		name = "autonomous_car_fuel",
		hidden = true,
		fuel_category = "autonomous_car_fuel",
		fuel_value = "6MJ",
		stack_size = 50,
		icon = "__autonomous-car__/graphics/fuel/icon.png",
		subgroup = "autonomous_car",
		order = "zz[fuel]",
	},
	-- Raised when a car finishes its current step (see _utils.raise_next_task).
	{
		type = "custom-event",
		name = "autonomous_car_next_task",
	}
}

require("prototypes/car.lua")
require("prototypes/charger.lua")
require("prototypes/garage.lua")
require("prototypes/chest.lua")
require("prototypes/ghost_selector.lua")
