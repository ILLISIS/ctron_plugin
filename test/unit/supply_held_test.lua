local t = require("testlib")

-- supply.missing counts what the character holds in ammo, gun and armour slots as held (issue #33).
package.preload["modules/universal_edges"] = function()
	return { runtime = { bridge = { channel = function() return function() end end, on = function() end },
		scheduler = { periodic = function() end } } }
end
_G.storage = {} -- luacheck: ignore
_G.defines = _G.defines or {} -- luacheck: ignore
defines.inventory = { character_main = 1, character_ammo = 2, character_guns = 3, character_armor = 4 } -- luacheck: ignore
defines.events = setmetatable({}, { __index = function(_, k) return k end }) -- luacheck: ignore
local supply = require("modules/ctron_pluginv2/supply")

local function inv(contents) return { get_contents = function() return contents end } end
local function char(by_inv, filters)
	return {
		get_inventory = function(which) return by_inv[which] end,
		get_requester_point = function() return { enabled = true, filters = filters } end,
	}
end
local function f(name, count) return { index = 1, name = name, quality = "normal", comparator = "=", count = count } end

t.test("missing: magazines in ammo slots and worn armour meet the request", function()
	local c = char({
		inv({ { name = "iron-plate", quality = "normal", count = 10 } }),
		inv({ { name = "firearm-magazine", quality = "normal", count = 100 } }),
		inv({}),
		inv({ { name = "light-armor", quality = "normal", count = 1 } }),
	}, { f("firearm-magazine", 100), f("light-armor", 1), f("iron-plate", 30) })
	t.expect_same(supply.missing(c), { ["iron-plate"] = { normal = 20 } })
end)
