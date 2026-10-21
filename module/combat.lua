-- The game side of destroy squads (spec §5.7, R-105): reads the world into combat_core's views (runs.lua's combat
-- fact) and applies its ops; keeps the global threat modifier from research.
local ct = require("modules/ctron_pluginv2/ct")
local combat_core = require("modules/ctron_pluginv2/combat_core")

local combat = { events = {} }

local function S() return storage.ctron_pluginv2 end

local MOVING = { moving = true, routing = true, crossing = true, waiting_robots = true }
local CLUSTER = 17.5

local function moving(run, entity)
	return entity.autopilot_destination ~= nil or MOVING[ct.travel.status(run.unit)] == true
end

local function packs(f, cfg)
	return f.net and f.net.can_satisfy_request({ name = cfg.repair_tool[1], quality = cfg.repair_tool[2] }, 1, true) or false
end

local function leader_view(run, entity, cfg, f)
	local range = combat_core.gun_range(entity.quality.name)
	local pos, surface = f.pos, entity.surface
	local enemies, in_range = {}, false
	for _, e in ipairs(surface.find_entities_filtered({ position = pos, radius = range + 4, force = "enemy",
		is_military_target = true })) do
		enemies[#enemies + 1] = e.name
		in_range = in_range or combat_core.dist(pos, e.position) <= range
	end
	local bombs, spawners = 0, nil
	if cfg.atomic and cfg.atomic_count > 0 then
		bombs = entity.get_inventory(defines.inventory.spider_trunk)
			.get_item_count({ name = cfg.atomic[1], quality = cfg.atomic[2] })
		if bombs > 0 then
			spawners = {}
			local filter = { position = pos, radius = range, force = "enemy", type = "unit-spawner" }
			for _, s in ipairs(surface.find_entities_filtered(filter)) do
				local id = tostring(s.unit_number)
				if not run.combat.nuked[id] then
					local cluster = {}
					for _, o in ipairs(surface.find_entities_filtered({ position = s.position, radius = CLUSTER,
						force = "enemy", type = "unit-spawner" })) do
						cluster[#cluster + 1] = tostring(o.unit_number)
					end
					spawners[#spawners + 1] = { id = id, x = s.position.x, y = s.position.y, cluster = cluster }
				end
			end
		end
	end
	local members = {}
	for i, cid in ipairs(run.squad.members) do
		local other = S().runs[cid]
		local rec = other and other.jid == run.jid and not other.in_transit and other.state ~= "ended" and ct.registry.ctron(cid)
		local e = rec and rec.entity
		if e and e.valid then
			members[i] = { here = true, dist = combat_core.dist(pos, e.position),
				follow = e.follow_target ~= nil }
		else
			members[i] = { here = false }
		end
	end
	local st = run.station
	return { tick = f.tick, pos = pos, health = f.health, here = f.here,
		station = { inst = st.inst, x = st.x, y = st.y }, crossing = ct.travel.status(run.unit) == "crossing",
		enemies = enemies, enemy_in_range = in_range, g = S().threat.global_threat_modifier or 1.6,
		atomic_count = cfg.atomic_count, bombs = bombs, min_cluster = cfg.min_cluster, spawners = spawners,
		robots = f.robots, packs = packs(f, cfg), out = f.out, moving = moving(run, entity), members = members }
end

function combat.facts(run, entity, cfg, f)
	if run.role == "leader" then
		return leader_view(run, entity, cfg, f)
	end
	return { pos = f.pos, health = f.health, robots = f.robots, packs = packs(f, cfg), out = f.out,
		moving = moving(run, entity), follow = entity.follow_target ~= nil, here = f.here,
		lead = run.squad.lead or false, leader_crossing = f.leader and f.leader.crossing or false,
		leader_pos = f.leader and f.leader.pos or false }
end

local OPS = {}

OPS.move = function(run, entity, op)
	ct.travel.cancel(run.unit)
	entity.autopilot_destination = { op[2], op[3] }
end

-- CC's circle (destroy.lua:279-301): a 7-tile square dance round the spot, then back to it.
OPS.evade = function(_, entity)
	local p = entity.position
	for i = 0, 3 do
		local a = i * math.pi / 2
		entity.add_autopilot_destination({ p.x + 7 * math.cos(a), p.y + 7 * math.sin(a) })
	end
	entity.add_autopilot_destination(p)
end

OPS.nuke = function(run, entity, op)
	local cfg = ct.settings.of(run.surface)
	local name, quality = cfg.atomic[1], cfg.atomic[2]
	local removed = entity.get_inventory(defines.inventory.spider_trunk)
		.remove({ name = name, quality = quality, count = 1 })
	if removed == 1 then
		entity.surface.create_entity({ name = name == "atomic-bomb" and "atomic-rocket" or name, quality = quality,
			position = entity.position, target = { op[2], op[3] }, speed = 0.4, force = entity.force })
	end
	entity.autopilot_destination = nil
end

OPS.follow = function(run, entity)
	local rec = ct.registry.ctron(run.squad.leader)
	if rec and rec.entity.valid then
		entity.follow_target = rec.entity
	end
end

OPS.leader_repair = function(run)
	local lead = S().runs[run.squad.leader]
	if lead and lead.jid == run.jid and not lead.in_transit then
		lead.combat.repairing = true
	end
end

function combat.apply(run, entity, op)
	OPS[op[1]](run, entity, op)
end

combat.events[defines.events.on_research_finished] = function(event)
	local t = S().threat
	t.global_threat_modifier = combat_core.research(t.global_threat_modifier or 1.6, event.research.name)
end

return combat
