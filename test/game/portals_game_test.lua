-- G16 (spec §14.3): extraction around a lake on the line; components; report shape; a refresh after landfill; the
-- quiet rule; SP-16's probe cost and the pathing Lua cost, noted for the stop report.
local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local portals = require("modules/ctron_pluginv2/portals")
local tcore = require("modules/ctron_pluginv2/travel_core")

local function water(x1, y1, x2, y2, name)
	local tiles = {}
	for x = x1, x2 do
		for y = y1, y2 do
			tiles[#tiles + 1] = { name = name or "water", position = { x, y } }
		end
	end
	return tiles
end

local function report(s)
	return portals.reports()[s.name]
end

local function node(r, edge, k)
	for _, n in ipairs(r.nodes) do
		if n.edge == edge and n.k == k then
			return n
		end
	end
end

t.case("G16 extraction: a lake on side a's line splits window 1; two components", function(ctx)
	local c = {}
	ctx.at(60, function()
		c.s = fx.surface("ctv2-g16-lake")
		c.ex, c.ey = fx.pair(c.s, "g16lake", 0, nil, nil, 256)
		c.s.set_tiles(water(160, 2970, 184, 3008))
	end)
	ctx.expect_ipc("ctron_pluginv2:out", '"ct.portals"')
	fx.wait(ctx, 70, 3000, "first report", function()
		return report(c.s) ~= nil
	end, function()
		local r = report(c.s)
		ctx.expect(r.surface == c.s.name and r.epoch == 1, "surface and epoch 1")
		ctx.expect(#r.nodes == 4, "four window nodes, got " .. #r.nodes)
		local a0, a1, b0, b1 = node(r, c.ex, 0), node(r, c.ex, 1), node(r, c.ey, 0), node(r, c.ey, 1)
		ctx.expect(a0 and a0.lo == 16 and a0.hi == 120 and a0.x == 68 and a0.y == 3006, "side a, window 0")
		ctx.expect(a1 and a1.lo == 192 and a1.hi == 240 and a1.x == 216 and a1.y == 3006, "side a, window 1 past the lake")
		ctx.expect(b0 and b0.lo == 16 and b0.hi == 120 and b0.x == 68 and b0.y == 1994, "side b, window 0, a's frame")
		ctx.expect(b1 and b1.lo == 128 and b1.hi == 240 and b1.x == 184 and b1.y == 1994, "side b, window 1, a's frame")
				ctx.expect(a0.comp == a1.comp and b0.comp == b1.comp and a0.comp ~= b0.comp, "one component per region")
		ctx.expect(r.links == nil, "no links in the report")
	end)
end)

t.case("G16 landfill: filling the lake refreshes after the quiet period and opens window 1", function(ctx)
	local c = {}
	ctx.at(60, function()
		c.s = fx.surface("ctv2-g16-fill")
		c.ex, c.ey = fx.pair(c.s, "g16fill", 0, nil, nil, 256)
		c.s.set_tiles(water(160, 2970, 184, 3008))
	end)
	fx.wait(ctx, 70, 3000, "first report", function()
		return report(c.s) ~= nil
	end, function(k)
		c.s.set_tiles(water(160, 2970, 184, 3008, "landfill"), true, false, true, true) -- raises the event
		c.filled = k
		fx.wait(ctx, k + 10, 4000, "second report", function()
			return report(c.s).epoch == 2
		end, function(k2)
			ctx.expect(k2 - c.filled >= 1800, "waited for 1800 quiet ticks")
			local a1 = node(report(c.s), c.ex, 1)
			ctx.expect(a1 and a1.lo == 128 and a1.hi == 240, "window 1 is whole again")
		end)
	end)
end)

t.case("G16 dirty: portals.dirty refreshes only after 1800 quiet ticks; nothing refreshes on a timer", function(ctx)
	local c = {}
	ctx.at(60, function()
		c.s = fx.surface("ctv2-g16-dirty")
		c.ex, c.ey = fx.pair(c.s, "g16dirty", 0, nil, nil, 256)
	end)
	fx.wait(ctx, 70, 3000, "first report", function()
		return report(c.s) ~= nil
	end, function(k)
		portals.dirty(c.s.name)
		ctx.at(k + 1700, function()
			ctx.expect(report(c.s).epoch == 1, "no refresh inside the quiet period")
		end)
		fx.wait(ctx, k + 1710, 1500, "refresh", function()
			return report(c.s).epoch == 2
		end, function(k2)
			ctx.at(k2 + 1300, function()
				ctx.expect(report(c.s).epoch == 2, "no further refresh without a change")
			end)
		end)
	end)
end)

t.case("G16 SP-16 and the pathing Lua cost (logged)", function(ctx)
	local c = {}
	ctx.at(60, function()
		c.s = fx.surface("ctv2-g16-cost")
		c.ex, c.ey = fx.pair(c.s, "g16cost", 0, nil, nil, 512)
	end)
	fx.wait(ctx, 70, 4000, "report on a 512 side", function()
		return report(c.s) ~= nil
	end, function()
		local P = storage.ctron_pluginv2.portals.surfaces[c.s.name]
		fx.note("sp16", "refresh: probes=", P.stats.probes, " requests=", P.stats.requests, " ticks=", P.stats.ticks,
			" nodes=", #report(c.s).nodes)
		-- One tick's probe batch: 16 samples, two collision checks each.
		local side = { origin = { 0, 3000 }, facing = 0, length = 512 }
		local prof = helpers.create_profiler()
		for i = 0, 15 do
			local A, _, O = tcore.points(side, "a", 16 + 8 * i)
			c.hits = (c.hits or 0) + (c.s.entity_prototype_collides("constructron_pathing_proxy_10", A, false) and 1 or 0)
				+ (c.s.entity_prototype_collides("constructron_pathing_proxy_8", O, false) and 1 or 0)
		end
		prof.stop()
		fx.note("sp16", "probe batch (16 probes): ", prof)
		-- One path result's Lua: leaves_tile + simplify over a 400-waypoint path, 100 times.
		local path = {}
		for i = 1, 400 do
			path[i] = { position = { x = i, y = 3050 + (i % 7) } }
		end
		local frames = { side, { origin = { 512, 2000 }, facing = 8, length = 512 } }
		prof = helpers.create_profiler()
		for _ = 1, 100 do
			tcore.leaves_tile(path, frames)
			tcore.simplify(path)
		end
		prof.stop()
		fx.note("sp16", "pathing Lua: 100 path results (400 waypoints): ", prof)
		ctx.expect(P.stats.probes == 2 * 61, "61 probes per 512 side")
	end)
end)

t.case("G16 stall: a refresh with lost probes and leaked requests is abandoned and recovers", function(ctx)
	local c = {}
	ctx.at(60, function()
		c.s = fx.surface("ctv2-g16-stall")
		c.ex, c.ey = fx.pair(c.s, "g16stall", 0, nil, nil, 256)
	end)
	fx.wait(ctx, 70, 3000, "first report", function()
		return report(c.s) ~= nil
	end, function(k)
		local S = storage.ctron_pluginv2.portals
		local P = S.surfaces[c.s.name]
		-- What lost probes and a recreated surface leave behind.
		P.phase, P.run, P.left, P.stats.started = "probe", 999, 5, game.tick - 41000
		S.reqs["fake"], S.inflight = { surface = c.s.name, run = 1, at = game.tick - 5000 }, 4
		fx.wait(ctx, k + 1, 5000, "second report", function()
			return report(c.s).epoch == 2
		end, function()
			ctx.expect(S.inflight == 0 and S.reqs["fake"] == nil, "leaked requests forgotten")
		end)
	end)
end)
