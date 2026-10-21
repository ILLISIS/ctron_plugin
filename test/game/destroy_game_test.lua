local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ct = require("modules/ctron_pluginv2/ct")

-- G12 (P2 Task 6): destroy squads against real nests.
local events_of, cid_of, charge = fx.events_of, fx.cid_of, fx.charge

local function dist(a, b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

--- A paved, hostile surface with the station at (0, 0), a leader at (-6, 0) and a minion at (-6, 6).
local function setup(c, name, peaceful)
	c.surface = fx.paved(name, -40, -60, 140, 60)
	c.surface.peaceful_mode = peaceful or false
	c.station = fx.station(c.surface, 0, 0, { ["construction-robot"] = 60, ["repair-pack"] = 40 })
	c.leader = fx.ctron(c.surface, -6, 0, { robots = 10 })
	c.minion = fx.ctron(c.surface, -6, 6, { robots = 10 })
	for _, v in ipairs({ c.leader, c.minion }) do
		-- Stocked by hand: the station's 10 robots take ~10,000 ticks to fill four squads, past the run's 10 minutes.
		v.get_inventory(defines.inventory.spider_trunk).insert({ name = "repair-pack", count = 16 })
	end
	c.lcid, c.mcid = cid_of(c.leader), cid_of(c.minion)
	c.armed = {}
end

local function enemy(c, name, x, y)
	return assert(c.surface.create_entity({ name = name, position = { x, y }, force = "enemy" }))
end

local function box(x1, y1, x2, y2)
	return { left_top = { x = x1 - 10, y = y1 - 10 }, right_bottom = { x = x2 + 10, y = y2 + 10 } }
end

local function assign(c, jid, nest)
	for _, v in ipairs({ c.leader, c.minion }) do
		charge(v)
		ct.registry.set_state(cid_of(v), "idle")
	end
	fx.squad(jid, c.surface, c.leader, { c.minion }, c.station, { { wid = "4242|" .. c.surface.name
		.. "|destroy|0", key = 0, area = nest, bring = {}, out = 0 } })
end

--- Charges the roboports, and puts 200 rockets in a ctron's ammo once it has left loading: ammo that is not
--- requested (ammo_count is 0) counts as excess and would go to the trash while the run loads.
local function keep_charged(c)
	for _, v in ipairs({ c.leader, c.minion }) do
		charge(v)
		local run = ct.runs.get(cid_of(v))
		if run and run.state ~= "loading" and run.state ~= "to_station" and not c.armed[v.unit_number] then
			c.armed[v.unit_number] = true
			v.get_inventory(defines.inventory.spider_ammo).insert({ name = "rocket", count = 200 })
		end
	end
end

local function enemies_in(c, nest)
	return c.surface.count_entities_filtered({ force = "enemy", area = { nest.left_top, nest.right_bottom } })
end

t.case("G12 a squad clears a small nest", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g12-clear")
		enemy(c, "biter-spawner", 80, -4)
		enemy(c, "biter-spawner", 80, 4)
		enemy(c, "small-worm-turret", 86, 0)
		enemy(c, "small-worm-turret", 74, 0)
		c.nest = box(74, -4, 86, 4)
	end)
	ctx.at(14, function()
		assign(c, "g12-clear", c.nest)
	end)
	fx.wait(ctx, 16, 25000, "both done events", function()
		keep_charged(c)
		local m, l = ct.runs.get(c.mcid), ct.runs.get(c.lcid)
		-- D2: the leader waits at the station for the minion; D11: its roboports are at radius 0 from loading on.
		if not c.minion_followed then
			c.max_out = math.max(c.max_out or 0, dist(c.leader.position, c.station.position))
		end
		c.r0 = c.r0 or (l and l.state == "loading" and not c.leader.allow_dispatching_robots) -- R-205: roboports off
		c.m_load = c.m_load or (m and m.load)
		c.minion_followed = c.minion_followed or (m and m.state == "follow" and c.minion.valid
			and c.minion.follow_target ~= nil and c.minion.follow_target.unit_number == c.leader.unit_number)
		c.leader_fought = c.leader_fought or (l and l.state == "fight")
		return #events_of("g12-clear", "done") >= 2
	end, function()
		ctx.expect(c.r0, "the leader's roboports were off while loading")
		ctx.expect(c.max_out <= 16, "no more than 16 tiles from the station before the minion followed: " .. c.max_out)
		ctx.expect(c.m_load and c.m_load["atomic-bomb"] == nil, "no atomic line in the minion's load")
		ctx.expect(c.minion_followed, "the minion followed the leader")
		ctx.expect(c.leader_fought, "the leader fought")
		ctx.expect(enemies_in(c, c.nest) == 0, "no enemy left: " .. enemies_in(c, c.nest))
	end)
end)

t.case("G12 threat at or above 100 retreats", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g12-retreat")
		-- 36 worms: threat = 36 * (1.6 + 1.55) = 113 for a full-health leader with one minion.
		for i = 0, 5 do
			for j = 0, 5 do
				enemy(c, "big-worm-turret", 70 + i * 3, -7 + j * 3)
			end
		end
		c.nest = box(70, -7, 85, 8)
	end)
	ctx.at(14, function()
		assign(c, "g12-retreat", c.nest)
	end)
	fx.wait(ctx, 16, 15000, "the leader in fight", function()
		keep_charged(c)
		local l = ct.runs.get(c.lcid)
		return l and l.state == "fight"
	end, function(k)
		fx.wait(ctx, k + 1, 3000, "the leader retreating", function()
			keep_charged(c)
			local l = ct.runs.get(c.lcid)
			return l and l.combat.retreating == true
		end, function()
			local l = ct.runs.get(c.lcid)
			ctx.expect(l.status == "safe_position", "status safe_position: " .. tostring(l.status))
			-- D4 (the owner's "walks all the way back to the station"): the trail began at the station, before contact.
			local safe, st = l.combat.safe, l.station
			ctx.expect(#safe >= 1, "a safe position was recorded: " .. #safe)
			local first, last = safe[1], safe[#safe]
			local d1, dl = dist(first, st), dist(last, st)
			local near = c.surface.count_entities_filtered({ position = first, radius = 40, force = "enemy",
				is_military_target = true, limit = 1 })
			local dest = c.leader.autopilot_destination
			local dd = dest and dist(dest, last) or math.huge
			fx.note("g12-squads", "retreat D4 safe=", #safe, " first-to-station=", d1, " last-to-station=", dl,
				" enemies-near-first=", near, " dest-to-last=", dd, " tick=", game.tick)
			ctx.expect(d1 > 16, "the first entry is more than 16 from the station: " .. d1)
			ctx.expect(near == 0, "no enemy within gun range + 4 of the first entry (recorded before contact)")
			ctx.expect(dl > 16, "the last entry is not the station: " .. dl)
			ctx.expect(dd <= 1, "the autopilot goes one trail step back: " .. dd)
		end)
	end)
end)

t.case("G12 an atomic strike above min_cluster", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g12-nuke")
		local st = storage.ctron_pluginv2
		local overrides = {}
		for k, v in pairs(st.settings.overrides) do
			overrides[k] = v
		end
		overrides[c.surface.name] = { atomic_count = 1, min_cluster = 1 }
		local surfaces = {}
		for name in pairs(st.schedulable) do
			surfaces[#surfaces + 1] = name
		end
		fx.send("ct.settings", { overrides = overrides, surfaces = surfaces })
		-- D8: the bomb sits in the launchers; loading's balance_ammo moves it to the trunk before the strike can fire.
		-- D7: the minion carries none, and its load names none.
		c.leader.get_inventory(defines.inventory.spider_ammo).insert({ name = "atomic-bomb", count = 1 })
		enemy(c, "biter-spawner", 70, -3)
		enemy(c, "biter-spawner", 70, 3)
		enemy(c, "biter-spawner", 74, 0)
		c.nest = box(70, -3, 74, 3)
	end)
	ctx.at(16, function()
		assign(c, "g12-nuke", c.nest)
	end)
	fx.wait(ctx, 18, 6000, "an atomic rocket", function()
		keep_charged(c)
		local l, m = ct.runs.get(c.lcid), ct.runs.get(c.mcid)
		if l and m and not c.checked then
			c.checked = true
			ctx.expect(l.load["atomic-bomb"] ~= nil, "the leader's load names the bomb")
			ctx.expect(m.load["atomic-bomb"] == nil, "the minion's load names none")
		end
		return c.surface.count_entities_filtered({ name = "atomic-rocket" }) > 0
	end, function(k)
		-- Only the nest's own box: the surface's autoplaced enemies (Gleba spawners far out) are not ours.
		fx.wait(ctx, k + 1, 1200, "the spawners destroyed", function()
			keep_charged(c)
			return c.surface.count_entities_filtered({ type = "unit-spawner", area = { c.nest.left_top,
				c.nest.right_bottom } }) == 0
		end)
	end)
end)

t.case("G12 the leader holds at its station for a minion still loading", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g12-wait", true)
		enemy(c, "biter-spawner", 60, 0)
		c.nest = box(60, 0, 60, 0)
	end)
	ctx.at(14, function()
		assign(c, "g12-wait", c.nest)
	end)
	-- The minion stays in loading: its next poll is pushed far ahead the tick it is seen there (D3).
	fx.wait(ctx, 16, 600, "the minion in loading", function()
		local m = ct.runs.get(c.mcid)
		if m and m.state == "loading" then
			m.next = game.tick + 1000000
			return true
		end
	end, function(k)
		fx.wait(ctx, k + 1, 3000, "the leader holding with minion_proximity", function()
			keep_charged(c)
			local l = ct.runs.get(c.lcid)
			return l and l.state == "fight" and l.status == "minion_proximity"
		end, function(k2)
			local from = game.tick
			fx.wait(ctx, k2 + 1, 700, "600 ticks of holding", function()
				keep_charged(c)
				local l = ct.runs.get(c.lcid)
				c.drift = math.max(c.drift or 0, dist(c.leader.position, c.station.position))
				c.popped = c.popped or (l and l.done_tasks > 0)
				return game.tick >= from + 600
			end, function(k3)
				ctx.expect(c.drift <= 16, "the leader stayed within 16 of the station: " .. c.drift)
				ctx.expect(not c.popped, "no task done while the minion loads")
				ct.runs.get(c.mcid).next = game.tick
				fx.wait(ctx, k3 + 1, 600, "the minion following the leader", function()
					keep_charged(c)
					local m = ct.runs.get(c.mcid)
					return m and m.state == "follow" and c.minion.follow_target ~= nil
						and c.minion.follow_target.unit_number == c.leader.unit_number
				end, function(k4)
					fx.wait(ctx, k4 + 1, 3000, "the leader leaving the station", function()
						keep_charged(c)
						return dist(c.leader.position, c.station.position) > 16
					end)
				end)
			end)
		end)
	end)
end)

t.case("G12 another job's run is not the squad's, and evade moves the leader", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g12-jid", true)
		enemy(c, "biter-spawner", 60, 0)
		c.nest = box(60, 0, 60, 0)
	end)
	ctx.at(14, function()
		assign(c, "g12-jid", c.nest)
	end)
	fx.wait(ctx, 16, 600, "both runs adopted", function()
		return ct.runs.get(c.lcid) and ct.runs.get(c.mcid)
	end, function()
		local l, m = ct.runs.get(c.lcid), ct.runs.get(c.mcid)
		local f = { tick = game.tick, pos = c.leader.position, health = 1, robots = 0, out = 0, net = false,
			here = ct.registry.here() }
		local cfg = ct.settings.of(c.surface.name)
		-- A member whose cid now holds another job's run is absent for the leader.
		m.jid = "other"
		ctx.expect(ct.combat.facts(l, c.leader, cfg, f).members[1].here == false, "a replaced member is absent")
		m.jid = l.jid
		-- A leader's cid held by a non-destroy run (no combat table) is no leader: no raise, no repair flag.
		local saved = l.combat
		l.jid, l.combat = "other", nil
		local ok = pcall(ct.combat.apply, m, c.minion, { "leader_repair" })
		l.jid, l.combat = m.jid, saved
		ctx.expect(ok, "leader_repair on a replaced leader does not raise")
		ctx.expect(not l.combat.repairing, "the leader was not flagged")
		ct.combat.apply(l, c.leader, { "evade" })
		ctx.expect(c.leader.autopilot_destination ~= nil, "evade sets a destination")
		-- D6: a minion that leaves is dropped from the leader's list at once, and the controller hears `left`.
		ctx.expect(#l.squad.members == 1, "the leader lists the minion")
		ct.runs.leave(m)
		ctx.expect(#l.squad.members == 0, "the leader's list is empty after the minion left")
		local left = events_of("g12-jid", "left")
		ctx.expect(#left == 1 and left[1].fields.cid == c.mcid, "one left event for the minion: " .. #left)
	end)
end)
