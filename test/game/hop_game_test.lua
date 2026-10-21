-- G15 (spec §14.3): A -> S capture, arrival, the 12-tick settle; each restored reason; route-reply edge cases.
local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local loop = require("modules/v2_test/loopback")
local ue = require("modules/universal_edges")
local connectors = require("modules/universal_edges/edges/connectors")
local portals = require("modules/ctron_pluginv2/portals")
local registry = require("modules/ctron_pluginv2/registry")
local runs = require("modules/ctron_pluginv2/runs")
local travel = require("modules/ctron_pluginv2/travel")

local arrived, failed, restored, moved, dirtied = {}, {}, {}, {}, {}
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
-- The "not captured" case: right after travel puts its spidertron on UE's watch, mark it rejected, so UE's next watch
-- pass drops it and it can't be captured (watch clears the mark, so it must come after).
local nocap, nocap_at = {}, {}
local watch = ue.vehicles.watch
ue.vehicles.watch = function(v)
	watch(v)
	if nocap[v.unit_number] then
		storage.universal_edges.rejected[v.unit_number] = true
		nocap_at[v.unit_number] = game.tick
	end
end

-- UE's vehicle connector seams, keyed by edge: the destination answers reject or busy (by the destination edge), and
-- the source's send answers too_big (by the source edge). The originals run otherwise.
local reject, busy, too_big = {}, {}, {}
local vt = connectors.types.vehicle
local credit = vt.credit
vt.credit = function(ep, dir, body, meta)
	if reject[ep.edge] then
		return "reject"
	end
	if busy[ep.edge] then
		return "busy"
	end
	return credit(ep, dir, body, meta)
end
local ep_send = connectors.methods.send
connectors.methods.send = function(ep, dir, payload)
	if ep.type == "vehicle" and too_big[ep.edge] then
		return nil, "too_big"
	end
	return ep_send(ep, dir, payload)
end

-- Test spidertrons, by unit number (storage, so UE's hooks see them).
local function mine(v)
	return v.name == "spidertron" and storage.ctv2_hop ~= nil and storage.ctv2_hop[v.unit_number] == true
end
ue.transfers.extend({ name = "ctronv2_hop_test", types = { vehicle = true },
	capture = function(_, v)
		if mine(v) then
			return { travel = travel.export(v) }
		end
	end,
	materialized = function(ep, v, data)
		if data and data.travel then
			storage.ctv2_hop[v.unit_number] = true
			moved[v.surface.name] = v
			travel.import(v, data.travel, ep.edge)
		end
	end,
	restored = function(_, v, why)
		if mine(v) then
			restored[v.unit_number] = why
			travel.restored(v, why)
		end
	end,
})

local function T()
	return storage.ctron_pluginv2.travel
end

local function reply(req, route)
	fx.send("ct.route.reply", { req = req, route = route })
end

local OTHER -- an instance id that isn't this one, so the goal needs a route

--- The record's pending ask's req, while it is routing.
local function asked(c)
	local r = T().units[c.unit]
	return r and r.status == "routing" and r.ask and r.ask.req or nil
end

local function route(c, edge)
	return { v = 1, goal = { inst = OTHER, x = 32, y = 1960 }, graph = 1,
		hops = { { edge = edge or c.ex, x = 32, from = registry.here() } } }
end

--- A case's surface and looped edge (side a "<id>-x" on y = 3000, region A south; side b "<id>-y" on y = 2000,
--- region B north), a spidertron at (32, 3060), and a travel to (32, 1960) in region B. tweak(c) runs before go.
local function setup(ctx, c, name, tweak)
	ctx.at(60, function()
		OTHER = registry.here() + 1
		c.s = fx.surface("ctv2-g15-" .. name)
		c.id = "g15" .. name
		c.ex, c.ey = fx.pair(c.s, c.id, 0)
		c.v = assert(c.s.create_entity({ name = "spidertron", position = { 32, 3060 }, force = "player" }))
		c.unit = c.v.unit_number
		storage.ctv2_hop = storage.ctv2_hop or {}
		storage.ctv2_hop[c.unit] = true
		if tweak then
			tweak(c)
		end
		travel.go(c.unit, { inst = OTHER, x = 32, y = 1960 }, { kind = "work", radius = 3 })
	end)
end

t.case("G15 hop: ask, A, step out, capture, arrival, a 12-tick settle, then the final leg", function(ctx)
	local c = {}
	setup(ctx, c, "hop")
	ctx.expect_ipc("ctron_pluginv2:out", '"ct.route.ask"')
	fx.wait(ctx, 70, 600, "asked", function()
		return asked(c)
	end, function()
		reply(asked(c), route(c))
	end)
	fx.wait(ctx, 80, 5000, "arrived at the goal", function()
		local nv = moved[c.s.name]
		return nv and nv.valid and arrived[nv.unit_number]
	end, function()
		local nv = moved[c.s.name]
		local rec = T().units[nv.unit_number]
		ctx.expect(rec.route.i == 2, "the hop was popped")
		ctx.expect(rec.captures == 1, "one capture")
		ctx.expect(rec.settled_at - rec.arrived_at >= 12, "the next leg waited 12 ticks after arrival")
		ctx.expect(math.sqrt((nv.position.x - 32) ^ 2 + (nv.position.y - 1960) ^ 2) <= 6, "at the goal")
		ctx.expect(T().units[c.unit] == nil, "the source record is gone")
	end)
end)

--- Shared assertions for a refused crossing: walked back inside to A (y = 3006), the right avoid keys, one re-route.
local function refused(ctx, c, why, edge_avoided)
	fx.wait(ctx, 80, 5000, "restored " .. why, function()
		return restored[c.unit] ~= nil
	end, function(k)
		ctx.expect(restored[c.unit] == why, "restored " .. why .. ", got " .. tostring(restored[c.unit]))
		fx.wait(ctx, k + 10, 1500, "re-asked after walking back", function()
			return asked(c) ~= nil
		end, function()
			local rec = T().units[c.unit]
			ctx.expect(c.v.position.y > 3002, "back inside, at A, before re-asking: y = " .. c.v.position.y)
			ctx.expect(rec.avoid[c.ex .. ":0"] ~= nil, "the window is avoided")
			ctx.expect((rec.avoid[c.ex] ~= nil) == edge_avoided, "the edge avoided: " .. tostring(edge_avoided))
			ctx.expect(rec.reroutes == 1, "one re-route")
			ctx.expect(dirtied[c.s.name] == nil, "a refusal doesn't dirty the portals")
		end)
	end)
end

t.case("G15 reject: back to A, edge and window avoided, re-routed", function(ctx)
	local c = {}
	setup(ctx, c, "reject", function(x)
		reject[x.ey] = true
	end)
	fx.wait(ctx, 70, 600, "asked", function()
		return asked(c)
	end, function()
		reply(asked(c), route(c))
	end)
	refused(ctx, c, "reject", true)
end)

t.case("G15 too_big: back to A, edge and window avoided, re-routed", function(ctx)
	local c = {}
	setup(ctx, c, "toobig", function(x)
		too_big[x.ex] = true
	end)
	fx.wait(ctx, 70, 600, "asked", function()
		return asked(c)
	end, function()
		reply(asked(c), route(c))
	end)
	refused(ctx, c, "too_big", true)
end)

t.case("G15 close: the edge goes while the crossing is held; back to A, window avoided, re-routed", function(ctx)
	local c = {}
	setup(ctx, c, "close", function(x)
		busy[x.ey] = true
	end)
	fx.wait(ctx, 70, 600, "asked", function()
		return asked(c)
	end, function()
		reply(asked(c), route(c))
	end)
	fx.wait(ctx, 80, 4000, "held", function()
		local rec = T().units[c.unit]
		return rec and rec.phase == "held"
	end, function(k)
		ctx.at(k + 30, function()
			loop.connectors(c.id, 2, {}, true)
		end)
	end)
	refused(ctx, c, "close", false)
end)

t.case("G15 not captured: no capture within 300 ticks at S; back to A, portals dirtied, re-routed", function(ctx)
	local c = {}
	setup(ctx, c, "nocap", function(x)
		nocap[x.unit] = true
	end)
	fx.wait(ctx, 70, 600, "asked", function()
		return asked(c)
	end, function()
		reply(asked(c), route(c))
	end)
	fx.wait(ctx, 80, 5000, "re-asked after the step-out", function()
		return nocap_at[c.unit] ~= nil and asked(c) ~= nil
	end, function()
		local rec = T().units[c.unit]
		ctx.expect(game.tick - nocap_at[c.unit] >= 300, "waited 300 ticks at S")
		ctx.expect(c.v.position.y > 3002, "back inside at A")
		ctx.expect(rec.avoid[c.ex .. ":0"] ~= nil and rec.avoid[c.ex] == nil, "only the window is avoided")
		ctx.expect(dirtied[c.s.name] == true, "a failed hop dirties the portals")
		ctx.expect(restored[c.unit] == nil and moved[c.s.name] == nil, "never captured")
	end)
end)

t.case("G15 stale replies: a wrong req and an old req change nothing; an unanswered ask is re-sent", function(ctx)
	local c = {}
	setup(ctx, c, "stale")
	fx.wait(ctx, 70, 600, "asked", function()
		return asked(c)
	end, function(k)
		c.req1 = asked(c)
		reply(c.req1 .. "x", route(c))
		ctx.at(k + 5, function()
			ctx.expect(asked(c) == c.req1, "a reply for an unknown req is ignored")
		end)
		fx.wait(ctx, k + 10, 900, "re-asked after 300 ticks", function()
			return asked(c) and asked(c) ~= c.req1
		end, function(k2)
			reply(c.req1, route(c))
			ctx.at(k2 + 5, function()
				ctx.expect(asked(c) ~= nil and asked(c) ~= c.req1, "the old req's reply is ignored")
				reply(asked(c), route(c))
			end)
			ctx.at(k2 + 10, function()
				local rec = T().units[c.unit]
				ctx.expect(rec.status == "moving" and rec.leg.purpose == "A", "the current req's reply starts the hop")
			end)
		end)
	end)
end)

t.case("G15 unknown edge: each route names an edge this tile lacks; after 3 re-routes, budget", function(ctx)
	local c = { replies = 0 }
	setup(ctx, c, "noedge")
	for i = 0, 3 do
		fx.wait(ctx, 70 + i * 40, 600, "ask " .. (i + 1), function()
			return asked(c) and asked(c) ~= c.last
		end, function()
			c.last = asked(c)
			c.replies = c.replies + 1
			reply(c.last, route(c, "no-such-edge"))
		end)
	end
	fx.wait(ctx, 80, 3000, "failed", function()
		return failed[c.unit] ~= nil
	end, function()
		ctx.expect(failed[c.unit] == "budget", "budget, got " .. tostring(failed[c.unit]))
		ctx.expect(c.replies == 4 and T().units[c.unit].reroutes == 4, "four routes, the fourth over the limit")
		ctx.expect(T().units[c.unit].avoid["no-such-edge:0"] ~= nil, "a stale hop avoids its window")
	end)
end)

t.case("G15 unplanned refusal: a forced step-out with no hop comes back inside, then goes on to its goal", function(ctx)
	local c = {}
	ctx.at(60, function()
		c.s = fx.surface("ctv2-g15-forced")
		c.ex, c.ey = fx.pair(c.s, "g15forced", 0)
		too_big[c.ex] = true
		c.v = assert(c.s.create_entity({ name = "spidertron", position = { 32, 3010 }, force = "player" }))
		c.unit = c.v.unit_number
		storage.ctv2_hop = storage.ctv2_hop or {}
		storage.ctv2_hop[c.unit] = true
		travel.go(c.unit, { inst = registry.here(), x = 32, y = 3100 }, { kind = "work", radius = 3 })
	end)
	-- Once travel has its path, force the spidertron past side a's line, as P2's G10 forces a crossing.
	fx.wait(ctx, 61, 600, "path applied", function()
		local rec = T().units[c.unit]
		return rec and rec.leg and not rec.leg.pending and #c.v.autopilot_destinations > 0
	end, function()
		ue.vehicles.watch(c.v)
		c.v.autopilot_destination = { 32, 2997 }
	end)
	fx.wait(ctx, 70, 3000, "arrived at the goal", function()
		return arrived[c.unit] ~= nil
	end, function()
		local rec = T().units[c.unit]
		ctx.expect(restored[c.unit] == "too_big", "the forced crossing was refused")
		ctx.expect(rec.reroutes == 0 and rec.route == nil, "no route was asked for")
		ctx.expect(math.sqrt((c.v.position.x - 32) ^ 2 + (c.v.position.y - 3100) ^ 2) <= 6, "at the goal")
	end)
end)

t.case("G15 no route: a null reply fails no_route at once", function(ctx)
	local c = {}
	setup(ctx, c, "noroute")
	fx.wait(ctx, 70, 600, "asked", function()
		return asked(c)
	end, function(k)
		reply(asked(c), nil)
		ctx.at(k + 5, function()
			ctx.expect(failed[c.unit] == "no_route", "no_route, got " .. tostring(failed[c.unit]))
		end)
	end)
end)

t.case("G15 held mid-leg: a capture during a goal leg isn't stuck, however long UE holds it", function(ctx)
	local c = {}
	ctx.at(60, function()
		c.s = fx.surface("ctv2-g15-held")
		fx.pair(c.s, "g15held", 0)
		c.v = assert(c.s.create_entity({ name = "spidertron", position = { 32, 3010 }, force = "player" }))
		c.unit = c.v.unit_number
		travel.go(c.unit, { inst = registry.here(), x = 32, y = 3100 }, { kind = "work", radius = 3 })
	end)
	fx.wait(ctx, 61, 600, "path applied", function()
		local rec = T().units[c.unit]
		return rec and rec.leg and not rec.leg.pending and #c.v.autopilot_destinations > 0
	end, function(k)
		ctx.expect(travel.export(c.v) ~= nil, "exported")
		c.v.autopilot_destination = nil -- UE's freeze
		ctx.at(k + 400, function()
			local rec = T().units[c.unit]
			ctx.expect(rec and rec.status == "crossing" and rec.phase == "held", "still held, not stuck")
			ctx.expect(failed[c.unit] == nil, "no failure for a ctron in transit")
		end)
	end)
end)

t.case("G15 loop bounds: captures, budget, reroutes and avoid survive the save; over budget fails", function(ctx)
	local c = {}
	ctx.at(60, function()
		c.s = fx.surface("ctv2-g15-bounds")
		fx.pair(c.s, "g15bounds", 0)
		c.v = assert(c.s.create_entity({ name = "spidertron", position = { 32, 3010 }, force = "player" }))
		c.u = c.v.unit_number
		c.w = assert(c.s.create_entity({ name = "spidertron", position = { 40, 3010 }, force = "player" }))
		c.wu = c.w.unit_number
		-- over budget: the fifth capture of a budget of four
		travel.import(c.v, { goal = { inst = OTHER or registry.here() + 1, x = 32, y = 1960 }, kind = "work", radius = 3,
			route = { hops = { { edge = "e", x = 32, from = registry.here() } }, i = 1 }, budget = 4, captures = 4,
			reroutes = 0, avoid = {}, stepping = true }, "e")
		-- a same-tick round trip
		travel.go(c.wu, { inst = registry.here(), x = 40, y = 3100 }, { kind = "work", radius = 3 })
		local rec = T().units[c.wu]
		rec.captures, rec.budget, rec.reroutes, rec.avoid = 1, 4, 2, { k = game.tick + 100 }
		local data = travel.export(c.w)
		ctx.expect(data.avoid.k == 100, "avoid leaves as ticks left: " .. tostring(data.avoid.k))
		travel.import(c.w, data, "e")
		local n = T().units[c.wu]
		ctx.expect(n.captures == 2 and n.budget == 4 and n.reroutes == 2, "captures 2, budget 4, reroutes 2")
		ctx.expect(n.avoid.k == game.tick + 100, "avoid re-based on this tick")
	end)
	ctx.at(62, function()
		ctx.expect(failed[c.u] == "budget", "budget, got " .. tostring(failed[c.u]))
	end)
end)
