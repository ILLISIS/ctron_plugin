local t = require("testlib")
local core = require("modules/ctron_pluginv2/travel_core")

local function wp(x, y)
	return { position = { x = x, y = y } }
end

t.test("request_spec: travel and background params, a fresh table each call", function()
	local a = core.request_spec(false, false)
	t.expect_same(a.bounding_box, { { -5, -5 }, { 5, 5 } })
	t.expect_eq(a.path_resolution_modifier, -2)
	t.expect_eq(a.max_gap_size, 12)
	t.expect_eq(a.radius, 2)
	t.expect_same(a.pathfind_flags, { cache = false })
	local b = core.request_spec(true, true)
	t.expect_same(b.bounding_box, { { -1, -1 }, { 1, 1 } })
	t.expect_eq(b.path_resolution_modifier, 0)
	t.expect_same(b.pathfind_flags, { cache = false, low_priority = true })
	a.pathfind_flags.cache = true
	t.expect_same(core.request_spec(false, false).pathfind_flags, { cache = false })
end)

-- A north-facing side at (0, 0), 64 long: local == world offset; inside is +y.
local north = { origin = { 0, 0 }, facing = 0, length = 64 }

t.test("leaves_tile: more than 2 past a live line, inside the barrier band and span", function()
	t.expect_eq(core.leaves_tile({ wp(10, 5), wp(32, 0) }, { north }), false, "inside")
	t.expect_eq(core.leaves_tile({ wp(32, -1.9) }, { north }), false, "within 2")
	t.expect_eq(core.leaves_tile({ wp(10, 5), wp(32, -2.5) }, { north }), true, "2.5 past")
	t.expect_eq(core.leaves_tile({ wp(32, -30) }, { north }), false, "beyond the band (FAR = 26)")
	t.expect_eq(core.leaves_tile({ wp(-40, -5) }, { north }), false, "beyond the span (MARGIN = 32)")
	t.expect_eq(core.leaves_tile({ wp(-30, -5) }, { north }), true, "inside the margin")
	t.expect_eq(core.leaves_tile({ wp(32, -5) }, {}), false, "no live side")
	-- An east-facing side at (64, 0) runs south; world (67, 10) is local (10, -3).
	local east = { origin = { 64, 0 }, facing = 4, length = 64 }
	t.expect_eq(core.leaves_tile({ wp(60, 10) }, { east }), false, "west of it is inside")
	t.expect_eq(core.leaves_tile({ wp(67, 10) }, { north, east }), true, "3 past the east side")
end)

t.test("simplify: drop the start, keep turns, merge points closer than 5, keep the last", function()
	local line = {}
	for x = 0, 9 do
		line[#line + 1] = wp(x, 0)
	end
	t.expect_same(core.simplify(line), { { x = 9, y = 0 } }, "a straight line")
	t.expect_same(core.simplify({ wp(0, 0), wp(6, 0), wp(12, 0), wp(12, 6), wp(12, 12) }),
		{ { x = 12, y = 0 }, { x = 12, y = 12 } }, "an L")
	t.expect_same(core.simplify({ wp(0, 0), wp(3, 0), wp(3, 3), wp(10, 3) }), { { x = 10, y = 3 } },
		"turns closer than 5 merge")
	t.expect_same(core.simplify({ wp(4, 4) }), { { x = 4, y = 4 } }, "one waypoint")
end)

t.test("points: A, S and O in world coordinates on side a and on its partner b", function()
	local fa = { origin = { 100, 200 }, facing = 0, length = 64 }
	local A, S, O = core.points(fa, "a", 20)
	t.expect_same(A, { x = 120, y = 206 })
	t.expect_same(S, { x = 120, y = 197 })
	t.expect_same(O, { x = 120, y = 200 })
	-- The partner faces south from (164, 100), running west: a-frame x 20 is its local x 44, world x 120.
	local fb = { origin = { 164, 100 }, facing = 8, length = 64 }
	A, S, O = core.points(fb, "b", 20)
	t.expect_same(A, { x = 120, y = 94 })
	t.expect_same(S, { x = 120, y = 103 })
	t.expect_same(O, { x = 120, y = 100 })
end)

t.test("budget, clamp_x, near and short", function()
	t.expect_eq(core.budget(0), 2)
	t.expect_eq(core.budget(1), 4)
	t.expect_eq(core.budget(3), 8)
	t.expect_eq(core.clamp_x(64, 5), 16)
	t.expect_eq(core.clamp_x(64, 60), 48)
	t.expect_eq(core.clamp_x(64, 30), 30)
	t.expect_eq(core.short(0, 0, 12, 0), true)
	t.expect_eq(core.short(0, 0, 12.1, 0), false)
	t.expect_eq(core.near(0, 0, 3, 4, 5), true)
	t.expect_eq(core.near(0, 0, 3, 4, 4.9), false)
end)

t.test("avoid: keys expire after 18000 ticks; the list is sorted", function()
	local avoid = {}
	core.avoid_add(avoid, "e2", 100)
	core.avoid_add(avoid, "e1:0", 100)
	t.expect_same(core.avoid_list(avoid, 100), { "e1:0", "e2" })
	t.expect_same(core.avoid_list(avoid, 18099), { "e1:0", "e2" })
	t.expect_same(core.avoid_list(avoid, 18100), {})
	t.expect_eq(next(avoid), nil, "expired keys removed")
end)

t.test("planned: the source was stepping out for the current hop, or the edge matches it", function()
	local route = { hops = { { edge = "e1", x = 32, from = 1 } }, i = 1 }
	t.expect_eq(core.planned(route, true, "e1-y"), true, "stepping: a looped edge's twin id still counts")
	t.expect_eq(core.planned(route, false, "e1"), true, "same edge")
	t.expect_eq(core.planned(route, false, "e2"), false, "another edge")
	t.expect_eq(core.planned(nil, true, "e1"), false, "no route")
	t.expect_eq(core.planned({ hops = route.hops, i = 2 }, true, "e1"), false, "hops exhausted")
end)

t.test("step_back: the A point of the side the point is past, else nil", function()
	t.expect_same(core.step_back({ north }, 20, -3), { x = 20, y = 6 })
	t.expect_eq(core.step_back({ north }, 20, 5), nil, "inside")
	t.expect_eq(core.step_back({ north }, 70, -3), nil, "beyond the side's end")
	t.expect_eq(core.step_back({ north }, 20, -30), nil, "beyond the barrier band")
	local south = { origin = { 164, 100 }, facing = 8, length = 64 }
	t.expect_same(core.step_back({ north, south }, 120, 103), { x = 120, y = 94 }, "the partner side")
end)

t.test("stuck: under 2 tiles of progress and no stickers", function()
	t.expect_eq(core.stuck(0, 0, 1, 1, false), true)
	t.expect_eq(core.stuck(0, 0, 3, 0, false), false, "moved 3")
	t.expect_eq(core.stuck(0, 0, 1, 1, true), false, "a sticker slows it")
end)
