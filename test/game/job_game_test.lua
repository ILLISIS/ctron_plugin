local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local fx = require("modules/v2_test/ctron")
local job = require("modules/ctron_plugin/script/job")
local util_func = require("modules/ctron_plugin/script/utility_functions")

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

t.case("R23: the destroy scan skips UE's oracle and finds a plain spawner at the same spot (biters R23)",
	function(ctx)
		local surface, oracle
		local function chunk(x, y)
			return { key = 1, surface_index = surface.index, last_update_tick = game.tick, from_tool = false,
				minimum = { x = x - 10, y = y - 10 }, maximum = { x = x + 10, y = y + 10 } }
		end
		ctx.at(10, function()
			surface = fx.surface("ctron-r23")
			surface.peaceful_mode = false
			loop.ground(-40, -40, 120, 40, surface.name)
			storage.destroy_job_toggle[surface.index] = true
			storage.destroy_min_cluster_size[surface.index] = 0
			-- the ctron run may not load UE's data mod: then the oracle is a stand-in with the oracle's name prefix
			local name = prototypes.entity["ue-oracle"] and "ue-oracle" or nil
			ctx.expect(util_func.is_ue_oracle({ name = "ue-oracle-gleba" }), "the prefix covers ue-oracle-gleba")
			ctx.expect(not util_func.is_ue_oracle({ name = "biter-spawner" }), "a biter-spawner is no oracle")
			if name then
				oracle = surface.create_entity({ name = name, position = { 0, 0 }, force = "enemy" })
				ctx.expect(not job.find_chunk_entities(chunk(0, 0), "destroy"), "an oracle alone makes no destroy chunk")
				ctx.expect(next(storage.destroy_queue[surface.index]) == nil, "and queues nothing")
				ctx.expect(oracle.valid and oracle.health == oracle.max_health, "the oracle is undamaged")
				oracle.destroy()
			else
				game.print("R23: no ue-oracle prototype in the ctron run, only the filter is tested")
			end
			surface.create_entity({ name = "biter-spawner", position = { 0, 0 }, force = "enemy" })
			ctx.expect(job.find_chunk_entities(chunk(0, 0), "destroy"), "a biter-spawner makes a destroy chunk")
			ctx.expect(next(storage.destroy_queue[surface.index]) ~= nil, "queued")
		end)
	end)
