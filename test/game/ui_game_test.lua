local t = require("modules/v2_test/testlib")
local ct = require("modules/ctron_pluginv2/ct") -- filled by control.lua; read ct.gui inside steps only
local view = require("modules/ctron_pluginv2/gui/view_core")

local function inbox(id, msg_type, payload)
	ue_rt.inbox("ctron_pluginv2", helpers.table_to_json({ { id = "c7e50001." .. id, type = msg_type, payload = payload } }))
end

local function list(seq, p, parts, full, up, rm)
	return { watch = { surface = "nauvis", tile = 4242 }, seq = seq, part = p, parts = parts, full = full, up = up or {},
		rm = rm or {}, stats = { total = 2, available = 1, surfaces = { "nauvis" }, tiles = { { 4242, "test" } },
		more = {}, waiting = {}, now = 0 } }
end

local function row(key, sec, ord)
	return { key = key, sec = sec, ord = ord, kind = "construction", at = 4242, atName = "test",
		worker = "4242.1", n = 1, state = "to_work", status = "moving", tasks = { 0, 1 },
		station = { sid = "4242.2", name = "S", inst = 4242, x = 0, y = 0 } }
end

t.case("ctronv2 ui: a watch sends on, a full list in two parts fills the mirror, a delta updates it", function(ctx)
	ctx.expect_ipc("ctron_pluginv2:out", '"ct.ui.watch"')
	ctx.at(5, function()
		local k = ct.gui.watch(0, { surface = "nauvis", tile = 4242 })
		ctx.expect(k == "nauvis|4242|", "watch key " .. tostring(k))
		ctx.expect(storage.ctron_pluginv2.ui.watches[k].n == 1, "one viewer")
	end)
	ctx.at(10, function()
		inbox(1, "ct.ui.list", list(1, 1, 2, true, { row("j:a", "progress", 1) }))
		local m = ct.gui.mirror("nauvis|4242|")
		ctx.expect(m and m.ready == false, "part 1 of 2 leaves the mirror not ready")
	end)
	ctx.at(12, function()
		inbox(2, "ct.ui.list", list(1, 2, 2, true, { row("j:b", "attention", 1) }))
		local m = ct.gui.mirror("nauvis|4242|")
		ctx.expect(m and m.ready and m.rows["j:a"] and m.rows["j:b"], "both parts applied")
	end)
	ctx.at(14, function()
		inbox(3, "ct.ui.list", list(2, 1, 1, false, { row("j:c", "progress", 2) }, { "j:a" }))
		local m = ct.gui.mirror("nauvis|4242|")
		ctx.expect(m.rows["j:a"] == nil and m.rows["j:c"] ~= nil and m.seq == 2, "delta applied")
		local s = view.screen(m, { here = 4242, link_up = true })
		ctx.expect(#s.jobs[1].rows == 1 and #s.jobs[2].rows == 1, "attention 1, progress 1")
	end)
end)

t.case("ctronv2 ui: a gap re-watches; a list for an unheld watch changes nothing; the last viewer sends off", function(ctx)
	ctx.expect_ipc("ctron_pluginv2:out", '"on":false')
	ctx.at(20, function()
		ct.gui.watch(0, { surface = "nauvis", tile = 4242 })
		inbox(10, "ct.ui.list", list(1, 1, 1, true, { row("j:a", "progress", 1) }))
		inbox(11, "ct.ui.list", list(5, 1, 1, false, { row("j:z", "progress", 2) }))
		ctx.expect(ct.gui.mirror("nauvis|4242|") == nil, "a gap drops the mirror until the full list")
		inbox(12, "ct.ui.list", { watch = { surface = "vulcanus" }, seq = 1, part = 1, parts = 1, full = true,
			up = { row("j:q", "progress", 1) }, rm = {}, stats = {} })
		ctx.expect(storage.ctron_pluginv2.ui.watches["vulcanus||"] == nil, "no watch made for an unheld list")
	end)
	ctx.at(22, function()
		ct.gui.watch(1, { surface = "nauvis", tile = 4242 })
		ctx.expect(storage.ctron_pluginv2.ui.watches["nauvis|4242|"].n == 2, "two viewers")
		ct.gui.watch(0, nil)
		ctx.expect(storage.ctron_pluginv2.ui.watches["nauvis|4242|"].n == 1, "one viewer left, no off yet")
		ct.gui.watch(1, nil)
		ctx.expect(storage.ctron_pluginv2.ui.watches["nauvis|4242|"] == nil, "released")
	end)
end)

local function fake(sec, i)
	local job = { key = "j:" .. sec .. i, sec = sec, ord = i, kind = "construction", at = (i % 2 == 0) and 4242 or 7,
		atName = "t7", worker = "7." .. i, n = 1, state = "to_work", status = "moving", tasks = { 0, 3 },
		station = { sid = "7.1", name = "S", inst = 7, x = 0, y = 0 },
		missing = i <= 5 and { { "pipe", "normal", i } } or nil }
	if sec == "pending" then
		return { key = "g:7|k" .. i, sec = sec, ord = i, kind = "construction", owner = 7, ownerName = "t7", n = i,
			oldestMs = 0, st = "open" }
	elseif sec == "cells" then
		return { key = "w:7|nauvis|construction|" .. i, sec = sec, ord = i, kind = "construction", owner = 7,
			ownerName = "t7", c = { i, i }, st = "open", rem = 1, committed = 0, firstSeenMs = 0, tool = false }
	elseif sec == "ctrons" then
		return { key = "c:7." .. i, sec = sec, ord = i, at = 7, atName = "t7", name = "constructron", state = "idle",
			x = i, y = i }
	elseif sec == "stations" then
		return { key = "s:7." .. i, sec = sec, ord = i, at = 7, atName = "t7", name = "S" .. i, x = i, y = i }
	end
	return job
end

t.case("ctronv2 ui: SP-22, the cost of a 300-row list (numbers in factorio-current.log)", function(ctx)
	ctx.at(40, function()
		local sizes = { { "attention", 20 }, { "progress", 50 }, { "finishing", 30 }, { "pending", 50 }, { "cells", 50 },
			{ "ctrons", 50 }, { "stations", 50 } }
		local up = {}
		for _, s in ipairs(sizes) do
			for i = 1, s[2] do
				up[#up + 1] = fake(s[1], i)
			end
		end
		local stats = { total = 50, available = 50, surfaces = { "nauvis" }, tiles = { { 7, "t7" } }, more = {},
			waiting = {}, now = 0 }
		local full = { watch = { surface = "nauvis" }, seq = 1, part = 1, parts = 1, full = true, up = up, rm = {},
			stats = stats }
		local opts = { here = 4242, expand = "7|k1", link_up = true }
		local function diff_all(prev, s)
			for i, sec in ipairs(s.jobs) do
				view.diff(prev and prev.jobs[i].rows or {}, sec.rows)
			end
			view.diff(prev and prev.ctrons.rows or {}, s.ctrons.rows)
			view.diff(prev and prev.stations.rows or {}, s.stations.rows)
		end
		local open = helpers.create_profiler()
		for _ = 1, 100 do
			diff_all(nil, view.screen(view.apply(nil, full), opts))
		end
		open.stop()
		open.divide(100)
		local m = view.apply(nil, full)
		local prev = view.screen(m, opts)
		local steady = helpers.create_profiler(true)
		local p_apply, p_screen, p_diff = helpers.create_profiler(true), helpers.create_profiler(true),
			helpers.create_profiler(true)
		for k = 1, 100 do
			local changed = {}
			for i = 1, 20 do
				local r = fake("progress", i)
				r.status = (k % 2 == 0) and "requesting" or "moving"
				changed[i] = r
			end
			local delta = { watch = { surface = "nauvis" }, seq = m.seq + 1, part = 1, parts = 1, full = false,
				up = changed, rm = {}, stats = stats }
			steady.restart()
			p_apply.restart()
			m = view.apply(m, delta)
			p_apply.stop()
			p_screen.restart()
			local s = view.screen(m, opts)
			p_screen.stop()
			p_diff.restart()
			diff_all(prev, s)
			p_diff.stop()
			steady.stop()
			prev = s
		end
		steady.divide(100)
		p_apply.divide(100)
		p_screen.divide(100)
		p_diff.divide(100)
		log({ "", "ctronv2.sp22 open (300 rows: full apply + sections + diff from nothing), per apply: ", open })
		log({ "", "ctronv2.sp22 steady (20-row delta + sections + diff), per apply: ", steady })
		log({ "", "ctronv2.sp22 steady split: apply ", p_apply, " screen ", p_screen, " diff ", p_diff })
		ctx.expect(m.seq == 101, "100 deltas applied in order")
	end)
end)
