local t = require("modules/v2_test/testlib")
-- module_exports.lua returns control.lua's lib: without CC, control.lua returns {} at its gate.
local exports = require("modules/ctron_plugin")

-- Review Focus 1: every new gridworld tile loads the plugin's module (load_plugin defaults to true), most without CC.
t.case("ctron_plugin without Constructron-Continued: the save loads, the module is an empty lib and keeps no state",
	function(ctx)
		ctx.at(2, function()
			ctx.expect(script.active_mods["Constructron-Continued"] == nil, "this run has no CC")
			ctx.expect(type(exports) == "table" and next(exports) == nil, "the module is an empty lib")
			ctx.expect(storage.jobs == nil and storage.constructron_names == nil, "and it made no state")
		end)
	end)
