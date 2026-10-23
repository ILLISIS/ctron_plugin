local t = require("testlib")
local rc = require("modules/ctron_pluginv2/run_core")

local CFG = { ammo_count = 0 }
local ST1 = { sid = "1.5", inst = 1, x = -20, y = 0 }
local function box(x1, y1, x2, y2) return { left_top = { x = x1, y = y1 }, right_bottom = { x = x2, y = y2 } } end
local function facts(over)
	local f = { tick = 1000, here = 1, pos = { x = 0, y = 0 }, health = 1, robots = 10, out = 0, count = 0,
		ammo_slots = 0, ammo_trunk = 0, landfill_aboard = 0, fulfilled = false, missing = {}, unloaded = false,
		delivered = false, trash_empty = true, trash_items = {}, station_ok = true, covers_missing = true, alt_station = false,
		drop_station = false, enemy_near = false, leader = false, trunk_count = 0, can_spawn = true }
	for k, v in pairs(over or {}) do f[k] = v end
	return f
end
local function msg(kind, bring, area)
	kind = kind or "construction"
	return { jid = "b.1", kind = kind, surface = "nauvis", station = ST1, members = { "1.10" },
		work = { { wid = "1|nauvis|" .. kind .. "|0,0", key = 0, area = area or box(0, 0, 40, 40),
			bring = bring or { { "stone-furnace", "normal", 4, 50 } }, out = 0 } } }
end
local CTX = { tick = 1000, radius = 10, unit = 10, profile = { ["construction-robot"] = { normal = 50 } } }
local ONE = box(5, 5, 5, 5) -- an area with one task
local function run_of(m) return rc.new(m or msg(), 1, CTX) end
local function op(acts, name) for _, a in ipairs(acts) do if a[1] == name then return a end end end
local function ops(acts) local r = {} for i, a in ipairs(acts) do r[i] = a[1] end return r end
local function loaded(run) -- start, arrive at the station, load; returns the last step's acts
	rc.start(run, facts(), CFG)
	rc.step(run, facts(), CFG, { type = "arrived" })
	return rc.step(run, facts({ tick = 1120, fulfilled = true }), CFG)
end
local function at_task(run) -- loaded, then arrived at the first task at tick 1200
	loaded(run)
	return rc.step(run, facts({ tick = 1200 }), CFG, { type = "arrived" })
end
local function unloading(run) -- a one-task run that finished its task at 1260 and reached its station at 1500
	at_task(run)
	rc.step(run, facts({ tick = 1260, count = 0 }), CFG)
	return rc.step(run, facts({ tick = 1500 }), CFG, { type = "arrived" })
end
local CARGO = { jid = "b.2", kind = "cargo", surface = "nauvis", station = ST1, members = { "1.10" }, work = {},
	cargo = { dest = { sid = "2.7", inst = 2, x = 50, y = 0 }, items = { { "iron-plate", "normal", 200 } } } }

t.test("grid: CC's spacing, one point per 2r, centred when one fits", function()
	local g = rc.grid(box(0, 0, 40, 40), 9.5)
	t.expect_eq(#g, 9)
	t.expect_same(g[1], { x = 9.5, y = 9.5 }); t.expect_same(g[5], { x = 20, y = 20 }); t.expect_same(g[9], { x = 30.5, y = 30.5 })
	t.expect_same(rc.grid(ONE, 9.5), { { x = 5.5, y = 5.5 } })
	t.expect_eq(#rc.grid(box(0, 0, 80, 20), 9.5), 10)  -- 5 along x, 2 along y
end)

t.test("new: tasks over the shares at 0.95 r, load = bring + profile, work instance from the wid", function()
	local run = run_of(msg("construction", { { "stone-furnace", "normal", 4, 50 }, { "construction-robot", "normal", 2, 50 } }))
	t.expect_eq(run.total_tasks, 9); t.expect_eq(#run.tasks, 9); t.expect_eq(run.done_tasks, 0)
	t.expect_same(run.load, { ["stone-furnace"] = { normal = 4 }, ["construction-robot"] = { normal = 52 } })
	t.expect_eq(run.work_inst, 1); t.expect_eq(run.unit, 10); t.expect_eq(run.landfill, nil); t.expect_eq(run.reached, 0)
	t.expect_eq(run.cid, "1.10"); t.expect_eq(run.role, "worker"); t.expect_same(run.station, ST1)
	t.expect_eq(run_of(msg("construction", { { "landfill", "normal", 30, 100 } })).landfill, "landfill")
end)

t.test("new: a cargo run has no tasks and loads its items plus the profile", function()
	local run = rc.new(CARGO, 1, { tick = 1, radius = 10, unit = 10, profile = { rocket = { normal = 10 } } })
	t.expect_eq(#run.tasks, 0); t.expect_eq(run.work_inst, nil)
	t.expect_same(run.load, { ["iron-plate"] = { normal = 200 }, rocket = { normal = 10 } })
end)

t.test("pick: nearest to the ctron, deferred tasks last, the first task off the work's instance", function()
	local run = run_of()
	run.tasks = { { x = 30, y = 0 }, { x = 5, y = 0, again = true }, { x = 10, y = 0 } }
	t.expect_eq(rc.pick(run, { x = 0, y = 0 }, 1), 3)
	run.tasks[3].again = true
	t.expect_eq(rc.pick(run, { x = 0, y = 0 }, 1), 1, "the only task that hasn't failed")
	run.tasks[1].again = true
	t.expect_eq(rc.pick(run, { x = 0, y = 0 }, 1), 2, "all deferred: the nearest")
	t.expect_eq(rc.pick(run, { x = 0, y = 0 }, 2), 1, "off the work's instance: the first task")
	run.tasks = {}
	t.expect_eq(rc.pick(run, { x = 0, y = 0 }, 1), nil)
end)

t.test("start: to_station at radius 10, event only", function()
	local run = run_of()
	local acts = rc.start(run, facts(), CFG)
	t.expect_eq(run.state, "to_station"); t.expect_eq(run.next, nil); t.expect_eq(run.status, "moving")
	t.expect_same(acts, { { "travel", { inst = 1, x = -20, y = 0 }, { kind = "station", radius = 10 } } })
end)

t.test("to_station: arrival at a working station starts loading", function()
	local run = run_of()
	rc.start(run, facts(), CFG)
	local acts = rc.step(run, facts(), CFG, { type = "arrived" })
	t.expect_eq(run.state, "loading"); t.expect_same(acts, { { "requests", "load" } })
	t.expect_eq(run.next, 1120); t.expect_eq(run.status, "requesting")
end)

t.test("to_station: a dead station tries one other local station, then fails in place", function()
	local run = run_of()
	rc.start(run, facts(), CFG)
	local alt = { sid = "1.6", inst = 1, x = -40, y = 0 }
	local acts = rc.step(run, facts({ station_ok = false, alt_station = alt }), CFG, { type = "arrived" })
	t.expect_same(run.station, alt); t.expect_same(op(acts, "travel")[2], { inst = 1, x = -40, y = 0 })
	acts = rc.step(run, facts({ station_ok = false, alt_station = ST1 }), CFG, { type = "arrived" })
	t.expect_same(op(acts, "emit"), { "emit", "failed", { cid = "1.10", why = "no_stations", wid = "1|nauvis|construction|0,0",
		left = 1000 } })
	t.expect_true(op(acts, "release")); t.expect_true(op(acts, "rescan"), "on the work's instance: left and a rescan (R-124)")
	t.expect_eq(run.state, "ended"); t.expect_eq(run.status, "no_stations")
	t.expect_same(rc.step(run, facts(), CFG), {}, "an ended run does nothing")
end)

t.test("to_station: a travel failure takes the same fallback", function()
	local run = run_of()
	rc.start(run, facts(), CFG)
	local acts = rc.step(run, facts(), CFG, { type = "failed", reason = "no_route" })
	t.expect_eq(op(acts, "emit")[3].why, "no_route"); t.expect_eq(run.state, "ended")
end)

t.test("loading: fulfilled clears, balances ammo and walks to the nearest task", function()
	local run = run_of()
	local acts = loaded(run)
	t.expect_same(acts, { { "requests", "clear" }, { "balance_ammo" },
		{ "travel", { inst = 1, x = 9.5, y = 9.5 }, { kind = "work", radius = 3, reach = 10 } } })
	t.expect_eq(run.state, "to_work"); t.expect_eq(run.task, 1); t.expect_eq(run.next, nil)
end)

t.test("loading: a short after 900 ticks when the network covers none of the missing items, again every 900 (R-212)", function()
	local run = run_of()
	rc.start(run, facts(), CFG); rc.step(run, facts(), CFG, { type = "arrived" }) -- loading since 1000
	local missing = { { "iron-plate", "normal", 5 } }
	local acts = rc.step(run, facts({ tick = 1800, missing = missing, covers_missing = false }), CFG)
	t.expect_same(acts, {}, "not before 900 ticks"); t.expect_eq(run.status, "awaiting_logistics")
	t.expect_same(run.arg, missing)
	acts = rc.step(run, facts({ tick = 1900, missing = missing, covers_missing = false }), CFG)
	t.expect_same(acts, { { "emit", "short", { cid = "1.10", missing = missing } } }); t.expect_eq(run.status, "short")
	acts = rc.step(run, facts({ tick = 2020, missing = missing, covers_missing = false }), CFG)
	t.expect_same(acts, {}, "not again within 900 ticks"); t.expect_eq(run.next, 2140)
	acts = rc.step(run, facts({ tick = 2800, missing = missing, covers_missing = false }), CFG)
	t.expect_same(acts, { { "emit", "short", { cid = "1.10", missing = missing } } }, "again after 900")
end)

t.test("loading: no short while the network covers something missing; trash_full once", function()
	local run = run_of()
	rc.start(run, facts(), CFG); rc.step(run, facts(), CFG, { type = "arrived" })
	local items = { { "wood", "normal", 50 } }
	local acts = rc.step(run, facts({ tick = 1900, trash_empty = false, trash_stuck = true, trash_items = items }), CFG)
	t.expect_same(acts, { { "emit", "trash_full", { cid = "1.10", items = items } } })
	t.expect_eq(run.status, "trash_full"); t.expect_same(run.arg, items)
	acts = rc.step(run, facts({ tick = 2020, trash_empty = false, trash_stuck = true, trash_items = items }), CFG)
	t.expect_same(acts, {})
	t.expect_eq(run.status, "trash_full", "still trash_full on a later poll"); t.expect_same(run.arg, items)
end)

t.test("loading: a new station (ct.job.station) walks there and starts a new visit", function()
	local run = run_of()
	rc.start(run, facts(), CFG); rc.step(run, facts(), CFG, { type = "arrived" })
	rc.step(run, facts({ tick = 1900, covers_missing = false }), CFG) -- short sent
	local acts = rc.step(run, facts({ tick = 1950 }), CFG, { type = "station", station = { sid = "2.9", inst = 2, x = 100, y = 0 } })
	t.expect_eq(run.state, "to_station"); t.expect_same(op(acts, "travel")[2], { inst = 2, x = 100, y = 0 })
	rc.step(run, facts({ tick = 2500, here = 2 }), CFG, { type = "arrived" })
	t.expect_eq(run.state, "loading"); t.expect_same(run.sent, {})
end)

t.test("to_work: the first failure defers the task and re-picks", function()
	local run = run_of()
	loaded(run) -- task 1 = (9.5, 9.5)
	local acts = rc.step(run, facts({ tick = 1200 }), CFG, { type = "failed", reason = "no_path" })
	t.expect_true(run.tasks[1].again); t.expect_eq(run.task, 2); t.expect_eq(#run.tasks, 9)
	t.expect_same(op(acts, "travel")[2], { inst = 1, x = 20, y = 9.5 })
end)

t.test("to_work: every task dropped ends failed after unloading (review 8)", function()
	local run = run_of(msg("construction", nil, ONE))
	loaded(run)
	rc.step(run, facts({ tick = 1200 }), CFG, { type = "failed", reason = "no_path" })
	t.expect_eq(run.state, "to_work"); t.expect_true(run.tasks[1].again)
	local acts = rc.step(run, facts({ tick = 1300 }), CFG, { type = "failed", reason = "no_path" })
	t.expect_eq(#run.tasks, 0); t.expect_eq(run.state, "returning")
	t.expect_true(op(acts, "rescan")); t.expect_eq(run.left, 1300)
	rc.step(run, facts({ tick = 1500 }), CFG, { type = "arrived" })
	acts = rc.step(run, facts({ tick = 1620, unloaded = true }), CFG)
	t.expect_same(op(acts, "emit"), { "emit", "failed", { cid = "1.10", why = "no_path", wid = "1|nauvis|construction|0,0",
		left = 1300 } })
	t.expect_true(op(acts, "release"))
end)

t.test("to_work: arrival starts at_task (poll 60, 3600-tick limit per task)", function()
	local run = run_of()
	local acts = at_task(run)
	t.expect_eq(run.state, "at_task"); t.expect_eq(run.reached, 1); t.expect_eq(run.next, 1260)
	t.expect_eq(run.task_since, 1200); t.expect_eq(run.status, "working"); t.expect_eq(run.arg, "construction")
	t.expect_same(acts, {}, "no roboport op for a run at full size")
end)

t.test("repick: after a crossing's arrival, the nearest task from where the ctron stands, with no stop", function()
	local run = run_of()
	loaded(run)
	local acts = rc.step(run, facts({ tick = 1200, pos = { x = 31, y = 31 } }), CFG, { type = "repick" })
	t.expect_eq(run.task, 9)
	t.expect_same(acts, { { "travel", { inst = 1, x = 30.5, y = 30.5 }, { kind = "work", radius = 3, reach = 10 } } })
end)

t.test("at_task: robots out unchanged for 5 checks pops, whatever charging does (review 24)", function()
	local run = run_of()
	at_task(run)
	for i = 1, 5 do
		rc.step(run, facts({ tick = 1200 + 60 * i, out = 3 }), CFG)
		t.expect_eq(run.state, "at_task", "check " .. i)
	end
	rc.step(run, facts({ tick = 1560, out = 3 }), CFG)
	t.expect_eq(run.state, "to_work"); t.expect_eq(run.done_tasks, 1); t.expect_eq(#run.tasks, 8)
end)

t.test("at_task: robots all out but the count falling is progress, no stall pop (I1)", function()
	local run = run_of()
	at_task(run)
	for i = 1, 8 do
		rc.step(run, facts({ tick = 1200 + 60 * i, out = 10, count = 20 - i }), CFG)
		t.expect_eq(run.state, "at_task", "check " .. i)
	end
	for i = 9, 12 do rc.step(run, facts({ tick = 1200 + 60 * i, out = 10, count = 12 }), CFG) end
	t.expect_eq(run.state, "at_task", "four unchanged checks after the last change")
	rc.step(run, facts({ tick = 1200 + 60 * 13, out = 10, count = 12 }), CFG)
	t.expect_eq(run.state, "to_work")
end)

t.test("at_task: robots emptying a full chest move the trunk's items: progress, no stall pop (E8)", function()
	local run = run_of()
	at_task(run)
	for i = 1, 10 do
		rc.step(run, facts({ tick = 1200 + 60 * i, out = 10, count = 3, trunk_count = 50 * i }), CFG)
		t.expect_eq(run.state, "at_task", "check " .. i)
	end
	for i = 11, 14 do rc.step(run, facts({ tick = 1200 + 60 * i, out = 10, count = 3, trunk_count = 500 }), CFG) end
	t.expect_eq(run.state, "at_task", "four unchanged checks after the last change")
	rc.step(run, facts({ tick = 1200 + 60 * 15, out = 10, count = 3, trunk_count = 500 }), CFG)
	t.expect_eq(run.state, "to_work")
end)

t.test("at_task: something left with no robot out waits while no roboport can spawn robots (E8)", function()
	local run = run_of()
	at_task(run)
	for i = 1, 10 do
		rc.step(run, facts({ tick = 1200 + 60 * i, out = 0, count = 3, can_spawn = false }), CFG)
		t.expect_eq(run.state, "at_task", "check " .. i)
	end
	rc.step(run, facts({ tick = 1860, out = 0, count = 3 }), CFG); t.expect_eq(run.state, "at_task")
	rc.step(run, facts({ tick = 1920, out = 0, count = 3 }), CFG); t.expect_eq(run.state, "to_work")
end)

t.test("at_task: a ctron that never can spawn robots pops by the 3600-tick limit from arrival (E8)", function()
	local run = run_of()
	at_task(run)
	for i = 1, 59 do rc.step(run, facts({ tick = 1200 + 60 * i, out = 0, count = 3, can_spawn = false }), CFG) end
	t.expect_eq(run.state, "at_task", "3540 ticks after arrival")
	rc.step(run, facts({ tick = 4800, out = 0, count = 3, can_spawn = false }), CFG)
	t.expect_eq(run.state, "to_work")
end)

t.test("at_task: the 3600-tick limit runs from the task's last progress (E8)", function()
	local run = run_of()
	at_task(run)
	for i = 1, 70 do -- robots cycling (out changes) and the trunk filling: an hour of real work
		rc.step(run, facts({ tick = 1200 + 60 * i, out = 5 + i % 2, count = 3, trunk_count = i }), CFG)
	end
	t.expect_eq(run.state, "at_task", "70 checks of progress")
	for i = 71, 129 do rc.step(run, facts({ tick = 1200 + 60 * i, out = 5 + i % 2, count = 3, trunk_count = 70 }), CFG) end
	t.expect_eq(run.state, "at_task", "3540 ticks since the last progress")
	rc.step(run, facts({ tick = 1200 + 60 * 130, out = 5, count = 3, trunk_count = 70 }), CFG)
	t.expect_eq(run.state, "to_work")
end)

t.test("trash deadlines wait while the network is still taking the trash (C1)", function()
	local items = { { "wood", "normal", 50 } }
	local run = run_of()
	rc.start(run, facts(), CFG); rc.step(run, facts(), CFG, { type = "arrived" })
	t.expect_same(rc.step(run, facts({ tick = 2020, trash_empty = false, trash_items = items }), CFG), {})
	run = run_of(msg("construction", nil, ONE))
	unloading(run)
	local drop = { sid = "1.7", inst = 1, x = 0, y = 30 }
	t.expect_same(rc.step(run, facts({ tick = 2400, trash_empty = false, trash_items = items, drop_station = drop }), CFG), {})
	t.expect_eq(run.state, "unloading")
	run = rc.new(CARGO, 1, CTX)
	loaded(run)
	rc.step(run, facts({ tick = 2000, here = 2 }), CFG, { type = "arrived" })
	rc.step(run, facts({ tick = 2900, here = 2, trash_empty = false }), CFG)
	t.expect_eq(run.status, "delivering", "draining: keep waiting")
end)

t.test("at_task: nothing out and nothing left pops at once; something left pops on the second check in a row", function()
	local run = run_of()
	at_task(run)
	rc.step(run, facts({ tick = 1260, out = 0, count = 0 }), CFG)
	t.expect_eq(run.state, "to_work")
	run = run_of()
	at_task(run)
	rc.step(run, facts({ tick = 1260, out = 0, count = 4 }), CFG)
	t.expect_eq(run.state, "at_task")
	rc.step(run, facts({ tick = 1320, out = 2 }), CFG) -- robots out again: the count restarts
	rc.step(run, facts({ tick = 1380, out = 0, count = 4 }), CFG)
	t.expect_eq(run.state, "at_task")
	rc.step(run, facts({ tick = 1440, out = 0, count = 4 }), CFG)
	t.expect_eq(run.state, "to_work")
end)

t.test("at_task: repair pops on the second check; 3600 ticks on one task pops any kind", function()
	local run = run_of(msg("repair"))
	at_task(run)
	rc.step(run, facts({ tick = 1260, out = 0 }), CFG); t.expect_eq(run.state, "at_task")
	rc.step(run, facts({ tick = 1320, out = 0 }), CFG); t.expect_eq(run.state, "to_work")
	run = run_of(msg("repair")) -- I2: robots out keep a repair task (CC job.lua:1167-1176)
	at_task(run)
	for i = 1, 3 do rc.step(run, facts({ tick = 1200 + 60 * i, out = 5 }), CFG) end
	t.expect_eq(run.state, "at_task")
	run = run_of(msg("repair")) -- every robot busy repairing is progress, not a stall
	at_task(run)
	for i = 1, 8 do rc.step(run, facts({ tick = 1200 + 60 * i, out = 10, robots = 10 }), CFG) end
	t.expect_eq(run.state, "at_task")
	run = run_of(msg("repair")) -- an idle robot and nothing changing for 5 checks is a stall
	at_task(run)
	for i = 1, 6 do rc.step(run, facts({ tick = 1200 + 60 * i, out = 5, robots = 10 }), CFG) end
	t.expect_eq(run.state, "to_work")
	run = run_of()
	at_task(run)
	rc.step(run, facts({ tick = 4740, out = 7 }), CFG); t.expect_eq(run.state, "at_task")
	rc.step(run, facts({ tick = 4800, out = 7 }), CFG); t.expect_eq(run.state, "to_work")
end)

t.test("the last pop leaves work: rescan and left on the work's tile, then returning", function()
	local run = run_of(msg("construction", nil, ONE))
	at_task(run)
	local acts = rc.step(run, facts({ tick = 1260, out = 0, count = 0 }), CFG)
	t.expect_eq(run.state, "returning"); t.expect_eq(run.left, 1260)
	t.expect_same(acts, { { "rescan" }, { "travel", { inst = 1, x = -20, y = 0 }, { kind = "station", radius = 10 } } })
end)

t.test("unloading: done carries left once the trunk holds only kept items (no rescan gate, review 2)", function()
	local run = run_of(msg("construction", nil, ONE))
	local acts = unloading(run)
	t.expect_eq(run.state, "unloading"); t.expect_same(acts, { { "requests", "unload" } })
	rc.step(run, facts({ tick = 1620 }), CFG)
	t.expect_eq(run.state, "unloading"); t.expect_eq(run.next, 1740)
	acts = rc.step(run, facts({ tick = 1740, unloaded = true }), CFG)
	t.expect_same(acts, { { "requests", "clear" }, { "emit", "done", { cid = "1.10", left = 1260 } }, { "release" } })
	t.expect_eq(run.state, "ended")
end)

t.test("unloading: trash not taken in 900 ticks tries one dropping station, then trash_full once", function()
	local run = run_of(msg("construction", nil, ONE))
	unloading(run) -- unloading since 1500
	local drop = { sid = "1.7", inst = 1, x = 0, y = 30 }
	local items = { { "wood", "normal", 400 } }
	local acts = rc.step(run, facts({ tick = 2400, trash_empty = false, trash_stuck = true, trash_items = items, drop_station = drop }), CFG)
	t.expect_eq(run.state, "returning"); t.expect_same(op(acts, "travel")[2], { inst = 1, x = 0, y = 30 })
	rc.step(run, facts({ tick = 2600 }), CFG, { type = "arrived" }) -- unloading since 2600
	acts = rc.step(run, facts({ tick = 3500, trash_empty = false, trash_stuck = true, trash_items = items, drop_station = drop }), CFG)
	t.expect_same(acts, { { "emit", "trash_full", { cid = "1.10", items = items } } })
	t.expect_eq(run.state, "unloading"); t.expect_eq(run.status, "trash_full"); t.expect_same(run.arg, items)
end)

t.test("a station change in unloading goes returning to it (review 16)", function()
	local run = run_of(msg("construction", nil, ONE))
	unloading(run)
	local acts = rc.step(run, facts({ tick = 1550 }), CFG, { type = "station", station = { sid = "2.9", inst = 2, x = 100, y = 0 } })
	t.expect_eq(run.state, "returning"); t.expect_same(op(acts, "travel")[2], { inst = 2, x = 100, y = 0 })
end)

t.test("cancel: stops, returns without a rescan and ends done; ignored once returning", function()
	local run = run_of()
	at_task(run)
	local acts = rc.step(run, facts({ tick = 1230 }), CFG, { type = "cancel" })
	t.expect_eq(ops(acts)[1], "stop"); t.expect_eq(run.state, "returning"); t.expect_true(run.cancelled)
	t.expect_eq(op(acts, "rescan"), nil, "the controller clears cancelled cells (R-39)")
	t.expect_same(rc.step(run, facts({ tick = 1240 }), CFG, { type = "cancel" }), {})
	rc.step(run, facts({ tick = 1500 }), CFG, { type = "arrived" })
	t.expect_same(rc.step(run, facts({ tick = 1520 }), CFG, { type = "cancel" }), {}, "ignored in unloading")
	acts = rc.step(run, facts({ tick = 1620, unloaded = true }), CFG)
	t.expect_same(op(acts, "emit"), { "emit", "done", { cid = "1.10" } })
end)

t.test("interrupts in order: health, robots, ammo", function()
	local run = run_of()
	at_task(run)
	rc.step(run, facts({ tick = 1260, health = 0.5, robots = 0 }), CFG)
	t.expect_eq(run.state, "returning", "health first: leave_work, then returning")
	run = run_of()
	at_task(run)
	rc.step(run, facts({ tick = 1260, robots = 0 }), CFG)
	t.expect_eq(run.state, "to_station"); t.expect_eq(run.status, "missing_robots"); t.expect_eq(#run.tasks, 9, "the task stays")
	local cfg = { ammo_count = 100 }
	run = run_of()
	at_task(run)
	rc.step(run, facts({ tick = 1260, ammo_slots = 25, ammo_trunk = 25, out = 1 }), cfg)
	t.expect_eq(run.state, "to_station", "neither slots nor trunk holds more than ceil(25 %)")
	run = run_of()
	at_task(run)
	rc.step(run, facts({ tick = 1260, ammo_slots = 26, ammo_trunk = 0, out = 1 }), cfg)
	t.expect_eq(run.state, "at_task")
	local none = { ammo_slots = 0, ammo_trunk = 0 }
	t.expect_true(rc.ammo_low(none, cfg)); t.expect_eq(rc.ammo_low(none, CFG), false)
end)

t.test("an ammo setting changed mid-run: the restock loads the new ammo, so the run doesn't turn straight back (#5)", function()
	local rockets = { ammo_count = 100, ammo = { "rocket", "normal" } }
	local run = rc.new(msg(), 1, { tick = 1000, radius = 10, unit = 10, profile = { rocket = { normal = 100 } },
		ammo = { "rocket", "normal", 100 } })
	rc.start(run, facts(), rockets)
	rc.step(run, facts(), rockets, { type = "arrived" })
	t.expect_same(run.load, { ["stone-furnace"] = { normal = 4 }, rocket = { normal = 100 } }, "unchanged settings")
	rc.step(run, facts({ tick = 1120, fulfilled = true }), rockets)
	rc.step(run, facts({ tick = 1200 }), rockets, { type = "arrived" })
	local explosive = { ammo_count = 200, ammo = { "explosive-rocket", "normal" } }
	rc.step(run, facts({ tick = 1260, out = 1 }), explosive) -- none of the new ammo aboard
	t.expect_eq(run.state, "to_station")
	rc.step(run, facts({ tick = 1500 }), explosive, { type = "arrived" })
	t.expect_eq(run.state, "loading")
	t.expect_same(run.load, { ["stone-furnace"] = { normal = 4 }, ["explosive-rocket"] = { normal = 200 } },
		"the old ammo's line gives way to the new one")
	rc.step(run, facts({ tick = 1620, fulfilled = true }), explosive)
	rc.step(run, facts({ tick = 1700 }), explosive, { type = "arrived" })
	rc.step(run, facts({ tick = 1760, out = 1 }), { ammo_count = 0 }) -- ammo turned off: no restock
	t.expect_eq(run.state, "at_task")
	rc.step(run, facts({ tick = 1820, robots = 0 }), { ammo_count = 0 })
	rc.step(run, facts({ tick = 2000 }), { ammo_count = 0 }, { type = "arrived" })
	t.expect_same(run.load, { ["stone-furnace"] = { normal = 4 } }, "and no ammo line")
end)

t.test("landfill: reduced roboports and logistics while walking, full at the task, out of landfill leaves", function()
	local run = run_of(msg("construction", { { "landfill", "normal", 30, 100 } }))
	local acts = loaded(run)
	t.expect_same(ops(acts), { "requests", "balance_ammo", "roboports", "moving_logistics", "travel" })
	t.expect_same(op(acts, "roboports"), { "roboports", 1 }); t.expect_same(op(acts, "moving_logistics"), { "moving_logistics", true })
	t.expect_same(op(acts, "travel")[3], { kind = "work", radius = 8, landfill = 10, reach = 10 })
	acts = rc.step(run, facts({ tick = 1200, landfill_aboard = 30 }), CFG, { type = "arrived" })
	t.expect_same(acts, { { "roboports", "full" } })
	rc.step(run, facts({ tick = 1230, landfill_aboard = 0, out = 3 }), CFG)
	t.expect_eq(run.state, "at_task", "robots out still carry landfill: no interrupt")
	acts = rc.step(run, facts({ tick = 1260, landfill_aboard = 0, out = 0 }), CFG)
	t.expect_eq(run.state, "returning"); t.expect_eq(run.status, "no_landfill")
	t.expect_same(op(acts, "moving_logistics"), { "moving_logistics", false })
	t.expect_eq(op(acts, "roboports"), nil, "already full")
end)

t.test("cargo: loads, delivers at the destination and ends there (R-45)", function()
	local run = rc.new(CARGO, 1, CTX)
	local acts = loaded(run)
	t.expect_eq(run.state, "to_dest")
	t.expect_same(op(acts, "travel"), { "travel", { inst = 2, x = 50, y = 0 }, { kind = "station", radius = 3 } })
	acts = rc.step(run, facts({ tick = 2000, here = 2 }), CFG, { type = "arrived" })
	t.expect_eq(run.state, "deliver"); t.expect_same(acts, { { "requests", "deliver" } })
	acts = rc.step(run, facts({ tick = 2900, here = 2, trash_empty = false, trash_stuck = true }), CFG)
	t.expect_eq(run.status, "trash_full"); t.expect_same(acts, {}, "cargo raises trash_full as a status only (R-117)")
	acts = rc.step(run, facts({ tick = 3020, here = 2, delivered = true }), CFG)
	t.expect_same(acts, { { "requests", "clear" }, { "emit", "done", { cid = "1.10" } }, { "release" } })
end)

t.test("cargo: a cancel returns the load to the supplier; a failed trip fails in place", function()
	local run = rc.new(CARGO, 1, CTX)
	loaded(run)
	local acts = rc.step(run, facts({ tick = 1500 }), CFG, { type = "cancel" })
	t.expect_eq(run.state, "returning"); t.expect_same(op(acts, "travel")[2], { inst = 1, x = -20, y = 0 })
	run = rc.new(CARGO, 1, CTX)
	loaded(run)
	acts = rc.step(run, facts({ tick = 1500 }), CFG, { type = "failed", reason = "budget" })
	t.expect_eq(op(acts, "emit")[3].why, "budget"); t.expect_eq(run.state, "ended")
end)

t.test("lost: stamps left and rescans only on the work's instance; an earlier left stands", function()
	local run = run_of()
	at_task(run)
	local fields, rescan = rc.lost(run, 1, 1300)
	t.expect_same(fields, { cid = "1.10", left = 1300 }); t.expect_true(rescan)
	run = run_of(msg("construction", nil, ONE))
	at_task(run)
	rc.step(run, facts({ tick = 1260, count = 0 }), CFG) -- left work at 1260
	fields, rescan = rc.lost(run, 1, 1400)
	t.expect_same(fields, { cid = "1.10", left = 1260 }); t.expect_true(rescan)
	run = run_of()
	at_task(run)
	fields, rescan = rc.lost(run, 2, 1300)
	t.expect_same(fields, { cid = "1.10" }); t.expect_eq(rescan, false)
	local cargo = rc.new(CARGO, 1, CTX)
	fields, rescan = rc.lost(cargo, 1, 1300)
	t.expect_same(fields, { cid = "1.10" }); t.expect_eq(rescan, false, "a cargo run has no work instance")
end)

t.test("rebase moves every tick field but left", function()
	local run = { since = 100, next = 160, task_since = 130, left = 50, squad = { leader = "1.10" } }
	rc.rebase(run, 1000)
	t.expect_same(run, { since = 1100, next = 1160, task_since = 1130, left = 50, squad = { leader = "1.10" } })
	rc.rebase(run, -1500)
	t.expect_eq(run.next, -340, "a negative delta just makes the next poll due at once")
end)

local function squad_msg()
	return { jid = "b.3", kind = "destroy", surface = "nauvis", station = ST1, members = { "1.10", "1.11" },
		work = { { wid = "1|nauvis|destroy|0,0", key = 0, area = box(0, 0, 40, 40), bring = {}, out = 0 } } }
end
local function squad_run(i) return rc.new(squad_msg(), i, CTX) end
local function minion_msg() -- the minion assign for the squad above (R-196): no work, the leader's place
	return { jid = "b.3", kind = "destroy", surface = "nauvis", station = ST1, members = { "1.11" }, work = {},
		lead = { cid = "1.10", inst = 1, x = 0, y = 0 } }
end
local function minion_run() return rc.new(minion_msg(), 1, CTX) end
local AT_STATION = { x = -20, y = 0 }
local function lview(over) -- a leader's combat view; run_core fills task, tasks_left and minions
	local v = { tick = 1200, here = 1, pos = { x = 9.5, y = 9.5 }, health = 1, station = { x = -20, y = 0, inst = 1 },
		enemies = {}, enemy_in_range = false, g = 1.6, atomic_count = 0, bombs = 0, min_cluster = 8, robots = 4, packs = true,
		out = 0, moving = false, crossing = false, members = {} }
	for k, x in pairs(over or {}) do v[k] = x end
	return v
end
local function mview(over)
	local v = { here = 1, pos = { x = 0, y = 0 }, health = 1, robots = 4, packs = true, out = 0, moving = false, follow = false,
		leader_pos = { x = 10, y = 0 }, leader_crossing = false, lead = { inst = 1, x = 0, y = 0 } }
	for k, x in pairs(over or {}) do v[k] = x end
	return v
end
-- Both roles are in their fight / follow state at the station once loading completes (R-198): no arrival step.
local function fighting(run) return loaded(run) end
local function following(run) return loaded(run) end
local LEADER = { state = "fight", pos = { x = 10, y = 0 }, dist = 10 }
local DEMOLISHER = { "small-demolisher" } -- threat 1000 x modifier: far past the retreat band

t.test("new: a leader assign gives the leader its squad list and a combat table", function()
	local leader = squad_run(1)
	t.expect_same(leader.squad, { leader = "1.10", members = { "1.11" } })
	t.expect_same(leader.combat, { safe = {}, nuked = {} }); t.expect_eq(leader.role, "leader")
	t.expect_eq(leader.work_inst, 1); t.expect_true(#leader.tasks > 0)
end)

t.test("new: a minion assign builds minions with no work, no tasks and the leader's place (R-209)", function()
	local m = minion_msg()
	m.work = squad_msg().work -- never read for a minion assign
	local minion = rc.new(m, 1, CTX)
	t.expect_eq(minion.role, "minion"); t.expect_same(minion.work, {}); t.expect_same(minion.tasks, {})
	t.expect_eq(minion.total_tasks, 0); t.expect_eq(minion.work_inst, nil); t.expect_eq(minion.cid, "1.11")
	t.expect_same(minion.squad, { leader = "1.10", members = {}, lead = { inst = 1, x = 0, y = 0 } })
	t.expect_same(minion.combat, { safe = {}, nuked = {} })
	t.expect_eq(rc.new({ jid = "b.4", kind = "destroy", surface = "nauvis", station = ST1, members = { "1.11", "1.12" },
		work = {}, lead = m.lead }, 2, CTX).cid, "1.12", "every i of a minion assign is a minion")
	t.expect_eq(rc.new({ jid = "b.4", kind = "destroy", surface = "nauvis", station = ST1, members = { "1.11", "1.12" },
		work = {}, lead = m.lead }, 2, CTX).role, "minion")
end)

t.test("loading: the leader enters fight and the minion follow, at the station (R-198)", function()
	local run = squad_run(1)
	local acts = loaded(run)
	t.expect_eq(run.state, "fight"); t.expect_eq(run.status, "working"); t.expect_eq(run.next, 1180); t.expect_eq(run.task, 1)
	t.expect_same(ops(acts), { "requests", "balance_ammo" }, "no travel to the work: the fight starts at the station")
	run = minion_run()
	loaded(run)
	t.expect_eq(run.state, "follow"); t.expect_eq(run.status, "following"); t.expect_eq(run.next, 1180)
end)

t.test("roboports: radius 0 from the start, through leave_work and returning, full again at unloading (R-205)", function()
	local run = squad_run(1)
	t.expect_same(rc.start(run, facts(), CFG), { { "roboports", 0 },
		{ "travel", { inst = 1, x = -20, y = 0 }, { kind = "station", radius = 10 } } })
	rc.step(run, facts(), CFG, { type = "arrived" })
	rc.step(run, facts({ tick = 1120, fulfilled = true }), CFG)
	run.tasks = { run.tasks[run.task] }
	run.task = 1
	local acts = rc.step(run, facts({ tick = 1320, combat = lview({ tick = 1320, pos = run.tasks[1] }) }), CFG)
	t.expect_eq(run.state, "returning"); t.expect_eq(op(acts, "roboports"), nil, "leave_work keeps them at 0")
	t.expect_true(op(acts, "rescan"))
	acts = rc.step(run, facts({ tick = 1500 }), CFG, { type = "arrived" })
	t.expect_same(acts, { { "roboports", "full" }, { "requests", "unload" } })
	acts = rc.step(run, facts({ tick = 1620, unloaded = true }), CFG)
	t.expect_eq(op(acts, "roboports"), nil); t.expect_eq(run.state, "ended")
	run = minion_run()
	t.expect_same(op(rc.start(run, facts(), CFG), "roboports"), { "roboports", 0 })
end)

t.test("fight: a pop takes the next task and stays in fight; the last pop leaves work", function()
	local run = squad_run(1)
	fighting(run)
	local acts = rc.step(run, facts({ tick = 1260, pos = { x = 9.5, y = 9.5 }, combat = lview({ tick = 1260 }) }), CFG)
	t.expect_eq(run.state, "fight"); t.expect_eq(run.done_tasks, 1); t.expect_eq(#run.tasks, 8)
	t.expect_eq(run.task, rc.pick(run, { x = 9.5, y = 9.5 }, 1)); t.expect_eq(run.next, 1320)
	t.expect_same(acts, {}, "already at radius 0")
	run.tasks = { run.tasks[run.task] }
	run.task = 1
	acts = rc.step(run, facts({ tick = 1320, combat = lview({ tick = 1320, pos = run.tasks[1] }) }), CFG)
	t.expect_eq(run.state, "returning"); t.expect_eq(op(acts, "roboports"), nil)
	t.expect_true(op(acts, "rescan"))
end)

t.test("fight: away from the task, travel there at radius 3; the travel is to the work's instance (D2)", function()
	local run = squad_run(1)
	fighting(run)
	local acts = rc.step(run, facts({ tick = 1260, combat = lview({ tick = 1260, pos = { x = 0, y = 0 } }) }), CFG)
	t.expect_same(acts, { { "travel", { inst = 1, x = 9.5, y = 9.5 }, { kind = "work", radius = 3 } } })
	t.expect_eq(run.state, "fight"); t.expect_eq(run.status, "moving")
	run = squad_run(1)
	fighting(run)
	acts = rc.step(run, facts({ tick = 1260, here = 2, combat = lview({ tick = 1260, here = 2, pos = { x = 0, y = 0 } }) }), CFG)
	t.expect_same(acts, { { "travel", { inst = 1, x = 9.5, y = 9.5 }, { kind = "work", radius = 3 } } },
		"from another tile it is route travel to the work's instance")
end)

t.test("fight: low health repairs in place; no packs sends the leader to restock", function()
	local run = squad_run(1)
	fighting(run)
	local acts = rc.step(run, facts({ tick = 1260, health = 0.5, combat = lview({ tick = 1260, health = 0.5 }) }), CFG)
	t.expect_true(run.combat.repairing); t.expect_eq(run.state, "fight")
	t.expect_same(acts, { { "roboports", "full" } }); t.expect_eq(run.status, "repairing")
	acts = rc.step(run, facts({ tick = 1320, health = 0.5, combat = lview({ tick = 1320, health = 0.5, packs = false }) }), CFG)
	t.expect_eq(run.state, "to_station"); t.expect_same(op(acts, "roboports"), { "roboports", 0 }, "back to radius 0 (R-205)")
end)

t.test("fight: no robots or low ammo sends the leader to restock", function()
	local run = squad_run(1)
	fighting(run)
	rc.step(run, facts({ tick = 1260, robots = 0 }), CFG)
	t.expect_eq(run.state, "to_station"); t.expect_eq(run.status, "missing_robots")
	run = squad_run(1)
	fighting(run)
	rc.step(run, facts({ tick = 1260 }), { ammo_count = 100 })
	t.expect_eq(run.state, "to_station")
end)

t.test("fight: a failed walk to a task defers it and re-picks, as to_work does", function()
	local run = squad_run(1)
	fighting(run)
	rc.step(run, facts({ tick = 1260, pos = { x = 9.5, y = 9.5 } }), CFG, { type = "failed", reason = "no_path" })
	t.expect_true(run.tasks[1].again); t.expect_eq(run.state, "fight"); t.expect_eq(run.next, 1320); t.expect_eq(run.task, 2)
end)

t.test("fight: the leader holds for a minion that is not attached, at any tick (D3)", function()
	local run = squad_run(1)
	fighting(run)
	local absent = { { here = false } }
	local acts = rc.step(run, facts({ tick = 1260, combat = lview({ tick = 1260, members = absent }) }), CFG)
	t.expect_eq(run.status, "minion_proximity"); t.expect_eq(run.done_tasks, 0); t.expect_same(acts, { { "stop" } })
	rc.step(run, facts({ tick = 9000, combat = lview({ tick = 9000, members = absent }) }), CFG)
	t.expect_eq(run.status, "minion_proximity", "no time limit"); t.expect_eq(run.done_tasks, 0)
	acts = rc.step(run, facts({ tick = 9060, combat = lview({ tick = 9060, pos = { x = 0, y = 0 },
		members = { { here = true, dist = 10, follow = true } } }) }), CFG)
	t.expect_eq(run.status, "moving"); t.expect_eq(ops(acts)[1], "travel", "attached: the advance resumes")
end)

t.test("fight: the first step at the station records no safe position; a restock keeps combat.safe (D4)", function()
	local run = squad_run(1)
	fighting(run)
	local at = facts({ tick = 1180, pos = AT_STATION })
	at.combat = lview({ tick = 1180, pos = AT_STATION })
	rc.step(run, at, CFG)
	t.expect_same(run.combat.safe, {}, "the trail starts 16 tiles out")
	rc.step(run, facts({ tick = 1240, pos = { x = -3, y = 0 }, combat = lview({ tick = 1240, pos = { x = -3, y = 0 } }) }), CFG)
	t.expect_same(run.combat.safe, { { x = -3, y = 0, inst = 1 } })
	local cfg = { ammo_count = 100, ammo = { "rocket", "normal" } }
	rc.step(run, facts({ tick = 1300, pos = { x = -3, y = 0 }, ammo_slots = 0, ammo_trunk = 0 }), cfg)
	t.expect_eq(run.state, "to_station")
	rc.step(run, facts({ tick = 1400, pos = AT_STATION }), cfg, { type = "arrived" })
	t.expect_eq(run.state, "loading")
	rc.step(run, facts({ tick = 1520, pos = AT_STATION, fulfilled = true }), cfg)
	t.expect_eq(run.state, "fight")
	t.expect_same(run.combat.safe, { { x = -3, y = 0, inst = 1 } }, "to_station -> loading -> fight keeps the trail")
end)

t.test("fight: a retreat place on another tile is route travel; on this tile a direct move (D5)", function()
	local run = squad_run(1)
	fighting(run)
	run.combat.safe = { { x = -100, y = 0, inst = 2 } }
	local acts = rc.step(run, facts({ tick = 1260, combat = lview({ tick = 1260, enemies = DEMOLISHER }) }), CFG)
	t.expect_same(acts, { { "travel", { inst = 2, x = -100, y = 0 }, { kind = "work", radius = 3 } } })
	t.expect_eq(run.status, "safe_position")
	run = squad_run(1)
	fighting(run)
	run.combat.safe = { { x = -100, y = 0, inst = 1 } }
	acts = rc.step(run, facts({ tick = 1260, combat = lview({ tick = 1260, enemies = DEMOLISHER }) }), CFG)
	t.expect_same(acts, { { "move", -100, 0 } })
end)

t.test("repick: in fight, the nearest task from where the ctron stands, with no travel; none leaves work (review finding 5)", function()
	local run = squad_run(1)
	fighting(run)
	local acts = rc.step(run, facts({ tick = 1200, pos = { x = 31, y = 31 } }), CFG, { type = "repick" })
	t.expect_eq(run.task, 9); t.expect_eq(run.state, "fight")
	t.expect_same(acts, {}, "the next fight poll holds, retreats or goes to the task")
	run.tasks = {}
	acts = rc.step(run, facts({ tick = 1260 }), CFG, { type = "repick" })
	t.expect_eq(run.state, "returning"); t.expect_true(op(acts, "rescan"))
end)

t.test("fight: a failed retreat travel drops the safe place it routed to, not the task (review finding 6)", function()
	local run = squad_run(1)
	fighting(run)
	run.combat.safe = { { x = -50, y = 0, inst = 2 }, { x = -100, y = 0, inst = 2 } }
	rc.step(run, facts({ tick = 1260, combat = lview({ tick = 1260, enemies = DEMOLISHER }) }), CFG)
	t.expect_eq(run.leg, "retreat")
	rc.step(run, facts({ tick = 1320 }), CFG, { type = "failed", reason = "budget" })
	t.expect_same(run.combat.safe, { { x = -50, y = 0, inst = 2 } }); t.expect_eq(run.next, 1380)
	t.expect_eq(run.tasks[1].again, nil, "the task keeps its chance"); t.expect_eq(run.task, 1); t.expect_eq(run.state, "fight")
end)

t.test("fight: a failed task walk defers it; a leader that dropped one task and popped another ends done (findings 4, 6)", function()
	local run = squad_run(1)
	fighting(run)
	run.tasks = { { x = 9.5, y = 9.5, again = true }, { x = 20, y = 9.5 } }
	run.task = 1
	local acts = rc.step(run, facts({ tick = 1260, pos = { x = 0, y = 0 }, combat = lview({ tick = 1260, pos = { x = 0, y = 0 } }) }), CFG)
	t.expect_eq(run.leg, "task"); t.expect_eq(ops(acts)[1], "travel")
	rc.step(run, facts({ tick = 1320, pos = { x = 0, y = 0 } }), CFG, { type = "failed", reason = "no_path" })
	t.expect_eq(#run.tasks, 1, "the second failure drops it"); t.expect_eq(run.fail_why, "no_path"); t.expect_eq(run.reached, 0)
	rc.step(run, facts({ tick = 1380, pos = { x = 20, y = 9.5 }, combat = lview({ tick = 1380, pos = { x = 20, y = 9.5 } }) }), CFG)
	t.expect_eq(run.reached, 1, "a popped task counts"); t.expect_eq(run.state, "returning")
	rc.step(run, facts({ tick = 1500 }), CFG, { type = "arrived" })
	acts = rc.step(run, facts({ tick = 1620, unloaded = true }), CFG)
	t.expect_eq(op(acts, "emit")[2], "done")
end)

t.test("follow: follows a near leader and walks to a far one", function()
	local run = minion_run()
	following(run)
	local acts = rc.step(run, facts({ tick = 1260, leader = LEADER, combat = mview() }), CFG)
	t.expect_same(acts, { { "follow" } }); t.expect_eq(run.next, 1320)
	local far = { state = "fight", pos = { x = 50, y = 0 }, dist = 50 }
	acts = rc.step(run, facts({ tick = 1320, leader = far, combat = mview({ leader_pos = far.pos }) }), CFG)
	t.expect_same(acts, { { "travel", { inst = 1, x = 50, y = 0 }, { kind = "follow", radius = 10 } } })
end)

t.test("follow: a leader on another tile gets a route travel to its relayed place; no timeout (R-199)", function()
	local run = minion_run()
	following(run)
	run.squad.lead = { inst = 2, x = 50, y = 7 }
	local remote = mview({ leader_pos = false, lead = run.squad.lead })
	local acts = rc.step(run, facts({ tick = 1260, combat = remote }), CFG)
	t.expect_same(acts, { { "travel", { inst = 2, x = 50, y = 7 }, { kind = "follow", radius = 10 } } })
	rc.step(run, facts({ tick = 90000, combat = mview({ leader_pos = false, lead = run.squad.lead, moving = true }) }), CFG)
	t.expect_eq(run.state, "follow", "the old 1800-tick give-up is gone")
end)

t.test("follow: returns when the leader returns", function()
	local run = minion_run()
	following(run)
	local acts = rc.step(run, facts({ tick = 1260, leader = { state = "returning", pos = { x = 1, y = 0 }, dist = 1 } }), CFG)
	t.expect_eq(acts[1][1], "stop"); t.expect_eq(run.state, "returning")
end)

t.test("follow: low ammo or a failed repair restocks at the own station and rejoins (R-204)", function()
	local run = minion_run()
	following(run)
	local acts = rc.step(run, facts({ tick = 1260, leader = LEADER, combat = mview() }), { ammo_count = 100 })
	t.expect_eq(run.state, "to_station")
	t.expect_same(ops(acts), { "stop", "leave_squad", "travel" })
	t.expect_same(op(acts, "travel")[2], { inst = 1, x = -20, y = 0 })
	rc.step(run, facts({ tick = 1500 }), CFG, { type = "arrived" })
	t.expect_eq(run.state, "loading")
	rc.step(run, facts({ tick = 1620, fulfilled = true }), CFG)
	t.expect_eq(run.state, "follow", "after loading it follows again")
	run = minion_run()
	following(run)
	acts = rc.step(run, facts({ tick = 1260, health = 0.5, leader = LEADER, combat = mview({ health = 0.5, packs = false }) }), CFG)
	t.expect_eq(run.state, "to_station"); t.expect_eq(ops(acts)[2], "leave_squad")
end)

t.test("leader_lost sends a minion home, in loading too; leave_squad drops a lost minion", function()
	local run = minion_run()
	following(run)
	local acts = rc.step(run, facts({ tick = 1300 }), CFG, { type = "leader_lost" })
	t.expect_eq(acts[1][1], "stop"); t.expect_eq(run.state, "returning")
	t.expect_same(rc.step(run, facts({ tick = 1310 }), CFG, { type = "leader_lost" }), {}, "already returning")
	run = minion_run()
	rc.start(run, facts(), CFG); rc.step(run, facts(), CFG, { type = "arrived" })
	t.expect_eq(run.state, "loading")
	rc.step(run, facts({ tick = 1050 }), CFG, { type = "leader_lost" })
	t.expect_eq(run.state, "returning")
	local leader = squad_run(1)
	rc.leave_squad(leader, "1.11")
	t.expect_same(leader.squad.members, {})
end)

t.test("follow: a failed walk to the leader waits for the next poll", function()
	local run = minion_run()
	following(run)
	local acts = rc.step(run, facts({ tick = 1230 }), CFG, { type = "failed", reason = "no_path" })
	t.expect_same(acts, {}); t.expect_eq(run.next, 1290); t.expect_eq(run.state, "follow")
end)
