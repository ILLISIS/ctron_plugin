-- Travel (spec §7.2-§7.5): local legs with the failure ladder, arrival and the stuck watchdog; route asks, hops and
-- export/import across UE crossings (Task 5). State is plain data in storage.ctron_pluginv2.travel; the entity is
-- found by unit number on every use (UE does the same for vehicles, transports/vehicle.lua:82).
local ue = require("modules/universal_edges")
local bridge = require("modules/ctron_pluginv2/bridge")
local core = require("modules/ctron_pluginv2/travel_core")
local portal_core = require("modules/ctron_pluginv2/portal_core")
local ct = require("modules/ctron_pluginv2/ct")
local debug_draw = require("modules/ctron_pluginv2/debug_draw")

local travel = {}

local function S()
	return storage.ctron_pluginv2.travel
end

local function ensure()
	local s = S()
	s.units, s.reqs, s.queue, s.asks, s.active = s.units or {}, s.reqs or {}, s.queue or {}, s.asks or {}, s.active or {}
	s.inflight, s.serial = s.inflight or 0, s.serial or 0
end

local function entity(unit)
	local v = game.get_entity_by_unit_number(unit)
	if v and v.valid then
		return v
	end
end

local mask
local function collision_mask()
	mask = mask or prototypes.entity["constructron_pathing_proxy_1"].collision_mask
	return mask
end

--- A ctronv2.travel line (R-12): with cid and jid when the ctron is registered and has a run (P1 / P2 seams).
local function trace(t, phase, level, fields)
	local p = fields or {}
	p.op, p.phase, p.level, p.tick, p.unit = "ctronv2.travel", phase, level, game.tick, t.unit
	local v = entity(t.unit)
	p.cid = v and ct.registry.ctron_of(v)
	local run = p.cid and ct.runs.get(p.cid)
	p.jid = run and run.jid
	bridge.send("trace", p)
end

local function drop(unit)
	S().units[unit], S().active[unit] = nil, nil
end

--- The frames of this surface's live sides, for the leaves-tile check.
function travel.live_frames(surface)
	local out = {}
	for _, side in ipairs(ue.edges.list(surface.index)) do
		if side.active and not side.deleted then
			out[#out + 1] = side.frame
		end
	end
	return out
end

local function direct(v, leg)
	return v.name == "constructron-rocket-powered" or core.short(v.position.x, v.position.y, leg.tx, leg.ty)
end

local function issue(t, v)
	local s = S()
	local spec = core.request_spec(t.leg.small, false)
	spec.start, spec.goal = v.position, { t.leg.tx, t.leg.ty }
	spec.force, spec.collision_mask = v.force, collision_mask()
	local id = v.surface.request_path(spec)
	s.reqs[id] = { unit = t.unit, n = t.leg.n }
	s.inflight = s.inflight + 1
end

--- One path request for t's current leg, or a place in the FIFO when 8 are in flight (R-77).
local function request(t, v)
	t.leg.pending = true
	if S().inflight >= core.TRAVEL_CAP then
		table.insert(S().queue, { unit = t.unit, n = t.leg.n })
		return
	end
	issue(t, v)
end

local function drain()
	local s = S()
	while s.inflight < core.TRAVEL_CAP and #s.queue > 0 do
		local q = table.remove(s.queue, 1)
		local t = s.units[q.unit]
		local v = t and t.leg and t.leg.n == q.n and entity(q.unit)
		if v then
			issue(t, v)
		end
	end
end

local retry = ue.runtime.scheduler.once({ name = "ctron.travel.retry", cap = 256, per_tick = 8, fn = function(args)
	local t = S().units[args.unit]
	local v = t and t.leg and t.leg.n == args.n and entity(args.unit)
	if v then
		request(t, v)
	end
end })

local function move(t, v)
	if direct(v, t.leg) then
		t.leg.pending = false
		v.autopilot_destination = { t.leg.tx, t.leg.ty }
	else
		request(t, v)
	end
end

--- Start a leg toward (x, y). purpose: "goal" (a stand point within r), or Task 5's "A" / "back" (exact points).
local fail

local function start_leg(t, v, x, y, r, purpose)
	local tx, ty = x, y
	if purpose == "goal" then
		-- Landfill (t.landfill = the construction radius): the goal is water, so stand on the nearest land within
		-- twice the reach; none means no_land, never the water goal.
		local p
		if t.landfill then
			p = v.surface.find_non_colliding_position("constructron_pathing_proxy_10", { x, y }, 2 * t.landfill, 2)
			if not p then
				fail(t, "no_land")
				return
			end
		else
			p = v.surface.find_non_colliding_position("constructron_pathing_proxy_10", { x, y }, r, 1)
			-- Work (t.reach = the construction radius): a task point in a lake moves to land its robots still reach it
			-- from, as they fly over water; none means no_land, never the water goal (ILLISIS/ctron_plugin#6).
			if not p and t.reach then
				p = v.surface.find_non_colliding_position("constructron_pathing_proxy_10", { x, y }, t.reach, 2)
				if not p then
					fail(t, "no_land")
					return
				end
			end
		end
		if p then
			tx, ty = p.x, p.y
		end
	end
	local s = S()
	s.serial = s.serial + 1 -- unique per tile, so a replaced travel's late result never matches (Review Focus 1)
	t.leg = { n = s.serial, tx = tx, ty = ty, r = r, purpose = purpose, small = false, stuck = 0, pending = false,
		lx = v.position.x, ly = v.position.y, at = game.tick }
	t.status, t.phase = "moving", nil
	S().active[t.unit] = true
	move(t, v)
end

fail = function(t, reason)
	t.status, t.reason = "failed", reason
	S().active[t.unit] = nil
	local v = entity(t.unit)
	if v then
		v.autopilot_destination = nil -- else it keeps walking at the target it failed to reach, often water (#6)
	end
	trace(t, reason, "warn")
	if t.kind == "station" and (reason == "no_path" or reason == "stuck") then
		ct.portals.dirty(t.surface) -- a failed dock leg (R-135)
	end
	ct.runs.on_failed(t.unit, reason)
end

local function arrived(t)
	t.status = "arrived"
	S().active[t.unit] = nil
	ct.runs.on_arrived(t.unit)
end

local ask, begin, next_step, hop_failed

local function robots_out(v)
	local cell = v.logistic_cell
	local net = cell and cell.logistic_network
	if not net then
		return 0
	end
	return net.all_construction_robots - net.available_construction_robots
end

local function side_of(surface, edge)
	for _, side in ipairs(ue.edges.list(surface.index)) do
		if side.id == edge then
			return side
		end
	end
end

local function reroute(t, v)
	t.reroutes = t.reroutes + 1
	if t.reroutes > core.REROUTES then
		fail(t, "budget")
		return
	end
	t.hop, t.phase = nil, nil
	ask(t, v)
end

-- Terrain failures only (R-161); reject, too_big and close are UE outcomes.
local DIRTY = { no_path = true, stuck = true, stale = true, not_captured = true }

hop_failed = function(t, v, reason)
	local hop = t.hop
	if hop then
		core.avoid_add(t.avoid, hop.key, game.tick)
		if reason == "reject" or reason == "too_big" then
			core.avoid_add(t.avoid, hop.edge, game.tick)
		end
	end
	if DIRTY[reason] then
		ct.portals.dirty(t.surface)
	end
	trace(t, "hop_failed", "warn", { reason = reason, edge = hop and hop.edge })
	reroute(t, v)
end

local function all_frames(surface)
	local out = {}
	for _, side in ipairs(ue.edges.list(surface.index)) do
		out[#out + 1] = side.frame
	end
	return out
end

--- R-133: walk back to A by direct autopilot (S to A is 9 tiles), then hop_failed / begin on arrival or failure.
local function back(t, v, reason)
	t.back_reason, t.stepping, t.phase = reason, false, nil
	local p = t.hop and { x = t.hop.ax, y = t.hop.ay } or core.step_back(all_frames(v.surface), v.position.x, v.position.y)
	if p then
		start_leg(t, v, p.x, p.y, 2, "back")
	else
		begin(t, v) -- not past any line: carry on from here
	end
end

local function step_out(t, v)
	t.phase, t.status, t.since, t.stepping = "step_out", "crossing", game.tick, true
	ue.vehicles.watch(v)
	v.autopilot_destination = { t.hop.sx, t.hop.sy }
end

local function start_hop(t, v, hop)
	t.hop = { edge = hop.edge, key = portal_core.key(hop.edge, hop.x) } -- so a stale hop avoids its window too
	local side = side_of(v.surface, hop.edge)
	if not (side and side.active and not side.deleted and hop.from == ct.registry.here()) then
		hop_failed(t, v, "stale")
		return
	end
	local xa = core.clamp_x(side.frame.length, hop.x)
	local A, S_, O = core.points(side.frame, side.me, xa)
	if v.surface.entity_prototype_collides("constructron_pathing_proxy_10", A, false)
		or v.surface.entity_prototype_collides("constructron_pathing_proxy_8", O, false) then
		hop_failed(t, v, "stale")
		return
	end
	t.hop = { edge = hop.edge, key = portal_core.key(hop.edge, xa), ax = A.x, ay = A.y, sx = S_.x, sy = S_.y }
	start_leg(t, v, A.x, A.y, 2, "A")
end

begin = function(t, v)
	if t.goal.inst == ct.registry.here() then
		start_leg(t, v, t.goal.x, t.goal.y, t.radius, "goal")
	else
		ask(t, v)
	end
end

next_step = function(t, v)
	local hop = t.route.hops[t.route.i]
	if hop then
		start_hop(t, v, hop)
	else
		start_leg(t, v, t.goal.x, t.goal.y, t.radius, "goal") -- the last hop lands on the goal's tile
	end
end

ask = function(t, v)
	local req = ue.runtime.trace.new_id()
	local cid = ct.registry.ctron_of(v)
	local run = cid and ct.runs.get(cid)
	t.status, t.leg, t.ask = "routing", nil, { req = req, at = game.tick }
	S().asks[req] = t.unit
	S().active[t.unit] = true
	bridge.send("ct.route.ask", { req = req, jid = run and run.jid, surface = t.surface,
		from = { x = v.position.x, y = v.position.y }, to = { inst = t.goal.inst, x = t.goal.x, y = t.goal.y },
		avoid = core.avoid_list(t.avoid, game.tick) })
	trace(t, "ask", "info")
end

bridge.on("ct.route.reply", function(p)
	local s = S()
	local unit = s.asks[p.req]
	if not unit then
		return
	end
	s.asks[p.req] = nil
	local t = s.units[unit]
	if not (t and t.status == "routing" and t.ask and t.ask.req == p.req) then
		return -- stale
	end
	t.ask = nil
	local v = entity(unit)
	if not v then
		drop(unit)
		return
	end
	if not p.route then
		fail(t, "no_route")
		return
	end
	local hops = p.route.hops or {}
	t.budget = t.budget or core.budget(#hops)
	t.route = { hops = hops, i = 1 }
	trace(t, t.reroutes > 0 and "rerouted" or "routed", "info", { hops = #hops })
	next_step(t, v)
end)

--- The leg after a crossing waits 12 ticks (R-78, R-136).
local settle = ue.runtime.scheduler.once({ name = "ctron.leg", cap = 256, per_tick = 8, fn = function(args, tick)
	local t = S().units[args.unit]
	if not (t and t.phase == "settle") then
		return
	end
	local v = entity(args.unit)
	if not v then
		drop(args.unit)
		return
	end
	t.phase, t.settled_at = nil, tick
	if t.begin then
		t.begin = nil
		begin(t, v) -- a go during the settle
	elseif args.planned then
		next_step(t, v)
	else
		reroute(t, v)
	end
end })

--- A leg failed after its ladder: a leg toward an A point or a back leg fails the hop.
local function leg_failed(t, v, reason)
	local purpose = t.leg.purpose
	if purpose == "A" then
		hop_failed(t, v, reason)
	elseif purpose == "back" then
		if t.hop then
			hop_failed(t, v, t.back_reason)
		else
			begin(t, v)
		end
	else
		fail(t, reason)
	end
end

--- The leg reached its target.
local function leg_arrived(t, v)
	local purpose = t.leg.purpose
	if purpose == "A" then
		t.phase, t.status, t.since = "wait_robots", "waiting_robots", game.tick
		if robots_out(v) == 0 then
			step_out(t, v)
		end
	elseif purpose == "back" then
		if t.hop then
			hop_failed(t, v, t.back_reason)
		else
			begin(t, v)
		end
	else
		arrived(t)
	end
end

local function stuck(t, v)
	t.leg.stuck = t.leg.stuck + 1
	trace(t, "stuck", "warn", { n = t.leg.stuck })
	if t.leg.stuck >= 2 then
		leg_failed(t, v, "stuck")
		return
	end
	v.autopilot_destination = nil
	t.leg.lx, t.leg.ly, t.leg.at = v.position.x, v.position.y, game.tick
	move(t, v)
end

local function leg_end(t, v)
	local p = v.position
	if core.near(p.x, p.y, t.leg.tx, t.leg.ty, t.leg.r + 2) then
		leg_arrived(t, v)
	else
		stuck(t, v) -- it stopped elsewhere, e.g. a player steered it
	end
end

local function on_path(e)
	local s = S()
	local r = s.reqs[e.id]
	if not r then
		return -- not travel's (portals' or another mod's)
	end
	s.reqs[e.id] = nil
	s.inflight = s.inflight - 1
	drain()
	local t = s.units[r.unit]
	if not (t and t.leg and t.leg.n == r.n) then
		return -- superseded or cancelled (Review Focus 1)
	end
	local v = entity(r.unit)
	if not v then
		drop(r.unit)
		return
	end
	if e.try_again_later then
		if not retry.schedule(core.RETRY, { unit = r.unit, n = r.n }) then
			request(t, v)
		end
		return
	end
	local why = not e.path and "no_path" or (core.leaves_tile(e.path, travel.live_frames(v.surface)) and "leaves_tile")
	if not why then
		local points = core.simplify(e.path)
		t.leg.pending = false
		v.autopilot_destination = nil
		for _, p in ipairs(points) do
			v.add_autopilot_destination(p)
		end
		t.leg.lx, t.leg.ly, t.leg.at = v.position.x, v.position.y, game.tick
		debug_draw.path(v.surface, points)
		return
	end
	trace(t, why, "info", { small = t.leg.small })
	if not t.leg.small then
		t.leg.small = true
		request(t, v)
		return
	end
	leg_failed(t, v, "no_path")
end

local function on_command_completed(e)
	local v = e.vehicle
	if not (v and v.valid) then
		return
	end
	local t = S().units[v.unit_number]
	if not (t and t.leg and t.status == "moving" and not t.leg.pending) or #v.autopilot_destinations > 0 then
		return
	end
	leg_end(t, v)
end

--- The watchdog (R-76): over active travels only; also the arrival check SP-12's fallback needs.
ue.runtime.scheduler.periodic({ name = "ctron.travel", interval = core.WATCH, fn = function(tick)
	local s = S()
	local units = {}
	for unit in pairs(s.active) do
		units[#units + 1] = unit
	end
	for _, unit in ipairs(units) do
		local t, v = s.units[unit], entity(unit)
		if not v then
			drop(unit) -- destroyed mid-travel (Review Focus 2)
		elseif t and t.status == "moving" and t.leg and not t.leg.pending then
			local p = v.position
			if #v.autopilot_destinations == 0 then
				leg_end(t, v)
			elseif tick - t.leg.at >= core.WATCH then -- a younger baseline: it may still be accelerating
				if core.stuck(t.leg.lx, t.leg.ly, p.x, p.y, v.stickers ~= nil and #v.stickers > 0) then
					stuck(t, v)
				else
					t.leg.lx, t.leg.ly, t.leg.at = p.x, p.y, tick
				end
			end
		elseif t and t.status == "routing" and t.ask and tick - t.ask.at >= core.ASK_RETRY then
			s.asks[t.ask.req] = nil
			ask(t, v) -- no fallback planner (R-148)
		elseif t and t.phase == "wait_robots" then
			local n = robots_out(v)
			if n == 0 then
				step_out(t, v)
			elseif tick - t.since >= core.ROBOT_WAIT then
				trace(t, "robots_left", "warn", { n = n })
				step_out(t, v)
			end
		elseif t and t.phase == "step_out" and tick - t.since >= core.CAPTURE_WAIT then
			trace(t, "not_captured", "warn")
			back(t, v, "not_captured")
		end
	end
	return #units
end })

function travel.go(unit, goal, opts)
	local v = entity(unit)
	if not v then
		return
	end
	local old = S().units[unit]
	local settling = old ~= nil and old.phase == "settle"
	travel.cancel(unit)
	local t = { unit = unit, surface = v.surface.name, goal = { inst = goal.inst, x = goal.x, y = goal.y },
		kind = opts.kind, radius = opts.radius or 3, landfill = opts.landfill, reach = opts.reach, avoid = {}, captures = 0,
		reroutes = 0 }
	S().units[unit] = t
	if settling then
		-- the 12 ticks after a crossing (R-78): the pending ctron.leg begins this travel instead of the old one
		t.phase, t.begin, t.status, t.arrived_at = "settle", true, "crossing", old.arrived_at
		S().active[unit] = true
	else
		-- R-210: a start past a live line (a follower that came to the step-out point) walks back first, or the path's
		-- leaves-tile check fails on its first waypoint.
		local p = core.step_back(all_frames(v.surface), v.position.x, v.position.y)
		if p then
			start_leg(t, v, p.x, p.y, 2, "back")
		else
			begin(t, v)
		end
	end
end

function travel.cancel(unit)
	local t = S().units[unit]
	if not t then
		return
	end
	local busy = S().active[unit]
	drop(unit)
	local v = busy and entity(unit)
	if v then
		v.autopilot_destination = nil
	end
end

function travel.status(unit)
	local t = S().units[unit]
	if t then
		return t.status, t.reason
	end
end

function travel.export(v)
	local t = S().units[v.unit_number]
	if not (t and S().active[v.unit_number]) then
		return nil -- only an active travel rides a crossing
	end
	local tick, avoid = game.tick, {}
	for key, until_tick in pairs(t.avoid) do
		if until_tick > tick then
			avoid[key] = until_tick - tick -- ticks left: each save has its own game.tick
		end
	end
	t.phase, t.status = "held", "crossing" -- UE freezes it: neither the watchdog nor a command-completed may act
	return { goal = t.goal, kind = t.kind, radius = t.radius, landfill = t.landfill, reach = t.reach,
		route = t.route and { hops = t.route.hops, i = t.route.i }, budget = t.budget, captures = t.captures,
		reroutes = t.reroutes, avoid = avoid, stepping = t.stepping }
end

function travel.import(v, data, edge)
	if not data then
		return
	end
	travel.cancel(v.unit_number)
	v.autopilot_destination = nil -- UE restores the mirrored destinations
	local tick, avoid = game.tick, {}
	for key, left in pairs(data.avoid or {}) do
		avoid[key] = tick + left
	end
	local t = { unit = v.unit_number, surface = v.surface.name, goal = data.goal, kind = data.kind,
		radius = data.radius, landfill = data.landfill, reach = data.reach, route = data.route, budget = data.budget,
		captures = (data.captures or 0) + 1, reroutes = data.reroutes or 0, avoid = avoid,
		status = "crossing", phase = "settle", arrived_at = tick }
	S().units[t.unit], S().active[t.unit] = t, true
	local planned = core.planned(t.route, data.stepping, edge)
	if planned then
		t.route.i = t.route.i + 1
	end
	trace(t, "arrived", "info", { edge = edge, planned = planned })
	if t.budget and t.captures > t.budget then
		t.phase = nil -- so the pending settle can't revive it
		fail(t, "budget")
		return
	end
	if not settle.schedule(core.SETTLE, { unit = t.unit, planned = planned }) then
		t.phase = nil -- the once queue is full: go now rather than never
		if planned then
			next_step(t, v)
		else
			reroute(t, v)
		end
	end
end

function travel.restored(v, why)
	local t = S().units[v.unit_number]
	if not (t and t.phase == "held") then
		return
	end
	trace(t, "restored", "warn", { why = why })
	back(t, v, why) -- R-133: walk back to A first, then re-route
end

travel.on_init = ensure
travel.on_server_startup = ensure
travel.events = {
	[defines.events.on_script_path_request_finished] = on_path,
	[defines.events.on_spider_command_completed] = on_command_completed,
}

return travel
