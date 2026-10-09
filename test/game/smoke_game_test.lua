local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctron")

t.case("ctron smoke: CP runs on 2.1 with UE and CC 2.1.0 (b1 applied); a constructron built by script registers",
	function(ctx)
		ctx.at(10, function()
			ctx.expect(script.active_mods["Constructron-Continued"] == "2.1.0", "CC 2.1.0 is loaded")
			local barrier = prototypes.entity["ue-barrier"]
			ctx.expect(barrier ~= nil and not barrier.collision_mask.layers["constructron_pathing_layer"],
				"b1: UE's barrier lacks CC's pathing layer")
			ctx.expect(prototypes.entity["constructron_pathing_proxy_10"] ~= nil, "CC's pathing proxies exist")
			ctx.expect(storage.jobs ~= nil and storage.constructron_names.constructron, "CP initialised its storage")
			local surface = fx.surface("ctron-smoke")
			local v = fx.ctron(surface, 0, 0)
			ctx.expect(storage.constructrons[v.unit_number] == v, "registered")
			ctx.expect(storage.constructrons_count[surface.index] == 1 and storage.available_ctron_count[surface.index] == 1,
				"counted, and idle")
		end)
	end)
