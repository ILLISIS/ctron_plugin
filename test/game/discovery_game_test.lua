local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ct = require("modules/ctron_pluginv2/ct")
local cells = require("modules/ctron_pluginv2/cells_core")

--- Make surface schedulable (and give it its own overrides patch, if any), keeping every other case's settings.
local function schedule(name, patch)
	local s = storage.ctron_pluginv2
	local o = helpers.json_to_table(helpers.table_to_json({ o = s.settings.overrides })).o or {}
	if patch then
		o[name] = patch
	end
	local list = { name }
	for other in pairs(s.schedulable) do
		if other ~= name then
			list[#list + 1] = other
		end
	end
	fx.send("ct.settings", { overrides = o, surfaces = list })
end

local function wid(surface, kind, x, y)
	return cells.wid(ct.registry.here(), surface.name, kind, cells.key(x, y))
end

--- An item map from a record's tuple list, so tests compare without caring about order.
local function map(list)
	local m = {}
	for _, it in ipairs(list or {}) do
		m[it[1] .. "/" .. it[2]] = it[3]
	end
	return m
end

local function same(a, b)
	for k, v in pairs(a) do
		if b[k] ~= v then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

--- Wait until the cell at w has a completed scan (record.scanned set), then done(record).
local function scanned(ctx, from, w, done)
	fx.wait(ctx, from, 2400, "a completed scan of " .. w, function()
		local r = ct.discovery.record(w)
		return r and r.scanned and r.due == 0
	end, function()
		done(ct.discovery.record(w))
	end)
end

--- Grass over the area, so trees and tile ghosts can be placed (refined concrete takes neither).
local function grass(surface, x1, y1, x2, y2)
	local tiles = {}
	for x = x1, x2 do
		for y = y1, y2 do
			tiles[#tiles + 1] = { name = "grass-1", position = { x, y } }
		end
	end
	surface.set_tiles(tiles)
end

local function tree(surface, x, y)
	return surface.create_entity({ name = "tree-01", position = { x, y }, force = "neutral" })
end

local function wood_per_tree()
	for _, p in pairs(prototypes.entity["tree-01"].mineable_properties.products) do
		if p.name == "wood" then
			return p.amount_max or p.amount
		end
	end
end

t.case("G3 construction: ghosts, a tile ghost and module requests make one cell; due first, exact totals after the delay",
	function(ctx)
		ctx.at(10, function()
			local surface = fx.surface("ctv2-dis-1")
			fx.ground(surface, -10, -10, 40, 30)
			grass(surface, 15, 9, 17, 11)
			schedule(surface.name)
			for _, x in ipairs({ 10.5, 12.5, 14.5 }) do
				fx.ghost(surface, x, 10.5)
			end
			ctx.expect(surface.create_entity({ name = "tile-ghost", inner_name = "stone-path", position = { 16, 10 },
				force = "player", raise_built = true }) ~= nil, "tile ghost created")
			local am = surface.create_entity({ name = "entity-ghost", inner_name = "assembling-machine-2",
				position = { 22.5, 10.5 }, force = "player", raise_built = true })
			ctx.expect(am ~= nil, "assembling machine ghost created")
			am.insert_plan = { { id = { name = "speed-module", quality = "rare" }, items = { in_inventory = {
				{ inventory = defines.inventory.crafter_modules, stack = 0 } } } } }
			local w = wid(surface, "construction", 10.5, 10.5)
			local r = ct.discovery.record(w)
			ctx.expect(r ~= nil and r.due > 0 and r.due <= 300 and r.bring == nil,
				"due first, no totals: " .. serpent.line(r))
			scanned(ctx, 11, w, function(rec)
				local stone = prototypes.tile["stone-path"].items_to_place_this[1]
				local want = { ["wooden-chest/normal"] = 3, ["assembling-machine-2/normal"] = 1,
					["speed-module/rare"] = 1 }
				want[stone.name .. "/normal"] = stone.count
				ctx.expect(same(map(rec.bring), want), "bring " .. serpent.line(rec.bring))
				for _, it in ipairs(rec.bring) do
					ctx.expect(it[4] == prototypes.item[it[1]].stack_size, it[1] .. " carries its stack size")
				end
				ctx.expect(rec.out == 0 and rec.n == 5, "out " .. tostring(rec.out) .. ", n " .. tostring(rec.n))
			end)
		end)
	end)

t.case("G3 deconstruction: a full chest, trees and an item on the ground", function(ctx)
	ctx.at(20, function()
		local surface = fx.surface("ctv2-dis-2")
		fx.ground(surface, -10, -10, 40, 30)
		grass(surface, 13, 9, 19, 11)
		schedule(surface.name)
		fx.chest(surface, 10.5, 10.5, { ["iron-plate"] = 250 }, "wooden-chest").order_deconstruction("player")
		for _, x in ipairs({ 14, 16, 18 }) do
			local tr = tree(surface, x, 10)
			ctx.expect(tr ~= nil, "tree created")
			tr.order_deconstruction("player")
		end
		local coal = surface.create_entity({ name = "item-on-ground", position = { 20, 10 },
			stack = { name = "coal", count = 5 } })
		coal.order_deconstruction("player")
		scanned(ctx, 21, wid(surface, "deconstruction", 10.5, 10.5), function(r)
			ctx.expect(r.n == 5, "n " .. tostring(r.n))
			ctx.expect(next(map(r.bring)) == nil, "nothing to bring: " .. serpent.line(r.bring))
			local want = math.ceil(250 / 100) + 1 + math.ceil(3 * wood_per_tree() / 100) + 1
			ctx.expect(r.out == want, "out " .. tostring(r.out) .. ", want " .. want)
		end)
	end)
end)

t.case("G3 upgrade: the target item in, the replaced item out", function(ctx)
	ctx.at(30, function()
		local surface = fx.surface("ctv2-dis-3")
		fx.ground(surface, -10, -10, 40, 30)
		schedule(surface.name)
		for _, x in ipairs({ 10.5, 11.5 }) do
			local belt = surface.create_entity({ name = "transport-belt", position = { x, 10.5 }, force = "player" })
			ctx.expect(belt.order_upgrade({ target = "fast-transport-belt", force = "player" }), "upgrade ordered")
		end
		scanned(ctx, 31, wid(surface, "upgrade", 10.5, 10.5), function(r)
			ctx.expect(same(map(r.bring), { ["fast-transport-belt/normal"] = 2 }), "bring " .. serpent.line(r.bring))
			ctx.expect(r.out == 1 and r.n == 2, "out " .. tostring(r.out) .. ", n " .. tostring(r.n))
		end)
	end)
end)

t.case("G3 repair: damaged entities are remembered and found again; a healed one drops out", function(ctx)
	local walls, w
	ctx.at(40, function()
		local surface = fx.surface("ctv2-dis-4")
		fx.ground(surface, -10, -10, 40, 30)
		schedule(surface.name)
		walls = {}
		for i, x in ipairs({ 10.5, 12.5, 14.5 }) do
			walls[i] = surface.create_entity({ name = "stone-wall", position = { x, 10.5 }, force = "player" })
			walls[i].damage(50, "enemy")
		end
		w = wid(surface, "repair", 10.5, 10.5)
	end)
	ctx.at(42, function()
		ctx.expect(ct.discovery.cell(w) and ct.discovery.cell(w).nents == 3, "three remembered")
		walls[2].health = walls[2].max_health
		scanned(ctx, 43, w, function(r)
			ctx.expect(same(map(r.bring), { ["repair-pack/normal"] = 2 }), "bring " .. serpent.line(r.bring))
			ctx.expect(r.n == 2 and ct.discovery.cell(w).nents == 2, "n " .. tostring(r.n))
		end)
	end)
end)

t.case("G3 strips never double-count; a neighbouring cell keeps its own", function(ctx)
	ctx.at(50, function()
		local surface = fx.surface("ctv2-dis-5")
		fx.ground(surface, -5, 30, 90, 50)
		schedule(surface.name)
		for i = 0, 39 do
			fx.ghost(surface, 0.5 + 2 * i, 40.5)
		end
		fx.ghost(surface, 80.5, 40.5)
		scanned(ctx, 51, wid(surface, "construction", 0.5, 40.5), function(r)
			ctx.expect(map(r.bring)["wooden-chest/normal"] == 40 and r.n == 40, "first cell: n " .. tostring(r.n))
		end)
		scanned(ctx, 51, wid(surface, "construction", 80.5, 40.5), function(r)
			ctx.expect(r.n == 1, "neighbour: n " .. tostring(r.n))
		end)
	end)
end)

t.case("G3 zone restriction skips covered entities, not the cell; a ctron's own roboport is no zone; a tool cell ignores it",
	function(ctx)
		local surface, w, near
		ctx.at(60, function()
			surface = fx.surface("ctv2-dis-6")
			fx.ground(surface, -80, 25, 100, 60)
			schedule(surface.name, { zone_restriction = true })
			surface.create_entity({ name = "roboport", position = { -50, 40 }, force = "player" })
			local power = surface.create_entity({ name = "electric-energy-interface", position = { -55, 35 },
				force = "player" })
			power.power_production, power.electric_buffer_size = 1e9 / 60, 1e10
			surface.create_entity({ name = "substation", position = { -55, 45 }, force = "player" })
			near = fx.ghost(surface, 2.5, 40.5)
			fx.ghost(surface, 70.5, 40.5)
			fx.ctron(surface, 72, 44, { robots = 0 })
			w = wid(surface, "construction", 2.5, 40.5)
			scanned(ctx, 61, w, function(r)
				ctx.expect(r.n == 1, "only the far ghost: n " .. tostring(r.n))
				ct.discovery.touch("construction", near, true)
				local touched = game.tick
				fx.wait(ctx, touched - t.first_tick + 1, 2400, "a rescan of the tool cell", function()
					local c = ct.discovery.cell(w)
					return c.scanned > touched and ct.discovery.record(w).due == 0
				end, function()
					local r2 = ct.discovery.record(w)
					ctx.expect(r2.n == 2 and r2.tool == true, "tool cell: n " .. tostring(r2.n))
				end)
			end)
		end)
	end)

t.case("G3 destroy: the flood merges the cells it reaches; the oracle and other forces don't count; the sector gate",
	function(ctx)
		ctx.at(70, function()
			local surface = fx.surface("ctv2-dis-7")
			fx.ground(surface, -20, -10, 120, 30)
			schedule(surface.name)
			local spawners = {}
			for i, x in ipairs({ 66.5, 73.5, 80.5 }) do
				spawners[i] = surface.create_entity({ name = "biter-spawner", position = { x, 10.5 }, force = "enemy" })
				ctx.expect(spawners[i] ~= nil, "spawner created")
			end
			if prototypes.entity["ue-oracle"] then
				surface.create_entity({ name = "ue-oracle", position = { 70, 14 },
					force = game.forces["ue-oracle"] or game.create_force("ue-oracle") })
			end
			-- A is older than B, so A is the cell that survives whichever visits first.
			local a = ct.discovery.touch("destroy", spawners[1], true)
			ctx.at(71, function()
				local b = ct.discovery.touch("destroy", spawners[3], true)
				ctx.expect(a ~= b, "two cells")
				fx.wait(ctx, 72, 2400, "one merged destroy cell", function()
					local ca = ct.discovery.cell(a)
					return ca and ca.scanned and ct.discovery.cell(b) == nil
				end, function()
					local r = ct.discovery.record(a)
					ctx.expect(r.n == 3, "n " .. tostring(r.n))
					ctx.expect(r.area.left_top.x < 67 and r.area.right_bottom.x > 80, "area " .. serpent.line(r.area))
					-- A new event in B's square makes a newer cell; the older one keeps its wid (I-3).
					local since = ct.discovery.cell(a).since
					local touched = game.tick
					local b2 = ct.discovery.touch("destroy", spawners[3], true)
					ctx.expect(b2 == b, "B's wid is reused")
					fx.wait(ctx, touched - t.first_tick + 1, 2400, "the newer cell gives way", function()
						local ca = ct.discovery.cell(a)
						return ct.discovery.cell(b) == nil and ca.scanned > touched and ct.discovery.record(a).due == 0
					end, function()
						local r2 = ct.discovery.record(a)
						ctx.expect(ct.discovery.cell(a).since == since and r2.n == 3, "the oldest cell survived: n "
							.. tostring(r2.n))
						ctx.expect(r2.area.left_top.x < 67 and r2.area.right_bottom.x > 80, "merged bbox covers both: "
							.. serpent.line(r2.area))
					end)
				end)
			end)

			-- The sector gate: destroy is off by default on a second surface.
			local other = fx.surface("ctv2-dis-7b")
			fx.ground(other, -20, -20, 40, 40)
			local radar = other.create_entity({ name = "radar", position = { 20.5, 20.5 }, force = "player" })
			local spawner = other.create_entity({ name = "biter-spawner", position = { 5.5, 5.5 }, force = "enemy" })
			ctx.expect(radar ~= nil and spawner ~= nil, "radar and spawner created")
			local event = { radar = radar, area = { left_top = { x = -10, y = -10 }, right_bottom = { x = 10, y = 10 } } }
			local handler = ct.discovery.events[defines.events.on_sector_scanned]
			local dw = wid(other, "destroy", 5.5, 5.5)
			handler(event)
			ctx.expect(ct.discovery.cell(dw) == nil, "destroy off: no cell")
			schedule(other.name, { kinds = { destroy = true } })
			handler(event)
			ctx.expect(ct.discovery.cell(dw) ~= nil, "destroy on: one cell")
		end)
	end)

t.case("G3 kind gates: construction off stops ghosts; rebuild has its own toggle", function(ctx)
	local surface, was
	ctx.at(80, function()
		surface = fx.surface("ctv2-dis-8")
		fx.ground(surface, -10, -10, 120, 50)
		schedule(surface.name, { kinds = { construction = false } })
		fx.ghost(surface, 10.5, 10.5)
		ctx.expect(ct.discovery.cell(wid(surface, "construction", 10.5, 10.5)) == nil, "construction off: no cell")
		local force = game.forces.player
		was = force.create_ghost_on_entity_death
		-- luacheck: ignore 122
		force.create_ghost_on_entity_death = true
		fx.chest(surface, 30.5, 30.5, nil, "wooden-chest").die()
	end)
	ctx.at(85, function()
		ctx.expect(ct.discovery.cell(wid(surface, "construction", 30.5, 30.5)) ~= nil, "rebuild on: a cell")
		schedule(surface.name, { kinds = { construction = false, rebuild = false } })
		fx.chest(surface, 90.5, 30.5, nil, "wooden-chest").die()
	end)
	ctx.at(90, function()
		ctx.expect(ct.discovery.cell(wid(surface, "construction", 90.5, 30.5)) == nil, "rebuild off: no cell")
		local force = game.forces.player
		-- luacheck: ignore 122
		force.create_ghost_on_entity_death = was
	end)
end)

t.case("G3 an unschedulable surface records cells but scans them only once it becomes schedulable", function(ctx)
	local surface, w
	ctx.at(90, function()
		surface = fx.surface("ctv2-dis-9")
		fx.ground(surface, -10, -10, 40, 30)
		fx.ghost(surface, 10.5, 10.5)
		w = wid(surface, "construction", 10.5, 10.5)
		ctx.expect(ct.discovery.cell(w) ~= nil, "cell recorded")
		ctx.expect(ct.discovery.record(w) == nil, "no record while unschedulable")
		ctx.expect(storage.ctron_pluginv2.scan[w] == nil, "not queued")
	end)
	ctx.at(500, function()
		ctx.expect(ct.discovery.cell(w).scanned == nil, "still unscanned")
		schedule(surface.name)
		ctx.expect(storage.ctron_pluginv2.scan[w] == true, "queued once schedulable")
		scanned(ctx, 501, w, function(r)
			ctx.expect(r.n == 1, "scanned: n " .. tostring(r.n))
		end)
	end)
end)

t.case("G3 a scanned, clean cell on a surface that leaves the schedulable set is reported again when it returns", function(ctx)
	local surface, w
	ctx.at(100, function()
		surface = fx.surface("ctv2-dis-20")
		fx.ground(surface, -10, -10, 40, 30)
		schedule(surface.name)
		fx.ghost(surface, 10.5, 10.5)
		w = wid(surface, "construction", 10.5, 10.5)
		scanned(ctx, 101, w, function()
			-- one tick, so no flush clears the marks in between
			local all, rest = {}, {}
			for name in pairs(storage.ctron_pluginv2.schedulable) do
				all[#all + 1] = name
				if name ~= surface.name then
					rest[#rest + 1] = name
				end
			end
			ct.discovery.set_schedulable(rest)
			ctx.expect(ct.discovery.record(w) == nil, "left out of a snapshot")
			storage.ctron_pluginv2.dirty.cell[w] = nil -- what the snapshot's replace does
			ct.discovery.set_schedulable(all)
			ctx.expect(storage.ctron_pluginv2.dirty.cell[w] == true, "marked for report on return")
			ctx.expect(storage.ctron_pluginv2.scan[w] == nil, "a clean cell isn't rescanned")
			ctx.expect(ct.discovery.record(w).due == 0, "reported with its totals, assignable")
		end)
	end)
end)

t.case("G3 clear and forced rescans", function(ctx)
	local surface, w, wd, t0
	ctx.at(100, function()
		surface = fx.surface("ctv2-dis-10")
		fx.ground(surface, -10, -10, 90, 30)
		grass(surface, 49, 9, 51, 11)
		schedule(surface.name)
		fx.ghost(surface, 10.5, 10.5)
		tree(surface, 50, 10).order_deconstruction("player")
		w, wd = wid(surface, "construction", 10.5, 10.5), wid(surface, "deconstruction", 50, 10)
		ctx.expect(ct.discovery.cell(wd) ~= nil, "deconstruction cell")
		ct.discovery.clear({ surface = surface.name, kind = "deconstruction" })
		ctx.expect(ct.discovery.cell(wd) == nil and ct.discovery.cell(w) ~= nil, "only the deconstruction cell went")
		scanned(ctx, 101, w, function()
			t0 = game.tick
			ct.discovery.rescan_now({ w })
			local k = 0
			local function touch()
				k = k + 1
				fx.ghost(surface, 12.5 + 2 * k, 10.5)
				if k < 30 then
					ctx.at(game.tick - t.first_tick + 20, touch)
				end
			end
			touch()
			fx.wait(ctx, game.tick - t.first_tick + 1, 2400, "a forced scan under events", function()
				local c = ct.discovery.cell(w)
				return c and c.scanned and c.scanned >= t0
			end, function()
				ct.discovery.clear({ w })
				ctx.expect(ct.discovery.cell(w) == nil, "cleared by wid")
			end)
		end)
	end)
end)

t.case("G3 a deleted surface takes its cells with it", function(ctx)
	local surface, name
	ctx.at(110, function()
		surface = fx.surface("ctv2-dis-11")
		name = surface.name
		fx.ground(surface, -10, -10, 40, 30)
		fx.ghost(surface, 10.5, 10.5)
		ctx.expect(ct.discovery.has_cells(name), "a cell first")
		game.delete_surface(surface)
	end)
	ctx.at(130, function()
		for _, c in pairs(storage.ctron_pluginv2.cells) do
			ctx.expect(c.surface ~= name, "a cell is left on the deleted surface")
		end
		ctx.expect(ct.discovery.has_cells(name) == false, "has_cells")
	end)
end)

t.case("SP-7 discovery: one dense-forest strip, scanned over several visits within the entity budget", function(ctx)
	ctx.expect_file("ctronv2-spikes/sp7.txt")
	ctx.at(120, function()
		local surface = fx.surface("ctv2-dis-12")
		fx.ground(surface, -10, -10, 100, 90)
		grass(surface, 0, 0, 20, 82)
		schedule(surface.name)
		local planted = 0
		for i = 0, 19 do
			for j = 0, 26 do
				local tr = tree(surface, i + 0.5, 3 * j + 0.5)
				if tr then
					tr.order_deconstruction("player")
					planted = planted + 1
				end
			end
		end
		tree(surface, 79.5, 0.5).order_deconstruction("player") -- widens the cell to four strips
		ctx.at(121, function()
			local w = wid(surface, "deconstruction", 0.5, 0.5)
			local c = ct.discovery.cell(w)
			ctx.expect(c ~= nil, "cell")
			ct.discovery.rescan_now({ w })
			local function counted()
				return c.acc and c.acc.n or c.n or 0
			end
			local visits, worst = 0, 0
			while not c.scanned and visits < 60 do
				local before = counted()
				local p = helpers.create_profiler()
				ct.discovery.visit(w)
				p.stop()
				visits = visits + 1
				local got = counted() - before
				fx.note("sp7", "discovery visit ", visits, ": ", got, " entities, ", p)
				worst = math.max(worst, got)
			end
			ctx.expect(c.scanned and c.n == planted + 1, "exact total: n " .. tostring(c.n) .. " of " .. (planted + 1))
			ctx.expect(worst <= ct.discovery.ENTITY_BUDGET, "no visit scans more than the budget: " .. worst)
			ctx.expect(visits >= 3, "scanned over several visits: " .. visits)
			fx.note("sp7", "discovery strip scan: ", planted, " planted, ", visits, " visits, at most ", worst, " per visit")
			ct.discovery.clear({ w })
		end)
	end)
end)

t.case("G3 a finished scan shrinks the cell's area to the remaining work", function(ctx)
	ctx.at(130, function()
		local surface = fx.surface("ctv2-dis-13")
		fx.ground(surface, -10, -10, 90, 30)
		schedule(surface.name)
		fx.ghost(surface, 10.5, 10.5)
		local far = fx.ghost(surface, 70.5, 10.5)
		local w = wid(surface, "construction", 10.5, 10.5)
		scanned(ctx, 131, w, function(r)
			ctx.expect(r.n == 2 and r.area.right_bottom.x == 70.5, "full area first: " .. serpent.line(r.area))
			ctx.expect(far.revive(), "far ghost built")
			local t0 = game.tick
			ct.discovery.rescan_now({ w })
			fx.wait(ctx, t0 - t.first_tick + 1, 2400, "the forced rescan", function()
				local c = ct.discovery.cell(w)
				return c.scanned and c.scanned >= t0
			end, function()
				local r2 = ct.discovery.record(w)
				ctx.expect(r2.n == 1 and r2.area.left_top.x == 10.5 and r2.area.right_bottom.x == 10.5,
					"area shrank to the remaining ghost: " .. serpent.line(r2.area))
			end)
		end)
	end)
end)
