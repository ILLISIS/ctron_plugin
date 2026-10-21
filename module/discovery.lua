-- Work-cell discovery (spec §5.2, R-21..R-27): CC's work events grow 80×80 cells in O(1); a rescan task scans each due
-- cell one 20-tile strip per visit, on schedulable surfaces only, and keeps the cells' records for the report. State is
-- plain data in storage.ctron_pluginv2.cells (cells_core); `scan` is the rescan task's source.
local ue = require("modules/universal_edges")
local bridge = require("modules/ctron_pluginv2/bridge")
local cells = require("modules/ctron_pluginv2/cells_core")
local ct = require("modules/ctron_pluginv2/ct")
local items = require("modules/ctron_pluginv2/items_core")

local discovery = { events = {} }

local function S()
	return storage.ctron_pluginv2
end

-- Prototype caches (CC control.lua:270-294): built from prototypes only, so every peer agrees.
local function lazy(build)
	return setmetatable({}, {
		__index = function(t, name)
			local v = build(name)
			rawset(t, name, v)
			return v
		end,
	})
end

--- The item that places a prototype of `group` ("entity" or "tile"), {item, count}; bots use only the first.
local function placer(group)
	return lazy(function(name)
		local proto = prototypes[group][name]
		local first = proto and proto.items_to_place_this and proto.items_to_place_this[1]
		return first and { first.name, first.count } or false
	end)
end

local place_entity, place_tile = placer("entity"), placer("tile")

local mined = lazy(function(name)
	local m = {}
	local proto = prototypes.entity[name]
	for _, p in pairs(proto and proto.mineable_properties.products or {}) do
		if p.type == "item" then
			m[p.name] = p.amount_max or p.amount or 0
		end
	end
	return m
end)

--- Remove the cell; the missing record makes the next report flush send `rm`.
local function remove(s, wid)
	s.cells[wid] = nil
	s.scan[wid] = nil
	ct.report.mark("cell", wid)
end

--- An event of `kind` at entity e (or tile): grow its cell, queue it for scanning on a schedulable surface.
--- Returns the wid and the cell.
function discovery.touch(kind, e, tool)
	local s = S()
	if not (s and s.scan and e and e.valid) then
		return nil
	end
	local surface, pos = e.surface.name, e.position
	local key = cells.key(pos.x, pos.y)
	local wid = cells.wid(ct.registry.here(), surface, kind, key)
	local armed = not (s.cells[wid] and s.cells[wid].dirty)
	local c = cells.touch(s.cells, wid, kind, surface, key, pos.x, pos.y, game.tick, tool)
	if s.schedulable[surface] then
		s.scan[wid] = true
		-- A cell that is already dirty isn't re-sent per event (R-22).
		if armed then
			ct.report.mark("cell", wid)
		end
	end
	return wid, c
end

local function gate(surface_name, kind)
	return ct.settings.of(surface_name).kinds[kind]
end

local function live(event)
	local e = event.entity
	return S() and e and e.valid and e or nil
end

local GHOSTS = { ["entity-ghost"] = true, ["tile-ghost"] = true, ["item-request-proxy"] = true }

local function on_built(event)
	local e = live(event)
	if e and GHOSTS[e.type] and e.force.name == "player" and gate(e.surface.name, "construction") then
		discovery.touch("construction", e)
	end
end
discovery.events[defines.events.on_built_entity] = on_built
discovery.events[defines.events.script_raised_built] = on_built

discovery.events[defines.events.on_post_entity_died] = function(event)
	local g = event.ghost
	if S() and g and g.valid and g.type == "entity-ghost" and g.force.name == "player" and gate(g.surface.name, "rebuild") then
		discovery.touch("construction", g)
	end
end

discovery.events[defines.events.on_marked_for_deconstruction] = function(event)
	local e = live(event)
	if e and e.type ~= "fish" and gate(e.surface.name, "deconstruction") then
		discovery.touch("deconstruction", e)
	end
end

discovery.events[defines.events.on_marked_for_upgrade] = function(event)
	local e = live(event)
	if e and e.force.name == "player" and gate(e.surface.name, "upgrade") then
		discovery.touch("upgrade", e)
	end
end

-- Filtered in-engine by control.lua (R-23, SP-2); the force check stays the first read.
discovery.events[defines.events.on_entity_damaged] = function(event)
	local e = live(event)
	if e and e.force.name == "player" and gate(e.surface.name, "repair") then
		local _, c = discovery.touch("repair", e)
		if c then
			local pos = e.position
			cells.remember(c, pos.x, pos.y, e.name)
		end
	end
end

discovery.events[defines.events.on_sector_scanned] = function(event)
	local radar = event.radar
	if not (S() and radar and radar.valid and gate(radar.surface.name, "destroy")) then
		return
	end
	for _, e in pairs(radar.surface.find_entities_filtered({ area = event.area, force = "enemy",
		type = { "unit-spawner", "turret" } })) do
		discovery.touch("destroy", e)
	end
end

discovery.events[defines.events.on_pre_surface_deleted] = function(event)
	local s = S()
	local surface = game.get_surface(event.surface_index)
	if not (s and s.scan and surface) then
		return
	end
	local name = surface.name
	for wid, c in pairs(s.cells) do
		if c.surface == name then
			remove(s, wid)
		end
	end
	s.schedulable[name] = nil
end

-- Entity items (spec §5.2 step 3): each returns bring, out item maps, or nil to skip the entity.
local ITEMS = {}

ITEMS.construction = function(e)
	if not e.is_registered_for_construction() then
		return nil
	end
	local bring = {}
	local kind = e.type
	local place = kind == "entity-ghost" and place_entity[e.ghost_name] or kind == "tile-ghost" and place_tile[e.ghost_name]
	if place then
		items.add(bring, place[1], e.quality.name, place[2])
	end
	if kind ~= "tile-ghost" then
		for _, r in ipairs(e.item_requests) do
			items.add(bring, r.name, r.quality, r.count)
		end
	end
	return bring, {}
end

ITEMS.deconstruction = function(e)
	if not e.is_registered_for_deconstruction("player") then
		return nil
	end
	local kind = e.type
	if kind == "cliff" then
		return { ["cliff-explosives"] = { normal = 1 } }, {}
	elseif kind == "deconstructible-tile-proxy" then
		return {}, { concrete = { normal = 1 } } -- CC's assumption (entity_processor.lua:494-497)
	elseif kind == "item-entity" then
		local stack = e.stack
		return {}, items.add({}, stack.name, stack.quality.name, stack.count)
	end
	local out = {}
	-- Per entity, nil-guarded as CC does: a prototype-level cache would depend on which entity a peer meets first.
	for i = 1, e.get_max_inventory_index() do
		local inv = e.get_inventory(i)
		if inv then
			for _, it in ipairs(inv.get_contents()) do
				items.add(out, it.name, it.quality, it.count)
			end
		end
	end
	local quality = e.quality.name
	for name, n in pairs(mined[e.name]) do
		items.add(out, name, quality, n)
	end
	return {}, out
end

ITEMS.upgrade = function(e)
	if not e.is_registered_for_upgrade() then
		return nil
	end
	local target, quality = e.get_upgrade_target()
	local bring, out = {}, {}
	local place = target and place_entity[target.name]
	if place then
		items.add(bring, place[1], quality.name, place[2])
	end
	place = place_entity[e.name] -- the replaced item comes back (CC used the target's name here, a slip)
	if place then
		items.add(out, place[1], e.quality.name, place[2])
	end
	return bring, out
end

ITEMS.repair = function(e, cfg)
	if not e.is_registered_for_repair() then
		return nil
	end
	return { [cfg.repair_tool[1]] = { [cfg.repair_tool[2]] = 1 } }, {}
end

--- Whether pos is inside a real construction zone (R-25, R-144) and the entity is skipped. SP-6 fallback: a network
--- counts only if some cell's owner isn't a spider-vehicle (a ctron's own cell is no zone). `zones` memoises the answer
--- per network for one visit: LuaLogisticNetwork.cells builds the whole array on every read.
local function covered(surface, c, cfg, pos, zones)
	if not cfg.zone_restriction or c.tool or c.kind == "destroy" then
		return false
	end
	for _, net in pairs(surface.find_logistic_networks_by_construction_area(pos, "player")) do
		local id = net.network_id
		local real = zones[id]
		if real == nil then
			real = false
			for _, cell in pairs(net.cells) do
				if cell.owner.type ~= "spider-vehicle" then
					real = true
					break
				end
			end
			zones[id] = real
		end
		if real then
			return true
		end
	end
	return false
end

local STRIP_FILTERS = {
	construction = { type = { "entity-ghost", "tile-ghost", "item-request-proxy" }, force = "player" },
	deconstruction = { to_be_deconstructed = true, force = { "player", "neutral" } },
	upgrade = { to_be_upgraded = true, force = "player" },
	repair = { force = "player" },
}

--- Entities one visit may scan (UPS, §14.5): a dense strip costs
--- about 3.5-4.5 us per tree, so 200 is about 0.8 ms.
--- count_entities_filtered is about 13x cheaper than find (SP-3), so a strip is counted first and its y-extent halved
--- until the piece fits, down to one tile. The count is over the padded area, an upper bound on what is scanned.
discovery.ENTITY_BUDGET = 200

--- One piece of the cell's current 20-tile strip; true when the strip was the last piece of the last strip. c.y is the
--- piece's start in y (nil at the strip's start); a piece owns positions with y in [c.y, end), so none is counted twice.
local function scan_strip(surface, c, cfg)
	local area, lo = cells.strip_area(c, c.strip)
	local top, bottom = c.y or area.left_top.y, area.right_bottom.y
	local filter = { area = area }
	for k, v in pairs(STRIP_FILTERS[c.kind]) do
		filter[k] = v
	end
	local pieces_end = bottom
	while pieces_end - top > 1 do
		area.left_top.y, area.right_bottom.y = top - 0.5, pieces_end + 0.5
		if surface.count_entities_filtered(filter) <= discovery.ENTITY_BUDGET then
			break
		end
		pieces_end = top + (pieces_end - top) / 2
	end
	area.left_top.y, area.right_bottom.y = top - 0.5, pieces_end + 0.5
	local item_of, zones = ITEMS[c.kind], {}
	for _, e in pairs(surface.find_entities_filtered(filter)) do
		local pos = e.position
		if cells.owns(c, lo, pos.x, pos.y) and pos.y >= top and pos.y < pieces_end then
			local ratio = c.kind == "repair" and e.get_health_ratio()
			if (c.kind ~= "repair" or (ratio and ratio < 1)) and not covered(surface, c, cfg, pos, zones) then
				local bring, out = item_of(e, cfg)
				if bring then
					cells.count(c, bring, out, pos.x, pos.y)
				end
			end
		end
	end
	if pieces_end < bottom then
		c.y = pieces_end
		return false
	end
	c.y = nil
	c.strip = c.strip + 1
	return c.strip > cells.strips(c)
end

local function scan_repair(surface, c, cfg)
	-- Area scan past the cap (ents == false, R-24), or finishing one a damage event's first remember interrupted.
	if not c.ents or c.strip > 1 or c.y then
		return scan_strip(surface, c, cfg)
	end
	local zones = {}
	for k, r in pairs(c.ents) do
		local e = surface.find_entity(r[1], { r[2], r[3] })
		local ratio = e and e.get_health_ratio()
		if not (ratio and ratio < 1) then
			c.ents[k] = nil
			c.nents = c.nents - 1
		elseif not covered(surface, c, cfg, e.position, zones) then
			local bring, out = ITEMS.repair(e, cfg) -- a robot already dispatched keeps the entry, uncounted
			if bring then
				cells.count(c, bring, out)
			end
		end
	end
	return true
end

local function enemies(surface, area)
	return surface.find_entities_filtered({ area = area, force = "enemy", type = { "unit-spawner", "turret" } })
end

local function nodes(list)
	local out = {}
	for i, e in ipairs(list) do
		out[i] = { id = e.unit_number, x = e.position.x, y = e.position.y }
	end
	return out
end

-- ponytail: up to FLOOD_CAP small searches in one visit; spread them over visits if SP-7 or the bench shows the spike.
local function scan_destroy(surface, c, _cfg, wid)
	local s = S()
	local found = enemies(surface, { left_top = { x = c.min.x - 0.5, y = c.min.y - 0.5 },
		right_bottom = { x = c.max.x + 0.5, y = c.max.y + 0.5 } })
	if #found == 0 then
		return true
	end
	local list = cells.flood(nodes(found), function(n)
		return nodes(enemies(surface, { left_top = { x = n.x - 8, y = n.y - 8 }, right_bottom = { x = n.x + 8, y = n.y + 8 } }))
	end, cells.FLOOD_CAP)
	-- The oldest destroy cell among this one and those the flood reached survives (smallest since, then wid), so a live
	-- job keeps its wid (R-128). A younger visitor removes itself and re-arms the older cell.
	local reached = {}
	for _, key in ipairs(cells.absorbed(list, c.key)) do
		local other = cells.wid(ct.registry.here(), c.surface, "destroy", key)
		if other ~= wid and s.cells[other] then
			reached[#reached + 1] = other
		end
	end
	local oldest = wid
	for _, other in ipairs(reached) do
		local o, b = s.cells[other], s.cells[oldest]
		if o.since < b.since or (o.since == b.since and other < oldest) then
			oldest = other
		end
	end
	if oldest ~= wid then
		local o = s.cells[oldest]
		-- Widen it over the whole flood, so this cell's spawners still have a cell; a scan under a moved bbox restarts.
		local lo, hi = cells.extent(list)
		o.min.x, o.min.y = math.min(o.min.x, lo.x), math.min(o.min.y, lo.y)
		o.max.x, o.max.y = math.max(o.max.x, hi.x), math.max(o.max.y, hi.y)
		o.strip, o.acc, o.scan_start, o.y = nil, nil, nil, nil
		o.dirty, o.t = true, game.tick
		if s.schedulable[o.surface] then
			s.scan[oldest] = true
		end
		ct.report.mark("cell", oldest)
		remove(s, wid)
		for _, other in ipairs(reached) do
			if other ~= oldest then
				remove(s, other)
			end
		end
		return true
	end
	c.min, c.max = cells.extent(list)
	for _, other in ipairs(reached) do
		remove(s, other)
	end
	for _ = 1, #list do
		cells.count(c, {}, {})
	end
	return true
end

local SCAN = {
	construction = scan_strip, deconstruction = scan_strip, upgrade = scan_strip, repair = scan_repair,
	destroy = scan_destroy,
}

--- One rescan visit (spec §5.2 "The rescan").
function discovery.visit(wid)
	local s = S()
	if not (s and s.scan) then
		return
	end
	local c = s.cells[wid]
	if not (c and s.schedulable[c.surface]) then
		s.scan[wid] = nil
		return
	end
	local tick = game.tick
	if not c.strip then
		if not cells.ready(c, tick, ct.settings.global().job_start_delay) then
			return
		end
		cells.begin(c, tick)
		c.y = nil
	end
	local surface = game.get_surface(c.surface)
	if not surface then
		remove(s, wid)
		return
	end
	if not SCAN[c.kind](surface, c, ct.settings.of(c.surface), wid) then
		return
	end
	if not s.cells[wid] then -- a destroy cell that gave way to an older one
		return
	end
	if cells.finish(c, ct.settings.stacks, ct.settings.allowed) then
		remove(s, wid)
	else
		if not c.dirty then
			s.scan[wid] = nil
		end
		ct.report.mark("cell", wid)
	end
end

-- fn deletes its own key; a destroy visit may delete other keys (UE restarts a walk only when the cursor key itself
-- vanished) and, when a younger cell gives way, adds the older cell's key. That is safe only because per_tick = 1
-- (scheduler_core.lua:227): the walk is never in the middle of a batch. Events add keys between ticks.
ue.runtime.scheduler.iterate({
	name = "ctron.rescan", per_tick = 1, interval = 60,
	source = function()
		local s = S()
		return s and s.scan
	end,
	fn = function(wid)
		discovery.visit(wid)
	end,
})

--- target: an array of wids, or {surface, kind}.
function discovery.clear(target)
	local s = S()
	if not (s and s.scan) then
		return
	end
	if target.surface then
		for wid, c in pairs(s.cells) do
			if c.surface == target.surface and c.kind == target.kind then
				remove(s, wid)
			end
		end
	else
		for _, wid in ipairs(target) do
			if s.cells[wid] then
				remove(s, wid)
			end
		end
	end
end

--- R-127: skip the quiet period and drop a scan in progress.
function discovery.rescan_now(wids)
	local s = S()
	for _, wid in ipairs(wids) do
		local c = s and s.cells[wid]
		if c then
			cells.force(c)
			if s.schedulable[c.surface] then
				s.scan[wid] = true
			end
		end
	end
end

function discovery.cell(wid)
	local s = S()
	return s and s.cells[wid]
end

-- ponytail: O(cells) with an early exit; count per surface if the bench shows it.
function discovery.has_cells(surface)
	local s = S()
	for _, c in pairs(s and s.cells or {}) do
		if c.surface == surface then
			return true
		end
	end
	return false
end

--- surfaces: the schedulable surface names, from ct.settings (R-145).
function discovery.set_schedulable(surfaces)
	local s = S()
	if not (s and s.scan) then
		return
	end
	local new = {}
	for _, name in ipairs(surfaces) do
		new[name] = true
	end
	for wid, c in pairs(s.cells) do
		if new[c.surface] and not s.schedulable[c.surface] then
			-- a snapshot taken meanwhile left this cell out and the controller dropped it: report clean ones too
			if c.dirty or c.forced then
				s.scan[wid] = true
			end
			ct.report.mark("cell", wid) -- the controller learns of it now
		end
	end
	for wid in pairs(s.scan) do
		local c = s.cells[wid]
		if not (c and new[c.surface]) then
			s.scan[wid] = nil
		end
	end
	s.schedulable = new
end

--- The cell's wire record, nil for a missing cell or one on a surface that isn't schedulable.
function discovery.record(wid)
	local s = S()
	local c = s and s.cells[wid]
	if not (c and s.schedulable[c.surface]) then
		return nil
	end
	return cells.record(c, wid, game.tick, ct.settings.global().job_start_delay)
end

function discovery.records()
	local out = {}
	for wid in pairs(S().cells) do
		out[#out + 1] = discovery.record(wid)
	end
	return out
end

bridge.on("ct.work.clear", function(payload)
	if payload.wids then
		discovery.clear(payload.wids)
	elseif payload.surface and payload.kind then
		discovery.clear({ surface = payload.surface, kind = payload.kind })
	else
		return false
	end
end)

local function init()
	local s = S()
	s.scan = s.scan or {}
	s.schedulable = s.schedulable or {}
end

discovery.on_init = init
discovery.on_server_startup = init

return discovery
