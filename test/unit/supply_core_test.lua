local t = require("testlib")
local core = require("modules/ctron_pluginv2/supply_core")

local STACKS = { ["iron-plate"] = 100, ["copper-plate"] = 100, ["transport-belt"] = 100, stone = 50 }
local function f(name, quality, count, comparator)
	return { index = 1, name = name, quality = quality, comparator = comparator or "=", count = count }
end
local function empty(filter) return { count = 0, filter = filter } end
local function slot(name, count, quality) return { name = name, quality = quality or "normal", count = count } end

t.test("missing: minimums added up per item and quality, less held and on the way; ranges left out", function()
	local filters = {
		f("iron-plate", "normal", 100), f("iron-plate", "normal", 50), -- two sections asking for iron add up
		f("copper-plate", "uncommon", 50), f("transport-belt", "normal", 20),
		f("stone", nil, 30, nil), f("wood", "normal", 10, ">="), f("coal", "normal", 0),
		{ index = 9, type = "fluid", name = "water", quality = "normal", comparator = "=", count = 5 },
	}
	local held = { ["iron-plate"] = { normal = 30 }, ["copper-plate"] = { normal = 50, uncommon = 10 },
		["transport-belt"] = { normal = 60 } }
	local coming = { ["iron-plate"] = { normal = 20 } }
	t.expect_same(core.missing(filters, held, coming), {
		["iron-plate"] = { normal = 100 }, ["copper-plate"] = { uncommon = 40 },
	}, "150 - 30 held - 20 coming; normal copper doesn't count for uncommon; belts are over")
	t.expect_same(core.missing({}, held, {}), {})
end)

t.test("call_items: tuples with stack sizes, the kinds that fill the most slots first, cut to max", function()
	local missing = { ["iron-plate"] = { normal = 250 }, stone = { normal = 10 }, ["copper-plate"] = { uncommon = 100 } }
	t.expect_same(core.call_items(missing, STACKS, 30), {
		{ "iron-plate", "normal", 250, 100 }, { "copper-plate", "uncommon", 100, 100 }, { "stone", "normal", 10, 50 },
	})
	t.expect_same(core.call_items(missing, STACKS, 1), { { "iron-plate", "normal", 250, 100 } })
end)

t.test("give: what is missing, up to what the trunk holds beyond the kept robots and ammo", function()
	local missing = { ["iron-plate"] = { normal = 100 }, ["construction-robot"] = { normal = 20 }, wood = { normal = 5 } }
	local held = { ["iron-plate"] = { normal = 60 }, ["construction-robot"] = { normal = 55 } }
	local keep = { ["construction-robot"] = { normal = 50 } }
	t.expect_same(core.give(missing, held, keep), { ["iron-plate"] = { normal = 60 }, ["construction-robot"] = { normal = 5 } })
end)

t.test("place: tops up stacks of the item first, then empty slots a filter leaves free; no room, no entry", function()
	local main = { slot("iron-plate", 90), slot("copper-plate", 10), empty(), empty("stone"), empty(),
		slot("iron-plate", 40, "uncommon") }
	t.expect_same(core.place({ ["iron-plate"] = { normal = 150 } }, main, STACKS),
		{ { "iron-plate", "normal", { { 0, 10 }, { 2, 100 }, { 4, 40 } } } },
		"10 into the 90, then the empty slots, skipping the one reserved for stone")
	t.expect_same(core.place({ stone = { normal = 30 }, ["iron-plate"] = { normal = 10 } }, main, STACKS), {
		{ "iron-plate", "normal", { { 0, 10 } } }, { "stone", "normal", { { 2, 30 } } },
	}, "each slot once; the stone takes the first free empty slot")
	t.expect_same(core.place({ wood = { normal = 5 } }, { slot("stone", 50) }, STACKS), {}, "a full inventory")
end)

t.test("plan: every filled trash slot is taken; equal plans share a sig, any change gives another", function()
	local main, trash = { empty(), empty() }, { slot("stone", 40), { count = 0 }, slot("wood", 20) }
	local p = core.plan({ ["iron-plate"] = { normal = 50 } }, main, trash, STACKS)
	t.expect_same(p.inserts, { { "iron-plate", "normal", { { 0, 50 } } } })
	t.expect_same(p.takes, { { "stone", "normal", 0, 40 }, { "wood", "normal", 2, 20 } })
	t.expect_eq(p.n, 3)
	t.expect_eq(core.plan({ ["iron-plate"] = { normal = 50 } }, main, trash, STACKS).sig, p.sig)
	t.expect_true(core.plan({ ["iron-plate"] = { normal = 49 } }, main, trash, STACKS).sig ~= p.sig)
	local none = core.plan({}, main, { { count = 0 } }, STACKS)
	t.expect_eq(none.n, 0); t.expect_eq(none.sig, "")
end)
