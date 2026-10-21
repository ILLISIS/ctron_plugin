-- Pure combat decisions for destroy squads (spec §5.7, R-41, R-42): CC's thresholds, weights and moves, as data in
-- and decisions out. combat.lua reads the game into a view and applies the ops; run_core calls fight and follow.
local combat_core = {}

combat_core.GUN_RANGE = { normal = 36, uncommon = 39.6, rare = 43.2, epic = 46.8, legendary = 54 }
combat_core.WEIGHTS = {
	["small-biter"] = 0.1, ["medium-biter"] = 0.5, ["big-biter"] = 1, ["behemoth-biter"] = 2,
	["small-spitter"] = 0.5, ["medium-spitter"] = 1, ["big-spitter"] = 2, ["behemoth-spitter"] = 3,
	["small-worm-turret"] = 0.1, ["medium-worm-turret"] = 0.5, ["big-worm-turret"] = 1, ["behemoth-worm-turret"] = 2,
	["biter-spawner"] = 0.5, ["spitter-spawner"] = 0.5,
	["small-wriggler-pentapod"] = 1, ["medium-wriggler-pentapod"] = 1.5, ["big-wriggler-pentapod"] = 2,
	["small-wriggler-pentapod-premature"] = 1, ["medium-wriggler-pentapod-premature"] = 1.5,
	["big-wriggler-pentapod-premature"] = 2,
	["small-strafer-pentapod"] = 4, ["medium-strafer-pentapod"] = 7, ["big-strafer-pentapod"] = 10,
	["small-stomper-pentapod"] = 5, ["medium-stomper-pentapod"] = 10, ["big-stomper-pentapod"] = 15,
	["gleba-spawner-small"] = 0.5, ["gleba-spawner"] = 0.5,
	["small-demolisher"] = 1000, ["medium-demolisher"] = 1000, ["big-demolisher"] = 1000,
}
local RESEARCH = {
	["stronger-explosives-3"] = 0.1, ["stronger-explosives-4"] = 0.1, ["stronger-explosives-5"] = 0.1,
	["stronger-explosives-6"] = 0.1, ["weapon-shooting-speed-3"] = 0.2, ["weapon-shooting-speed-4"] = 0.2,
	["weapon-shooting-speed-5"] = 0.2, ["weapon-shooting-speed-6"] = 0.2,
}

local function dist(a, b)
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx * dx + dy * dy)
end
combat_core.dist = dist

function combat_core.gun_range(quality)
	return combat_core.GUN_RANGE[quality] or 36
end

--- CC's modifier: it grows as health drops and shrinks with each minion, with 0.1 as the floor inside the max.
function combat_core.modifier(g, health, minions)
	return g + math.max(g + (1 - health) * 2 - minions * 0.05, 0.1)
end

function combat_core.threat(names, mod)
	local sum = 0
	for _, name in ipairs(names) do
		sum = sum + (combat_core.WEIGHTS[name] or 1)
	end
	return sum * mod
end

function combat_core.research(g, tech)
	local step = RESEARCH[tech]
	return step and math.max(0.4, g - step) or g
end

--- The first spawner not yet considered whose cluster (itself included) is strictly larger than min_cluster and that
--- is more than 20 away. A too-small cluster is marked considered; a too-close one is only skipped (CC :104-136).
function combat_core.pick_nuke(spawners, nuked, min_cluster, pos)
	for _, s in ipairs(spawners) do
		if not nuked[s.id] then
			if #s.cluster > min_cluster then
				if dist(pos, s) > 20 then
					nuked[s.id] = true
					for _, id in ipairs(s.cluster) do
						nuked[id] = true
					end
					return s
				end
			else
				nuked[s.id] = true
			end
		end
	end
end

--- CC's hold (destroy.lua:373-385): stop while any listed minion is not on this tile, is more than 32 away or has no
--- follow_target. No time limit; the member's state is not read.
function combat_core.squad_hold(members)
	for _, m in ipairs(members) do
		if not m.here or m.dist > 32 or not m.follow then
			return true, "minion_proximity"
		end
	end
	return false
end

-- Places are {x, y, inst}; a place on another instance is unboundedly far (R-201).
local function dist_to(v, p)
	if p.inst ~= nil and p.inst ~= v.here then
		return math.huge
	end
	return dist(v.pos, p)
end

local function last_safe(c, v)
	return c.safe[#c.safe] or v.station
end

-- Drop the last safe position and return the one before it, or the station.
local function retreat_target(c, v)
	c.safe[#c.safe] = nil
	return c.safe[#c.safe] or v.station
end

-- run_core turns the place into a local move or a route travel (R-201); no place stays put (CC destroy.lua:124-127).
local function move(ops, p)
	ops[#ops + 1] = p and { "move", p } or { "stop" }
end

-- CC's repairing state (destroy.lua:303-357, minion.lua:118-160) without the threat check. Returns true when the
-- run must give up: no robots or no repair packs.
local function repairing(v, c, d, ops)
	if v.health < 1 then
		if v.robots < 1 or not v.packs then
			c.repairing = nil
			d.status = "missing_robots"
			return true
		end
		ops[#ops + 1] = { "roboports", "full" }
		d.status = "repairing"
		return false
	end
	ops[#ops + 1] = { "roboports", 0 }
	if v.out > 0 then
		d.status = "repairing"
	else
		c.repairing = nil
	end
	return false
end

function combat_core.fight(v, c)
	local ops = {}
	local d = { ops = ops, status = "working" }
	if v.crossing then
		d.status = "crossing"
		return d
	end
	local mod = combat_core.modifier(v.g, v.health, v.minions)
	if c.repairing then
		if combat_core.threat(v.enemies, mod) > 50 then
			move(ops, retreat_target(c, v))
			d.status = "fleeing"
		elseif repairing(v, c, d, ops) then
			d.to_station = true
		end
		return d
	end
	if v.atomic_count > 0 and v.bombs > 0 and v.spawners then
		local target = combat_core.pick_nuke(v.spawners, c.nuked, v.min_cluster, v.pos)
		if target then
			ops[#ops + 1] = { "nuke", target.x, target.y }
			ops[#ops + 1] = { "stop" }
			if dist(v.pos, target) < 36 then
				move(ops, c.safe[#c.safe])      -- CC destroy.lua:124-127: no safe position stays put (D14)
			end
			return d
		end
	end
	local threat = combat_core.threat(v.enemies, mod)
	if threat < 50 then
		c.holding, c.retreating = nil, nil
		local last = last_safe(c, v)
		if threat < 40 and dist_to(v, last) > 16 then
			c.safe[#c.safe + 1] = { x = math.floor(v.pos.x), y = math.floor(v.pos.y), inst = v.here }
		end
		local hold, why = combat_core.squad_hold(v.members)
		if hold then
			ops[#ops + 1] = { "stop" }
			d.status = why
		elseif v.task and dist_to(v, v.task) > 3 then
			d.status = "moving"
			if not v.moving then
				ops[#ops + 1] = { "goto_task" }
			end
		elseif v.tasks_left > 1 or threat < 3 or not v.enemy_in_range then
			d.pop = true
		end
		return d
	end
	if threat < 100 then
		if not c.holding then
			c.holding = true
			ops[#ops + 1] = { "stop" }
			ops[#ops + 1] = { "evade" }
		elseif not v.moving then
			ops[#ops + 1] = { "evade" }
		end
		d.status = "standing_ground"
		return d
	end
	d.status = "safe_position"
	local safe = last_safe(c, v)
	if not c.retreating then
		c.retreating = true
		move(ops, safe)
	elseif safe and dist_to(v, safe) < 7 then
		move(ops, retreat_target(c, v))
	elseif safe and not v.moving then
		move(ops, safe)
	end
	return d
end

function combat_core.follow(v, c)
	local ops = {}
	local d = { ops = ops, status = "following" }
	if c.repairing then
		if repairing(v, c, d, ops) then
			d.leave = true
		elseif v.health < 1 then
			ops[#ops + 1] = { "leader_repair" }
		end
		return d
	end
	if v.leader_pos then
		c.goal = nil
		if v.leader_crossing then
			if v.follow or v.moving then
				ops[#ops + 1] = { "stop" }
			end
			return d
		end
		if dist(v.pos, v.leader_pos) > 32 then
			if not v.moving then
				ops[#ops + 1] = { "goto_leader" }
			end
		elseif not v.moving and not v.follow then
			ops[#ops + 1] = { "follow" }
		end
		return d
	end
	-- The leader is on another tile (or in transit): drop a dead follow_target, then route to its last relayed place.
	local moving = v.moving
	if v.follow then
		ops[#ops + 1] = { "stop" }
		moving = false
	end
	local lead, goal = v.lead, c.goal
	if lead and lead.inst ~= v.here
		and (not moving or not goal or goal.inst ~= lead.inst or goal.x ~= lead.x or goal.y ~= lead.y) then
		ops[#ops + 1] = { "goto_lead" }
		c.goal = { inst = lead.inst, x = lead.x, y = lead.y }
	end
	return d
end

return combat_core
