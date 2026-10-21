local t = require("testlib")
local view = require("modules/ctron_pluginv2/gui/view_core")

t.test("chip: CC's caption key and colour per kind; nil without a kind", function()
	local c = view.chip("deconstruction")
	t.expect_same(c.caption, { "ctron_gui_locale.job_card_deconstruction_name" })
	t.expect_eq(c.color.r, 1)
	t.expect_eq(view.chip(nil), nil)
	t.expect_eq(view.chip("minion"), nil)
end)

t.test("status: severity sprite and key; working names the kind; cargo says working", function()
	local s = view.status("no_path")
	t.expect_eq(s.sev, "problem")
	t.expect_eq(s.sprite, "utility/status_not_working")
	t.expect_same(s.caption, { "ctron_status.no_path_found" })
	t.expect_same(view.status("working", "upgrade").caption, { "ctron_status.job_type_upgrade" })
	t.expect_same(view.status("working", "cargo").caption, { "ctron_status.job_type_working" })
end)

t.test("status: a string or number arg rides as parameter 1; a table arg is dropped", function()
	t.expect_same(view.status("no_path", nil, "tile-2").caption, { "ctron_status.no_path_found", "tile-2" })
	t.expect_same(view.status("no_path", nil, { 1 }).caption, { "ctron_status.no_path_found" })
end)

t.test("status: an unknown code shows the raw code with the wait icon (Review Focus 4)", function()
	local s = view.status("bogus_code")
	t.expect_eq(s.caption, "bogus_code")
	t.expect_eq(s.sprite, "utility/status_yellow")
	t.expect_eq(view.status(nil).caption, "?")
end)

t.test("local rows and tile captions", function()
	t.expect_eq(view.is_local({ at = 7 }, 7), true)
	t.expect_eq(view.is_local({ owner = 7 }, 7), true)
	t.expect_eq(view.is_local({ at = 8, atName = "tile-1-0" }, 7), false)
	t.expect_same(view.tile({ at = 7 }, 7), { "ctronv2.this_tile" })
	t.expect_eq(view.tile({ owner = 8, ownerName = "tile-1-0" }, 7), "tile-1-0")
	t.expect_eq(view.unit("7.417"), "#417")
end)

t.test("age in whole minutes, never negative; due in whole seconds", function()
	t.expect_same(view.age(0, 185000), { "ctronv2.age_min", 3 })
	t.expect_same(view.age(5000, 1000), { "ctronv2.age_min", 0 })
	t.expect_eq(view.age(nil, 1000), nil)
	t.expect_same(view.due(10500, 1000), { "ctronv2.due_tooltip", 9 })
	t.expect_eq(view.due(nil, 1000), nil)
end)

t.test("items text and slots from [name, quality, count] tuples; {} is empty", function()
	t.expect_eq(view.items_text({ { "pipe", "normal", 12 }, { "iron-gear-wheel", "rare", 40 } }),
		"[item=pipe,quality=normal] 12  [item=iron-gear-wheel,quality=rare] 40")
	t.expect_eq(view.items_text({}), "")
	t.expect_same(view.slots({ { "pipe", "normal", 12 } }),
		{ { sprite = "item/pipe", quality = "normal", number = 12, name = "pipe", q = "normal" } })
	t.expect_same(view.slots(nil), {})
end)

t.test("detail: nil greys the window out (Review Focus 5)", function()
	t.expect_same(view.detail(nil, 1), { gone = true })
end)

t.test("detail: member 1 by default; requests show want - have, nil when met", function()
	local d = {
		job = { kind = "construction", state = "loading", status = "requesting", tasks = { 2, 7 } },
		station = { sid = "7.5", inst = 7, x = 1, y = 2 },
		members = {
			{ cid = "7.417", x = 10, y = 20, trunk = { { "pipe", "normal", 100 } }, ammo = {}, trash = {},
				requests = { { "pipe", "normal", 200, 100 }, { "rocket", "normal", 10, 10 } } },
			{ cid = "7.418", x = 11, y = 21, trunk = {}, ammo = {}, trash = {}, requests = {} },
		},
		tasks = { { 412, -88 } },
	}
	local vm = view.detail(d, nil)
	t.expect_eq(vm.cid, "7.417")
	t.expect_same(vm.members, { "#417", "#418" })
	t.expect_same(vm.chip.caption, { "ctron_gui_locale.job_card_construction_name" })
	t.expect_same(vm.status.caption, { "ctron_status.requesting_items" })
	t.expect_same(vm.tasks, { "ctron_gui_locale.job_job_stat_tasks_label", "2/7" })
	t.expect_eq(vm.requests[1].number, 100)
	t.expect_eq(vm.requests[2].number, nil)
	t.expect_eq(vm.requests[1].name, "pipe")
	t.expect_same(vm.trunk, { { sprite = "item/pipe", quality = "normal", number = 100, name = "pipe", q = "normal" } })
	t.expect_same(vm.pos, { x = 10, y = 20 })
	t.expect_same(vm.task, { x = 412, y = -88 })
	t.expect_eq(view.detail(d, 2).cid, "7.418")
	t.expect_eq(view.detail(d, 9).cid, "7.417")
end)

t.test("detail: ammo shows slot by slot; trunk and trash totals split into stacks (owner: rockets stack to 100)", function()
	local d = { members = { { cid = "7.417", x = 0, y = 0, requests = {},
		ammo = { { "rocket", "normal", 100 }, { "rocket", "normal", 100 }, { "rocket", "normal", 50 } },
		trunk = { { "rocket", "normal", 250 }, { "pipe", "rare", 100 } }, trash = { { "stone", "normal", 1 } } } } }
	local stacks = { rocket = 100, pipe = 100, stone = 50 }
	local vm = view.detail(d, 1, stacks)
	local function numbers(slots)
		local out = {}
		for i, s in ipairs(slots) do
			out[i] = s.name .. ":" .. s.q .. ":" .. s.number
		end
		return out
	end
	t.expect_same(numbers(vm.ammo), { "rocket:normal:100", "rocket:normal:100", "rocket:normal:50" })
	t.expect_same(numbers(vm.trunk), { "rocket:normal:100", "rocket:normal:100", "rocket:normal:50", "pipe:rare:100" })
	t.expect_same(numbers(vm.trash), { "stone:normal:1" })
	t.expect_same(numbers(view.detail(d, 1).trunk), { "rocket:normal:250", "pipe:rare:100" }) -- no stacks: one per total
end)

t.test("detail: no job row and no members still renders", function()
	local vm = view.detail({ members = {}, tasks = {} }, 1)
	t.expect_eq(vm.gone, nil)
	t.expect_eq(vm.chip, nil)
	t.expect_eq(vm.cid, nil)
	t.expect_same(vm.requests, {})
end)

t.test("clamp: CC's caps, whole numbers, bad text is nil", function()
	t.expect_eq(view.clamp("robot_count", "20000"), 10000)
	t.expect_eq(view.clamp("robot_count", "-5"), 0)
	t.expect_eq(view.clamp("ammo_count", "12.7"), 12)
	t.expect_eq(view.clamp("atomic_count", "5000"), 1000)
	t.expect_eq(view.clamp("min_cluster", "0"), 1)
	t.expect_eq(view.clamp("minions", "101"), 100)
	t.expect_eq(view.clamp("robot_count", ""), nil)
	t.expect_eq(view.clamp("robot_count", "abc"), nil)
	t.expect_eq(view.clamp("robot_count", "1e999"), nil)
	t.expect_eq(view.clamp("horde", "1"), nil)
end)

t.test("clamp: the start delay is seconds in, ticks out, decimals kept", function()
	t.expect_eq(view.clamp("job_start_delay", "5"), 300)
	t.expect_eq(view.clamp("job_start_delay", "2.5"), 150)
	t.expect_eq(view.clamp("job_start_delay", "-1"), 0)
	t.expect_eq(view.delay_text(300), "5")
	t.expect_eq(view.delay_text(150), "2.5")
end)

t.test("settings table: every §4.6 surface key once; nested kinds patch; apply-all copies them", function()
	local seen = {}
	for _, f in ipairs(view.TOGGLES) do seen[f.path] = (seen[f.path] or 0) + 1 end
	for _, f in ipairs(view.VALUES) do seen[f.path] = (seen[f.path] or 0) + 1 end
	for _, k in ipairs({ "kinds.construction", "kinds.rebuild", "kinds.deconstruction", "kinds.upgrade",
		"kinds.repair", "kinds.destroy", "horde", "zone_restriction", "robot", "robot_count", "repair_tool", "ammo",
		"ammo_count", "atomic", "atomic_count", "min_cluster", "minions" }) do
		t.expect_eq(seen[k], 1, k)
	end
	t.expect_same(view.patch("kinds.destroy", true), { kinds = { destroy = true } })
	t.expect_same(view.patch("robot_count", 60), { robot_count = 60 })
	local eff = {
		job_start_delay = 300, debug = false, horde = false, zone_restriction = true,
		kinds = { construction = true, rebuild = true, deconstruction = false, upgrade = true, repair = true, destroy = false },
		robot = { "construction-robot", "normal" }, robot_count = 50, repair_tool = { "repair-pack", "normal" },
		ammo = { "rocket", "normal" }, ammo_count = 0, atomic_count = 0, min_cluster = 8, minions = 1,
	}
	t.expect_eq(view.get(eff, "kinds.deconstruction"), false)
	t.expect_same(view.get(eff, "robot"), { "construction-robot", "normal" })
	local all = view.all_patch(eff)
	t.expect_same(all.kinds, eff.kinds)
	t.expect_eq(all.zone_restriction, true)
	t.expect_eq(all.atomic, nil)
	t.expect_eq(all.job_start_delay, nil)
	t.expect_eq(all.debug, nil)
	all.robot[1] = "x"
	t.expect_eq(eff.robot[1], "construction-robot")
end)

t.test("cargo: a duplicate pick warns; set needs min < max; remove keeps the rest", function()
	local slots = { { "iron-gear-wheel", "normal", 100, 500 } }
	local item, warn = view.cargo_pick(slots, "iron-gear-wheel", "normal")
	t.expect_eq(item, nil)
	t.expect_eq(warn, "ctron_warnings.item_already_requested")
	t.expect_same(view.cargo_pick(slots, "iron-gear-wheel", "rare"), { "iron-gear-wheel", "rare" })
	local _, w2 = view.cargo_set(slots, { "pipe", "normal" }, "200", "200")
	t.expect_eq(w2, "ctron_warnings.min_value")
	local _, w3 = view.cargo_set(slots, { "pipe", "normal" }, "", "")
	t.expect_eq(w3, "ctron_warnings.min_value")
	local added = view.cargo_set(slots, { "pipe", "normal" }, "", "200")
	t.expect_same(added, { { "iron-gear-wheel", "normal", 100, 500 }, { "pipe", "normal", 0, 200 } })
	local edited = view.cargo_set(added, { "iron-gear-wheel", "normal" }, "10", "20")
	t.expect_same(edited[1], { "iron-gear-wheel", "normal", 10, 20 })
	t.expect_eq(#edited, 2)
	t.expect_same(slots[1], { "iron-gear-wheel", "normal", 100, 500 })
	t.expect_same(view.cargo_remove(edited, "iron-gear-wheel", "normal"), { { "pipe", "normal", 0, 200 } })
end)

t.test("request buttons: number = max, count in the tooltip when known, selected is yellow", function()
	local b = view.request_buttons({ { "pipe", "normal", 100, 500, 42 }, { "rail", "rare", 1, 2 } }, { "rail", "rare" })
	t.expect_eq(b[1].number, 500)
	t.expect_eq(b[1].style, "slot_button")
	t.expect_eq(b[2].style, "yellow_slot_button")
	t.expect_eq(b[1].sprite, "item/pipe")
	t.expect_eq(b[2].quality, "rare")
	t.expect_same(b[1].tooltip, { "", { "ctronv2.cargo_below" }, " 100 · ", { "ctronv2.cargo_bring" }, " 500 · 42" })
	t.expect_same(b[2].tooltip, { "", { "ctronv2.cargo_below" }, " 1 · ", { "ctronv2.cargo_bring" }, " 2" })
end)

t.test("watch keys and viewer counting: first viewer sends on, last sends off (Review Focus 3)", function()
	t.expect_eq(view.wkey({ surface = "nauvis" }), "nauvis||")
	t.expect_eq(view.wkey({ surface = "nauvis", tile = 7, expand = "7|construction" }), "nauvis|7|7|construction")
	local ws = {}
	local first, k = view.acquire(ws, { surface = "nauvis" }, 1)
	t.expect_eq(first, true)
	t.expect_eq(k, "nauvis||")
	t.expect_eq((view.acquire(ws, { surface = "nauvis" }, 1)), false)
	t.expect_eq((view.acquire(ws, { surface = "nauvis" }, 2)), false)
	t.expect_eq(ws[k].n, 2)
	local first2, k2 = view.acquire(ws, { surface = "nauvis", tile = 8 }, 3)
	t.expect_eq(first2, true)
	t.expect_eq(k2, "nauvis|8|")
	t.expect_eq(view.release(ws, k, 1), nil)
	t.expect_eq(view.release(ws, k, 1), nil)
	local gone = view.release(ws, k, 2)
	t.expect_eq(gone.surface, "nauvis")
	t.expect_eq(ws[k], nil)
	t.expect_eq(ws[k2].n, 1)
	t.expect_eq(view.release(ws, "nope", 1), nil)
end)

local function part(seq, p, parts, full, up, rm)
	return { watch = { surface = "nauvis" }, seq = seq, part = p, parts = parts, full = full, up = up or {}, rm = rm or {},
		stats = { total = p } }
end

t.test("apply: a full list in two parts is partial, then done; a full part 1 replaces (Review Focus 1)", function()
	local m, v = view.apply({ rows = { ["j:old"] = {} }, seq = 3, part = 1, ready = true },
		part(9, 1, 2, true, { { key = "j:1" } }))
	t.expect_eq(v, "partial")
	t.expect_eq(m.ready, false)
	t.expect_eq(m.rows["j:old"], nil)
	t.expect_eq(m.rows["j:1"].key, "j:1")
	m, v = view.apply(m, part(9, 2, 2, true, { { key = "j:2" } }))
	t.expect_eq(v, "done")
	t.expect_eq(m.ready, true)
	t.expect_eq(m.stats.total, 2)
	m, v = view.apply(m, part(10, 1, 1, false, { { key = "j:2", status = "x" } }, { "j:1" }))
	t.expect_eq(v, "done")
	t.expect_eq(m.rows["j:1"], nil)
	t.expect_eq(m.rows["j:2"].status, "x")
	t.expect_eq(m.seq, 10)
end)

t.test("apply: gaps re-watch; nothing before the first full list", function()
	local m = view.apply(nil, part(1, 1, 1, true, { { key = "j:1" } }))
	local same, v = view.apply(m, part(3, 1, 1, false, { { key = "j:9" } }))
	t.expect_eq(v, "gap")
	t.expect_eq(same.rows["j:9"], nil)
	local _, v2 = view.apply(m, part(1, 3, 3, false))
	t.expect_eq(v2, "gap")
	local _, v3 = view.apply(m, part(2, 2, 2, false))
	t.expect_eq(v3, "gap")
	local none, v4 = view.apply(nil, part(5, 1, 1, false))
	t.expect_eq(none, nil)
	t.expect_eq(v4, "skip")
end)

t.test("apply: a new seq while the last push is incomplete is a gap", function()
	local m = view.apply(nil, part(1, 1, 2, true, { { key = "j:1" } }))
	local _, v = view.apply(m, part(2, 1, 1, false, { { key = "j:2" } }))
	t.expect_eq(v, "gap")
end)

local function mirror()
	local rows = {
		["j:1"] = { key = "j:1", sec = "progress", ord = 2, kind = "construction", at = 7, atName = "t7",
			worker = "7.417", n = 3, state = "to_work", status = "moving", tasks = { 0, 3 } },
		["j:2"] = { key = "j:2", sec = "progress", ord = 1, kind = "deconstruction", at = 8, atName = "tile-8",
			worker = "8.5", n = 1, state = "loading", status = "requesting", tasks = { 0, 1 },
			missing = { { "pipe", "normal", 12 } } },
		["j:3"] = { key = "j:3", sec = "attention", ord = 1, kind = "construction", at = 8, atName = "tile-8",
			worker = "8.6", n = 1, state = "to_work", status = "no_path", tasks = { 0, 1 } },
		["w:8|nauvis|repair|3"] = { key = "w:8|nauvis|repair|3", sec = "attention", ord = 2, kind = "repair", owner = 8,
			ownerName = "tile-8", st = "backoff", rem = 1, committed = 0, firstSeenMs = 0, tool = false },
		["j:4"] = { key = "j:4", sec = "finishing", ord = 1, kind = "upgrade", at = 7, atName = "t7",
			worker = "7.418", n = 1, state = "returning", status = "moving", tasks = { 1, 1 } },
		["g:7|construction"] = { key = "g:7|construction", sec = "pending", ord = 1, kind = "construction", owner = 7,
			ownerName = "t7", n = 4, oldestMs = 0, why = "no_ctron" },
		["g:8|upgrade"] = { key = "g:8|upgrade", sec = "pending", ord = 2, kind = "upgrade", owner = 8,
			ownerName = "tile-8", n = 1, oldestMs = 60000, st = "delay" },
		["w:7|nauvis|construction|12"] = { key = "w:7|nauvis|construction|12", sec = "cells", ord = 1,
			kind = "construction", owner = 7, ownerName = "t7", c = { 412.5, -88 }, st = "delay", rem = 3, committed = 0,
			firstSeenMs = 0, dueAtMs = 190000, tool = false },
		["c:7.417"] = { key = "c:7.417", sec = "ctrons", ord = 1, at = 7, atName = "t7", name = "constructron",
			label = "Bob", state = "busy", jid = "1", kind = "construction", status = "moving" },
		["c:8.9"] = { key = "c:8.9", sec = "ctrons", ord = 2, at = 8, atName = "tile-8", name = "constructron",
			state = "idle", x = 1, y = 2 },
		["s:7.5"] = { key = "s:7.5", sec = "stations", ord = 1, at = 7, atName = "t7", name = "Mall", x = 5, y = 6 },
		["n:7.5"] = { key = "n:7.5", sec = "stations", ord = 1, sid = "7.5", slots = { { "pipe", "normal", 100, 500, 42, 100 } },
			order = { { "pipe", "normal", 458 } }, why = "no_supplier" },
		["w:8|nauvis|upgrade|4"] = { key = "w:8|nauvis|upgrade|4", sec = "attention", ord = 3, kind = "upgrade", owner = 8,
			ownerName = "tile-8", c = { 1, 2 }, st = "backoff", why = "no_progress", rem = 1, committed = 0,
			firstSeenMs = 0, tool = false },
	}
	return { seq = 1, part = 1, ready = true, rows = rows, stats = { total = 18, available = 17, surfaces = { "nauvis" },
		tiles = { { 7, "t7" }, { 8, "tile-8" } }, more = { progress = 3 }, waiting = { { "pipe", "normal", 12 } },
		now = 180000 } }
end

local function keys(section)
	local out = {}
	for i, r in ipairs(section.rows) do
		out[i] = r.key
	end
	return out
end

t.test("screen: sections in order, rows by ord, more counts in titles", function()
	local s = view.screen(mirror(), { here = 7, expand = "7|construction", link_up = true })
	t.expect_eq(#s.jobs, 4)
	t.expect_eq(s.jobs[1].sec, "attention")
	t.expect_same(keys(s.jobs[1]), { "j:3", "w:8|nauvis|repair|3", "w:8|nauvis|upgrade|4" })
	t.expect_same(keys(s.jobs[2]), { "j:2", "j:1" })
	t.expect_eq(s.jobs[2].more, 3)
	t.expect_same(s.jobs[2].title, { "", { "ctron_gui_locale.inprogress_section_name" }, " (5)" })
	t.expect_same(keys(s.jobs[3]), { "j:4" })
	t.expect_same(keys(s.jobs[4]), { "g:7|construction", "w:7|nauvis|construction|12", "g:8|upgrade" })
	t.expect_same(keys(s.ctrons), { "c:7.417", "c:8.9" })
	t.expect_same(keys(s.stations), { "s:7.5" })
	t.expect_same(s.badges, { jobs = "9", ctrons = "17/18", stations = "1" })
	t.expect_same(s.summary, { "ctronv2.summary", 17, 18, 2 })
	t.expect_same(s.waiting, { { sprite = "item/pipe", quality = "normal", number = 12, name = "pipe", q = "normal" } })
	t.expect_same(s.tiles, { { 7, "t7" }, { 8, "tile-8" } })
end)

t.test("screen: job rows, local and remote", function()
	local s = view.screen(mirror(), { here = 7, link_up = true })
	local local_job = s.jobs[2].rows[2].vm
	t.expect_eq(local_job.type, "job")
	t.expect_eq(local_job.id, "1")
	t.expect_eq(local_job.kind, "construction")
	t.expect_eq(local_job.locate, true)
	t.expect_eq(local_job.cancel, true)
	t.expect_eq(local_job.who, "Bob +2")
	t.expect_same(local_job.tile, { "ctronv2.this_tile" })
	t.expect_eq(local_job.remote_tip, nil)
	local remote_job = s.jobs[2].rows[1].vm
	t.expect_eq(remote_job.locate, false)
	t.expect_same(remote_job.remote_tip, { "ctronv2.remote_tooltip", "tile-8" })
	t.expect_eq(remote_job.tip, "[item=pipe,quality=normal] 12")
	t.expect_eq(remote_job.who, "#5")
	t.expect_eq(remote_job.tile, "tile-8")
	t.expect_eq(s.jobs[3].rows[1].vm.finishing, true)
	t.expect_eq(remote_job.finishing, false)
	local down = view.screen(mirror(), { here = 7, link_up = false })
	t.expect_eq(down.jobs[2].rows[1].vm.cancel, false)
end)

t.test("screen: pending groups, the expanded group's cells, cells without their group go last", function()
	local s = view.screen(mirror(), { here = 7, expand = "7|construction", link_up = true })
	local g = s.jobs[4].rows[1].vm
	t.expect_eq(g.type, "group")
	t.expect_eq(g.id, "7|construction")
	t.expect_eq(g.open, true)
	t.expect_same(g.count, { "ctronv2.group_count", 4 })
	t.expect_same(g.age, { "ctronv2.age_min", 3 })
	t.expect_same(g.status, { "ctron_gui_locale.job_status" })
	local cell = s.jobs[4].rows[2].vm
	t.expect_eq(cell.type, "cell")
	t.expect_eq(cell.id, "7|nauvis|construction|12")
	t.expect_eq(cell.who, "(412, -88)")
	t.expect_same(cell.pos, { x = 412.5, y = -88 })
	t.expect_same(cell.tip, { "ctronv2.due_tooltip", 10 })
	t.expect_same(cell.status, { "ctronv2.wait_delay" })
	t.expect_eq(s.jobs[4].rows[3].vm.open, false)
	t.expect_same(s.jobs[4].rows[3].vm.status, { "ctronv2.wait_delay" })
	t.expect_same(s.jobs[4].title, { "", { "ctron_gui_locale.pending_section_name" }, " (5)" })
	local backed = s.jobs[1].rows[2].vm
	t.expect_eq(backed.type, "cell")
	t.expect_same(backed.status, { "ctronv2.backoff" })
	t.expect_eq(backed.who, "")
	t.expect_eq(backed.pos, nil)
	t.expect_eq(backed.locate, false)
	t.expect_same(backed.chip.caption, { "ctron_gui_locale.job_card_repair_name" })
	t.expect_same(s.jobs[1].rows[3].vm.status, { "ctronv2.no_progress" })
	local other = view.screen(mirror(), { here = 7, expand = "9|repair", link_up = true })
	t.expect_same(keys(other.jobs[4]), { "g:7|construction", "g:8|upgrade", "w:7|nauvis|construction|12" })
end)

t.test("screen: ctron and station rows", function()
	local s = view.screen(mirror(), { here = 7, link_up = true })
	local busy, idle = s.ctrons.rows[1].vm, s.ctrons.rows[2].vm
	t.expect_eq(busy.type, "ctron")
	t.expect_eq(busy.who, "Bob")
	t.expect_eq(busy.jid, "1")
	t.expect_eq(busy.details, true)
	t.expect_eq(busy.remote, true)
	t.expect_same(busy.chip.caption, { "ctron_gui_locale.job_card_construction_name" })
	t.expect_same(busy.status, { "ctron_status.moving_to_pos" })
	t.expect_eq(idle.who, "")
	t.expect_eq(idle.chip.caption, "#9") -- an idle ctron's name sits in the grey bar
	t.expect_same(idle.chip.color, view.COLORS.cargo)
	t.expect_eq(idle.details, false)
	t.expect_eq(idle.remote, false)
	t.expect_eq(idle.locate, false)
	t.expect_same(idle.status, { "ctronv2.idle" })
	t.expect_eq(idle.sprite, "utility/status_inactive")
	t.expect_same(idle.pos, { x = 1, y = 2 })
	local st = s.stations.rows[1].vm
	t.expect_eq(st.type, "station")
	t.expect_eq(st.who, "")
	t.expect_eq(st.chip.caption, "Mall")
	t.expect_eq(st.cargo, true)
	-- a station on another tile: Cargo needs the controller link
	t.expect_eq(view.screen(mirror(), { here = 8, link_up = true }).stations.rows[1].vm.cargo, true)
	t.expect_eq(view.screen(mirror(), { here = 8, link_up = false }).stations.rows[1].vm.cargo, false)
	t.expect_eq(st.icons[1].number, 500)
	t.expect_same(st.pos, { x = 5, y = 6 })
	t.expect_same(st.status, { "ctronv2.no_supplier" })
	t.expect_eq(st.tip, "[item=pipe,quality=normal] 458")
end)

t.test("screen: an empty ready mirror renders empty sections", function()
	local s = view.screen({ rows = {}, stats = {}, ready = true }, { here = 7, link_up = true })
	t.expect_eq(#s.jobs, 4)
	t.expect_same(s.jobs[1].rows, {})
	t.expect_same(s.badges, { jobs = "0", ctrons = "0/0", stations = "0" })
	t.expect_same(s.tiles, {})
	t.expect_same(s.surfaces, {})
end)

local function rows(list)
	local out = {}
	for i, kv in ipairs(list) do
		out[i] = { key = kv[1], vm = { x = kv[2] } }
	end
	return out
end

t.test("diff: nothing for an identical list", function()
	t.expect_same(view.diff(rows({ { "a", 1 }, { "b", 1 } }), rows({ { "a", 1 }, { "b", 1 } })), {})
	t.expect_same(view.diff({}, {}), {})
end)

t.test("diff: remove, move, update and add, in apply order", function()
	local ops = view.diff(rows({ { "a", 1 }, { "b", 1 }, { "c", 1 } }), rows({ { "c", 1 }, { "a", 2 }, { "d", 1 } }))
	t.expect_same(ops, {
		{ op = "remove", key = "b" },
		{ op = "swap", a = 1, b = 2 },
		{ op = "update", key = "a", vm = { x = 2 }, old = { x = 1 } },
		{ op = "add", key = "d", index = 3, vm = { x = 1 } },
	})
end)

t.test("diff: applying the ops to prev's key order gives next's order", function()
	local prev = rows({ { "a", 1 }, { "b", 1 }, { "c", 1 }, { "d", 1 }, { "e", 1 } })
	local nxt = rows({ { "e", 2 }, { "x", 1 }, { "c", 1 }, { "a", 1 }, { "y", 1 } })
	local order = { "a", "b", "c", "d", "e" }
	local vms = { e = { x = 1 } }
	for _, op in ipairs(view.diff(prev, nxt)) do
		if op.op == "remove" then
			for i, k in ipairs(order) do
				if k == op.key then
					table.remove(order, i)
					break
				end
			end
		elseif op.op == "swap" then
			order[op.a], order[op.b] = order[op.b], order[op.a]
		elseif op.op == "update" then
			vms[op.key] = op.vm
		elseif op.op == "add" then
			table.insert(order, op.index, op.key)
		end
	end
	t.expect_same(order, { "e", "x", "c", "a", "y" })
	t.expect_same(vms.e, { x = 2 })
end)

t.test("screen: a delta touching one section leaves the others' row lists untouched, ops equal a full recompute", function()
	local m = mirror()
	m.bysec = nil
	local opts = { here = 7, expand = "7|construction", link_up = true }
	local prev = view.screen(m, opts)
	local delta = { seq = 2, part = 1, parts = 1, full = false, rm = { "j:4" }, stats = m.stats,
		up = { { key = "j:1", sec = "progress", ord = 2, kind = "construction", at = 7, atName = "t7", worker = "7.417",
			n = 3, state = "to_work", status = "requesting", tasks = { 0, 3 } } } }
	local m2, v = view.apply(m, delta)
	t.expect_eq(v, "done")
	local inc = view.screen(m2, opts)
	t.expect_eq(inc.jobs[1].rows, prev.jobs[1].rows)
	t.expect_eq(inc.jobs[4].rows, prev.jobs[4].rows)
	t.expect_eq(inc.stations.rows, prev.stations.rows)
	t.expect_eq(inc.ctrons.rows, prev.ctrons.rows)
	t.expect_eq(inc.jobs[2].rows == prev.jobs[2].rows, false)
	t.expect_same(view.diff(prev.jobs[1].rows, inc.jobs[1].rows), {})
	-- a bare mirror with the same rows gives the full recompute
	local full = view.screen({ rows = m2.rows, stats = m2.stats, ready = true }, opts)
	for i = 1, 4 do
		t.expect_same(inc.jobs[i].rows, full.jobs[i].rows)
		t.expect_same(view.diff(prev.jobs[i].rows, inc.jobs[i].rows), view.diff(prev.jobs[i].rows, full.jobs[i].rows))
	end
	t.expect_same(inc.badges, full.badges)
	t.expect_eq(#inc.jobs[3].rows, 0)
	-- a worker's label change reaches the job rows that show it
	local m3 = view.apply(m2, { seq = 3, part = 1, parts = 1, full = false, rm = {}, stats = m.stats,
		up = { { key = "c:7.417", sec = "ctrons", ord = 1, at = 7, atName = "t7", name = "constructron", label = "Al",
			state = "busy", jid = "1", kind = "construction", status = "moving" } } })
	t.expect_eq(view.screen(m3, opts).jobs[2].rows[2].vm.who, "Al +2")
	-- a time change refreshes ages
	m3.stats = { total = 18, now = 240000, more = m.stats.more }
	t.expect_same(view.screen(m3, opts).jobs[4].rows[1].vm.age, { "ctronv2.age_min", 4 })
end)

t.test("screen: seeded fuzz, the incremental screen and its diffs equal a full recompute", function()
	math.randomseed(20261019)
	local R = math.random
	local function pick(list)
		return list[R(#list)]
	end
	local JOBSEC = { "attention", "progress", "finishing" }
	local function make(key)
		local p, id = string.sub(key, 1, 2), string.sub(key, 3)
		local ord = R(1, 6)
		if p == "j:" then
			return { key = key, sec = pick(JOBSEC), ord = ord, kind = pick({ "construction", "repair" }), at = pick({ 7, 8 }),
				atName = "t", worker = "7." .. R(1, 4), n = R(1, 3), status = pick({ "moving", "requesting", "no_path" }),
				missing = R(2) == 1 and { { "pipe", "normal", R(9) } } or nil }
		elseif p == "g:" then
			return { key = key, sec = "pending", ord = ord, kind = "construction", owner = 7, ownerName = "t", n = R(1, 5),
				oldestMs = R(0, 1000), st = pick({ "open", "delay" }) }
		elseif p == "w:" then
			return { key = key, sec = pick({ "cells", "attention" }), ord = ord, kind = "construction", owner = pick({ 7, 8 }),
				ownerName = "t", c = R(2) == 1 and { R(50), R(50) } or nil, st = pick({ "open", "delay", "backoff" }),
				dueAtMs = R(0, 300000) }
		elseif p == "c:" then
			return { key = key, sec = "ctrons", ord = ord, at = pick({ 7, 8 }), atName = "t", name = "c",
				label = R(2) == 1 and ("L" .. R(9)) or nil, state = pick({ "idle", "busy" }), jid = "1", kind = "repair",
				status = "moving", x = R(9), y = R(9) }
		elseif p == "s:" then
			return { key = key, sec = "stations", ord = ord, at = pick({ 7, 8 }), atName = "t", name = "S" .. R(9),
				x = R(9), y = R(9) }
		end
		return { key = key, sec = "stations", ord = 1, sid = id, why = pick({ "no_supplier", nil }),
			slots = { { "pipe", "normal", R(9), R(9), R(9), R(9) } }, order = { { "pipe", "normal", R(9) } } }
	end
	local KEYS = {}
	for i = 1, 6 do
		for _, p in ipairs({ "j:", "g:7|k", "w:7|nauvis|construction|", "c:7.", "s:7.", "n:7." }) do
			KEYS[#KEYS + 1] = p .. i
		end
	end
	for _ = 1, 8 do
		local opts = { here = 7, expand = nil, link_up = true }
		local stats = { total = 9, available = 5, now = 1000, more = { progress = R(0, 3) }, tiles = {}, waiting = {} }
		local up = {}
		for _, k in ipairs(KEYS) do
			if R(2) == 1 then
				up[#up + 1] = make(k)
			end
		end
		local m = view.apply(nil, { seq = 1, part = 1, parts = 1, full = true, up = up, rm = {}, stats = stats })
		local prev = view.screen(m, opts)
		for seq = 2, 40 do
			local u, rm = {}, {}
			for _ = 1, R(0, 4) do
				local k = pick(KEYS)
				if R(4) == 1 then
					rm[#rm + 1] = k
				else
					u[#u + 1] = make(k)
				end
			end
			if R(4) == 1 then
				stats = { total = 9, available = R(9), now = stats.now + R(0, 90000), more = { progress = R(0, 3) },
					tiles = {}, waiting = {} }
			end
			if R(8) == 1 then
				opts = { here = pick({ 7, 8 }), expand = opts.expand, link_up = opts.link_up }
			end
			if R(8) == 1 then
				opts = { here = opts.here, expand = opts.expand, link_up = not opts.link_up }
			end
			if R(5) == 1 then
				opts = { here = opts.here, expand = pick({ "7|k1", "7|k2", "9|x" }), link_up = opts.link_up }
			end
			local v
			m, v = view.apply(m, { seq = seq, part = 1, parts = 1, full = false, up = u, rm = rm, stats = stats })
			t.expect_eq(v, "done")
			local inc = view.screen(m, opts)
			local full = view.screen({ rows = m.rows, stats = m.stats, ready = true }, opts)
			local pairs_ = {}
			for i = 1, 4 do
				pairs_[#pairs_ + 1] = { prev.jobs[i].rows, inc.jobs[i].rows, full.jobs[i].rows, inc.jobs[i], full.jobs[i] }
			end
			pairs_[5] = { prev.ctrons.rows, inc.ctrons.rows, full.ctrons.rows, inc.ctrons, full.ctrons }
			pairs_[6] = { prev.stations.rows, inc.stations.rows, full.stations.rows, inc.stations, full.stations }
			for _, p in ipairs(pairs_) do
				t.expect_same(p[4], p[5])
				t.expect_same(view.diff(p[1], p[2]), view.diff(p[1], p[3]))
			end
			t.expect_same(inc.badges, full.badges)
			t.expect_same(inc.summary, full.summary)
			prev = inc
		end
	end
end)
