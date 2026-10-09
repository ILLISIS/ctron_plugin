local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local fx = require("modules/v2_test/ctron")
local ue = require("modules/universal_edges")

-- The crossing glue (spec §5, §7): G1–G4 and Review Focus 4–5. Each case: a constructron on A with a job whose task
-- lies in B, its station a stand-in on A.

local function S()
	return storage.universal_edges
end

--- The live jobs with key: not paused for a crossing.
local function live(key)
	local n = 0
	for _, job in pairs(storage.jobs) do
		n = n + ((job.key == key and not job.in_transit) and 1 or 0)
	end
	return n
end

--- Case c's surface, edge, constructron and job; seam(c) runs before the job exists.
local function setup(ctx, c, name, seam)
	ctx.at(10, function()
		c.surface = fx.surface(name)
		c.ex, c.ey = fx.pair(c.surface, name, 0)
		if seam then
			seam(c)
		end
	end)
	ctx.at(12, function()
		c.v = fx.ctron(c.surface, 32, 3050)
		c.job = fx.job(c.v, { x = 40, y = 1950 }, fx.stand_in(32, 3100))
		c.key = c.job.key
	end)
end

t.case("G1: a job rides the crossing: after commit one live job, on B, its key and state kept, its chunks' surface " ..
	"rewritten, its station a stand-in; the source's job dropped at on_object_destroyed; counts right; no reassignment",
	function(ctx)
		local c, idle = {}, nil
		setup(ctx, c, "ctron-g1")
		ctx.at(13, function()
			idle = fx.ctron(c.surface, 10, 3120) -- idle all along: nothing gives it the paused job
			c.job.chunks = { [312337500] = { key = 312337500, surface_index = 99,
				minimum = { x = 35, y = 1945 }, maximum = { x = 45, y = 1955 } } }
		end)
		fx.wait(ctx, 14, 3000, "the crossing committed and the source's job dropped", function()
			return not c.v.valid and storage.jobs[c.job.job_index] == nil and fx.by_key(c.key) ~= nil
		end, function()
			local got = fx.by_key(c.key)
			ctx.expect(live(c.key) == 1, "exactly one live job with the key")
			ctx.expect(got.worker and got.worker.valid and got.worker.position.y < fx.B, "its worker is in B")
			ctx.expect(got.state == "in_progress" and got.in_transit == nil, "the state kept, not paused")
			ctx.expect(got.surface_index == c.surface.index, "the job's surface")
			for _, chunk in pairs(got.chunks) do
				ctx.expect(chunk.surface_index == c.surface.index, "a chunk's surface rewritten: " .. chunk.surface_index)
			end
			ctx.expect(got.station.object_name == nil and got.station.valid == true and got.station.position.y == 3100,
				"the station is a stand-in at A's station")
			ctx.expect(storage.constructrons_count[c.surface.index] == 2, "counts: the arrival and the idle one")
			ctx.expect(not storage.constructron_statuses[idle.unit_number].busy, "the idle one never got the job")
			ctx.expect(fx.phases(c.key, "ctron.cross") == "captured,arrived,handed_off",
				"lines: " .. fx.phases(c.key, "ctron.cross"))
		end)
	end)

t.case("G2: a rejected crossing gives the job back on A, waits 5 minutes without a watch, then retries and crosses",
	function(ctx)
		local c = {}
		setup(ctx, c, "ctron-g2", function(x)
			fx.reject[x.ey] = true
		end)
		fx.wait(ctx, 13, 3000, "the refusal", function()
			return c.job.cross_wait_until ~= nil
		end, function(k)
			ctx.expect(c.job.in_transit == nil and storage.jobs[c.job.job_index] == c.job and live(c.key) == 1,
				"the job stays on A, and runs")
			ctx.expect(c.job.cross_wait_until >= game.tick + 17900, "a 5-minute wait")
			local restored = fx.lines_of(c.key, "ctron.cross", "restored")
			ctx.expect(#restored == 1 and restored[1].fields.why == "reject" and restored[1].level == "error",
				"restored reject, logged at error")
			ctx.at(k + 400, function() -- four job passes
				ctx.expect(S().rejected[c.v.unit_number] and S().watch[c.v.unit_number] == nil, "no watch while it waits")
				ctx.expect(c.job.waiting == "refused" and #fx.lines_of(c.key, "ctron.path", "waiting") == 1,
					"waiting refused, logged once")
				fx.reject[c.ey] = nil
				c.job.cross_wait_until = game.tick -- the 5 minutes pass (R20)
				fx.wait(ctx, k + 401, 3000, "the retry", function()
					return not c.v.valid and fx.by_key(c.key) ~= nil and storage.jobs[c.job.job_index] == nil
				end)
			end)
		end)
	end)

t.case("G3: the edge removed while the constructron is held gives it back (close): the job runs again, W is on the " ..
	"watch, and the job waits on the gone side", function(ctx)
	local c = {}
	setup(ctx, c, "ctron-g3", function(x)
		fx.busy[x.ey] = true
	end)
	fx.wait(ctx, 13, 3000, "held", function()
		return c.job.in_transit ~= nil
	end, function(k)
		ctx.at(k + 30, function()
			loop.connectors("ctron-g3", 2, {}, true)
		end)
		fx.wait(ctx, k + 31, 1500, "given back", function()
			return c.job.in_transit == nil
		end, function(k2)
			ctx.expect(c.v.valid and not c.v.disabled_by_script and S().watch[c.v.unit_number] == c.v,
				"unfrozen, on UE's watch")
			ctx.expect(c.job.cross_wait_until == nil and live(c.key) == 1, "the job runs again, no wait")
			local restored = fx.lines_of(c.key, "ctron.cross", "restored")
			ctx.expect(#restored == 1 and restored[1].fields.why == "close" and restored[1].level == "warn",
				"restored close, logged at warn")
			fx.wait(ctx, k2 + 1, 400, "a wait on the gone side", function()
				return c.job.waiting == "edge_inactive"
			end)
		end)
	end)
end)

t.case("G4: a body over the cap (too_big) is refused at once: as a reject", function(ctx)
	local c = {}
	setup(ctx, c, "ctron-g4", function(x)
		fx.too_big[x.ex] = true
	end)
	fx.wait(ctx, 13, 3000, "the refusal", function()
		return c.job.cross_wait_until ~= nil
	end, function(k)
		ctx.expect(c.job.in_transit == nil and live(c.key) == 1 and S().rejected[c.v.unit_number],
			"the job stays on A; UE marked W rejected")
		ctx.expect(not c.v.disabled_by_script, "never frozen")
		local restored = fx.lines_of(c.key, "ctron.cross", "restored")
		ctx.expect(#restored == 1 and restored[1].fields.why == "too_big", "restored too_big")
		fx.too_big[c.ex] = nil
		c.job.cross_wait_until = game.tick
		fx.wait(ctx, k + 1, 3000, "the retry", function()
			return not c.v.valid and storage.jobs[c.job.job_index] == nil and fx.by_key(c.key) ~= nil
		end)
	end)
end)

t.case("a busy destination holds the constructron: the job stays paused, then crosses once (Review Focus 4)",
	function(ctx)
		local c = {}
		setup(ctx, c, "ctron-rf4", function(x)
			fx.busy[x.ey] = true
		end)
		fx.wait(ctx, 13, 3000, "held", function()
			return c.job.in_transit ~= nil
		end, function(k)
			local state, ran = c.job.state, false
			c.job.validate_worker = function() -- execute reaches this unless its in-transit skip holds
				ran = true
				return false
			end
			ctx.at(k + 600, function()
				ctx.expect(c.v.valid and c.v.disabled_by_script and c.job.in_transit ~= nil, "still held, paused")
				ctx.expect(c.job.state == state and live(c.key) == 0 and fx.by_key(c.key) == c.job, "not run, not copied")
				ctx.expect(not ran, "execute skipped the held job")
				c.job.validate_worker = nil
				fx.busy[c.ey] = nil
				fx.wait(ctx, k + 601, 2400, "the crossing", function()
					return not c.v.valid and storage.jobs[c.job.job_index] == nil and fx.by_key(c.key) ~= nil
				end, function()
					ctx.expect(live(c.key) == 1, "one live job, on B")
				end)
			end)
		end)
	end)

t.case("an idle constructron driven across is registered on arrival: counted once, idle, no job (Review Focus 5)",
	function(ctx)
		local surface, v
		ctx.at(10, function()
			surface = fx.surface("ctron-rf5")
			fx.pair(surface, "ctron-rf5", 0)
		end)
		ctx.at(12, function()
			v = fx.ctron(surface, 32, 3010)
			v.autopilot_destination = { 32, 2997 } -- past the line, as a player would steer it
			ue.vehicles.watch(v)
		end)
		fx.wait(ctx, 13, 2000, "the crossing", function()
			return not v.valid
		end, function(k)
			ctx.at(k + 2, function()
				local arrived = surface.find_entities_filtered({ name = "constructron", area = { { -20, 1850 }, { 84, 2000 } } })
				local w = arrived[1]
				ctx.expect(#arrived == 1 and storage.constructrons[w.unit_number] == w, "registered on arrival")
				ctx.expect(storage.constructrons_count[surface.index] == 1, "counted once")
				ctx.expect(not storage.constructron_statuses[w.unit_number].busy and #fx.jobs(surface) == 0, "idle, no job")
			end)
		end)
	end)
