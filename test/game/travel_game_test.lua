-- G14 (spec §14.3): local legs, the ladder, stand points, leaves-tile rejection, the stuck watchdog, the request FIFO.
local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local portals = require("modules/ctron_pluginv2/portals")
local registry = require("modules/ctron_pluginv2/registry")
local runs = require("modules/ctron_pluginv2/runs")
local travel = require("modules/ctron_pluginv2/travel")
local ue = require("modules/universal_edges")

-- Record travel's callbacks per unit; the originals still run. File-local, keyed by unit (unique within the run).
local arrived, failed, dirtied = {}, {}, {}
local on_arrived, on_failed, dirty = runs.on_arrived, runs.on_failed, portals.dirty
runs.on_arrived = function(unit)
	arrived[unit] = (arrived[unit] or 0) + 1
	return on_arrived(unit)
end
runs.on_failed = function(unit, reason)
	failed[unit] = reason
	return on_failed(unit, reason)
end
portals.dirty = function(surface)
	dirtied[surface] = true
	return dirty(surface)
end

local function T()
	return storage.ctron_pluginv2.travel
end

local function water(s, x1, y1, x2, y2, keep)
	local tiles = {}
	for x = x1, x2 do
		for y = y1, y2 do
			if not (keep and keep(x, y)) then
				tiles[#tiles + 1] = { name = "water", position = { x, y } }
			end
		end
	end
	s.set_tiles(tiles)
end

local function dist(p, x, y)
	return math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2)
end

--- A 50x50 lake with a 6x6 island in the middle: 22 tiles of water each way.
local function island(s)
	water(s, 20, 3040, 70, 3090, function(x, y)
		return x >= 42 and x <= 48 and y >= 3062 and y <= 3068
	end)
end

-- Every case paves region A with fx.pair: x -20..84, y 2990..3150, side a live on y = 3000 (inside is south).

t.case("G14 leg: a leg targets the stand point beside a pond; the goal table is untouched", function(ctx)
	local c = {}
	ctx.at(60, function()
		local s = fx.surface("ctv2-g14-leg")
		fx.pair(s, "g14leg", 0)
		water(s, 56, 3036, 64, 3044)
		c.v = fx.ctron(s, 0, 3120, { robots = 0 })
		c.goal = { inst = registry.here(), x = 60, y = 3040 }
		travel.go(c.v.unit_number, c.goal, { kind = "work", radius = 12 })
		-- #6: a work leg with no stand point within its radius stands on land within reach of the goal, or fails
		-- no_land at once when there is none; never a goal in the water.
		c.w = fx.ctron(s, 10, 3120, { robots = 0 })
		travel.go(c.w.unit_number, c.goal, { kind = "work", radius = 3, reach = 20 })
		c.n = fx.ctron(s, 20, 3120, { robots = 0 })
		travel.go(c.n.unit_number, c.goal, { kind = "work", radius = 3, reach = 3 })
		ctx.expect(failed[c.n.unit_number] == "no_land", "no land within reach: " .. tostring(failed[c.n.unit_number]))
		ctx.expect(#c.n.autopilot_destinations == 0, "and no autopilot")
	end)
	fx.wait(ctx, 70, 3000, "arrival", function()
		return arrived[c.v.unit_number] ~= nil and arrived[c.w.unit_number] ~= nil
	end, function()
		local leg = T().units[c.w.unit_number].leg
		ctx.expect(math.abs(leg.tx - 60) <= 20 and math.abs(leg.ty - 3040) <= 20, "the stand point is within reach")
		ctx.expect(dist(c.w.position, 60, 3040) > 4, "stopped beside the pond, not in it")
		ctx.expect(c.goal.inst == registry.here() and c.goal.x == 60 and c.goal.y == 3040, "goal unchanged")
		ctx.expect(travel.status(c.v.unit_number) == "arrived", "status arrived")
		ctx.expect(arrived[c.v.unit_number] == 1, "on_arrived once")
		local d = dist(c.v.position, 60, 3040)
		-- The stand-point search radius bounds a square, so a point can be r * sqrt(2) from the goal.
		ctx.expect(d > 4 and d <= 16, "stopped at the pond's edge, not in it: " .. d)
	end)
end)

t.case("G14 short: a move of 12 tiles or less sets the autopilot without a path request", function(ctx)
	local c = {}
	ctx.at(60, function()
		local s = fx.surface("ctv2-g14-short")
		fx.pair(s, "g14short", 0)
		c.v = fx.ctron(s, 10, 3100, { robots = 0 })
		local before = T().inflight
		travel.go(c.v.unit_number, { inst = registry.here(), x = 18, y = 3100 }, { kind = "park", radius = 3 })
		ctx.expect(T().inflight == before, "no path request")
		ctx.expect(#c.v.autopilot_destinations == 1, "autopilot set directly")
		-- R-210: a ctron 3 tiles past the looped line first walks back to the approach point.
		local frame = ue.edges.frame("g14short-x", "a")
		local px, py = ue.geometry.to_world(frame, 20, -3)
		c.past = fx.ctron(s, px, py, { robots = 0 })
		travel.go(c.past.unit_number, { inst = registry.here(), x = 18, y = 3100 }, { kind = "park", radius = 3 })
		local leg = T().units[c.past.unit_number].leg
		ctx.expect(leg and leg.purpose == "back", "a back leg starts: " .. tostring(leg and leg.purpose))
		travel.cancel(c.past.unit_number)
		c.past.destroy()
	end)
	fx.wait(ctx, 70, 600, "arrival", function()
		return arrived[c.v.unit_number] ~= nil
	end)
end)

t.case("G14 no path: an island past a 22-tile moat; the small box is tried, then on_failed no_path", function(ctx)
	local c = {}
	ctx.at(60, function()
		local s = fx.surface("ctv2-g14-island")
		fx.pair(s, "g14island", 0)
		island(s)
		c.v = fx.ctron(s, 0, 3130, { robots = 0 })
		travel.go(c.v.unit_number, { inst = registry.here(), x = 45, y = 3065 }, { kind = "work", radius = 3 })
	end)
	fx.wait(ctx, 70, 3000, "failure", function()
		return failed[c.v.unit_number] ~= nil
	end, function()
		local rec = T().units[c.v.unit_number]
		ctx.expect(failed[c.v.unit_number] == "no_path", "reason no_path, got " .. tostring(failed[c.v.unit_number]))
		ctx.expect(rec.status == "failed" and rec.reason == "no_path", "the record says failed / no_path")
		ctx.expect(rec.leg.small == true, "the small box was tried")
		ctx.expect(arrived[c.v.unit_number] == nil, "never arrived")
	end)
end)

t.case("G14 dirty: a failed task leg leaves the portals alone; a failed dock leg dirties them (R-135)", function(ctx)
	local c = {}
	ctx.at(60, function()
		c.ts = fx.surface("ctv2-g14-dtask")
		fx.pair(c.ts, "g14dtask", 0)
		island(c.ts)
		c.task = fx.ctron(c.ts, 0, 3130, { robots = 0 })
		travel.go(c.task.unit_number, { inst = registry.here(), x = 45, y = 3065 }, { kind = "work", radius = 3 })
		c.ds = fx.surface("ctv2-g14-ddock")
		fx.pair(c.ds, "g14ddock", 0)
		island(c.ds)
		c.dock = fx.ctron(c.ds, 0, 3130, { robots = 0 })
		travel.go(c.dock.unit_number, { inst = registry.here(), x = 45, y = 3065 }, { kind = "station", radius = 3 })
	end)
	fx.wait(ctx, 70, 5000, "both legs failed", function()
		return failed[c.task.unit_number] ~= nil and failed[c.dock.unit_number] ~= nil
	end, function()
		ctx.expect(dirtied[c.ts.name] == nil, "a failed task leg doesn't dirty the portals")
		ctx.expect(dirtied[c.ds.name] == true, "a failed dock leg does")
	end)
end)

t.case("G14 leaves tile: the only way round is past the live line, so both attempts are rejected", function(ctx)
	local c = {}
	ctx.at(60, function()
		local s = fx.surface("ctv2-g14-leave")
		fx.pair(s, "g14leave", 0)
		-- A closed box split by a wall whose only gap is the strip y 2975..2996,
		-- i.e. more than 2 past side a's line, inside UE's barrier band.
		water(s, -50, 2961, 114, 2974)
		water(s, -50, 2961, -36, 3156)
		water(s, 100, 2961, 114, 3156)
		water(s, -50, 3143, 114, 3156)
		water(s, 30, 2997, 45, 3143)
		c.v = fx.ctron(s, 0, 3100, { robots = 0 })
		travel.go(c.v.unit_number, { inst = registry.here(), x = 60, y = 3100 }, { kind = "work", radius = 3 })
	end)
	ctx.expect_ipc("ctron_pluginv2:out", "leaves_tile")
	fx.wait(ctx, 70, 4000, "failure", function()
		return failed[c.v.unit_number] ~= nil
	end, function()
		ctx.expect(failed[c.v.unit_number] == "no_path", "reason no_path")
		ctx.expect(T().units[c.v.unit_number].leg.small == true, "the small box was tried too")
		ctx.expect(c.v.position.y > 3000, "never stepped past the line")
	end)
end)

t.case("G14 stuck: a frozen ctron with a live autopilot is stuck twice, then on_failed stuck", function(ctx)
	local c = {}
	ctx.at(60, function()
		local s = fx.surface("ctv2-g14-stuck")
		fx.pair(s, "g14stuck", 0)
		c.v = fx.ctron(s, 0, 3100, { robots = 0 })
		travel.go(c.v.unit_number, { inst = registry.here(), x = 70, y = 3100 }, { kind = "work", radius = 3 })
	end)
	fx.wait(ctx, 70, 1000, "path applied", function()
		return #c.v.autopilot_destinations > 0
	end, function()
		c.v.disabled_by_script = true
	end)
	fx.wait(ctx, 80, 3000, "failure", function()
		return failed[c.v.unit_number] ~= nil
	end, function()
		ctx.expect(failed[c.v.unit_number] == "stuck", "reason stuck, got " .. tostring(failed[c.v.unit_number]))
		ctx.expect(T().units[c.v.unit_number].leg.stuck == 2, "two stucks")
		ctx.expect(#c.v.autopilot_destinations == 0, "the failed leg's autopilot is cleared (#6)")
	end)
end)

t.case("G14 stopped short: a ctron whose autopilot is cleared counts a stuck, twice, then on_failed stuck", function(ctx)
	local c = {}
	ctx.at(60, function()
		local s = fx.surface("ctv2-g14-short-stop")
		fx.pair(s, "g14stop", 0)
		c.v = fx.ctron(s, 0, 3100, { robots = 0 })
		travel.go(c.v.unit_number, { inst = registry.here(), x = 70, y = 3100 }, { kind = "work", radius = 3 })
	end)
	for k = 70, 1000, 10 do
		ctx.at(k, function()
			if c.v.valid and #c.v.autopilot_destinations > 0 then
				c.v.autopilot_destination = nil
			end
		end)
	end
	fx.wait(ctx, 80, 3000, "failure", function()
		return failed[c.v.unit_number] ~= nil
	end, function()
		ctx.expect(failed[c.v.unit_number] == "stuck", "reason stuck, got " .. tostring(failed[c.v.unit_number]))
		ctx.expect(T().units[c.v.unit_number].leg.stuck == 2, "two stucks")
	end)
end)

t.case("G14 FIFO: ten legs at once keep at most 8 requests in flight, and all arrive", function(ctx)
	local c = { units = {} }
	ctx.at(60, function()
		local s = fx.surface("ctv2-g14-fifo")
		fx.pair(s, "g14fifo", 0)
		for i = 0, 9 do
			local v = fx.ctron(s, -10 + 9 * i, 3140, { robots = 0 })
			c.units[#c.units + 1] = v.unit_number
			travel.go(v.unit_number, { inst = registry.here(), x = -10 + 9 * i, y = 3020 }, { kind = "work", radius = 3 })
		end
		ctx.expect(T().inflight <= 8, "at most 8 in flight")
		ctx.expect(#T().queue >= 2, "the rest wait")
	end)
	fx.wait(ctx, 70, 4000, "all arrived", function()
		for _, u in ipairs(c.units) do
			if not arrived[u] then
				return false
			end
		end
		return true
	end)
end)

t.case("G14 superseded: a replaced leg's result doesn't steer the ctron; a cancel frees its slot", function(ctx)
	local c = {}
	ctx.at(60, function()
		local s = fx.surface("ctv2-g14-super")
		fx.pair(s, "g14super", 0)
		c.v = fx.ctron(s, 0, 3060, { robots = 0 })
		local here = registry.here()
		travel.go(c.v.unit_number, { inst = here, x = 70, y = 3060 }, { kind = "work", radius = 3 })
		-- Short: no second request, so a leaked first result would visibly steer it away.
		travel.go(c.v.unit_number, { inst = here, x = 8, y = 3060 }, { kind = "work", radius = 3 })
	end)
	fx.wait(ctx, 70, 3000, "arrival", function()
		return arrived[c.v.unit_number] ~= nil
	end, function(k)
		ctx.expect(arrived[c.v.unit_number] == 1, "one arrival")
		ctx.expect(dist(c.v.position, 8, 3060) <= 6, "at the second goal")
		travel.go(c.v.unit_number, { inst = registry.here(), x = -10, y = 3020 }, { kind = "work", radius = 3 })
		travel.cancel(c.v.unit_number)
		ctx.expect(travel.status(c.v.unit_number) == nil, "no record after cancel")
		ctx.at(k + 400, function()
			ctx.expect(dist(c.v.position, 8, 3060) <= 6, "the first leg's result never steered it")
			for _, r in pairs(T().reqs) do
				ctx.expect(r.unit ~= c.v.unit_number, "no request left for the cancelled leg")
			end
			ctx.expect(#c.v.autopilot_destinations == 0, "no autopilot")
			ctx.expect(arrived[c.v.unit_number] == 1 and failed[c.v.unit_number] == nil, "no callback after cancel")
		end)
	end)
end)

t.case("G14 destroyed: a ctron destroyed mid-leg leaves no record and no callback", function(ctx)
	local c = {}
	ctx.at(60, function()
		local s = fx.surface("ctv2-g14-gone")
		fx.pair(s, "g14gone", 0)
		c.v = fx.ctron(s, 0, 3100, { robots = 0 })
		c.unit = c.v.unit_number
		travel.go(c.unit, { inst = registry.here(), x = 70, y = 3100 }, { kind = "work", radius = 3 })
	end)
	ctx.at(65, function()
		c.v.destroy()
	end)
	ctx.at(500, function()
		ctx.expect(T().units[c.unit] == nil and T().active[c.unit] == nil, "record dropped")
		ctx.expect(arrived[c.unit] == nil and failed[c.unit] == nil, "no callback")
	end)
end)
