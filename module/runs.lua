-- The tile's run shell (spec §5.3, R-105): turns ct.job.assign into runs, feeds run_core lazily computed facts,
-- applies its effects through P1's seams, steps runs on UE's iterate task and travel's callbacks, ends a run whose ctron
-- was destroyed, and gives P1's report the job records.
local ct = require("modules/ctron_pluginv2/ct")
local bridge = require("modules/ctron_pluginv2/bridge")
local run_core = require("modules/ctron_pluginv2/run_core")
local combat_core = require("modules/ctron_pluginv2/combat_core")
local items = require("modules/ctron_pluginv2/items_core")
local debug_draw = require("modules/ctron_pluginv2/debug_draw")
local ue = require("modules/universal_edges")

local runs = { events = {} }

local function S()
	return storage.ctron_pluginv2
end

function runs.trace(op, phase, level, jid, cid, fields)
	fields = fields or {}
	fields.op, fields.phase, fields.level, fields.tick, fields.jid, fields.cid = op, phase, level, game.tick, jid, cid
	bridge.send("trace", fields)
end

--- The run of cid, in transit included; nil for a missing or ended one.
function runs.get(cid)
	local run = S().runs[cid]
	if run and run.state ~= "ended" then
		return run
	end
end

--- This tile's runs of the job that haven't ended.
function runs.of_job(jid)
	local out = {}
	for _, run in pairs(S().runs) do
		if run.jid == jid and run.state ~= "ended" then
			out[#out + 1] = run
		end
	end
	return out
end

function runs.put(run)
	S().runs[run.cid] = run
end

-- travel also moves parked ctrons that have no run (P3's request 5).
local function by_unit(unit)
	local cid = S().by_unit[unit]
	local run = cid and S().runs[cid]
	if run and not run.in_transit and run.state ~= "ended" then
		return run
	end
end

-- Lazy facts: created per step, each computed on first read and cached. Every function returns a value, never nil.
local FACT = {}
local function facts_for(run, entity, cfg)
	local ctx = { run = run, entity = entity, cfg = cfg }
	return setmetatable({ tick = game.tick, here = ct.registry.here() }, {
		__index = function(f, key)
			local fn = FACT[key]
			if not fn then
				return nil
			end
			local value = fn(f, ctx)
			rawset(f, key, value)
			return value
		end,
	})
end

local function inv(entity, which)
	return entity.get_inventory(which)
end

FACT.pos = function(_, c) return c.entity.position end
FACT.health = function(_, c) return c.entity.get_health_ratio() end
FACT.net = function(_, c) return c.entity.logistic_network or false end
FACT.robots = function(f) return f.net and f.net.all_construction_robots or 0 end
-- SP-9 primary: the integer difference is the robots out.
FACT.out = function(f)
	return f.net and (f.net.all_construction_robots - f.net.available_construction_robots) or 0
end
FACT.radius = function(_, c)
	local cell = c.entity.logistic_cell
	return cell and cell.construction_radius or 0
end

local COUNT = {
	construction = function(e) return { type = { "entity-ghost", "tile-ghost", "item-request-proxy" }, force = e.force } end,
	deconstruction = function(e) return { to_be_deconstructed = true, force = { e.force, "neutral" } } end,
	upgrade = function(e) return { to_be_upgraded = true, force = e.force } end,
}
FACT.count = function(f, c)
	local make = COUNT[c.run.kind]
	if not make then
		return 0
	end
	local filter = make(c.entity)
	filter.position, filter.radius = f.pos, f.radius
	return c.entity.surface.count_entities_filtered(filter)
end

FACT.trunk_count = function(_, c) return inv(c.entity, defines.inventory.spider_trunk).get_item_count() end
-- ponytail: spawn_minimum isn't readable at runtime; its default, 20 % of the energy buffer (prototype docs), is assumed.
FACT.can_spawn = function(_, c)
	local grid = c.entity.grid
	for _, eq in pairs(grid and grid.equipment or {}) do
		if eq.type == "roboport-equipment" and eq.energy >= 0.2 * eq.max_energy then
			return true
		end
	end
	return false
end

local function ammo_count(c, which)
	if c.cfg.ammo_count == 0 then
		return 0
	end
	return inv(c.entity, which).get_item_count({ name = c.cfg.ammo[1], quality = c.cfg.ammo[2] })
end
FACT.ammo_slots = function(_, c) return ammo_count(c, defines.inventory.spider_ammo) end
FACT.ammo_trunk = function(_, c) return ammo_count(c, defines.inventory.spider_trunk) end
FACT.landfill_aboard = function(_, c)
	return c.run.landfill and inv(c.entity, defines.inventory.spider_trunk).get_item_count(c.run.landfill) or 0
end
FACT.fulfilled = function(f, c)
	local ok, missing, held, excess = ct.logistics.fulfilled(c.entity)
	rawset(f, "fulfilled", ok)
	rawset(f, "missing", missing)
	rawset(f, "held", held)
	rawset(f, "excess", excess)
	return ok
end
FACT.missing = function(f)
	local _ = f.fulfilled
	return rawget(f, "missing")
end
-- §5.4 kept items / R-132: unloading needs no minimum met (a player's own section may ask for what the network lacks),
-- only nothing above a max or unnamed, and the trash empty.
FACT.unloaded = function(f)
	local _ = f.fulfilled
	return not rawget(f, "excess") and f.trash_empty
end
FACT.trash_empty = function(_, c) return ct.logistics.trash_empty(c.entity) end
FACT.delivered = function(f, c)
	local trunk = inv(c.entity, defines.inventory.spider_trunk)
	for _, it in ipairs(c.run.cargo.items) do
		if trunk.get_item_count({ name = it[1], quality = it[2] }) > 0 then
			return false
		end
	end
	return f.trash_empty
end
FACT.trash_items = function(_, c)
	local map = {}
	for _, it in ipairs(inv(c.entity, defines.inventory.spider_trash).get_contents()) do
		items.add(map, it.name, it.quality, it.count)
	end
	return map
end
FACT.station = function(f, c)
	if c.run.station.inst ~= f.here then
		return false
	end
	local rec = ct.registry.station(c.run.station.sid)
	return rec and rec.entity.valid and rec or false
end
FACT.station_ok = function(f)
	return f.station and f.station.entity.logistic_network ~= nil and f.station.entity.energy > 0 or false
end
FACT.covers_missing = function(f)
	if not f.station_ok then
		return false
	end
	local list = {}
	for _, it in ipairs(items.tuples(f.missing)) do
		if it[2] ~= "any" then
			list[#list + 1] = { it[1], it[2], 1 } -- R-35: some of it, not the full count (robots carry stock in flight)
		end
	end
	return ct.logistics.cover(f.station.entity.logistic_network, list, "supply") ~= nil
end
-- R-34 / run_core: the stop's network can take no trash item (or is gone); gates every trash deadline.
FACT.trash_stuck = function(f, c)
	local at = c.run.state == "deliver" and c.run.cargo and c.run.cargo.dest or c.run.station
	local rec = at.inst == f.here and ct.registry.station(at.sid)
	local net = rec and rec.entity.valid and rec.entity.logistic_network
	if not net then
		return true
	end
	return ct.logistics.cover(net, items.tuples(f.trash_items), "drop") == nil
end

--- The nearest powered station with a network on the run's surface other than its own; `need_drop` also wants it to
--- take every trash item.
local function other_station(f, c, need_drop)
	local pos, best, best_d = f.pos, nil, nil
	for _, sid in ipairs(ct.registry.stations_on(c.run.surface)) do
		local rec = sid ~= c.run.station.sid and ct.registry.station(sid)
		local e = rec and rec.entity
		local net = e and e.valid and e.logistic_network
		if net and e.energy > 0 and (not need_drop or ct.logistics.cover(net, items.tuples(f.trash_items), "drop") == true) then
			local d = (e.position.x - pos.x) ^ 2 + (e.position.y - pos.y) ^ 2
			if not best_d or d < best_d then
				best, best_d = { sid = sid, inst = f.here, x = e.position.x, y = e.position.y }, d
			end
		end
	end
	return best or false
end
FACT.alt_station = function(f, c) return other_station(f, c, false) end
FACT.drop_station = function(f, c) return other_station(f, c, true) end

FACT.enemy_near = function(f, c)
	return c.entity.surface.count_entities_filtered({ position = f.pos,
		radius = combat_core.gun_range(c.entity.quality.name) + 4, force = "enemy", is_military_target = true,
		limit = 1 }) > 0
end
FACT.leader = function(f, c)
	local lead = c.run.squad and c.run.role == "minion" and S().runs[c.run.squad.leader]
	local rec = lead and lead.jid == c.run.jid and not lead.in_transit and lead.state ~= "ended" and ct.registry.ctron(lead.cid)
	local e = rec and rec.entity
	if not (e and e.valid) then
		return false
	end
	local p = f.pos
	return { state = lead.state, pos = e.position, dist = math.sqrt((e.position.x - p.x) ^ 2 + (e.position.y - p.y) ^ 2),
		crossing = ct.travel.status(lead.unit) == "crossing" }
end
FACT.combat = function(f, c) return ct.combat.facts(c.run, c.entity, c.cfg, f) end

-- The effect executor.
local APPLY = {}
local function apply(run, entity, acts, cfg)
	for _, a in ipairs(acts) do
		APPLY[a[1]](run, entity, a, cfg)
	end
end

--- The kept items of an unload: configured ammo, and the configured robots while the tile has cells (R-36).
local function keep(run, cfg)
	local map = {}
	if cfg.ammo_count > 0 then
		items.add(map, cfg.ammo[1], cfg.ammo[2], cfg.ammo_count)
	end
	if cfg.robot_count > 0 and ct.discovery.has_cells(run.surface) then
		items.add(map, cfg.robot[1], cfg.robot[2], cfg.robot_count)
	end
	return map
end

--- R-40: the launchers end up with the wanted ammo spread evenly, the rest in the trunk. Items that don't fit stay.
local function balance_ammo(entity, cfg)
	local slots, trunk = inv(entity, defines.inventory.spider_ammo), inv(entity, defines.inventory.spider_trunk)
	local map = {}
	for _, it in ipairs(slots.get_contents()) do
		items.add(map, it.name, it.quality, it.count)
	end
	local _, move = items.ammo_plan(map, #slots, cfg.ammo)
	for _, m in ipairs(move) do
		local stack = { name = m[1], quality = m[2], count = m[3] }
		local n = trunk.insert(stack)
		if n == m[3] then
			slots.remove(stack)
		elseif n > 0 then
			trunk.remove({ name = m[1], quality = m[2], count = n })
		end
	end
	-- The wanted ammo spreads over the slots that are empty or already hold it: a slot whose other ammo had no room in
	-- the trunk keeps that ammo, and the wanted ammo is never destroyed for lack of a slot.
	local usable = {}
	for i = 1, #slots do
		local s = slots[i]
		if not s.valid_for_read or (s.name == cfg.ammo[1] and s.quality.name == cfg.ammo[2]) then
			usable[#usable + 1] = s
		end
	end
	-- Wanted ammo delivered to the trunk while another ammo (an atomic bomb) held a slot joins the spread, up to what the
	-- usable slots hold (owner: 400 rockets loaded as 75 x 4 with 100 left in the trunk). CC spreads only the slots.
	local name, quality = cfg.ammo[1], cfg.ammo[2]
	local have = map[name] and map[name][quality] or 0
	local room = #usable * ct.settings.stacks[name] - have
	local take = math.min(room, trunk.get_item_count({ name = name, quality = quality }))
	if take > 0 then
		take = trunk.remove({ name = name, quality = quality, count = take })
		items.add(map, name, quality, take)
	end
	local per = items.ammo_plan(map, #usable, cfg.ammo)
	if per then
		for i, s in ipairs(usable) do
			if per[i] > 0 then
				s.set_stack({ name = cfg.ammo[1], quality = cfg.ammo[2], count = per[i] })
			else
				s.clear()
			end
		end
	end
end
runs.balance_ammo = balance_ammo

--- Size 0 is off: the personal roboports keep their equipment and stop dispatching robots (LuaEntity::
--- allow_dispatching_robots, vehicles since 2.1.7; UE carries it across a crossing). Any other size swaps each roboport
--- to its "<name>-reduced-<size>" variant, or back to the base name for "full" (CC's data-stage naming, CC
--- data/roboports.lua:4-13); position, quality and energy are kept. SP-10: read the radius a tick later.
function runs.set_roboports(entity, size)
	local grid = entity.grid
	if not grid then
		return
	end
	entity.allow_dispatching_robots = size ~= 0
	for _, eq in pairs(grid.equipment) do
		if eq.type == "roboport-equipment" then
			local base = (eq.name:gsub("%-reduced%-%d+$", ""))
			local target = (size == "full" or size == 0) and base or (base .. "-reduced-" .. size)
			if target ~= eq.name and prototypes.equipment[target] then
				local position, quality, energy = eq.position, eq.quality, eq.energy
				grid.take({ equipment = eq })
				local new = grid.put({ name = target, quality = quality, position = position })
				if new then
					new.energy = energy
				end
			end
		end
	end
end

-- The idle scatter (CC job.lua:824-833): with no cells and a crowd, a finished ctron wanders a few tiles off.
local function scatter(run, entity)
	if ct.discovery.has_cells(run.surface) then
		return
	end
	local crowd = 0
	for _, rec in pairs(S().ctrons) do
		if rec.entity.valid and rec.entity.surface.name == run.surface then
			crowd = crowd + 1
		end
	end
	if crowd > 10 then
		local p, a, d = entity.position, math.random() * 2 * math.pi, 5 + math.random() * 5
		ct.travel.go(run.unit, { inst = ct.registry.here(), x = p.x + d * math.cos(a), y = p.y + d * math.sin(a) },
			{ kind = "park", radius = 3 })
	end
end

local function release(run, entity)
	S().runs[run.cid] = nil -- SP-11: iterate survives deletes
	if entity.valid then
		ct.logistics.clear(entity)
		entity.autopilot_destination = nil
		entity.follow_target = nil
		entity.enable_logistics_while_moving = false
		if run.reduced then
			runs.set_roboports(entity, "full")
		end
		ct.registry.set_state(run.cid, "idle")
		scatter(run, entity)
	end
	ct.report.mark("job", run.jid)
end

APPLY.travel = function(run, _, a) ct.travel.go(run.unit, a[2], a[3]) end
APPLY.stop = function(run, entity)
	ct.travel.cancel(run.unit)
	entity.autopilot_destination = nil
	entity.follow_target = nil
end
APPLY.requests = function(run, entity, a, cfg)
	local what = a[2]
	if what == "load" then
		ct.logistics.write_load(entity, run.load)
	elseif what == "unload" then
		ct.logistics.write_unload(entity, keep(run, cfg))
	elseif what == "deliver" then
		ct.logistics.write_deliver(entity, items.map(run.cargo.items))
	else
		ct.logistics.clear(entity)
	end
end
APPLY.balance_ammo = function(_, entity, _, cfg) balance_ammo(entity, cfg) end
APPLY.leave_squad = function(run) runs.leave(run) end
APPLY.emit = function(run, _, a)
	ct.report.event(run.jid, a[2], a[3])
	if a[2] == "done" or a[2] == "failed" then
		runs.trace("ctronv2.job", a[2], a[2] == "done" and "info" or "warn", run.jid, run.cid, { why = a[3].why })
	end
end
APPLY.rescan = function(run)
	if ct.registry.here() == run.work_inst then
		local wids = {}
		for _, share in ipairs(run.work) do
			wids[#wids + 1] = share.wid
		end
		ct.discovery.rescan_now(wids)
	end
end
APPLY.roboports = function(_, entity, a) runs.set_roboports(entity, a[2]) end
APPLY.moving_logistics = function(_, entity, a) entity.enable_logistics_while_moving = a[2] end
APPLY.release = release
for _, op in ipairs({ "move", "evade", "nuke", "follow", "leader_repair" }) do
	APPLY[op] = function(run, entity, a) ct.combat.apply(run, entity, a) end
end

-- The runner.
local function step(run, ev)
	local rec = ct.registry.ctron(run.cid)
	local entity = rec and rec.entity
	if not (entity and entity.valid) then
		return -- the on_object_destroyed handler ends the run
	end
	local cfg = ct.settings.of(run.surface)
	local old_state, old_status = run.state, run.status
	local f = facts_for(run, entity, cfg)
	apply(run, entity, run_core.step(run, f, cfg, ev), cfg)
	if run.state == "ended" then
		return
	end
	-- A poll that finds a stop unfulfilled re-issues its requests from the trunk as it is now: an item that arrived
	-- after they were written (a robot's haul, a player) gets its 0/0 line and leaves. Loading re-issues when nothing
	-- is missing (the deliveries in flight aren't disturbed) or when the trunk holds an item the load doesn't name (a
	-- stray that fills the trunk would block the load). Only when the held kinds changed since the last write.
	local state = run.state
	if not ev and state == old_state and (state == "unloading" and not f.unloaded
		or state == "loading" and not f.fulfilled) then
		local held = f.held -- set by the f.fulfilled read above
		local kinds, stray = {}, false
		for name, qs in pairs(held) do
			for quality in pairs(qs) do
				kinds[#kinds + 1] = name .. "/" .. quality
				stray = stray or not (run.load[name] and run.load[name][quality])
			end
		end
		table.sort(kinds)
		local sig = state .. ":" .. table.concat(kinds, ",")
		if sig ~= run.req_sig and (state == "unloading" or stray or next(f.missing) == nil) then
			run.req_sig = sig
			APPLY.requests(run, entity, { "requests", state == "loading" and "load" or "unload" }, cfg)
		end
	end
	if run.state ~= old_state then
		run.req_sig = nil -- the first poll after any state entry rewrites
	end
	if run.state ~= old_state or run.status ~= old_status then
		ct.report.mark("job", run.jid) -- R-189: a status-only change goes out with the next flush too
	end
	if run.status ~= old_status then
		ct.gui.on_status(entity, run.status, type(run.arg) ~= "table" and run.arg or nil)
		debug_draw.text(entity, run.status)
	end
end
runs.step = step

ue.runtime.scheduler.iterate({
	name = "ctron.runs", per_tick = 4, interval = 60,
	source = function()
		return storage.ctron_pluginv2 and storage.ctron_pluginv2.runs or {}
	end,
	fn = function(_, run, tick)
		if run.next and tick >= run.next and not run.in_transit then
			step(run)
		end
	end,
})

function runs.on_arrived(unit)
	local run = by_unit(unit)
	if run then
		step(run, { type = "arrived" })
	end
end

function runs.on_failed(unit, reason)
	local run = by_unit(unit)
	if run then
		step(run, { type = "failed", reason = reason })
	end
end

-- Adopt (§5.3, R-131, R-132).
local function reject(msg, cid, why)
	ct.report.event(msg.jid, "rejected", { why = why, cid = cid })
	runs.trace("ctronv2.job", "rejected", "warn", msg.jid, cid, { why = why })
end

function runs.adopt(msg)
	local cfg = ct.settings.of(msg.surface)
	local minions = msg.lead ~= nil
	local profile = minions and "minion" or msg.kind == "destroy" and "destroy" or msg.kind == "cargo" and "cargo" or "normal"
	-- R-196: a minion assign adopts every member; a destroy leader's adopts only members[1] (the rest is its squad list).
	local adopt = {}
	for i, cid in ipairs(msg.members) do
		if minions or i == 1 or msg.kind ~= "destroy" then
			adopt[#adopt + 1] = cid
		end
	end
	local stacks = ct.settings.stacks
	local need = items.slots(items.map(msg.cargo and msg.cargo.items), stacks)
	for _, share in ipairs(msg.work) do
		need = need + items.slots(items.map(share.bring), stacks) + share.out
	end
	local entities = {}
	for i, cid in ipairs(adopt) do
		local rec = ct.registry.ctron(cid)
		local e = rec and rec.entity
		local why
		if not (e and e.valid) then
			why = "busy"
		elseif S().runs[cid] or rec.state == "busy" then
			-- Busy first: a running ctron may well fail the fitness test (robots out), and must keep its state.
			why = "busy"
			ct.report.mark("ctron", cid) -- the controller's view of it was stale
		else
			local ok, w = ct.registry.fit(e)
			if not ok then
				ct.registry.set_state(cid, "unfit", w)
				why = w
			elseif rec.state ~= "idle" or e.disabled_by_script then
				why = "busy"
			elseif i == 1 and not minions and need > ct.registry.capacity(cid)[profile] then
				why = "full"
			end
		end
		if why then
			return reject(msg, cid, why)
		end
		entities[i] = e
	end
	-- The leader's radius, read while its roboports are full size (00 N16); a destroy squad shares it.
	local lead_radius = entities[1].logistic_cell.construction_radius
	for i, cid in ipairs(adopt) do
		local e = entities[i]
		local radius = msg.kind == "destroy" and lead_radius or e.logistic_cell.construction_radius
		local run = run_core.new(msg, i, { tick = game.tick, radius = radius, unit = e.unit_number,
			profile = items.full(profile, cfg) })
		S().runs[cid] = run
		ct.registry.set_state(cid, "busy", nil, msg.jid)
		ct.registry.paint(e, run.role == "minion" and "minion" or msg.kind)
		apply(run, e, run_core.start(run, facts_for(run, e, cfg), cfg), cfg)
		ct.gui.on_status(e, run.status)
	end
	ct.report.event(msg.jid, "adopted", {})
	ct.report.mark("job", msg.jid)
	runs.trace("ctronv2.job", "adopted", "info", msg.jid, msg.members[1])
	for _, share in ipairs(msg.work) do
		debug_draw.area(game.get_surface(msg.surface), share.area, { r = 0, g = 1, b = 0 })
	end
end

bridge.on("ct.job.assign", function(p) runs.adopt(p) end)

-- Ending: lost or handed off (§5.3).
-- ponytail: one scan of the runs per destroyed registered entity (ctron deaths and crossing commits are rare; a tile
-- holds at most ~50 runs). An index by unit would need upkeep in adopt, crossing and release.
local function gone(cid, run)
	S().runs[cid] = nil
	ct.report.mark("job", run.jid)
	if run.in_transit or run.state == "ended" then
		return -- handed off: the destination reports the run from materialized on (§5.9)
	end
	local fields, rescan = run_core.lost(run, ct.registry.here(), game.tick)
	if rescan then
		APPLY.rescan(run)
	end
	ct.report.event(run.jid, "lost", fields)
	runs.trace("ctronv2.job", "lost", "warn", run.jid, cid)
	if run.squad then
		for _, other in pairs(S().runs) do
			if other.jid == run.jid and not other.in_transit and other.state ~= "ended" then
				if run.role == "leader" and other.role == "minion" then
					step(other, { type = "leader_lost" })
				elseif run.role == "minion" and other.role == "leader" then
					run_core.leave_squad(other, cid)
				end
			end
		end
	end
end

runs.events[defines.events.on_object_destroyed] = function(event)
	for cid, run in pairs(S().runs) do
		if run.unit == event.useful_id then
			return gone(cid, run)
		end
	end
end

-- Job records (§4.3, R-124).
local function ordered(list)
	table.sort(list, function(a, b)
		if (a.role == "minion") ~= (b.role == "minion") then
			return b.role == "minion"
		end
		return a.cid < b.cid
	end)
	return list
end

local function trash_of(run)
	local rec = ct.registry.ctron(run.cid)
	local map = {}
	if rec and rec.entity.valid then
		for _, it in ipairs(rec.entity.get_inventory(defines.inventory.spider_trash).get_contents()) do
			items.add(map, it.name, it.quality, it.count)
		end
	end
	return map
end

local function record_of(jid, list)
	ordered(list)
	local head = list[1].role ~= "minion" and list[1] or nil
	local any = list[1]
	local members, shares = {}, {}
	for i, run in ipairs(list) do
		members[i] = run.cid
	end
	for i, share in ipairs(head and head.work or {}) do
		shares[i] = { wid = share.wid, bring = share.bring, out = share.out }
	end
	local rec = { jid = jid, kind = any.kind, surface = any.surface, members = members, state = any.state,
		status = any.status, arg = type(any.arg) ~= "table" and any.arg or nil,
		tasks = { any.done_tasks, any.total_tasks }, station = any.station, shares = shares, left = any.left,
		cargo = any.cargo }
	if not head and any.squad then
		rec.lead = any.squad.leader -- R-209: a part without the leader names it, so a restarted controller knows it
	end
	local map = type(any.arg) == "table" and any.arg
	if not map and any.status == "trash_full" then
		map = trash_of(any) -- deliver's trash_full is a status with no arg (R-117)
	end
	if map then
		local missing = {}
		for i, t in ipairs(items.tuples(map)) do
			if i > 10 then
				break
			end
			missing[i] = t
		end
		rec.missing = missing
	end
	return rec
end

--- This tile's job records; a run in transit is reported by the source until the commit.
function runs.records()
	local by_jid, order = {}, {}
	for _, run in pairs(S().runs) do
		if run.state ~= "ended" then
			if not by_jid[run.jid] then
				by_jid[run.jid] = {}
				order[#order + 1] = run.jid
			end
			table.insert(by_jid[run.jid], run)
		end
	end
	local out = {}
	for i, jid in ipairs(order) do
		out[i] = record_of(jid, by_jid[jid])
	end
	return out
end

function runs.record(jid)
	local list = runs.of_job(jid)
	if #list > 0 then
		return record_of(jid, list)
	end
end

local function tuples_of(inventory)
	local out = {}
	for _, it in ipairs(inventory.get_contents()) do
		out[#out + 1] = { it.name, it.quality, it.count }
	end
	return out
end

--- Each filled slot in order, as CC's Job Details shows them (ui_job_screen.lua:315-334); for the 4 ammo slots only,
--- since a trunk's stacks one by one would outgrow the 3 KB detail.
local function stacks_of(inventory)
	local out = {}
	for i = 1, #inventory do
		local s = inventory[i]
		if s.valid_for_read then
			out[#out + 1] = { s.name, s.quality.name, s.count }
		end
	end
	return out
end

--- Job Details' live data for this tile (§6.12): nil when the job has no run here. Over 3000 bytes of JSON the task
--- list goes first (05 C5).
function runs.detail(jid)
	local list = runs.of_job(jid)
	if #list == 0 then
		return nil
	end
	ordered(list)
	local members = {}
	for _, run in ipairs(list) do
		local rec = not run.in_transit and ct.registry.ctron(run.cid)
		local e = rec and rec.entity
		if e and e.valid then
			local held = ct.logistics.held(e)
			local requests = {}
			for name, qs in pairs(run.load) do
				for quality, want in pairs(qs) do
					requests[#requests + 1] = { name, quality, want, held[name] and held[name][quality] or 0 }
				end
			end
			members[#members + 1] = { cid = run.cid, x = e.position.x, y = e.position.y,
				trunk = tuples_of(e.get_inventory(defines.inventory.spider_trunk)),
				ammo = stacks_of(e.get_inventory(defines.inventory.spider_ammo)),
				trash = tuples_of(e.get_inventory(defines.inventory.spider_trash)), requests = requests }
		end
	end
	local lead = list[1] -- ordered: the worker or leader first
	local tasks = {}
	for i, p in ipairs(lead.tasks or {}) do
		tasks[i] = { p.x, p.y }
	end
	local detail = { members = members, tasks = tasks, station = lead.station }
	if #helpers.table_to_json(detail) > 3000 then
		detail.tasks = {}
	end
	-- Still over (a big squad): the members after the leader go from the tail.
	while #detail.members > 1 and #helpers.table_to_json(detail) > 3000 do
		detail.members[#detail.members] = nil
	end
	return detail
end

local function unknown(jid)
	ct.report.event(jid, "unknown", {})
end

--- Cancels the job's runs here. A run in transit can't be reached: unknown, and the controller re-sends once the
--- job's new tile reports it (§6.9). A cancel never deletes a run, so stepping while walking S().runs is safe.
function runs.cancel(jid)
	local hit, transit
	for _, run in pairs(S().runs) do
		if run.jid == jid and run.state ~= "ended" then
			if run.in_transit then
				transit = true
			else
				step(run, { type = "cancel" })
				hit = true
			end
		end
	end
	if transit or not hit then
		unknown(jid)
	end
	if hit then
		runs.trace("ctronv2.job", "cancelled", "info", jid)
	end
end

--- P1's settings turned a kind off on a surface (§5.10).
function runs.cancel_kind(surface, kind)
	local jids = {}
	for _, run in pairs(S().runs) do
		if run.surface == surface and run.kind == kind and run.state ~= "ended" then
			jids[run.jid] = true
		end
	end
	for jid in pairs(jids) do
		runs.cancel(jid)
	end
end

--- R-202, R-204: a minion leaves its squad. The local leader drops it at once; the controller hears `left` and relays it
--- to the leader's tile.
function runs.leave(run)
	local lead = S().runs[run.squad.leader]
	if lead and lead.jid == run.jid and not lead.in_transit and lead.state ~= "ended" then
		run_core.leave_squad(lead, run.cid)
	end
	ct.report.event(run.jid, "left", { cid = run.cid })
end

--- The controller's squad state (squads.md §4.4): the leader's tile prunes its list by `gone`; a minion's tile learns
--- the leader's place (stepping a follower now replaces a stale travel) or that the squad is done (R-203). A run in
--- transit can't be reached: unknown, and the controller re-sends once its new tile reports the job.
bridge.on("ct.job.squad", function(p)
	local transit, hit = false, {}
	for _, run in pairs(S().runs) do
		if run.jid == p.jid and run.state ~= "ended" then
			if run.in_transit then
				transit = true
			elseif run.role == "leader" then
				for _, cid in ipairs(p.gone) do
					run_core.leave_squad(run, cid)
				end
			else
				hit[#hit + 1] = run
			end
		end
	end
	for _, run in ipairs(hit) do
		if p.lead then
			run.squad.lead = { inst = p.lead.inst, x = p.lead.x, y = p.lead.y }
			if run.state == "follow" then
				step(run)
			end
		end
		if p.done then
			step(run, { type = "leader_lost" })
		end
	end
	if transit then
		unknown(p.jid)
	end
end)

function runs.set_station(jid, cid, station)
	local run = S().runs[cid]
	if not run or run.jid ~= jid or run.state == "ended" or run.in_transit then
		return unknown(jid)
	end
	step(run, { type = "station", station = station })
end

--- A request is dropped: the runs work with what they already hold of it (05 C6).
function runs.drop(jid, surface, name, quality)
	local hit, transit
	for _, run in pairs(S().runs) do
		local mine
		if jid then
			mine = run.jid == jid
		else
			mine = run.surface == surface and run.state == "loading"
		end
		if mine and run.state ~= "ended" then
			if run.in_transit then
				transit = true
			else
				local rec = ct.registry.ctron(run.cid)
				local e = rec and rec.entity
				if e and e.valid then
					-- Only lowers or removes lines the run asked for: the named quality, or every quality for "any".
					local qs = run.load[name]
					local held = ct.logistics.held(e)[name] or {}
					for q, want in pairs(qs or {}) do
						if q == quality or quality == "any" then
							local have = 0
							for hq, n in pairs(held) do
								if hq == q then
									have = have + n
								end
							end
							local kept = math.min(have, want)
							qs[q] = kept > 0 and kept or nil
						end
					end
					if qs and next(qs) == nil then
						run.load[name] = nil
					end
					if run.state == "loading" then
						ct.logistics.write_load(e, run.load)
					end
					hit = true
				end
			end
		end
	end
	if jid and (transit or not hit) then
		unknown(jid)
	end
end

bridge.on("ct.job.cancel", function(p) runs.cancel(p.jid) end)
bridge.on("ct.job.station", function(p) runs.set_station(p.jid, p.cid, p.station) end)
bridge.on("ct.job.drop", function(p) runs.drop(p.jid, p.surface, p.name, p.quality) end)
bridge.on("ct.detail.fetch", function(p) bridge.send("ct.detail.reply", { req = p.req, detail = runs.detail(p.jid) }) end)

return runs
