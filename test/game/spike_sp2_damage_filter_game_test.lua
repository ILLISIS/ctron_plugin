local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")

t.case("SP-2 on_entity_damaged keeps control.lua's event filter after load", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-2.txt")
	local ev = defines.events.on_entity_damaged
	ctx.at(2, function()
		local filter = script.get_event_filter(ev)
		fx.json("SP-2", "filter", filter or {})
		fx.note("SP-2", "filter set: ", tostring(filter ~= nil), ", entries: ", filter and #filter or 0)
	end)
	ctx.at(3, function()
		local surface = fx.surface("sp2-filter")
		fx.ground(surface, -20, -20, 20, 20)
		local function make(name, x, y, force)
			local e = surface.create_entity({ name = name, position = { x, y }, force = force or "player" })
			ctx.expect(e ~= nil, name .. " created")
			return e
		end
		local wall1, wall2 = make("stone-wall", 0, 0), make("stone-wall", 4, 0)
		local biter, car = make("small-biter", 8, 0, "enemy"), make("car", 0, 8)
		local tree = make("tree-01", 8, 8, "neutral")
		local prev = script.get_event_handler(ev)
		local n = {}
		script.on_event(ev, function(e)
			n[e.entity.name] = (n[e.entity.name] or 0) + 1
			if prev then prev(e) end
		end, script.get_event_filter(ev))
		for _, e in ipairs({ wall1, biter, car, tree }) do
			if e and e.valid then e.damage(10, "neutral") end
		end
		if wall2 and wall2.valid then wall2.damage(10000, "neutral") end
		fx.json("SP-2", "counts", n)
		script.on_event(ev, prev, script.get_event_filter(ev))
	end)
end)
