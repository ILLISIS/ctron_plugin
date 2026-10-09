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

t.case("ctron repair filter (spec §9.1): damaging a car queues no repair chunk, damaging a wall does", function(ctx)
	ctx.at(10, function()
		local surface = fx.surface("ctron-repair")
		fx.station(surface, 10, 10)
		fx.ctron(surface, 0, 0)
		local queue = storage.repair_queue[surface.index]
		local car = surface.create_entity({ name = "car", position = { 20, 20 }, force = "player" })
		car.damage(1, "neutral")
		ctx.expect(next(queue) == nil, "no repair chunk for a damaged car")
		local wall = surface.create_entity({ name = "stone-wall", position = { 40, 40 }, force = "player" })
		wall.damage(1, "neutral")
		ctx.expect(next(queue) ~= nil, "a repair chunk for a damaged wall")
	end)
end)
