local t = require("testlib")
local core = require("modules/ctron_pluginv2/portal_core")

local function open_set(list)
	local s = {}
	for _, x in ipairs(list) do
		s[x] = true
	end
	return s
end

local function range(lo, hi)
	local out = {}
	for x = lo, hi, 8 do
		out[#out + 1] = x
	end
	return out
end

t.test("samples: every 8 tiles in [16, L - 16]", function()
	t.expect_same(core.samples(64), { 16, 24, 32, 40, 48 })
	t.expect_eq(#core.samples(512), 61)
end)

t.test("windows: one run per 128-tile window, midpoints", function()
	local w = core.windows(512, open_set(core.samples(512)))
	t.expect_same(w[0], { k = 0, lo = 16, hi = 120, x = 68 })
	t.expect_same(w[1], { k = 1, lo = 128, hi = 248, x = 188 })
	t.expect_same(w[2], { k = 2, lo = 256, hi = 376, x = 316 })
	t.expect_same(w[3], { k = 3, lo = 384, hi = 496, x = 440 })
end)

t.test("windows: the longest run survives a water gap; single samples don't count", function()
	local open = open_set(core.samples(512))
	for x = 160, 184, 8 do
		open[x] = nil
	end
	t.expect_same(core.windows(512, open)[1], { k = 1, lo = 192, hi = 248, x = 220 })
	t.expect_eq(next(core.windows(512, open_set({ 200 }))), nil, "a run of one")
end)

t.test("windows: a run crossing a window boundary splits; ties keep the first run", function()
	local w = core.windows(512, open_set(range(104, 152)))
	t.expect_same(w[0], { k = 0, lo = 104, hi = 120, x = 112 })
	t.expect_same(w[1], { k = 1, lo = 128, hi = 152, x = 140 })
	w = core.windows(512, open_set({ 16, 24, 40, 48 }))
	t.expect_same(w[0], { k = 0, lo = 16, hi = 24, x = 20 })
end)

t.test("key: edge and window", function()
	t.expect_eq(core.key("e1", 200), "e1:1")
	t.expect_eq(core.key("e1", 127.5), "e1:0")
end)

t.test("union-find", function()
	local p = core.uf(4)
	core.union(p, 1, 2)
	core.union(p, 3, 4)
	t.expect_eq(core.find(p, 2), core.find(p, 1))
	t.expect_true(core.find(p, 3) ~= core.find(p, 1))
	core.union(p, 2, 4)
	t.expect_eq(core.find(p, 4), core.find(p, 1))
end)

t.test("candidates: one node per component, the nearest, nearest first", function()
	local nodes = { { x = 0, y = 0 }, { x = 100, y = 0 }, { x = 10, y = 0 }, { x = 90, y = 0 } }
	local p = core.uf(4)
	t.expect_same(core.candidates(nodes, p, 3), { 1, 2 })
	core.union(p, 1, 2)
	t.expect_same(core.candidates(nodes, p, 4), { 2, 3 })
	t.expect_same(core.candidates(nodes, p, 1), {})
end)

t.test("report: ids in order, components by first appearance, no links", function()
	local nodes = {
		{ kind = "w", edge = "e", k = 0, lo = 16, hi = 24, x = 0, y = 0 },
		{ kind = "w", edge = "f", k = 1, lo = 136, hi = 248, x = 30, y = 40 },
		{ kind = "s", sid = "4242.7", x = 300, y = 400 },
	}
	local p = core.uf(3)
	core.union(p, 1, 2)
	t.expect_same(core.report("nauvis", 3, nodes, p), {
		surface = "nauvis", epoch = 3,
		nodes = {
			{ id = 1, kind = "w", edge = "e", k = 0, lo = 16, hi = 24, x = 0, y = 0, comp = 1 },
			{ id = 2, kind = "w", edge = "f", k = 1, lo = 136, hi = 248, x = 30, y = 40, comp = 1 },
			{ id = 3, kind = "s", sid = "4242.7", x = 300, y = 400, comp = 2 },
		},
	})
	t.expect_same(core.report("nauvis", 1, {}, core.uf(0)), { surface = "nauvis", epoch = 1, nodes = {} })
end)
