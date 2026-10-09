local t = require("testlib")
local core = require("modules/ctron_plugin/script/border_core")
local geometry = require("modules/universal_edges/edges/geometry_core")

local T = 512

--- A gridworld tile centred on (0, 0), as gridworld/world/grid.ts frames it: each side's id is its compass letter.
local function tile(active)
	local h = T / 2
	local frames = {
		n = { origin = { -h, -h }, facing = 0 }, e = { origin = { h, -h }, facing = 4 },
		s = { origin = { h, h }, facing = 8 }, w = { origin = { -h, h }, facing = 12 },
	}
	local sides = {}
	for id, f in pairs(frames) do
		f.length = T
		sides[#sides + 1] = { id = id, active = active == nil or active[id] ~= false, deleted = false, frame = f }
	end
	return sides
end

local function P(plan)
	return core.point(plan.frame, plan.lx)
end

local function near(a, b)
	return math.abs(a - b) < 1e-9
end

t.test("border: P is where the worker-to-goal line meets the side, 3 out", function()
	local plan = core.plan(tile(), { x = 100, y = -456 }, { x = 0, y = 44 })
	t.expect_eq(plan.edge, "n")
	local x, y = P(plan)
	t.expect_true(near(x, 60) and near(y, -259), "the line from (0, 44) to (100, -456) meets y = -256 at x = 60: " ..
		x .. ", " .. y)
end)

t.test("border: a goal on the tile gives nil, also right at the line", function()
	t.expect_eq(core.plan(tile(), { x = 200, y = -200 }, { x = 0, y = 0 }), nil)
	t.expect_eq(core.plan(tile(), { x = 0, y = -256 }, { x = 0, y = 0 }), nil, "local y 0 is on the tile")
end)

t.test("border: a diagonal takes the side the line leaves through, the other side when that one is down", function()
	local goal, from = { x = 400, y = -300 }, { x = 200, y = 0 }
	t.expect_eq(core.plan(tile(), goal, from).edge, "e", "x reaches 256 (t = 0.28) before y reaches -256 (t = 0.85)")
	t.expect_eq(core.plan(tile({ e = false }), goal, from).edge, "n")
	local plan = core.plan(tile({ e = false }), goal, from)
	t.expect_true(near(plan.lx, T - core.END), "on n, the line's local x (627) is clamped to L - 16: " .. plan.lx)
end)

t.test("border: only inactive or deleted sides past the goal give a wait", function()
	t.expect_same(core.plan(tile({ n = false }), { x = 0, y = -300 }, { x = 0, y = 0 }), { wait = "edge_inactive" })
	local sides = tile()
	for _, s in ipairs(sides) do
		s.deleted = s.id == "n" or s.id == "e"
	end
	t.expect_same(core.plan(sides, { x = 300, y = -300 }, { x = 0, y = 0 }), { wait = "edge_inactive" })
end)

t.test("border: P is clamped to [16, L - 16] along the side, and always 3 out", function()
	-- Goals past n only: the line meets y = -256 at x = -244.2 (local 11.8) and 244.2 (local 500.2).
	local low = core.plan(tile(), { x = -255, y = -400 }, { x = -240, y = -200 })
	t.expect_eq(low.edge, "n")
	t.expect_true(near(low.lx, core.END), "near the west end: " .. low.lx)
	local high = core.plan(tile(), { x = 255, y = -400 }, { x = 240, y = -200 })
	t.expect_eq(high.edge, "n")
	t.expect_true(near(high.lx, T - core.END), "near the east end: " .. high.lx)
	local _, y = geometry.to_local(low.frame, P(low))
	t.expect_true(near(y, -core.DEPTH), "3 out")
end)

t.test("border: all four facings", function()
	for _, c in ipairs({ { "n", 0, -400 }, { "e", 400, 0 }, { "s", 0, 400 }, { "w", -400, 0 } }) do
		local plan = core.plan(tile(), { x = c[2], y = c[3] }, { x = 0, y = 0 })
		t.expect_eq(plan.edge, c[1])
		local x, y = P(plan)
		t.expect_true(near(math.abs(x) + math.abs(y), 259), c[1] .. ": straight out, 3 past the line: " .. x .. ", " .. y)
		t.expect_true(near(plan.lx, T / 2), c[1] .. ": mid side")
	end
end)

t.test("border: sides the worker is more than 26 beyond aren't its tile's (one-save tests); standing past one is", function()
	-- Two edges in one save: A's north side at y = 3000 and B's south side at y = 2000 (loopback.lua's layout).
	local a = { id = "x", active = true, deleted = false, frame = { origin = { 0, 3000 }, facing = 0, length = 64 } }
	local b = { id = "y", active = true, deleted = false, frame = { origin = { 64, 2000 }, facing = 8, length = 64 } }
	local plan = core.plan({ a, b }, { x = 30, y = 1990 }, { x = 30, y = 3050 })
	t.expect_eq(plan.edge, "x", "from A, B's goal lies past A's side")
	t.expect_eq(core.plan({ a, b }, { x = 30, y = 1950 }, { x = 30, y = 1995 }), nil, "from B, B's goal is on B")
	t.expect_eq(core.plan({ a, b }, { x = 30, y = 3100 }, { x = 30, y = 1995 }).edge, "y", "and A's station past B's")
	t.expect_eq(core.plan({ a, b }, { x = 30, y = 1990 }, { x = 30, y = 2997 }).edge, "x", "at P, 3 out: still A's")
end)

t.test("border: the water search tries P, then 16 further each way, nearest first, within [16, L - 16]", function()
	t.expect_same(core.xs(40, 96), { 40, 56, 24, 72 })
	t.expect_eq(#core.xs(256, 512), 31, "31 on a 512 side")
	t.expect_same(core.xs(16, 48), { 16, 32 })
end)
