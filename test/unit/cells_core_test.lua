local t = require("testlib")
local core = require("modules/ctron_pluginv2/cells_core")

local stacks = { ["iron-chest"] = 50, wood = 100, ["cliff-explosives"] = 20, ["iron-plate"] = 100 }

local function cell(x0, y0, x1, y1, kind)
	local cells = {}
	local key = core.key(x0, y0)
	local c = core.touch(cells, "w", kind or "construction", "nauvis", key, x0, y0, 100, false)
	core.touch(cells, "w", kind or "construction", "nauvis", key, x1, y1, 100, false)
	return c
end

t.test("keys follow CC's formula, including negative coordinates", function()
	t.expect_eq(core.key(0, 0), 312512500)
	t.expect_eq(core.key(-0.5, -0.5), 312487499)
	t.expect_eq(core.key(79.9, 80), 312512501)
	t.expect_eq(core.key(-80, -80.1), 312487498)
	t.expect_eq(core.wid(4242, "nauvis", "construction", 312512500), "4242|nauvis|construction|312512500")
end)

t.test("touch creates a cell, grows its bbox, keeps since, re-arms t, and tool sticks", function()
	local cells = {}
	local c = core.touch(cells, "w", "construction", "nauvis", 1, 10, 20, 100, false)
	t.expect_same({ c.min, c.max, c.t, c.since, c.dirty, c.tool }, { { x = 10, y = 20 }, { x = 10, y = 20 }, 100, 100, true, false })
	t.expect_eq(cells.w, c)
	core.touch(cells, "w", "construction", "nauvis", 1, 5, 30, 110, false)
	t.expect_same({ c.min, c.max, c.t, c.since }, { { x = 5, y = 20 }, { x = 10, y = 30 }, 110, 100 })
	core.touch(cells, "w", "construction", "nauvis", 1, 6, 21, 120, true)
	core.touch(cells, "w", "construction", "nauvis", 1, 6, 21, 130, false)
	t.expect_eq(c.tool, true, "a tool cell stays a tool cell")
end)

t.test("the quiet period: due counts down, a scan clears it, a later event re-arms it, forced skips it", function()
	local c = cell(0, 0, 0, 0)
	t.expect_eq(core.due(c, 200, 300), 200)
	t.expect_eq(core.ready(c, 399, 300), false)
	t.expect_eq(core.ready(c, 400, 300), true)
	core.begin(c, 400)
	core.count(c, { ["iron-chest"] = { normal = 1 } }, {})
	core.finish(c, stacks, {})
	t.expect_eq(core.due(c, 401, 300), 0, "scanned and quiet")
	core.touch({ w = c }, "w", "construction", "nauvis", c.key, 1, 1, 500, false)
	t.expect_eq(core.due(c, 600, 300), 200, "re-armed by a later event")
	t.expect_eq(core.due(c, 900, 300), 1, "past its quiet period but not yet rescanned: not assignable")
	core.force(c)
	t.expect_eq(core.ready(c, 501, 300), true, "forced ignores the quiet period")
end)

t.test("the strip plan covers the bbox and each position counts in exactly one strip", function()
	local c = cell(0, 0, 79, 79)
	t.expect_eq(core.strips(c), 4)
	for _, x in ipairs({ 0, 19.99, 20, 59.5, 79 }) do
		local hits = 0
		for i = 1, core.strips(c) do
			local area, lo = core.strip_area(c, i)
			if core.owns(c, lo, x, 40) then
				hits = hits + 1
				t.expect_true(area.left_top.x <= x and x <= area.right_bottom.x, "the strip's area holds x = " .. x)
				t.expect_true(area.left_top.y <= 40 and 40 <= area.right_bottom.y, "and y")
			end
		end
		t.expect_eq(hits, 1, "x = " .. x)
	end
	local _, lo = core.strip_area(c, 4)
	t.expect_eq(core.owns(c, lo, 79, 80), false, "an entity of the next cell (y = 80) is not this cell's")
	t.expect_eq(core.strips(cell(5, 5, 5, 5)), 1, "a one-point cell has one strip")
end)

t.test("a destroy cell grown past its 80×80 square counts by strip only", function()
	local c = cell(0, 0, 200, 10, "destroy")
	t.expect_eq(core.strips(c), 11)
	local _, lo = core.strip_area(c, 11)
	t.expect_eq(core.owns(c, lo, 200, 10), true, "x = 200 lies in another key's square but is this destroy cell's")
end)

t.test("a scan adds totals in place; finish stores tuples, out slots, scanned = scan start, and drops disallowed items", function()
	local c = cell(0, 0, 10, 10, "deconstruction")
	core.begin(c, 500)
	core.count(c, { ["cliff-explosives"] = { normal = 1 } }, { wood = { normal = 4 } })
	core.count(c, {}, { wood = { normal = 150 }, ["iron-plate"] = { rare = 1 } })
	core.count(c, { ["hidden-thing"] = { normal = 2 } }, {})
	t.expect_eq(core.finish(c, stacks, { ["hidden-thing"] = false }), false, "not empty")
	t.expect_same(c.bring, { { "cliff-explosives", "normal", 1, 20 } })
	t.expect_eq(c.out, 3, "154 wood = 2 slots, 1 rare plate = 1 slot")
	t.expect_eq(c.n, 3)
	t.expect_eq(c.scanned, 500)
	t.expect_eq(c.dirty, false)
	t.expect_eq(c.forced, nil)
	t.expect_eq(c.strip, nil)
end)

t.test("finish keeps the 30 bring kinds with the most slots, ties by name (R-152)", function()
	local c = cell(0, 0, 10, 10)
	core.begin(c, 500)
	local many = {}
	for i = 1, 35 do
		-- item-01 .. item-05 take 3 slots each, the rest 1; an unknown stack size counts as 1
		many[string.format("item-%02d", i)] = { normal = i <= 5 and 3 or 1 }
	end
	core.count(c, many, {})
	core.finish(c, {}, {})
	t.expect_eq(#c.bring, 30)
	t.expect_same({ c.bring[1][1], c.bring[5][1], c.bring[6][1], c.bring[30][1] }, { "item-01", "item-05", "item-06", "item-30" })
	t.expect_eq(c.n, 1, "n still counts every entity")
end)

t.test("finish: empty and quiet goes; an event during the scan keeps the cell dirty and not empty", function()
	local c = cell(0, 0, 0, 0)
	core.begin(c, 500)
	t.expect_eq(core.finish(c, stacks, {}), true, "nothing found, nothing new")
	c = cell(0, 0, 0, 0)
	core.begin(c, 500)
	core.touch({ w = c }, "w", "construction", "nauvis", c.key, 0, 0, 520, false)
	t.expect_eq(core.finish(c, stacks, {}), false, "an event after the scan began")
	t.expect_eq(c.dirty, true)
	t.expect_eq(c.scanned, 500)
end)

t.test("force restarts the strip plan, so strips scanned before it don't count", function()
	local c = cell(0, 0, 79, 0)
	core.begin(c, 500)
	c.strip = 3
	core.count(c, { wood = { normal = 1 } }, {})
	core.force(c)
	t.expect_eq(c.strip, nil)
	t.expect_eq(c.acc, nil)
	t.expect_eq(c.forced, true)
	core.begin(c, 600)
	t.expect_eq(core.finish(c, stacks, {}), true, "the wood counted before force is gone; nothing new since tick 100")
end)

t.test("the repair memory keeps up to 256 positions, then falls back to the area scan", function()
	local c = cell(0, 0, 0, 0, "repair")
	core.remember(c, 1, 1, "wall")
	core.remember(c, 1, 1, "wall")
	t.expect_eq(c.nents, 1, "one position counts once")
	for i = 2, core.REPAIR_CAP do
		core.remember(c, i, 1, "wall")
	end
	t.expect_eq(c.nents, 256)
	t.expect_same(c.ents["256,1"], { "wall", 256, 1 }, "kept as {name, x, y}")
	core.remember(c, 300, 1, "wall")
	t.expect_eq(c.ents, false, "the 257th turns the memory off")
	core.remember(c, 301, 1, "wall")
	t.expect_eq(c.ents, false)
end)

t.test("the flood stops at the cap, visits each entity once, and lists absorbed keys in first-seen order", function()
	-- a 20 × 20 grid of enemies 4 apart; near = the grid neighbours
	local grid = {}
	for i = 0, 19 do
		for j = 0, 19 do
			grid[i * 20 + j] = { id = i * 20 + j, x = i * 4, y = j * 4 }
		end
	end
	local function near(e)
		local out, i, j = {}, e.x / 4, e.y / 4
		for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
			local n = grid[(i + d[1]) * 20 + (j + d[2])]
			if n and i + d[1] >= 0 and i + d[1] < 20 and j + d[2] >= 0 and j + d[2] < 20 then
				out[#out + 1] = n
			end
		end
		return out
	end
	local list = core.flood({ grid[0], grid[0] }, near, core.FLOOD_CAP)
	t.expect_eq(#list, 200)
	local seen = {}
	for _, e in ipairs(list) do
		t.expect_true(not seen[e.id], "visited once")
		seen[e.id] = true
	end
	t.expect_eq(#core.flood({ grid[0] }, function() return {} end, core.FLOOD_CAP), 1)
	local three = { { id = 1, x = 10, y = 10 }, { id = 2, x = 90, y = 10 }, { id = 3, x = 95, y = 12 }, { id = 4, x = 10, y = 90 } }
	t.expect_same(core.absorbed(three, core.key(10, 10)), { core.key(90, 10), core.key(10, 90) })
	local lo, hi = core.extent(three)
	t.expect_same({ lo, hi }, { { x = 10, y = 10 }, { x = 95, y = 90 } })
end)

t.test("the record carries totals only once a scan has completed", function()
	local c = cell(0, 0, 10, 20)
	local r = core.record(c, "w", 200, 300)
	t.expect_same(r, { wid = "w", surface = "nauvis", kind = "construction", since = 100, due = 200, tool = false })
	core.begin(c, 400)
	core.count(c, { ["iron-chest"] = { normal = 2 } }, {})
	core.finish(c, stacks, {})
	r = core.record(c, "w", 401, 300)
	t.expect_same(r, {
		wid = "w", surface = "nauvis", kind = "construction", since = 100, due = 0, tool = false,
		scanned = 400, n = 1, bring = { { "iron-chest", "normal", 2, 50 } }, out = 0,
		area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 10, y = 20 } }, center = { x = 5, y = 10 },
	})
end)

t.test("an event that grows the bbox during a scan drops the scan; the rescan counts each entity once", function()
	local c = cell(20, 0, 79, 0)
	core.begin(c, 500)
	core.count(c, { wood = { normal = 1 } }, {})
	c.strip = 2
	core.touch({ w = c }, "w", "construction", "nauvis", c.key, 5, 0, 520, false)
	t.expect_same({ c.strip, c.acc, c.scan_start }, { nil, nil, nil })
	core.begin(c, 900)
	for i = 1, core.strips(c) do
		local _, lo = core.strip_area(c, i)
		for _, x in ipairs({ 5, 20, 39.9, 40, 79 }) do
			if core.owns(c, lo, x, 0) then
				core.count(c, { wood = { normal = 1 } }, {})
			end
		end
	end
	core.finish(c, stacks, {})
	t.expect_eq(c.n, 5, "five entities, each once")
	core.begin(c, 1000)
	core.touch({ w = c }, "w", "construction", "nauvis", c.key, 10, 0, 1010, false)
	t.expect_eq(c.strip, 1, "an event inside the bbox leaves the scan running")
end)

t.test("finish shrinks the bbox to the extent of the entities found; none found, or an event since, leaves it", function()
	local c = cell(10, 10, 70, 60)
	core.begin(c, 500)
	core.count(c, { wood = { normal = 1 } }, {}, 12, 14)
	core.finish(c, stacks, {})
	t.expect_same({ c.min, c.max }, { { x = 12, y = 14 }, { x = 12, y = 14 } })
	local d = cell(10, 10, 70, 60)
	core.begin(d, 500)
	core.finish(d, stacks, {})
	t.expect_same({ d.min, d.max }, { { x = 10, y = 10 }, { x = 70, y = 60 } })
	local e = cell(10, 10, 70, 60)
	core.begin(e, 500)
	core.count(e, { wood = { normal = 1 } }, {}, 12, 14)
	core.count(e, { wood = { normal = 1 } }, {}, 20, 30)
	e.t = 510 -- an event inside the bbox while the scan ran
	core.finish(e, stacks, {})
	t.expect_same({ e.min, e.max }, { { x = 10, y = 10 }, { x = 70, y = 60 } })
	local f = cell(10, 10, 70, 60)
	core.begin(f, 500)
	core.count(f, {}, {}) -- no position (destroy, remembered repairs): the area stays
	core.finish(f, stacks, {})
	t.expect_same({ f.min, f.max }, { { x = 10, y = 10 }, { x = 70, y = 60 } })
end)
