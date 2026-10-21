local t = require("testlib")
local core = require("modules/ctron_pluginv2/items_core")

local stacks = { ["construction-robot"] = 50, rocket = 100, ["repair-pack"] = 100, ["iron-plate"] = 100, ["atomic-bomb"] = 10 }
local cfg = {
	robot = { "construction-robot", "normal" }, robot_count = 50,
	repair_tool = { "repair-pack", "normal" },
	ammo = { "rocket", "normal" }, ammo_count = 200,
	atomic = { "atomic-bomb", "rare" }, atomic_count = 2,
}

--- Requests as a set keyed "name/quality" -> {min, max}, so order doesn't matter.
local function byname(requests)
	local out = {}
	for _, r in ipairs(requests) do
		out[r[1] .. "/" .. tostring(r[2])] = { r[3], r[4] }
	end
	return out
end

t.test("slots count each (name, quality) separately and round up (CR11)", function()
	local m = {}
	core.add(m, "iron-plate", "normal", 150)
	core.add(m, "iron-plate", "rare", 1)
	core.add(m, "iron-plate", "normal", 50)
	t.expect_same(m, { ["iron-plate"] = { normal = 200, rare = 1 } }, "add keeps qualities apart")
	t.expect_eq(core.slots(m, stacks), 3, "200/100 + ceil(1/100)")
	t.expect_eq(core.slots({ unknown = { normal = 3 } }, stacks), 3, "an unknown stack size counts as 1")
	t.expect_eq(core.slots({}, stacks), 0)
end)

t.test("tuples and map round-trip; map accepts {} and nil", function()
	local m = { rocket = { normal = 5 } }
	t.expect_same(core.tuples(m), { { "rocket", "normal", 5 } })
	t.expect_same(core.tuples(m, stacks), { { "rocket", "normal", 5, 100 } })
	t.expect_same(core.map({ { "rocket", "normal", 5 }, { "rocket", "normal", 2 } }), { rocket = { normal = 7 } })
	t.expect_same(core.map({}), {})
	t.expect_same(core.map(nil), {})
end)

t.test("full amounts per profile, zero counts left out", function()
	t.expect_same(core.full("normal", cfg), { ["construction-robot"] = { normal = 50 }, rocket = { normal = 200 } })
	t.expect_same(core.full("destroy", cfg), {
		["construction-robot"] = { normal = 4 }, ["repair-pack"] = { normal = 16 },
		rocket = { normal = 200 }, ["atomic-bomb"] = { rare = 2 },
	})
	t.expect_same(core.full("minion", cfg), {
		["construction-robot"] = { normal = 4 }, ["repair-pack"] = { normal = 16 }, rocket = { normal = 200 },
	})
	t.expect_same(core.full("cargo", cfg), { rocket = { normal = 200 } })
	local none = { robot = cfg.robot, robot_count = 0, repair_tool = cfg.repair_tool, ammo = cfg.ammo, ammo_count = 0, atomic_count = 0 }
	t.expect_same(core.full("normal", none), {})
	t.expect_same(core.full("destroy", none), { ["construction-robot"] = { normal = 4 }, ["repair-pack"] = { normal = 16 } })
end)

t.test("restock is full minus held, never negative; free subtracts its slots", function()
	local held = { ["construction-robot"] = { normal = 60 }, rocket = { normal = 50, rare = 10 } }
	local r = core.restock(core.full("normal", cfg), held)
	t.expect_same(r, { rocket = { normal = 150 } }, "60 robots cover 50; rare rockets don't count for normal")
	t.expect_eq(core.free(10, r, stacks), 8, "150 rockets take 2 slots")
	t.expect_eq(core.free(1, r, stacks), 0, "never negative")
end)

t.test("load list: load items at min = max, other held items at 0/0, disallowed load items dropped", function()
	local load = { ["iron-plate"] = { normal = 300 }, rocket = { normal = 200 }, ["hidden-thing"] = { normal = 5 } }
	local held = { rocket = { normal = 20, rare = 4 }, wood = { normal = 7 } }
	local got = byname(core.load_list(load, held, { ["hidden-thing"] = false, wood = true }))
	t.expect_same(got, {
		["iron-plate/normal"] = { 300, 300 },
		["rocket/normal"] = { 200, 200 },
		["rocket/rare"] = { 0, 0 },
		["wood/normal"] = { 0, 0 },
	})
end)

t.test("unload list: every held item at 0/0 except kept ones at 0..count; kept but not held asks nothing", function()
	local held = { ["iron-plate"] = { normal = 5 }, ["construction-robot"] = { normal = 50 }, rocket = { normal = 10 } }
	local keep = { ["construction-robot"] = { normal = 50 }, rocket = { normal = 200 }, ["repair-pack"] = { normal = 3 } }
	t.expect_same(byname(core.unload_list(held, keep)), {
		["iron-plate/normal"] = { 0, 0 },
		["construction-robot/normal"] = { 0, 50 },
		["rocket/normal"] = { 0, 200 },
	})
	t.expect_same(byname(core.unload_list(held, {})), {
		["iron-plate/normal"] = { 0, 0 }, ["construction-robot/normal"] = { 0, 0 }, ["rocket/normal"] = { 0, 0 },
	})
end)

t.test("deliver list: every cargo item at 0/0", function()
	t.expect_same(byname(core.deliver_list({ ["iron-plate"] = { normal = 400 }, coal = { rare = 1 } })), {
		["iron-plate/normal"] = { 0, 0 }, ["coal/rare"] = { 0, 0 },
	})
end)

t.test("unmet is exact: short counts are missing, surplus is excess", function()
	local req = { { "iron-plate", "normal", 100, 100 }, { "rocket", "normal", 10, 10 }, { "wood", "normal", 0, 0 } }
	local m, x = core.unmet(req, { ["iron-plate"] = { normal = 100 }, rocket = { normal = 10 } })
	t.expect_same(m, {}); t.expect_eq(x, false, "exact is met")
	m, x = core.unmet(req, { ["iron-plate"] = { normal = 60 }, rocket = { normal = 10 } })
	t.expect_same(m, { ["iron-plate"] = { normal = 40 } }); t.expect_eq(x, false)
	m, x = core.unmet(req, { ["iron-plate"] = { normal = 100 }, rocket = { normal = 11 } })
	t.expect_same(m, {}); t.expect_eq(x, true, "one rocket too many")
	m, x = core.unmet(req, { ["iron-plate"] = { normal = 100 }, rocket = { normal = 10 }, wood = { normal = 1 } })
	t.expect_same(m, {}); t.expect_eq(x, true, "a 0/0 item still aboard")
	m, x = core.unmet(req, { ["iron-plate"] = { normal = 100 }, rocket = { normal = 10 }, coal = { normal = 3 } })
	t.expect_same(m, {}); t.expect_eq(x, true, "an item no request names")
	m, x = core.unmet(req, { ["iron-plate"] = { normal = 100, rare = 1 }, rocket = { normal = 10 } })
	t.expect_same(m, {}); t.expect_eq(x, true, "another quality of a requested item")
end)

t.test("unmet: a player's any-quality request sums every quality; a nil max has no upper bound", function()
	local req = { { "repair-pack", nil, 10, nil } }
	local m, x = core.unmet(req, { ["repair-pack"] = { normal = 4, rare = 6 } })
	t.expect_same(m, {}); t.expect_eq(x, false)
	m = core.unmet(req, { ["repair-pack"] = { rare = 3 } })
	t.expect_same(m, { ["repair-pack"] = { any = 7 } }, "any-quality shortfalls are keyed 'any'")
	m, x = core.unmet(req, { ["repair-pack"] = { normal = 500 } })
	t.expect_same(m, {}); t.expect_eq(x, false, "no max, no excess")
end)

t.test("ammo plan: the wanted ammo spread evenly, remainder to the first slots, other ammo and qualities moved", function()
	local per, move = core.ammo_plan({ rocket = { normal = 10, rare = 3 }, ["atomic-bomb"] = { normal = 1 } }, 4, { "rocket", "normal" })
	t.expect_same(per, { 3, 3, 2, 2 })
	local moved = {}
	for _, m in ipairs(move) do
		moved[m[1] .. "/" .. m[2]] = m[3]
	end
	t.expect_same(moved, { ["rocket/rare"] = 3, ["atomic-bomb/normal"] = 1 })
	per, move = core.ammo_plan({ rocket = { rare = 3 } }, 4, { "rocket", "normal" })
	t.expect_eq(per, nil, "none of the wanted ammo: slots untouched")
	t.expect_same(move, { { "rocket", "rare", 3 } })
	per = core.ammo_plan({ rocket = { normal = 3 } }, 0, { "rocket", "normal" })
	t.expect_eq(per, nil, "no launcher slots")
end)

t.test("cover: all, some (indexes in order), none", function()
	local items = { { "a", "normal", 1 }, { "b", "normal", 2 }, { "c", "rare", 3 } }
	t.expect_eq(core.cover(function() return true end, items), true)
	t.expect_same(core.cover(function(name) return name ~= "b" end, items), { 1, 3 })
	t.expect_eq(core.cover(function() return false end, items), nil)
	local seen = {}
	core.cover(function(name, quality, count) seen[#seen + 1] = name .. quality .. count; return true end, items)
	t.expect_same(seen, { "anormal1", "bnormal2", "crare3" }, "the probe gets name, quality and count")
	t.expect_eq(core.cover(function() return true end, {}), true, "nothing asked: covered")
end)
