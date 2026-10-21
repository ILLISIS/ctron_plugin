-- luacheck: globals ctronv2_rt
local t = require("testlib")

-- globals.lua needs ct (a plain table) and, at call time, Factorio's rcon and helpers; the bridge leaf needs UE's.
local printed
rcon = { print = function(s) printed = s end } -- luacheck: ignore
helpers = { table_to_json = function(v) return "json:" .. tostring(v.result) end } -- luacheck: ignore
package.preload["modules/universal_edges"] = function()
	return { runtime = { bridge = { channel = function() return function() end end, on = function() end } } }
end
local ct = require("modules/ctron_pluginv2/ct")
ct.fake = { two = function(a, b) return a, b end }
require("modules/ctron_pluginv2/globals")

t.test("call returns every value of the seam and prints the first", function()
	local a, b = ctronv2_rt.call("fake", "two", 1, 2)
	t.expect_eq(a, 1)
	t.expect_eq(b, 2)
	t.expect_eq(printed, "json:1")
end)

t.test("call raises on an unknown module or function", function()
	t.expect_true(not pcall(ctronv2_rt.call, "nope", "two"))
	t.expect_true(not pcall(ctronv2_rt.call, "fake", "nope"))
end)
