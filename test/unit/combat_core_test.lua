local t = require("testlib")
local cc = require("modules/ctron_pluginv2/combat_core")

local function leader(over)
	local v = { here = 1, pos = { x = 0, y = 0 }, health = 1, station = { x = -100, y = 0, inst = 1 },
		task = { x = 0, y = 0, inst = 1 }, tasks_left = 2, enemies = {}, enemy_in_range = false, g = 1.6, minions = 0,
		atomic_count = 0, bombs = 0,
		min_cluster = 8, robots = 4, packs = true, out = 0, moving = false, members = {} }
	for k, x in pairs(over or {}) do v[k] = x end
	return v
end
local function state() return { safe = {}, nuked = {} } end
local function names(n, name) local r = {} for i = 1, n do r[i] = name end return r end
local function has(ops, op) for _, o in ipairs(ops) do if o[1] == op then return o end end end

t.test("gun range by quality, 36 for unknown", function()
	t.expect_eq(cc.gun_range("normal"), 36); t.expect_eq(cc.gun_range("uncommon"), 39.6)
	t.expect_eq(cc.gun_range("rare"), 43.2); t.expect_eq(cc.gun_range("epic"), 46.8)
	t.expect_eq(cc.gun_range("legendary"), 54); t.expect_eq(cc.gun_range("modded"), 36)
end)

local function near(a, b, msg) t.expect_true(math.abs(a - b) < 1e-9, (msg or "") .. ": " .. a .. " vs " .. b) end

t.test("modifier: CC's formula, floor 0.1 inside the max", function()
	near(cc.modifier(1.6, 1, 0), 3.2)                       -- 1.6 + max(1.6 + 0 - 0, 0.1)
	near(cc.modifier(1.6, 0.5, 2), 4.1)                     -- 1.6 + max(1.6 + 1 - 0.1, 0.1)
	near(cc.modifier(0, 1, 10), 0.1)                        -- 0 + max(-0.5, 0.1)
end)

t.test("threat: CC's weights, unknown names weigh 1", function()
	near(cc.threat({ "small-biter", "big-spitter", "behemoth-worm-turret" }, 1), 4.1)
	near(cc.threat({ "modded-enemy" }, 2), 2)
	near(cc.threat({ "small-demolisher" }, 1), 1000)
	near(cc.threat({ "biter-spawner", "gleba-spawner" }, 1), 1)
	near(cc.threat({}, 3.2), 0)
end)

t.test("research lowers g with a floor of 0.4; other techs leave it", function()
	near(cc.research(1.6, "stronger-explosives-3"), 1.5)
	near(cc.research(1.6, "weapon-shooting-speed-6"), 1.4)
	near(cc.research(0.5, "weapon-shooting-speed-3"), 0.4)
	near(cc.research(1.6, "stronger-explosives-2"), 1.6)
	near(cc.research(1.6, "spidertron"), 1.6)
end)

t.test("pick_nuke: strict > min_cluster, > 20 away, marks the cluster", function()
	local nuked = {}
	local small = { id = "1", x = 30, y = 0, cluster = names(8, "x") }   -- 8 is not > 8
	t.expect_eq(cc.pick_nuke({ small }, nuked, 8, { x = 0, y = 0 }), nil)
	t.expect_true(nuked["1"], "a too-small cluster is marked considered")
	local near_one = { id = "2", x = 10, y = 0, cluster = { "2", "3", "4" } }
	t.expect_eq(cc.pick_nuke({ near_one }, nuked, 2, { x = 0, y = 0 }), nil)
	t.expect_eq(nuked["2"], nil, "too close: skipped, not marked")
	local far = { id = "5", x = 25, y = 0, cluster = { "5", "6", "7" } }
	t.expect_eq(cc.pick_nuke({ near_one, far }, nuked, 2, { x = 0, y = 0 }), far)
	t.expect_true(nuked["5"] and nuked["6"] and nuked["7"])
end)

t.test("squad_hold: a member not here, too far or not following holds; no time bound", function()
	local why = { true, "minion_proximity" }
	t.expect_same({ cc.squad_hold({ { here = false } }) }, why)
	t.expect_same({ cc.squad_hold({ { here = true, dist = 33, follow = true } }) }, why)
	t.expect_same({ cc.squad_hold({ { here = true, dist = 10, follow = false } }) }, why)
	t.expect_same({ cc.squad_hold({ { here = true, dist = 32, follow = true }, { here = true, dist = 1, follow = true } }) },
		{ false })
	t.expect_same({ cc.squad_hold({}) }, { false })
end)

t.test("fight: threat < 40 records a safe position every 16 tiles", function()
	local c = state()
	cc.fight(leader({ pos = { x = -83.5, y = 0.5 } }), c)  -- 16.5 from the station at (-100, 0)
	t.expect_same(c.safe, { { x = -84, y = 0, inst = 1 } })
	cc.fight(leader({ pos = { x = -70, y = 0 } }), c)      -- 14 from the last one: no new one
	t.expect_eq(#c.safe, 1)
end)

t.test("fight: thresholds 40 / 50 / 100", function()
	local mod = cc.modifier(1.6, 1, 0)                     -- 3.2
	local function at(threat) return names(math.ceil(threat / mod), "big-biter") end
	local c = state()
	local d = cc.fight(leader({ enemies = at(45) }), c)    -- 48
	t.expect_true(d.pop, "threat < 50 at the task with more tasks: pop")
	t.expect_eq(#c.safe, 0, "threat >= 40 records nothing")
	d = cc.fight(leader({ enemies = at(60) }), c)          -- 60.8
	t.expect_eq(d.status, "standing_ground"); t.expect_true(has(d.ops, "stop") and has(d.ops, "evade"))
	d = cc.fight(leader({ enemies = at(60), moving = true }), c)
	t.expect_eq(#d.ops, 0, "holding and still evading: nothing new")
	d = cc.fight(leader({ enemies = at(100) }), c)         -- 102.4
	t.expect_eq(d.status, "safe_position"); t.expect_same(has(d.ops, "move"), { "move", { x = -100, y = 0, inst = 1 } })
end)

t.test("fight: a retreat with no safe position goes to the station, on any instance", function()
	local c = state()
	c.retreating = true
	local d = cc.fight(leader({ enemies = names(40, "big-biter"), pos = { x = -97, y = 0 } }), c)
	t.expect_same(has(d.ops, "move"), { "move", { x = -100, y = 0, inst = 1 } })
	c = state()
	d = cc.fight(leader({ enemies = names(40, "big-biter"), station = { x = 5, y = 6, inst = 2 } }), c)
	t.expect_same(has(d.ops, "move"), { "move", { x = 5, y = 6, inst = 2 } }, "a station on another instance is still the target")
	d = cc.fight(leader({ enemies = names(40, "big-biter"), station = { x = 5, y = 6, inst = 2 }, pos = { x = 5, y = 6 } }), c)
	t.expect_eq(#c.safe, 0)
	t.expect_eq(has(d.ops, "stop"), nil, "never 'reaches' a place on another instance by geometry")
end)

t.test("fight: a retreat pops the safe position it reached", function()
	local c = state()
	c.safe = { { x = -50, y = 0, inst = 1 }, { x = -20, y = 0, inst = 1 } }
	c.retreating = true
	local d = cc.fight(leader({ enemies = names(40, "big-biter"), pos = { x = -22, y = 0 } }), c)
	t.expect_same(c.safe, { { x = -50, y = 0, inst = 1 } })
	t.expect_same(has(d.ops, "move"), { "move", { x = -50, y = 0, inst = 1 } })
end)

t.test("fight: safe positions carry the instance; a new tile records at once", function()
	local c = state()
	c.safe = { { x = 0, y = 0, inst = 1 } }
	cc.fight(leader({ here = 2, pos = { x = 1, y = 1 } }), c)
	t.expect_same(c.safe[2], { x = 1, y = 1, inst = 2 })
end)

t.test("fight: the trail starts 16 tiles out of the station and a retreat steps back along it (D4)", function()
	local c = state()
	local function at(x) return leader({ pos = { x = x, y = 0 }, station = { x = 0, y = 0, inst = 1 } }) end
	for x = 0, 16 do cc.fight(at(x), c) end
	t.expect_eq(#c.safe, 0, "nothing within 16 of the station")
	cc.fight(at(17), c)
	t.expect_same(c.safe, { { x = 17, y = 0, inst = 1 } })
	c.safe = { { x = 16, y = 0, inst = 1 }, { x = 32, y = 0, inst = 1 } }
	local d = cc.fight(leader({ pos = { x = 40, y = 0 }, station = { x = 0, y = 0, inst = 1 }, enemies = names(40, "big-biter") }), c)
	t.expect_same(d.ops[1], { "move", { x = 32, y = 0, inst = 1 } }, "the last trail entry, not the station")
end)

t.test("fight: the trail stays loop-free: back within 16 of an earlier entry, it is cut back to it (#8)", function()
	local c = state()
	local function calm(x) cc.fight(leader({ pos = { x = x, y = 100 }, station = { x = -300, y = 100, inst = 1 } }), c) end
	-- The biters tile's trail: forward, back, forward again near the nests.
	for _, x in ipairs({ -438, -458, -478, -456, -479, -472 }) do calm(x) end
	t.expect_same(c.safe, { { x = -438, y = 100, inst = 1 }, { x = -458, y = 100, inst = 1 } })
	local wave = leader({ pos = { x = -472, y = 100 }, station = { x = -300, y = 100, inst = 1 },
		enemies = names(40, "big-biter") })
	t.expect_same(has(cc.fight(wave, c).ops, "move"), { "move", { x = -458, y = 100, inst = 1 } },
		"the retreat steps toward the station, never back west")
	calm(-310)
	t.expect_eq(#c.safe, 0, "back within 16 of the station: no trail left")
end)

t.test("fight: a crossing leader does nothing", function()
	local c = state()
	local d = cc.fight(leader({ crossing = true, enemies = names(40, "big-biter") }), c)
	t.expect_eq(#d.ops, 0); t.expect_eq(d.status, "crossing"); t.expect_eq(#c.safe, 0)
end)

t.test("fight: the last task pops only when threat < 3 or nothing is in gun range", function()
	local d = cc.fight(leader({ tasks_left = 1, enemies = names(4, "big-biter"), enemy_in_range = true }), state())
	t.expect_eq(d.pop, nil, "threat 12.8 with an enemy in range: stay")
	d = cc.fight(leader({ tasks_left = 1, enemies = names(4, "big-biter"), enemy_in_range = false }), state())
	t.expect_true(d.pop, "nothing in gun range: pop")
	d = cc.fight(leader({ tasks_left = 1, enemies = { "small-biter", "small-biter" }, enemy_in_range = true }), state())
	t.expect_true(d.pop, "threat 0.64 < 3: pop")
end)

t.test("fight: away from the task, go there unless already moving", function()
	local d = cc.fight(leader({ task = { x = 10, y = 0, inst = 1 } }), state())
	t.expect_true(has(d.ops, "goto_task")); t.expect_eq(d.pop, nil); t.expect_eq(d.status, "moving")
	d = cc.fight(leader({ task = { x = 10, y = 0, inst = 1 }, moving = true }), state())
	t.expect_eq(#d.ops, 0); t.expect_eq(d.status, "moving")
	d = cc.fight(leader({ task = { x = 0, y = 0, inst = 2 } }), state())
	t.expect_true(has(d.ops, "goto_task"), "a task on another instance is far")
end)

t.test("fight: the squad wait stops the advance, at any tick", function()
	local d = cc.fight(leader({ members = { { here = false } } }), state())
	t.expect_eq(d.status, "minion_proximity"); t.expect_true(has(d.ops, "stop")); t.expect_eq(d.pop, nil)
	d = cc.fight(leader({ members = { { here = true, dist = 5, follow = true } } }), state())
	t.expect_true(d.pop, "all attached: no hold")
end)

t.test("fight: atomic only above min_cluster and over 20 away; a close strike retreats", function()
	local c = state()
	c.safe = { { x = -40, y = 0, inst = 1 } }
	local sp = { id = "9", x = 30, y = 0, cluster = { "9", "10", "11" } }
	local d = cc.fight(leader({ atomic_count = 1, bombs = 1, min_cluster = 2, spawners = { sp } }), c)
	t.expect_same(has(d.ops, "nuke"), { "nuke", 30, 0 }); t.expect_same(has(d.ops, "move"), { "move", { x = -40, y = 0, inst = 1 } })
	d = cc.fight(leader({ atomic_count = 1, bombs = 1, min_cluster = 2, spawners = { sp } }), c)
	t.expect_eq(has(d.ops, "nuke"), nil, "a nuked cluster is not struck twice")
	c = state()
	sp = { id = "12", x = 30, y = 0, cluster = { "12", "13", "14" } }
	d = cc.fight(leader({ atomic_count = 1, bombs = 1, min_cluster = 2, spawners = { sp } }), c)
	t.expect_true(has(d.ops, "nuke") and has(d.ops, "stop"))
	t.expect_eq(has(d.ops, "move"), nil, "a close strike with no safe position stays put (D14)")
end)

t.test("fight: repairing", function()
	local c = state()
	c.repairing = true
	local d = cc.fight(leader({ health = 0.5 }), c)
	t.expect_same(has(d.ops, "roboports"), { "roboports", "full" }); t.expect_eq(d.status, "repairing")
	d = cc.fight(leader({ health = 0.5, packs = false }), c)
	t.expect_true(d.to_station); t.expect_eq(c.repairing, nil)
	c.repairing = true
	d = cc.fight(leader({ health = 1, out = 3 }), c)
	t.expect_same(has(d.ops, "roboports"), { "roboports", 0 }); t.expect_true(c.repairing, "waits for robots to dock")
	cc.fight(leader({ health = 1, out = 0 }), c)
	t.expect_eq(c.repairing, nil)
	c.repairing, c.safe = true, { { x = -40, y = 0, inst = 1 }, { x = -20, y = 0, inst = 1 } }
	d = cc.fight(leader({ health = 0.5, enemies = names(20, "big-biter") }), c)  -- 20 * 4.2 = 84
	t.expect_same(has(d.ops, "move"), { "move", { x = -40, y = 0, inst = 1 } }, "threat > 50 while repairing retreats one safe position")
end)

t.test("follow: near the leader follows, far walks, absent does nothing", function()
	local v = { pos = { x = 0, y = 0 }, health = 1, robots = 4, packs = true, out = 0, moving = false, follow = false,
		leader_pos = { x = 10, y = 0 } }
	t.expect_true(has(cc.follow(v, state()).ops, "follow"))
	v.follow = true
	t.expect_eq(#cc.follow(v, state()).ops, 0)
	v.leader_pos = { x = 40, y = 0 }
	t.expect_true(has(cc.follow(v, state()).ops, "goto_leader"))
	v.leader_pos, v.follow = nil, false
	t.expect_eq(#cc.follow(v, state()).ops, 0)
end)

t.test("follow: repairing calls the leader in, and leaves without robots or packs", function()
	local c = state()
	c.repairing = true
	local v = { pos = { x = 0, y = 0 }, health = 0.5, robots = 4, packs = true, out = 0, moving = false, follow = true,
		leader_pos = { x = 1, y = 0 } }
	local d = cc.follow(v, c)
	t.expect_true(has(d.ops, "leader_repair")); t.expect_same(has(d.ops, "roboports"), { "roboports", "full" })
	v.robots = 0
	d = cc.follow(v, c)
	t.expect_true(d.leave); t.expect_eq(c.repairing, nil)
end)

t.test("follow: a leader crossing makes the minion stop and wait", function()
	local v = { pos = { x = 0, y = 0 }, health = 1, robots = 4, packs = true, out = 0, moving = true, follow = false,
		leader_pos = { x = 10, y = 0 }, leader_crossing = true }
	t.expect_same(cc.follow(v, state()).ops, { { "stop" } })
	v.moving = false
	t.expect_eq(#cc.follow(v, state()).ops, 0)
end)

t.test("follow: no local leader goes to a remote lead once, again when it changes", function()
	local c = state()
	local v = { here = 1, pos = { x = 0, y = 0 }, health = 1, robots = 4, packs = true, out = 0, moving = false,
		follow = false, lead = { inst = 2, x = 5, y = 6 } }
	t.expect_same(cc.follow(v, c).ops, { { "goto_lead" } })
	t.expect_same(c.goal, { inst = 2, x = 5, y = 6 })
	v.moving = true
	t.expect_eq(#cc.follow(v, c).ops, 0, "same lead while moving")
	v.lead = { inst = 3, x = 5, y = 6 }
	t.expect_same(cc.follow(v, c).ops, { { "goto_lead" } })
	v.lead = { inst = 3, x = 7, y = 6 }
	t.expect_same(cc.follow(v, c).ops, { { "goto_lead" } }, "a moved lead place")
	v.moving, v.lead = false, { inst = 1, x = 5, y = 6 }
	t.expect_eq(#cc.follow(v, c).ops, 0, "a lead on this tile with no leader here: wait")
end)

t.test("follow: a stale follow_target is dropped, then the lead is routed to in the same poll", function()
	local c = state()
	local v = { here = 1, pos = { x = 0, y = 0 }, health = 1, robots = 4, packs = true, out = 0, moving = true,
		follow = true, lead = { inst = 2, x = 5, y = 6 } }
	t.expect_same(cc.follow(v, c).ops, { { "stop" }, { "goto_lead" } })
	v.lead = nil
	t.expect_same(cc.follow(v, c).ops, { { "stop" } })
end)

t.test("follow: a local leader clears the goal", function()
	local c = state()
	c.goal = { inst = 2, x = 5, y = 6 }
	cc.follow({ pos = { x = 0, y = 0 }, health = 1, robots = 4, packs = true, out = 0, moving = false, follow = true,
		leader_pos = { x = 1, y = 0 } }, c)
	t.expect_eq(c.goal, nil)
end)
