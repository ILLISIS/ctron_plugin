-- The tile's portal graph (spec §7.4): dirty tracking, side probes, connectivity requests and the ct.portals report.
-- portal_core decides; this file reads the game. State is plain data in storage.ctron_pluginv2.portals.
local ue = require("modules/universal_edges")
local bridge = require("modules/ctron_pluginv2/bridge")
local core = require("modules/ctron_pluginv2/portal_core")
local ct = require("modules/ctron_pluginv2/ct")
local tcore = require("modules/ctron_pluginv2/travel_core")

local portals = {}
local QUIET = 1800 -- R-84: refresh once a surface has been dirty and quiet this long
local MAX_INFLIGHT = 4 -- connectivity requests in flight per tile (R-77)
local STALL = 40000 -- a refresh older than this is abandoned (lost probes: queue ttl 36000)
local REQ_TTL = 3600 -- a path request unanswered this long is forgotten
local LAYER = "constructron_pathing_layer"

local function S()
	return storage.ctron_pluginv2.portals
end

local function ensure()
	local s = S()
	s.surfaces, s.reqs = s.surfaces or {}, s.reqs or {}
	s.serial, s.inflight = s.serial or 0, s.inflight or 0
end

local blocking_tiles, blocking_entities -- lazy name sets: same prototypes on every peer, so never in storage
local function sets()
	if blocking_tiles then
		return
	end
	blocking_tiles, blocking_entities = {}, {}
	for name, proto in pairs(prototypes.tile) do
		if proto.collision_mask.layers[LAYER] then
			blocking_tiles[name] = true
		end
	end
	for name, proto in pairs(prototypes.entity) do
		if proto.collision_mask.layers[LAYER] then
			blocking_entities[name] = true
		end
	end
end

local function mark(name)
	local P = S().surfaces[name]
	if P then
		P.dirty_at = game.tick
	end
end

local function trace(phase, fields)
	fields.op, fields.phase, fields.level, fields.tick = "ctronv2.portals", phase, "info", game.tick
	bridge.send("trace", fields)
end

local function sorted_keys(t)
	local out = {}
	for k in pairs(t) do
		out[#out + 1] = k
	end
	table.sort(out)
	return out
end

local function finish(surface, P)
	P.epoch = (P.epoch or 0) + 1
	local nodes = P.nodes
	P.report = core.report(surface.name, P.epoch, nodes, P.uf)
	P.phase, P.run, P.left, P.edges, P.open = nil, nil, nil, nil, nil
	P.nodes, P.uf, P.j, P.cands, P.ci = nil, nil, nil, nil, nil
	P.stats.ticks = game.tick - P.stats.started
	bridge.send("ct.portals", P.report)
	trace("report", { surface = surface.name, epoch = P.epoch, nodes = #nodes })
end

local retry
local function request(surface, P)
	local s = S()
	if s.inflight >= MAX_INFLIGHT then
		if not retry.schedule(tcore.RETRY, { surface = surface.name, run = P.run }) then
			P.phase, P.dirty_at = nil, game.tick -- dropped: start over after the quiet period
		end
		return
	end
	local from, to = P.nodes[P.j], P.nodes[P.cands[P.ci]]
	local spec = tcore.request_spec(false, true)
	spec.surface, spec.start, spec.goal = surface, { from.x, from.y }, { to.x, to.y }
	spec.force = "player"
	spec.collision_mask = prototypes.entity["constructron_pathing_proxy_1"].collision_mask
	s.reqs[surface.request_path(spec)] = { surface = surface.name, run = P.run, at = game.tick }
	s.inflight = s.inflight + 1
	P.stats.requests = P.stats.requests + 1
end

--- Behaviour 5's loop: the next (node, candidate) pair to ask about, or the report.
local function next_test(surface, P)
	while true do
		if P.j > #P.nodes then
			return finish(surface, P)
		end
		if not P.cands then
			P.cands, P.ci = core.candidates(P.nodes, P.uf, P.j), 1
		end
		if P.ci <= #P.cands then
			return request(surface, P)
		end
		P.j, P.cands = P.j + 1, nil -- no candidate left: node j starts its own component
	end
end

local function build_nodes(surface, P)
	local nodes = {}
	for _, id in ipairs(sorted_keys(P.edges)) do
		local e = P.edges[id]
		local wins = core.windows(e.length, P.open[id])
		for _, k in ipairs(sorted_keys(wins)) do
			local w = wins[k]
			local A = tcore.points(e.frame, e.me, w.x)
			nodes[#nodes + 1] = { kind = "w", edge = id, k = k, lo = w.lo, hi = w.hi, x = A.x, y = A.y }
		end
	end
	for _, sid in ipairs(ct.registry.stations_on(surface.name)) do
		local station = ct.registry.station(sid)
		local ent = station and station.entity
		if ent and ent.valid then
			local p = surface.find_non_colliding_position("constructron_pathing_proxy_10", ent.position, 10, 1)
				or ent.position
			nodes[#nodes + 1] = { kind = "s", sid = sid, x = p.x, y = p.y }
		end
	end
	P.nodes, P.uf, P.j, P.phase = nodes, core.uf(#nodes), 2, "connect"
	next_test(surface, P)
end

local function probed(surface, P)
	P.left = P.left - 1
	if P.left == 0 then
		build_nodes(surface, P)
	end
end

local probe = ue.runtime.scheduler.queue({ name = "ctron.portals.probe", cap = 4096, ttl_ticks = 36000, per_tick = 16,
	fn = function(item)
		local surface = game.get_surface(item.surface)
		local P = S().surfaces[item.surface]
		if not (surface and P and P.phase == "probe" and P.run == item.run) then
			return
		end
		local e = P.edges[item.edge]
		local A, _, O = tcore.points(e.frame, e.me, item.xa)
		if not (surface.entity_prototype_collides("constructron_pathing_proxy_10", A, false)
			or surface.entity_prototype_collides("constructron_pathing_proxy_8", O, false)) then
			P.open[item.edge][item.xa] = true
		end
		probed(surface, P)
	end })

retry = ue.runtime.scheduler.once({ name = "ctron.portals.retry", cap = 64, per_tick = 4, fn = function(args)
	local surface = game.get_surface(args.surface)
	local P = S().surfaces[args.surface]
	if not (P and P.phase == "connect" and P.run == args.run) then
		return
	end
	if surface then
		request(surface, P)
	else
		P.phase = nil
	end
end })

local function start_refresh(surface, P, sides, tick)
	local s = S()
	s.serial = s.serial + 1
	P.dirty_at, P.phase, P.run = nil, "probe", s.serial
	P.stats = { started = tick, probes = 0, requests = 0 }
	P.edges, P.open, P.left = {}, {}, 0
	trace("refresh", { surface = surface.name })
	local pending = {}
	for _, side in ipairs(sides) do
		P.edges[side.id] = { me = side.me, length = side.length, frame = side.frame }
		P.open[side.id] = {}
		for _, xa in ipairs(core.samples(side.length)) do
			pending[#pending + 1] = { surface = surface.name, run = P.run, edge = side.id, xa = xa }
		end
	end
	P.left = #pending
	for _, item in ipairs(pending) do
		if probe.push(item) then
			P.stats.probes = P.stats.probes + 1
		else
			P.left = P.left - 1 -- dropped: a closed sample
		end
	end
	if P.left == 0 then
		build_nodes(surface, P)
	end
end

ue.runtime.scheduler.periodic({ name = "ctron.portals", interval = 600, fn = function(tick)
	local s = S()
	local surfaces = s.surfaces
	for name, P in pairs(surfaces) do
		if not game.get_surface(name) then
			surfaces[name] = nil
		elseif P.phase and tick - P.stats.started > STALL then
			P.phase, P.dirty_at = nil, tick -- lost probes or results: start over after the quiet period
			P.run, P.left, P.edges, P.open, P.nodes, P.uf, P.j, P.cands, P.ci = nil, nil, nil, nil, nil, nil, nil, nil, nil
		end
	end
	local live = 0
	for id, r in pairs(s.reqs) do
		if tick - r.at > REQ_TTL then
			s.reqs[id] = nil
		else
			live = live + 1
		end
	end
	s.inflight = live -- results of a deleted surface or a lost request never decrement
	for _, surface in pairs(game.surfaces) do
		local sides = {}
		for _, side in ipairs(ue.edges.list(surface.index)) do
			if not side.deleted then
				sides[#sides + 1] = side
			end
		end
		table.sort(sides, function(a, b) return a.id < b.id end)
		local ids = {}
		for i, side in ipairs(sides) do
			ids[i] = side.id
		end
		ids = table.concat(ids, ",")
		local P = surfaces[surface.name]
		if not P and #sides > 0 then
			P = { sides = ids, epoch = 0, dirty_at = tick - QUIET }
			surfaces[surface.name] = P
		elseif P and P.sides ~= ids then
			P.sides, P.dirty_at = ids, tick
		end
		if P and not P.phase and P.dirty_at and tick - P.dirty_at >= QUIET then
			start_refresh(surface, P, sides, tick)
		end
	end
end })

local function on_path(e)
	local s = S()
	local r = s.reqs[e.id]
	if not r then
		return -- not portals' (travel's or another mod's)
	end
	s.reqs[e.id] = nil
	s.inflight = s.inflight - 1
	local P = s.surfaces[r.surface]
	if not (P and P.phase == "connect" and P.run == r.run) then
		return
	end
	local surface = game.get_surface(r.surface)
	if not surface then
		P.phase = nil
		return
	end
	if e.try_again_later then
		if not retry.schedule(tcore.RETRY, { surface = r.surface, run = r.run }) then
			P.phase, P.dirty_at = nil, game.tick
		end
		return
	end
	if e.path and not tcore.leaves_tile(e.path, ct.travel.live_frames(surface)) then
		core.union(P.uf, P.cands[P.ci], P.j)
		P.j, P.cands = P.j + 1, nil
	else
		P.ci = P.ci + 1
	end
	next_test(surface, P)
end

local function tracked(surface_index)
	local surface = game.get_surface(surface_index)
	return surface and S().surfaces[surface.name] and surface
end

local function on_tiles_built(e)
	local surface = tracked(e.surface_index)
	if not surface then
		return
	end
	sets()
	local now = blocking_tiles[e.tile.name] or false
	for _, t in ipairs(e.tiles) do
		if (blocking_tiles[t.old_tile.name] or false) ~= now then
			mark(surface.name)
			return
		end
	end
end

local function on_tiles_mined(e)
	local surface = tracked(e.surface_index)
	if not surface then
		return
	end
	sets()
	for _, t in ipairs(e.tiles) do
		if (blocking_tiles[t.old_tile.name] or false) ~= (blocking_tiles[surface.get_tile(t.position).name] or false) then
			mark(surface.name)
			return
		end
	end
end

local function on_tiles_set(e)
	local surface = tracked(e.surface_index)
	if surface then
		mark(surface.name)
	end
end

local function on_entity(e)
	local ent = e.entity
	if not (ent and ent.valid) then
		return
	end
	sets()
	if blocking_entities[ent.name] then
		mark(ent.surface.name)
	end
end

function portals.reports()
	local out = {}
	for name, P in pairs(S().surfaces) do
		out[name] = P.report
	end
	return out
end

function portals.dirty(name)
	mark(name)
end

portals.on_init = ensure
portals.on_server_startup = ensure
portals.events = {
	[defines.events.on_script_path_request_finished] = on_path,
	[defines.events.on_player_built_tile] = on_tiles_built,
	[defines.events.on_robot_built_tile] = on_tiles_built,
	[defines.events.on_player_mined_tile] = on_tiles_mined,
	[defines.events.on_robot_mined_tile] = on_tiles_mined,
	[defines.events.script_raised_set_tiles] = on_tiles_set,
	[defines.events.on_built_entity] = on_entity,
	[defines.events.on_robot_built_entity] = on_entity,
	[defines.events.script_raised_built] = on_entity,
	[defines.events.on_player_mined_entity] = on_entity,
	[defines.events.on_robot_mined_entity] = on_entity,
	[defines.events.on_entity_died] = on_entity,
	[defines.events.script_raised_destroy] = on_entity,
}

return portals
