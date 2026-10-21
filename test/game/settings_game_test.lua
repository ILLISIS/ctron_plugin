local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ct = require("modules/ctron_pluginv2/ct")

--- The current overrides and schedulable list, deep-copied, so a case can change its own part and put them back.
local function current()
	local s = storage.ctron_pluginv2
	local list = {}
	for name in pairs(s.schedulable or {}) do
		list[#list + 1] = name
	end
	return helpers.json_to_table(helpers.table_to_json({ o = s.settings.overrides })).o or {}, list
end

--- Run fn with seam module[fn_name] replaced by a recorder; returns the recorded argument lists.
local function spy(module, fn_name, fn)
	local calls, real = {}, module[fn_name]
	module[fn_name] = function(...)
		calls[#calls + 1] = { ... }
	end
	local ok, err = pcall(fn)
	module[fn_name] = real
	assert(ok, err)
	return calls
end

t.case("G5 defaults: CC's values from prototypes", function(ctx)
	ctx.at(5, function()
		local d = ct.settings.defaults()
		ctx.expect(d.job_start_delay == 300 and d.debug == false, "global defaults")
		ctx.expect(d.kinds.construction and d.kinds.rebuild and d.kinds.repair and not d.kinds.destroy, "kinds")
		ctx.expect(d.robot[1] == "construction-robot" and d.robot[2] == "normal", "robot")
		ctx.expect(d.repair_tool[1] == "repair-pack", "repair tool")
		ctx.expect(d.ammo[1] == "rocket", "ammo")
		ctx.expect(d.atomic and d.atomic[1] == "atomic-bomb", "atomic bomb exists in base, so it is the default")
		ctx.expect(d.robot_count == 50 and d.min_cluster == 8 and d.minions == 1, "counts")
		ctx.expect(ct.settings.stacks["iron-plate"] == 100 and ct.settings.stacks["no-such-item"] == 1, "stacks")
		ctx.expect(ct.settings.allowed["iron-plate"] == true and ct.settings.allowed["iron-ore"] == true, "allowed")
	end)
end)

t.case("G5 kind off: clears that kind's cells and cancels its runs on that surface only; rebuild off clears nothing",
	function(ctx)
		ctx.at(10, function()
			local a = fx.surface("ctv2-g5-a").name
			fx.surface("ctv2-g5-b")
			local o, list = current()
			local new = current() -- a second copy to change; o stays as it was, for the restore
			new[a] = { kinds = { construction = false, rebuild = false } }
			local cancels
			local clears = spy(ct.discovery, "clear", function()
				cancels = spy(ct.runs, "cancel_kind", function()
					fx.send("ct.settings", { overrides = new, surfaces = list })
				end)
			end)
			ctx.expect(#clears == 1 and clears[1][1].surface == a and clears[1][1].kind == "construction",
				"one clear, construction on " .. a .. ": " .. serpent.line(clears))
			ctx.expect(#cancels == 1 and cancels[1][1] == a and cancels[1][2] == "construction",
				"one cancel_kind: " .. serpent.line(cancels))
			ctx.expect(ct.settings.of(a).kinds.construction == false, "effective on " .. a)
			ctx.expect(ct.settings.of("ctv2-g5-b").kinds.construction == true, "the other surface keeps construction")
			fx.send("ct.settings", { overrides = o, surfaces = list })
			ctx.expect(ct.settings.of(a).kinds.construction == true, "restored")
		end)
	end)

t.case("G5 validation: a bad item name falls back, counts clamp, '*' and the global keys apply", function(ctx)
	ctx.at(15, function()
		local a = fx.surface("ctv2-g5-c").name
		local o, list = current()
		local new = current()
		new[a] = { robot = { "iron-plate", "normal" }, ammo = { "rocket", "normal" }, robot_count = 99999 }
		new["*"] = new["*"] or {}
		new["*"].minions, new["*"].debug = 4, true
		fx.send("ct.settings", { overrides = new, surfaces = list })
		local e = ct.settings.of(a)
		ctx.expect(e.robot[1] == "construction-robot", "iron-plate places no robot: back to the default")
		ctx.expect(e.robot_count == 10000, "clamped to CC's cap")
		ctx.expect(e.minions == 4 and ct.settings.of("nauvis").minions == 4, "'*' applies to every surface")
		ctx.expect(ct.settings.global().debug == true, "a global key under '*'")
		fx.send("ct.settings", { overrides = o, surfaces = list })
		ctx.expect(ct.settings.global().debug == (o["*"] and o["*"].debug or false), "restored")
	end)
end)

t.case("G5 each ct.settings passes its surfaces to discovery and refreshes the Settings window once", function(ctx)
	ctx.at(20, function()
		local o, list = current()
		local mine = {}
		for i, name in ipairs(list) do
			mine[i] = name
		end
		mine[#mine + 1] = "ctv2-g5-sched"
		local refreshes
		local scheds = spy(ct.discovery, "set_schedulable", function()
			refreshes = spy(ct.gui, "on_settings", function()
				fx.send("ct.settings", { overrides = o, surfaces = mine })
			end)
		end)
		ctx.expect(#scheds == 1 and #scheds[1][1] == #mine and scheds[1][1][#mine] == "ctv2-g5-sched", "the list as sent")
		ctx.expect(#refreshes == 1, "one refresh")
		fx.send("ct.settings", { overrides = o, surfaces = list })
	end)
end)
