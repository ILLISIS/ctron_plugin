local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")

local FILTER = { position = { 0, 0 }, radius = 20, to_be_deconstructed = true, force = { "player", "neutral" } }

t.case("SP-3 kinds: what one to_be_deconstructed search returns", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-3.txt")
	local surface
	ctx.at(2, function()
		surface = fx.surface("sp3-kinds")
		fx.ground(surface, -30, -30, 30, 30)
		local function mark(label, spec)
			local e = surface.create_entity(spec)
			ctx.expect(e ~= nil, label .. " created")
			fx.note("SP-3", "order ", label, ": ", tostring(e ~= nil and e.order_deconstruction("player")))
		end
		mark("tree", { name = "tree-01", position = { 3, 3 } })
		mark("rock", { name = "huge-rock", position = { -6, 6 } })
		mark("cliff", { name = "cliff", position = { 10, -10 }, cliff_orientation = "west-to-east" })
		local cliff = surface.find_entities_filtered({ name = "cliff" })[1]
		if cliff then
			-- order_deconstruction refuses a cliff until the force may deconstruct cliffs.
			fx.note("SP-3", "cliff_deconstruction_enabled: ", tostring(game.forces.player.cliff_deconstruction_enabled))
			-- luacheck: ignore 122
			game.forces.player.cliff_deconstruction_enabled = true
			fx.note("SP-3", "order cliff (enabled): ", tostring(cliff.order_deconstruction("player")))
		end
		mark("item", { name = "item-on-ground", position = { -8, -3 }, stack = { name = "iron-plate", count = 5 } })
		mark("chest", { name = "wooden-chest", position = { 0, -12 }, force = "player" })
		surface.set_tiles({ { name = "stone-path", position = { 12, 12 } } })
		local proxy = surface.get_tile(12, 12).order_deconstruction("player")
		ctx.expect(proxy ~= nil, "tile proxy returned")
		if proxy then
			fx.json("SP-3", "tile proxy", { name = proxy.name, type = proxy.type, force = proxy.force.name })
		end
	end)
	ctx.at(4, function()
		local function list(filter)
			local out = {}
			for _, e in ipairs(surface.find_entities_filtered(filter)) do
				out[#out + 1] = { name = e.name, type = e.type, force = e.force.name }
			end
			return out
		end
		fx.json("SP-3", "found", list(FILTER))
		fx.note("SP-3", "count: ", surface.count_entities_filtered(FILTER))
		fx.json("SP-3", "found all forces", list({ position = { 0, 0 }, radius = 20, to_be_deconstructed = true }))
	end)
end)

t.case("SP-3 cost: find vs count over 400 marked trees", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-3.txt")
	ctx.at(2, function()
		local surface = fx.surface("sp3-cost")
		fx.ground(surface, 60, -30, 140, 30)
		for x = 80, 118, 2 do
			for y = -19, 19, 2 do
				local tree = surface.create_entity({ name = "tree-01", position = { x, y } })
				if tree then tree.order_deconstruction("player") end
			end
		end
		local filter = { position = { 100, 0 }, radius = 20, to_be_deconstructed = true, force = { "player", "neutral" } }
		local found = #surface.find_entities_filtered(filter)
		ctx.expect(found > 0, "trees found")
		fx.note("SP-3", "cost found: ", found)
		local p = helpers.create_profiler()
		for _ = 1, 1000 do local _ = surface.find_entities_filtered(filter) end
		p.stop()
		p.divide(1000)
		fx.note("SP-3", "find per call ", p)
		p = helpers.create_profiler()
		for _ = 1, 1000 do local _ = surface.count_entities_filtered(filter) end
		p.stop()
		p.divide(1000)
		fx.note("SP-3", "count per call ", p)
	end)
end)
