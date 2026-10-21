local t = require("modules/v2_test/testlib")
-- control.lua returns {} at its gate without CC; require hands back that same table.
local lib = require("modules/ctron_pluginv2/control")

t.case("G2 ctron_pluginv2 without Constructron-Continued: an empty lib, no state, no scheduler task", function(ctx)
	ctx.at(2, function()
		ctx.expect(script.active_mods["Constructron-Continued"] == nil, "this run has no CC")
		ctx.expect(type(lib) == "table" and next(lib) == nil, "the module is an empty lib")
		ctx.expect(storage.ctron_pluginv2 == nil, "it made no state")
		ctx.expect(ctronv2_rt.state() == "{}", "the RCON seam answers an empty summary")
		local tasks = storage.universal_edges.scheduler.tasks or {}
		ctx.expect(tasks["ctron.leg"] == nil, "no ctron.leg once task")
		for name in pairs(tasks) do
			ctx.expect(string.sub(name, 1, 6) ~= "ctron.", "no v2 scheduler task: " .. name)
		end
	end)
end)
