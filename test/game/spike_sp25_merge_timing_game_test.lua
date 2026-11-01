local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ct = require("modules/ctron_pluginv2/ct")
local cells = require("modules/ctron_pluginv2/cells_core")

-- SP-25 (merge timing): when do the cells of one small job become schedulable? The controller merges only cells
-- whose scan has completed (due 0, scanned set) at the moment of its pass, so cells of one job that finish their scan
-- seconds apart go to different ctrons. A probe: it records each cell's tick and asserts only the setup.
local SP = "SP-25"

local function schedule(name)
	local s = storage.ctron_pluginv2
	local o = helpers.json_to_table(helpers.table_to_json({ o = s.settings.overrides })).o or {}
	local list = { name }
	for other in pairs(s.schedulable) do
		if other ~= name then
			list[#list + 1] = other
		end
	end
	fx.send("ct.settings", { overrides = o, surfaces = list })
end

local function grass(surface, x1, y1, x2, y2)
	local tiles = {}
	for x = x1, x2 do
		for y = y1, y2 do
			tiles[#tiles + 1] = { name = "grass-1", position = { x, y } }
		end
	end
	surface.set_tiles(tiles)
end

--- Record the tick each of the four cells around (80, 80) is first schedulable (a record with scanned and due 0),
--- counted from `from`, and its strip visits; note them all at the end.
local function track(ctx, tag, surface, kind, from, limit)
	local got = {}
	local names = { { "A", 40, 40 }, { "B", 120, 40 }, { "C", 40, 120 }, { "D", 120, 120 } }
	for k = from, from + limit do
		ctx.at(k, function()
			for _, n in ipairs(names) do
				local w = cells.wid(ct.registry.here(), surface.name, kind, cells.key(n[2], n[3]))
				local r = not got[n[1]] and ct.discovery.record(w)
				if r and r.scanned and r.due == 0 then
					got[n[1]] = { tick = game.tick - from, n = r.n }
				end
			end
			if k == from + limit then
				local first, last = math.huge, 0
				for _, g in pairs(got) do
					first, last = math.min(first, g.tick), math.max(last, g.tick)
				end
				fx.json(SP, tag .. " schedulable after (ticks since the events)", got)
				fx.note(SP, tag, " spread ", last - first, " ticks between the first and the last cell")
			end
		end)
	end
end

t.case("SP-25a ghosts pasted in one tick over four cells, one of them full", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-25.txt")
	local surface
	ctx.at(10, function()
		surface = fx.surface("sp25-a")
		fx.ground(surface, -10, -10, 170, 170)
		schedule(surface.name)
	end)
	ctx.at(20, function()
		for x = 2, 78, 4 do -- A: the whole cell, every 4 tiles
			for y = 2, 78, 4 do
				fx.ghost(surface, x, y)
			end
		end
		for _, p in ipairs({ { 82, 70 }, { 86, 74 }, { 70, 82 }, { 74, 86 }, { 82, 82 }, { 86, 86 } }) do
			fx.ghost(surface, p[1], p[2]) -- B, C and D: a few ghosts near the shared corner
		end
	end)
	track(ctx, "a", { name = "sp25-a" }, "construction", 20, 1800)
end)

t.case("SP-25b trees marked in one drag over four cells of mixed density", function(ctx)
	local surface
	ctx.at(10, function()
		surface = fx.surface("sp25-b")
		fx.ground(surface, -10, -10, 170, 170)
		grass(surface, 0, 0, 160, 160)
		schedule(surface.name)
		local density = { { 0, 0, 1 }, { 80, 0, 3 }, { 0, 80, 6 }, { 80, 80, 2 } } -- tree every n tiles
		for _, d in ipairs(density) do
			for x = d[1] + 1, d[1] + 78, d[3] do
				for y = d[2] + 1, d[2] + 78, d[3] do
					surface.create_entity({ name = "tree-01", position = { x, y }, force = "neutral" })
				end
			end
		end
	end)
	ctx.at(20, function()
		for _, e in pairs(surface.find_entities_filtered({ type = "tree", area = { { 0, 0 }, { 160, 160 } } })) do
			e.order_deconstruction("player")
		end
	end)
	track(ctx, "b", { name = "sp25-b" }, "deconstruction", 20, 3600)
end)
