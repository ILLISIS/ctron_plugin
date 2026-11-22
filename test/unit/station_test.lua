local t = require("testlib")

-- A textfield raises on_gui_click when it is focused, so no click handler may share a textfield's tag
-- (the cargo editor's min/max fields used the confirm button's tag: focusing one confirmed and hid the bar).
package.preload["modules/universal_edges"] = function() return {} end
_G.prototypes = { item = {}, quality = {} } -- luacheck: ignore
_G.defines = _G.defines or { relative_gui_type = { roboport_gui = 1 }, relative_gui_position = { right = 1 }, mouse_button_type = {} } -- luacheck: ignore
local ct = require("modules/ctron_pluginv2/ct")

local added = {}
local function node(spec)
	local n = { children = {}, style = {}, spec = spec }
	n.add = function(s) local c = node(s); added[#added + 1] = s; n.children[#n.children + 1] = c; return c end
	n.clear = function() n.children = {} end
	return n
end
local state = {}
ct.gui = { state = function() return state end, here = function() return "t" end }
ct.registry = { station = function() return { entity = { valid = true } } end }
ct.logistics = { slots = function() return {} end }
local station = require("modules/ctron_pluginv2/gui/station")

t.test("no click handler shares a textfield's tag", function()
	local player = { gui = { relative = node() } }
	station.open_panel(player, { unit_number = 1, localised_name = "x", valid = true })
	local fields = 0
	for _, s in ipairs(added) do
		if s.type == "textfield" and s.tags and s.tags.host then
			fields = fields + 1
			t.expect_eq(station.on.click[s.tags.ct], nil)
		end
	end
	t.expect_eq(fields > 0, true)
end)
