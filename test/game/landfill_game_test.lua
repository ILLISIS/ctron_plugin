local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ct = require("modules/ctron_pluginv2/ct")
local events_of, cid_of, share, assign, charge = fx.events_of, fx.cid_of, fx.share, fx.assign, fx.charge

-- G13 (P2 Task 9): landfill on a lake: reduced roboports while walking, full at the task, and SP-17 (nearest-first
-- picks with 0.8 x radius stand points filling a lake from the shore).

--- A surface with a station at (0, 0) holding `landfill` in chests, and an idle ctron beside it.
local function setup(c, name, landfill)
	c.surface = fx.paved(name, -40, -50, 120, 50)
	c.station = fx.station(c.surface, 0, 0, { ["construction-robot"] = 60, landfill = math.min(landfill, 2400) })
	if landfill > 2400 then
		fx.chest(c.surface, 5, 2, { landfill = landfill - 2400 })
	end
	c.v = fx.ctron(c.surface, -6, 0, { robots = 10 })
end

--- Water over (x1, y1)-(x2, y2) (exclusive right/bottom) with a landfill ghost on each tile.
local function lake(surface, x1, y1, x2, y2)
	local tiles, n = {}, 0
	for x = x1, x2 - 1 do
		for y = y1, y2 - 1 do
			tiles[#tiles + 1] = { name = "water", position = { x, y } }
		end
	end
	surface.set_tiles(tiles)
	for x = x1, x2 - 1 do
		for y = y1, y2 - 1 do
			surface.create_entity({ name = "tile-ghost", inner_name = "landfill", position = { x, y },
				force = "player", raise_built = true })
			n = n + 1
		end
	end
	return n
end

local function start(c, jid, x1, y1, x2, y2, n)
	charge(c.v)
	ct.registry.set_state(cid_of(c.v), "idle")
	assign(jid, "construction", c.surface, { c.v }, c.station,
		{ share(c.surface, "construction", x1, y1, x2, y2, { { "landfill", "normal", n, 100 } }, 0) })
end

--- The ctron's roboport names, as a set.
local function port_names(v)
	local names = {}
	for _, eq in pairs(v.grid.equipment) do
		if eq.type == "roboport-equipment" then
			names[eq.name] = true
		end
	end
	return names
end

local function reduced(names)
	for name in pairs(names) do
		if name:match("%-reduced%-1$") then
			return true
		end
	end
	return false
end

t.case("G13 reduced roboports while walking", function(ctx)
	local c = {}
	local walk, task, seen_walk, seen_task = {}, {}, 0, 0
	ctx.at(10, function()
		setup(c, "ctv2-g13-pond", 300)
		c.n = lake(c.surface, 45, -5, 55, 5)
	end)
	ctx.at(14, function()
		start(c, "g13-pond", 43, -7, 57, 7, c.n + 100)
	end)
	fx.wait(ctx, 16, 12000, "the done event", function()
		charge(c.v)
		local run = ct.runs.get(cid_of(c.v))
		if run and c.v.valid then
			local names = port_names(c.v)
			if run.state == "to_work" then
				seen_walk = seen_walk + 1
				if not (reduced(names) and c.v.enable_logistics_while_moving == true) then
					walk[#walk + 1] = game.tick .. " " .. serpent.line(names)
				end
			elseif run.state == "at_task" then
				seen_task = seen_task + 1
				if reduced(names) then
					task[#task + 1] = game.tick .. " " .. serpent.line(names)
				end
			end
		end
		return #events_of("g13-pond", "done") > 0 or #events_of("g13-pond", "failed") > 0
	end, function()
		ctx.expect(#events_of("g13-pond", "done") > 0, "the run ended done")
		ctx.expect(seen_walk > 0 and seen_task > 0, "both states seen: " .. seen_walk .. "/" .. seen_task)
		ctx.expect(#walk == 0, "reduced and logistics on in to_work: " .. serpent.line(walk))
		ctx.expect(#task == 0, "full size in at_task: " .. serpent.line(task))
		ctx.expect(c.surface.count_entities_filtered({ type = "tile-ghost" }) == 0, "no tile-ghost is left")
		ctx.expect(c.surface.count_tiles_filtered({ name = "landfill", area = { { 45, -5 }, { 55, 5 } } }) == 100,
			"every pond tile is landfill")
		ctx.expect(not reduced(port_names(c.v)), "roboports at base names after done")
		ctx.expect(c.v.enable_logistics_while_moving == false, "logistics while moving is off after done")
	end)
end)

-- SP-17 runs as the cluster does it: a run ends, discovery rescans the lake's cells, the controller assigns the
-- remaining work again (a share per cell, from the cell's record), until no ghost is left or a pass fills nothing.
local PASSES = 8

--- Make the surface schedulable, keeping every other case's settings (as discovery_game_test).
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

--- The surface's construction cells, as wid = last scanned tick (false before any scan).
local function lake_cells(surface)
	local out = {}
	for wid, cell in pairs(storage.ctron_pluginv2.cells) do
		if cell.surface == surface.name and cell.kind == "construction" then
			out[wid] = cell.scanned or false
		end
	end
	return out
end

local function ghosts_of(surface)
	return surface.count_entities_filtered({ type = "tile-ghost" })
end

t.case("G13 SP-17 the lake fills over repeated jobs", function(ctx)
	local c, passes = {}, {}
	local stand_on_water = {}
	local over = { leave_work = true, returning = true, unloading = true, to_station = true }

	--- Rescan every cell, wait for the scans, assign the remaining work; then follow the run to its end.
	local function pass(k, at)
		local before = lake_cells(c.surface)
		local wids = {}
		for wid in pairs(before) do
			wids[#wids + 1] = wid
		end
		ct.discovery.rescan_now(wids)
		fx.wait(ctx, at + 1, 3000, "the rescan of pass " .. k, function()
			for wid, was in pairs(before) do
				local r = ct.discovery.record(wid)
				if r and not (r.scanned and r.scanned ~= was and r.due == 0) then
					return false
				end
			end
			return true
		end, function(at2)
			local work, n, left = {}, 0, ghosts_of(c.surface)
			for _, wid in ipairs(wids) do
				local r = ct.discovery.record(wid)
				if r and r.n and r.n > 0 then
					work[#work + 1] = { wid = wid, key = storage.ctron_pluginv2.cells[wid].key, area = r.area,
						bring = r.bring, out = r.out }
					n = n + r.n
				end
			end
			local p = { k = k, before = left, cells = #work, tasks = 0 }
			passes[k] = p
			charge(c.v)
			local have = fx.trunk_of(c.v).get_item_count("landfill")
			if have > n then
				fx.trunk_of(c.v).remove({ name = "landfill", count = have - n })
			end
			ct.registry.set_state(cid_of(c.v), "idle")
			assign("g13-lake-" .. k, "construction", c.surface, { c.v }, c.station, work)
			p.start, p.areas = game.tick, serpent.line((work[1] or {}).area, { compact = true })
			local last
			fx.wait(ctx, at2 + 1, 30000, "pass " .. k .. " ending", function()
				charge(c.v)
				local run = ct.runs.get(cid_of(c.v))
				if run and (run.state == "to_station" or run.state == "loading") then
					-- The station's 10 logistic robots deliver ~40 landfill per 1000 ticks, and an idle ctron's
					-- unrequested landfill goes to its trash: stand in for the delivery until loading is done.
					local short = n - fx.trunk_of(c.v).get_item_count("landfill")
					if short > 0 then
						fx.trunk_of(c.v).insert({ name = "landfill", count = short })
					end
				end
				if run and run.state ~= last then
					last = run.state
					fx.note("sp17", "  p", k, " ", game.tick, " ", run.state, " ", tostring(run.status), " ghosts ", ghosts_of(c.surface))
					if run.state == "at_task" then
						local pos = c.v.position
						local tile = c.surface.get_tile(pos.x, pos.y).name
						p.tasks = p.tasks + 1
						if tile == "water" then
							stand_on_water[#stand_on_water + 1] = serpent.line(pos)
						end
					end
				end
				if run and run.state == "to_work" then
					p.worked = true
				end
				if run and p.worked and over[run.state] and not p.work_end then
					p.work_end = game.tick
				end
				if run and p.work_end then
					-- Leftover landfill goes back through the station's 10 logistic robots (~40,000 ticks); this
					-- case is about the fill, so the trunk is emptied and the run unloads at once.
					fx.trunk_of(c.v).remove({ name = "landfill", count = 100000 })
				end
				return #events_of("g13-lake-" .. k, "done") + #events_of("g13-lake-" .. k, "failed") > 0
			end, function(at3)
				p.after, p.ticks = ghosts_of(c.surface), (p.work_end or game.tick) - p.start
				p.filled = p.before - p.after
				fx.note("sp17", "pass ", k, " cells ", p.cells, " tasks ", p.tasks, " ghosts ", p.before, " -> ", p.after,
					" filled ", p.filled, " work ticks ", p.ticks, " area ", p.areas)
				if p.after == 0 or p.filled <= 0 or k >= PASSES then
					ctx.expect(#stand_on_water == 0, "every stand point was on land: " .. serpent.line(stand_on_water))
					ctx.expect(passes[1].filled > 0, "pass 1 filled something")
					ctx.expect(p.after == 0, "the lake is filled within " .. PASSES .. " passes: " .. k .. " passes, " ..
						p.after .. " ghosts left, last pass filled " .. p.filled)
				else
					pass(k + 1, at3)
				end
			end)
		end)
	end

	ctx.at(10, function()
		setup(c, "ctv2-g13-lake", 1000)
		c.n = lake(c.surface, 40, -15, 70, 15)
		schedule(c.surface.name)
	end)
	ctx.at(20, function()
		pass(1, 20)
	end)
end)
