-- Ctrons and stations on this tile (spec §4.1, §4.3, §4.7, §5.6; R-37, R-46, R-121, R-131): ids, CC's setup at
-- registration, fitness, capacity per profile, colours, destruction, and the idle pass that collects robots left out.
local items = require("modules/ctron_pluginv2/items_core")
local status_core = require("modules/ctron_pluginv2/status_core")
local debug_draw = require("modules/ctron_pluginv2/debug_draw")
local ct = require("modules/ctron_pluginv2/ct")
local clusterio_api = require("modules/clusterio/api")
local ue = require("modules/universal_edges")

local registry = { events = {} }

local function S()
	return storage.ctron_pluginv2
end

--- CC's colours (color_lib, R-50).
local COLORS = {
	idle = { r = 1, g = 1, b = 1, a = 0.25 },
	construction = { r = 0, g = 0.35, b = 0.65, a = 0.4 },
	deconstruction = { r = 1, g = 0, b = 0, a = 0.4 },
	upgrade = { r = 0, g = 0.65, b = 0, a = 0.4 },
	repair = { r = 90, g = 0, b = 45, a = 128 },
	destroy = { r = 0, g = 0, b = 0, a = 0.6 },
	minion = { r = 255, g = 255, b = 0, a = 128 },
	cargo = { r = 0.55, g = 0.55, b = 0.55, a = 0.75 },
}

local PROFILES = { "normal", "destroy", "cargo" }

--- text cut to at most 60 bytes (R-154), never inside a UTF-8 character.
local function cut(text)
	if #text <= 60 then
		return text
	end
	local n = 60
	while n > 0 do
		local b = text:byte(n + 1)
		if b < 0x80 or b > 0xBF then
			break
		end
		n = n - 1
	end
	return text:sub(1, n)
end

local function mark(kind, id)
	ct.report.mark(kind, id)
end

local function start()
	local names = S().names
	names.ctrons = names.ctrons or { constructron = true, ["constructron-rocket-powered"] = true }
	names.stations = names.stations or { service_station = true }
end

registry.on_init = start
registry.on_server_startup = start

function registry.paint(entity, kind)
	local color = COLORS[kind]
	if entity.valid and color then
		entity.color = color
	end
end

function registry.here()
	return clusterio_api.get_instance_id()
end

--- ok, why: CC's worker test without its side effect (job.lua:47-102, R-46).
function registry.fit(entity)
	local grid, cell = entity.grid, entity.logistic_cell
	if not (grid and cell) then
		return false, "no_roboports"
	end
	if not (grid.get_generator_energy() > 0 or grid.max_solar_energy > 0) then
		return false, "no_power"
	end
	if cell.construction_radius == 0 then
		return false, "bad_roboports"
	end
	local net = cell.logistic_network
	-- SP-9: the integer difference is the robots out.
	if net and net.all_construction_robots - net.available_construction_robots > 0 then
		return false, "robots_out"
	end
	return true
end

--- free, restock of the live trunk per profile; marks the record dirty when they changed (M4: the idle pass retests
--- every unfit ctron every 300 ticks, and an unchanged record isn't re-sent).
function registry.capacity(cid)
	local rec = S().ctrons[cid]
	local e = rec and rec.entity
	if not (e and e.valid) then
		return nil
	end
	local held = ct.logistics.held(e)
	local cfg = ct.settings.of(e.surface.name)
	local empty = e.get_inventory(defines.inventory.spider_trunk).count_empty_stacks()
	for _, p in ipairs(PROFILES) do
		rec.restock[p] = items.restock(items.full(p, cfg), held)
		rec.free[p] = items.free(empty, rec.restock[p], ct.settings.stacks)
	end
	local sig = helpers.table_to_json({ rec.free, rec.restock })
	if sig ~= rec.cap_sig then
		rec.cap_sig = sig
		mark("ctron", cid)
	end
	return rec.free, rec.restock
end

function registry.set_state(cid, state, why, jid)
	local rec = S().ctrons[cid]
	local entity = rec and rec.entity
	if not (entity and entity.valid) then
		return
	end
	if state == "idle" then
		local ok, w = registry.fit(entity)
		if not ok then
			state, why = "unfit", w
		end
	end
	local changed = rec.state ~= state or rec.why ~= why
	rec.state, rec.why, rec.jid = state, why, jid
	if state == "idle" then
		registry.paint(entity, "idle")
	end
	if why ~= "robots_out" then
		rec.robots_out_since = nil
	end
	registry.capacity(cid)
	if changed then
		mark("ctron", cid) -- capacity marks only when the trunk's numbers changed
	end
	if changed and state ~= "busy" then
		local code = state == "unfit" and why or "idle"
		ct.gui.on_status(entity, code)
		local info = status_core.info(code)
		if info then
			debug_draw.text(entity, { info.key })
		end
	end
end

--- busy: the caller sets the state next (a crossing arrival with its run). The idle fit test is skipped: on the tick UE
--- creates the ctron its logistic cell isn't up yet, so the test reads no_roboports and alerts.
function registry.register(entity, cid, busy)
	if not (entity and entity.valid) then
		return nil
	end
	local s = S()
	local unit = entity.unit_number
	if s.by_unit[unit] then
		return s.by_unit[unit]
	end
	if s.names.stations[entity.name] then
		local sid = registry.here() .. "." .. unit
		local reg = script.register_on_object_destroyed(entity)
		entity.get_or_create_control_behavior().read_logistics = false
		s.stations[sid] = { entity = entity, unit = unit, reg = reg }
		s.by_unit[unit], s.by_reg[reg] = sid, sid
		ct.signals.wire(entity)
		mark("station", sid)
		return sid
	end
	if s.names.ctrons[entity.name] then
		local fresh = cid == nil
		cid = cid or (registry.here() .. "." .. unit)
		local reg = script.register_on_object_destroyed(entity)
		entity.enable_logistics_while_moving = false
		-- Off on every spider by default: the stock checks count buffer chests, so without it a request they "cover"
		-- is never filled (owner: constructrons don't take from buffer chests).
		entity.request_from_buffers = true
		entity.vehicle_automatic_targeting_parameters = { auto_target_without_gunner = true,
			auto_target_with_gunner = true }
		if fresh then
			registry.paint(entity, "idle")
		end
		s.ctrons[cid] = { entity = entity, unit = unit, reg = reg, state = "idle", free = {}, restock = {} }
		s.by_unit[unit], s.by_reg[reg] = cid, cid
		if not busy then
			registry.set_state(cid, "idle")
		end
		return cid
	end
	return nil
end

function registry.ctron(cid)
	return S().ctrons[cid]
end

function registry.station(sid)
	return S().stations[sid]
end

function registry.ctron_of(entity)
	local s = S()
	local id = s.by_unit[entity.unit_number]
	if id and s.ctrons[id] then
		return id
	end
end

function registry.stations_on(surface)
	local out = {}
	for sid, rec in pairs(S().stations) do
		if rec.entity.valid and rec.entity.surface.name == surface then
			out[#out + 1] = sid
		end
	end
	return out
end

function registry.rename(sid, name)
	local rec = S().stations[sid]
	if rec and rec.entity.valid then
		rec.entity.backer_name = name
		mark("station", sid)
	end
end

function registry.record(kind, id)
	local s = S()
	if kind == "ctron" then
		local rec = s.ctrons[id]
		local e = rec and rec.entity
		if not (e and e.valid) then
			return nil
		end
		local restock = {}
		for p, map in pairs(rec.restock) do
			restock[p] = items.tuples(map)
		end
		local label = e.entity_label
		return { cid = id, surface = e.surface.name, name = e.name, quality = e.quality.name,
			label = label and cut(label), x = e.position.x, y = e.position.y, state = rec.state, why = rec.why,
			jid = rec.jid, free = rec.free, restock = restock }
	end
	local rec = s.stations[id]
	local e = rec and rec.entity
	if not (e and e.valid) then
		return nil
	end
	return { sid = id, surface = e.surface.name, name = cut(e.backer_name), x = e.position.x, y = e.position.y }
end

function registry.records(kind)
	local out = {}
	for id in pairs(kind == "ctron" and S().ctrons or S().stations) do
		out[#out + 1] = registry.record(kind, id)
	end
	return out
end

local function known(entity)
	local names = S().names
	return names.ctrons[entity.name] or names.stations[entity.name]
end

local function on_built(event)
	local e = event.entity
	if S() and e and e.valid and known(e) then
		registry.register(e)
	end
end
registry.events[defines.events.on_built_entity] = on_built
registry.events[defines.events.on_robot_built_entity] = on_built
registry.events[defines.events.script_raised_built] = on_built

registry.events[defines.events.on_entity_cloned] = function(event)
	local e = event.destination
	if S() and e and e.valid and known(e) then
		registry.register(e)
	end
end

registry.events[defines.events.script_raised_teleported] = function(event)
	local e = event.entity
	if not (S() and e and e.valid and known(e)) then
		return
	end
	local id = S().by_unit[e.unit_number]
	if id then
		mark(S().ctrons[id] and "ctron" or "station", id)
	else
		registry.register(e)
	end
end

registry.events[defines.events.on_object_destroyed] = function(event)
	local s = S()
	local reg = event.registration_number
	local id = s and s.by_reg[reg]
	if not id then
		return
	end
	s.by_reg[reg] = nil
	if s.by_unit[event.useful_id] == id then
		s.by_unit[event.useful_id] = nil
	end
	local rec = s.ctrons[id]
	if rec then
		-- A looped-edge crossing re-registers the cid before the source entity dies: only the record's own reg counts.
		if rec.reg == reg then
			ct.travel.cancel(rec.unit)
			s.ctrons[id] = nil
			mark("ctron", id)
		end
		return
	end
	rec = s.stations[id]
	if rec and rec.reg == reg then
		s.stations[id] = nil
		ct.logistics.set_slots(id, nil)
		mark("station", id)
	end
end

registry.events[defines.events.on_entity_renamed] = function(event)
	local e = event.entity
	local s = S()
	local id = s and e and e.valid and s.by_unit[e.unit_number]
	if id then
		mark(s.ctrons[id] and "ctron" or "station", id)
	end
end

local function on_equipment(event)
	local s = S()
	local owner = s and event.grid.valid and event.grid.entity_owner
	local cid = owner and owner.valid and registry.ctron_of(owner)
	if cid and s.ctrons[cid].state ~= "busy" then
		registry.set_state(cid, "idle")
	end
end
registry.events[defines.events.on_equipment_inserted] = on_equipment
registry.events[defines.events.on_equipment_removed] = on_equipment

--- CC's meeting point with the nearest robot (utility.lua:27-46): along the line to it, split by relative speed.
local function meeting_point(v, robot)
	local sp = 0.18
	for _, eq in pairs(v.grid.equipment) do
		if eq.type == "movement-bonus-equipment" then
			sp = sp * (1 + eq.movement_bonus)
		end
	end
	local f = sp / (sp + 0.05)
	local p, r = v.position, robot.position
	return p.x + (r.x - p.x) * f, p.y + (r.y - p.y) * f
end

ue.runtime.scheduler.periodic({ name = "ctron.idle", interval = 300, fn = function(tick)
	local s = S()
	local n = 0
	local ids = {}
	for cid in pairs(s.ctrons) do
		ids[#ids + 1] = cid
	end
	for _, cid in ipairs(ids) do
		local rec = s.ctrons[cid]
		local v = rec and rec.entity
		if v and v.valid and rec.state == "unfit" then
			n = n + 1
			if rec.why ~= "robots_out" then
				-- A script's grid.put raises no event, so retest (R-37).
				registry.set_state(cid, "idle")
			elseif not rec.robots_out_since then
				rec.robots_out_since = tick
			else
				local ok = registry.fit(v)
				if ok then
					registry.set_state(cid, "idle")
				elseif (ct.travel.status(rec.unit)) ~= "moving" then
					local net = v.logistic_cell and v.logistic_cell.logistic_network
					local robot = net and net.construction_robots[1]
					if robot then
						local x, y = meeting_point(v, robot)
						ct.travel.go(rec.unit, { inst = registry.here(), x = x, y = y }, { kind = "park", radius = 3 })
					end
				end
			end
		end
	end
	return math.max(n, 1)
end })

return registry
