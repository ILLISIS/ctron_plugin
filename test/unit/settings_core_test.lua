local t = require("testlib")
local core = require("modules/ctron_pluginv2/settings_core")

local valid = {
	robot = { ["construction-robot"] = true },
	repair_tool = { ["repair-pack"] = true },
	ammo = { rocket = true, ["atomic-bomb"] = true },
	quality = { normal = true, rare = true },
}

local function defaults()
	return {
		job_start_delay = 300, debug = false,
		kinds = { construction = true, rebuild = true, deconstruction = true, upgrade = true, repair = true, destroy = false },
		horde = false, zone_restriction = false,
		robot = { "construction-robot", "normal" }, robot_count = 50,
		repair_tool = { "repair-pack", "normal" },
		ammo = { "rocket", "normal" }, ammo_count = 0,
		atomic = { "atomic-bomb", "normal" }, atomic_count = 0,
		min_cluster = 8, minions = 1,
	}
end

t.test("no overrides: effective equals the defaults", function()
	t.expect_same(core.effective(defaults(), nil, "nauvis", valid), defaults())
	t.expect_same(core.effective(defaults(), {}, "nauvis", valid), defaults())
end)

t.test("a surface override beats '*', which beats the defaults", function()
	local o = { ["*"] = { robot_count = 10, minions = 3 }, nauvis = { robot_count = 20 } }
	local e = core.effective(defaults(), o, "nauvis", valid)
	t.expect_eq(e.robot_count, 20, "surface wins")
	t.expect_eq(e.minions, 3, "'*' fills keys the surface doesn't set")
	t.expect_eq(core.effective(defaults(), o, "vulcanus", valid).robot_count, 10, "'*' applies to other surfaces")
end)

t.test("kinds merge key by key", function()
	local e = core.effective(defaults(), { nauvis = { kinds = { destroy = true } } }, "nauvis", valid)
	t.expect_eq(e.kinds.destroy, true)
	t.expect_eq(e.kinds.construction, true, "other kinds keep their defaults")
end)

t.test("an invalid item name or quality falls back to the layer below", function()
	local o = {
		["*"] = { ammo = { "rocket", "rare" } },
		nauvis = { ammo = { "firearm-magazine", "normal" }, robot = { "construction-robot", "legendary" }, repair_tool = "repair-pack" },
	}
	local e = core.effective(defaults(), o, "nauvis", valid)
	t.expect_same(e.ammo, { "rocket", "rare" }, "a non-rocket ammo falls back to '*'")
	t.expect_same(e.robot, { "construction-robot", "normal" }, "an unknown quality falls back to the default")
	t.expect_same(e.repair_tool, { "repair-pack", "normal" }, "a bare string is not an item tuple")
end)

t.test("ints are floored and clamped to CC's caps; non-numbers are ignored", function()
	local o = { nauvis = { robot_count = 20000, ammo_count = -5, atomic_count = 1001, min_cluster = 0, minions = 7.9 } }
	local e = core.effective(defaults(), o, "nauvis", valid)
	t.expect_eq(e.robot_count, 10000)
	t.expect_eq(e.ammo_count, 0)
	t.expect_eq(e.atomic_count, 1000)
	t.expect_eq(e.min_cluster, 1)
	t.expect_eq(e.minions, 7)
	t.expect_eq(core.effective(defaults(), { nauvis = { robot_count = "50" } }, "nauvis", valid).robot_count, 50)
end)

t.test("bools must be booleans", function()
	local e = core.effective(defaults(), { nauvis = { horde = "true", zone_restriction = true } }, "nauvis", valid)
	t.expect_eq(e.horde, false)
	t.expect_eq(e.zone_restriction, true)
end)

t.test("global keys count only under '*': the delay floored at 0, debug a boolean", function()
	t.expect_same(core.global(defaults(), { ["*"] = { job_start_delay = -60, debug = true } }), { job_start_delay = 0, debug = true })
	t.expect_same(core.global(defaults(), { ["*"] = { job_start_delay = 150.7, debug = "yes" } }), { job_start_delay = 150, debug = false })
	t.expect_same(core.global(defaults(), { nauvis = { job_start_delay = 60, debug = true } }), { job_start_delay = 300, debug = false })
	t.expect_same(core.global(defaults(), nil), { job_start_delay = 300, debug = false })
	t.expect_eq(core.effective(defaults(), { nauvis = { job_start_delay = 60 } }, "nauvis", valid).job_start_delay, 300)
end)

t.test("effective returns a copy: editing it leaves the defaults alone", function()
	local d = defaults()
	local e = core.effective(d, nil, "nauvis", valid)
	e.kinds.construction = false
	e.robot[1] = "x"
	t.expect_eq(d.kinds.construction, true)
	t.expect_eq(d.robot[1], "construction-robot")
end)

t.test("turned_off lists the kinds that clear and cancel, never rebuild", function()
	local old = defaults()
	local new = core.effective(defaults(), { nauvis = { kinds = { construction = false, rebuild = false, repair = false } } }, "nauvis", valid)
	t.expect_same(core.turned_off(old, new), { "construction", "repair" })
	t.expect_same(core.turned_off(new, old), {}, "turning kinds on clears nothing")
	t.expect_same(core.turned_off(old, old), {})
end)
