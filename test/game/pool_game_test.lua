local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local fx = require("modules/v2_test/ctron")

t.case("G6: a job claimed from the pool, as JSON with its integer chunk keys made strings, maps to the claimer's " ..
	"surface by name and completes there", function(ctx)
	local surface, v
	local at = { 80.5, 80.5 }
	ctx.at(10, function()
		surface = fx.surface("ctron-g6")
		loop.ground(-20, -20, 120, 120, surface.name)
		fx.station(surface, 10, 10, { ["construction-robot"] = 60, ["wooden-chest"] = 5 })
		v = fx.ctron(surface, 10, 22)
		fx.ghost(surface, at[1], at[2], true) -- quiet: only the claimed job builds it
		-- As a publisher sends one (job_processor.process_queue): set up, its chunk claimed, no worker, no station.
		local json = helpers.table_to_json({
			key = "4243|7", job_type = "construction", state = "setup", surface_index = 99, surface_name = surface.name,
			chunks = { [312337500] = { key = 312337500, surface_index = 99, last_update_tick = 1,
				minimum = { x = 79.5, y = 79.5 }, maximum = { x = 81.5, y = 81.5 }, midpoint = { x = 80.5, y = 80.5 },
				required_items = { ["wooden-chest"] = { normal = 1 } }, trash_items = {} } },
			required_items = { ["wooden-chest"] = { normal = 1 }, ["construction-robot"] = { normal = 50 } },
			trash_items = {}, station = {}, task_positions = {}, job_status = { "ctron_status.new" },
			landfill_job = false, roboports_enabled = true,
		})
		ctx.expect(string.find(json, '"312337500"', 1, true) ~= nil, "JSON makes the chunk key a string")
		ctron_plugin_on_job_claimed(json)
		local job = fx.by_key("4243|7")
		ctx.expect(job and job.surface_index == surface.index, "the job is on this surface")
		for _, chunk in pairs(job and job.chunks or {}) do
			ctx.expect(chunk.surface_index == surface.index, "and its chunk")
		end
	end)
	fx.wait(ctx, 11, 12000, "the claimed job built the ghost and finished", function()
		return surface.find_entity("wooden-chest", at) ~= nil and fx.by_key("4243|7") == nil
	end, function()
		local claimed = fx.lines_of("4243|7", "ctron.pool", "claimed")
		ctx.expect(#claimed == 1 and claimed[1].fields.surface == surface.name, "logged claimed, on this surface")
		ctx.expect(not storage.constructron_statuses[v.unit_number].busy, "the constructron is idle")
	end)
end)
