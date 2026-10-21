local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")

local NAMES = { "stone-wall", "gun-turret", "assembling-machine-1", "transport-belt", "underground-belt", "splitter",
	"small-electric-pole", "medium-electric-pole", "pipe", "storage-tank", "straight-rail", "curved-rail-a",
	"half-diagonal-rail", "rail-signal", "solar-panel", "inserter", "wooden-chest", "radar", "stone-furnace", "small-lamp",
	"beacon", "roboport" }

t.case("SP-18 surface.find_entity finds a damaged entity of every repairable type", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-18.txt")
	ctx.at(2, function()
		local surface = fx.surface("sp18-find")
		fx.ground(surface, -40, -40, 40, 40)
		local ents = {}
		for i, name in ipairs(NAMES) do
			local x, y = -36 + ((i - 1) % 8) * 8, -30 + math.floor((i - 1) / 8) * 12
			local e = surface.create_entity({ name = name, position = { x, y }, force = "player" })
			if not e then
				fx.json("SP-18", "skipped", { name = name })
			else
				e.damage(10, "neutral")
				-- As the damage handler stores it (spec 5.2).
				ents[x .. "," .. y] = { name = e.name, x = e.position.x, y = e.position.y }
				local rec = ents[x .. "," .. y]
				local found = surface.find_entity(rec.name, { rec.x, rec.y })
				fx.json("SP-18", "result", { name = name, x = rec.x, y = rec.y, found = found ~= nil and found == e })
			end
		end
		ctx.expect(next(ents) ~= nil, "some entities created")
	end)
end)
