local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctron")
local deconstruction_job = require("modules/ctron_plugin/script/job/deconstruction")
local destroy_job = require("modules/ctron_plugin/script/job/destroy")
local minion_job = require("modules/ctron_plugin/script/job/minion")

-- Whole trips (spec §12): G5, G7, G8 and G10.

t.case("G5: a ghost in B, the station and stock in A: the job is made on A, crosses, builds, crosses back and " ..
	"finishes at the station; the constructron ends idle there", function(ctx)
	local surface, key
	local at = { 40.5, 1950.5 }
	ctx.at(10, function()
		surface = fx.surface("ctron-g5")
		fx.pair(surface, "ctron-g5", 0)
		fx.station(surface, 32, 3100, { ["construction-robot"] = 60, ["wooden-chest"] = 5 })
		fx.ctron(surface, 32, 3088)
		fx.ghost(surface, at[1], at[2])
	end)
	fx.wait(ctx, 11, 15000, "the ghost built and the job done at the station", function()
		if not key then
			local job = fx.jobs(surface)[1]
			key = job and job.key
		end
		return surface.find_entity("wooden-chest", at) ~= nil and key ~= nil and fx.by_key(key) == nil
	end, function()
		ctx.expect(fx.phases(key, "ctron.cross") == "captured,arrived,handed_off,captured,arrived,handed_off",
			"out and back: " .. fx.phases(key, "ctron.cross"))
		local home = surface.find_entities_filtered({ name = "constructron", position = { 32, 3100 }, radius = 16 })
		ctx.expect(#home == 1 and not storage.constructron_statuses[home[1].unit_number].busy, "idle at the station")
	end)
end)

t.case("G7: a goal two hops away crosses twice and returns twice", function(ctx)
	local surface, ab, bc, job
	ctx.at(10, function()
		-- A (y > 3000) -ab- B (1900 < y < 2000) -bc- C (y < 900)
		surface = fx.surface("ctron-g7")
		ab = { fx.pair(surface, "ctron-g7ab", 0) }
		bc = { fx.pair(surface, "ctron-g7bc", 0, 1900, 900) }
	end)
	ctx.at(12, function()
		local v = fx.ctron(surface, 32, 3050)
		job = fx.job(v, { x = 40, y = 850 }, fx.stand_in(32, 3100))
	end)
	local function edges()
		local out = {}
		for _, line in ipairs(fx.lines_of(job.key, "ctron.cross", "captured")) do
			out[#out + 1] = line.fields.edge
		end
		return table.concat(out, ",")
	end
	fx.wait(ctx, 13, 12000, "four crossings", function()
		return job and #fx.lines_of(job.key, "ctron.cross", "handed_off") == 4
	end, function()
		ctx.expect(edges() == table.concat({ ab[1], bc[1], bc[2], ab[2] }, ","), "A → B → C → B → A: " .. edges())
	end)
end)

t.case("G8: a full trunk and a large deconstruction job: the crossing's body is under the 65,536-byte cap", function(ctx)
	local surface, ex, v, job
	ctx.at(10, function()
		surface = fx.surface("ctron-g8")
		ex = fx.pair(surface, "ctron-g8", 0)
		fx.measure[ex] = true
	end)
	ctx.at(12, function()
		v = fx.ctron(surface, 32, 3050)
		local trunk = v.get_inventory(defines.inventory.spider_trunk)
		for name, item in pairs(prototypes.item) do
			if trunk.count_empty_stacks() == 0 then
				break
			end
			if item.type == "item" and item.stack_size > 1 and not item.hidden then
				trunk.insert({ name = name, count = item.stack_size })
			end
		end
		storage.job_index = storage.job_index + 1
		job = deconstruction_job.new(storage.job_index, surface.index, "deconstruction", v)
		job.state, job.station = "in_progress", fx.stand_in(32, 3100)
		for i = 1, 40 do
			local x, y = 20 + i, 1960 - i
			local trash = {}
			for j = 1, 5 do
				trash["item-" .. i .. "-" .. j] = { normal = 50 }
			end
			job.chunks[1000000 + i] = { key = 1000000 + i, surface_index = surface.index, last_update_tick = 1,
				minimum = { x = x, y = y }, maximum = { x = x + 70, y = y + 70 }, midpoint = { x = x + 35, y = y + 35 },
				required_items = {}, trash_items = trash }
		end
		for i = 1, 200 do
			job.task_positions[i] = { x = 20 + i % 40, y = 1950 - i % 30 }
		end
		storage.jobs[storage.job_index] = job
	end)
	fx.wait(ctx, 13, 3000, "the offer", function()
		return fx.sent[ex] ~= nil
	end, function()
		helpers.write_file("ctron-g8-body.txt", tostring(fx.sent[ex])) -- the task report gives this number
		ctx.expect(fx.sent[ex] < 65536, "the body: " .. fx.sent[ex] .. " bytes")
	end)
	ctx.expect_file("ctron-g8-body.txt")
end)

t.case("G10: a destroy leader crosses alone: its minion goes home and never crosses; the leader goes on with no " ..
	"minions", function(ctx)
	local surface, leader, minion, job, mjob
	ctx.at(10, function()
		surface = fx.surface("ctron-g10")
		fx.pair(surface, "ctron-g10", 0)
	end)
	ctx.at(12, function()
		local station = fx.station(surface, 32, 3120, {})
		leader, minion = fx.ctron(surface, 32, 3050), fx.ctron(surface, 36, 3054)
		storage.job_index = storage.job_index + 1
		job = destroy_job.new(storage.job_index, surface.index, "destroy", leader)
		job.state, job.station, job.task_positions = "in_progress", station, { { x = 40, y = 1950 } }
		storage.jobs[storage.job_index] = job
		storage.job_index = storage.job_index + 1
		mjob = minion_job.new(storage.job_index, surface.index, "minion", minion)
		mjob.state, mjob.station, mjob.primary_job = "in_progress", station, job
		storage.jobs[storage.job_index] = mjob
		job.minion_jobs[storage.job_index] = mjob
	end)
	fx.wait(ctx, 13, 4000, "the leader crossed", function()
		return not leader.valid and storage.jobs[job.job_index] == nil and fx.by_key(job.key) ~= nil
	end, function(k)
		ctx.expect(next(fx.by_key(job.key).minion_jobs) == nil, "the leader goes on with no minions")
		fx.wait(ctx, k + 1, 600, "the minion heads home", function()
			return mjob.state == "finishing" or storage.jobs[mjob.job_index] == nil
		end, function()
			ctx.expect(minion.valid and minion.position.y > fx.B + 100, "the minion stayed on A")
			ctx.expect(#fx.lines_of(mjob.key, "ctron.cross") == 0, "no minion crossing")
		end)
	end)
end)
