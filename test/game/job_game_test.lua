local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local fx = require("modules/v2_test/ctron")

t.case("G0: a construction job on one tile completes on 2.1: the ghost is built, the constructron idle again",
	function(ctx)
		local surface, v
		local at = { 80.5, 80.5 }
		ctx.at(10, function()
			surface = fx.surface("ctron-g0")
			loop.ground(-20, -20, 120, 120, surface.name)
			fx.station(surface, 10, 10, { ["construction-robot"] = 60, ["wooden-chest"] = 5 })
			v = fx.ctron(surface, 10, 22)
			fx.ghost(surface, at[1], at[2])
		end)
		fx.wait(ctx, 11, 12000, "the ghost built and the job done", function()
			return surface.find_entity("wooden-chest", at) ~= nil and #fx.jobs(surface) == 0
		end, function()
			ctx.expect(v.valid and not storage.constructron_statuses[v.unit_number].busy, "the constructron is idle")
		end)
	end)
