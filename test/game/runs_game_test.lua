local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local util = require("util")
local ct = require("modules/ctron_pluginv2/ct")
local discovery = require("modules/ctron_pluginv2/discovery")
local events_of, cid_of, share, assign = fx.events_of, fx.cid_of, fx.share, fx.assign
local charge, paved, trunk_of = fx.charge, fx.paved, fx.trunk_of

-- The wids every rescan_now was called with; the original still runs.
local rescanned = {}
local real_rescan = discovery.rescan_now
discovery.rescan_now = function(wids)
	for _, wid in ipairs(wids) do
		rescanned[wid] = true
	end
	return real_rescan(wids)
end

--- Wait until the ctron is idle again (its run released), then call done(offset).
local function idle(ctx, from, v, done)
	fx.wait(ctx, from, 600, "the ctron idle again", function()
		charge(v)
		local rec = ct.registry.ctron(cid_of(v))
		return rec and rec.state == "idle"
	end, done)
end

-- G9 (P2 Task 4): one tile, assign to done; the adopt rejections; a destroyed worker.

local function setup(c, name, items)
	c.surface = paved(name, -40, -40, 110, 40)
	c.station = fx.station(c.surface, 0, 0, items or { ["construction-robot"] = 60, ["wooden-chest"] = 50 })
	c.v = fx.ctron(c.surface, -6, 0, { robots = 10 })
end

local function start(c)
	charge(c.v)
	ct.registry.set_state(cid_of(c.v), "idle")
end

t.case("G9 construction assign to done", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g9-build")
		c.ghosts = {}
		for i = 1, 6 do
			c.ghosts[i] = fx.ghost(c.surface, 49.5 + i * 2, 0.5)
		end
	end)
	ctx.at(14, function()
		start(c)
		c.cid = cid_of(c.v)
		c.share = share(c.surface, "construction", 45, -5, 65, 5, { { "wooden-chest", "normal", 6 } }, 0)
		assign("g9-build", "construction", c.surface, { c.v }, c.station, { c.share })
	end)
	fx.wait(ctx, 16, 8000, "the done event", function()
		charge(c.v)
		return #events_of("g9-build", "done") > 0
	end, function()
		local built = c.surface.count_entities_filtered({ name = "wooden-chest" })
		ctx.expect(built == 6, "6 chests built: " .. built)
		ctx.expect(c.surface.count_entities_filtered({ type = "entity-ghost" }) == 0, "no ghost left")
		local f = events_of("g9-build", "done")[1].fields
		ctx.expect(f.cid == c.cid, "the event carries the cid")
		ctx.expect(type(f.left) == "number", "left is a number: " .. tostring(f.left))
		ctx.expect(storage.ctron_pluginv2.runs[c.cid] == nil, "the run is gone")
		ctx.expect(ct.registry.ctron(c.cid).state == "idle", "idle again: " .. ct.registry.ctron(c.cid).state)
		ctx.expect(rescanned[c.share.wid], "the cell was rescanned")
	end)
end)

t.case("G9 deconstruction bigger than the trunk as two assigns", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g9-decon")
		-- More storage beside the station's own chest, for the armour that comes back.
		for _, p in ipairs({ { 5, -3 }, { 5, 3 }, { 8, -3 }, { 8, 3 }, { 8, 0 } }) do
			fx.chest(c.surface, p[1], p[2])
		end
		c.size = #trunk_of(c.v)
		c.total = math.min(c.size + 16, 96)
		ctx.expect(c.total > c.size, "the armour (" .. c.total .. ") outgrows the trunk (" .. c.size .. ")")
		c.chests = {
			fx.chest(c.surface, 52, 0, { ["modular-armor"] = math.ceil(c.total / 2) }, "steel-chest"),
			fx.chest(c.surface, 54, 0, { ["modular-armor"] = math.floor(c.total / 2) }, "steel-chest"),
		}
		for _, chest in ipairs(c.chests) do
			chest.order_deconstruction(game.forces.player)
		end
	end)
	ctx.at(14, function()
		start(c)
		assign("g9-decon-1", "deconstruction", c.surface, { c.v }, c.station,
			{ share(c.surface, "deconstruction", 45, -5, 60, 5, {}, c.size - 10) })
	end)
	fx.wait(ctx, 16, 12000, "the first done event", function()
		charge(c.v)
		return #events_of("g9-decon-1", "done") > 0
	end, function(k)
		idle(ctx, k + 2, c.v, function(k2)
			assign("g9-decon-2", "deconstruction", c.surface, { c.v }, c.station,
				{ share(c.surface, "deconstruction", 45, -5, 60, 5, {}, c.size - 10) })
			fx.wait(ctx, k2 + 2, 12000, "the second done event", function()
				charge(c.v)
				return #events_of("g9-decon-2", "done") > 0
			end, function()
				ctx.expect(not c.chests[1].valid and not c.chests[2].valid, "both chests are gone")
				ctx.expect(#events_of("g9-decon-1", "done") == 1 and #events_of("g9-decon-2", "done") == 1,
					"two done events")
			end)
		end)
	end)
end)

t.case("G9 adopt rejects an unfit ctron and reports it unfit", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g9-unfit")
	end)
	ctx.at(14, function()
		start(c)
		for _, eq in pairs(c.v.grid.equipment) do
			if eq.type == "roboport-equipment" then
				c.v.grid.take({ equipment = eq })
			end
		end
	end)
	ctx.at(18, function()
		assign("g9-unfit", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 45, -5, 60, 5, { { "wooden-chest", "normal", 1 } }, 0) })
	end)
	ctx.at(22, function()
		local rejected = events_of("g9-unfit", "rejected")
		ctx.expect(#rejected == 1 and rejected[1].fields.why == "no_roboports", "rejected no_roboports: " .. serpent.line(rejected))
		ctx.expect(storage.ctron_pluginv2.runs[cid_of(c.v)] == nil, "no run")
		ctx.expect(ct.registry.ctron(cid_of(c.v)).state == "unfit", "unfit: " .. ct.registry.ctron(cid_of(c.v)).state)
	end)
end)

t.case("G9 adopt rejects a full trunk with why full", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g9-full")
		local trunk = trunk_of(c.v)
		trunk.insert({ name = "stone", count = trunk.count_empty_stacks() * 50 })
	end)
	ctx.at(14, function()
		start(c)
		ctx.expect(trunk_of(c.v).count_empty_stacks() == 0, "the trunk is full")
		assign("g9-full", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 45, -5, 60, 5, {}, 10) })
	end)
	ctx.at(18, function()
		local rejected = events_of("g9-full", "rejected")
		ctx.expect(#rejected == 1 and rejected[1].fields.why == "full", "rejected full: " .. serpent.line(rejected))
		ctx.expect(storage.ctron_pluginv2.runs[cid_of(c.v)] == nil, "no run")
	end)
end)

t.case("G9 a destroyed worker ends lost", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g9-lost")
		fx.ghost(c.surface, 100.5, 30.5)
	end)
	ctx.at(14, function()
		start(c)
		c.cid = cid_of(c.v)
		assign("g9-lost", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 90, 20, 100, 30, { { "wooden-chest", "normal", 1 } }, 0) })
	end)
	fx.wait(ctx, 16, 6000, "the run in to_work", function()
		charge(c.v)
		local run = ct.runs.get(c.cid)
		return run and run.state == "to_work"
	end, function(k)
		c.v.die()
		ctx.at(k + 10, function()
			local lost = events_of("g9-lost", "lost")
			ctx.expect(#lost == 1 and lost[1].fields.cid == c.cid, "one lost event: " .. serpent.line(lost))
			ctx.expect(storage.ctron_pluginv2.runs[c.cid] == nil, "the run is gone")
		end)
	end)
end)

t.case("G9 adopt rejects a running ctron as busy without touching its state", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g9-busy")
		fx.ghost(c.surface, 100.5, 30.5)
	end)
	ctx.at(14, function()
		start(c)
		assign("g9-busy-1", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 90, 20, 100, 30, { { "wooden-chest", "normal", 1 } }, 0) })
	end)
	ctx.at(20, function()
		-- Take the roboports out while it runs: a fitness check first would now mark it unfit (and drop the job).
		for _, eq in pairs(c.v.grid.equipment) do
			if eq.type == "roboport-equipment" then
				c.v.grid.take({ equipment = eq })
			end
		end
	end)
	ctx.at(24, function()
		assign("g9-busy-2", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 90, 20, 100, 30, { { "wooden-chest", "normal", 1 } }, 0) })
	end)
	ctx.at(28, function()
		local rejected = events_of("g9-busy-2", "rejected")
		ctx.expect(#rejected == 1 and rejected[1].fields.why == "busy", "rejected busy: " .. serpent.line(rejected))
		local rec = ct.registry.ctron(cid_of(c.v))
		ctx.expect(rec.state == "busy" and rec.jid == "g9-busy-1", "state untouched: " .. serpent.line({ rec.state, rec.jid }))
		ctx.expect(ct.runs.get(cid_of(c.v)) ~= nil, "the run goes on")
	end)
end)

-- G9 (P2 Task 5): cancel, station change, drop, detail, unknown in transit.

local function place_of(station)
	return { sid = cid_of(station), inst = ct.registry.here(), x = station.position.x, y = station.position.y }
end

t.case("G9 cancel sends the run home and ends done", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g9-cancel")
		fx.ghost(c.surface, 60.5, 0.5)
	end)
	ctx.at(14, function()
		start(c)
		c.cid = cid_of(c.v)
		assign("g9-cancel", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 55, -5, 65, 5, { { "wooden-chest", "normal", 1 } }, 0) })
	end)
	ctx.at(400, function()
		charge(c.v)
		fx.send("ct.job.cancel", { jid = "g9-cancel" })
	end)
	fx.wait(ctx, 402, 4000, "the done event", function()
		charge(c.v)
		return #events_of("g9-cancel", "done") > 0
	end, function()
		ctx.expect(storage.ctron_pluginv2.runs[c.cid] == nil, "the run is gone")
		ctx.expect(ct.registry.ctron(c.cid).state == "idle", "idle again")
	end)
end)

t.case("G9 cancel for a job this tile doesn't hold answers unknown", function(ctx)
	ctx.at(10, function()
		fx.send("ct.job.cancel", { jid = "nope.1" })
	end)
	ctx.at(14, function()
		ctx.expect(#events_of("nope.1", "unknown") == 1, "one unknown event")
	end)
end)

t.case("G9 cancel_kind cancels that kind's runs on that surface only", function(ctx)
	local a, b = {}, {}
	ctx.at(10, function()
		setup(a, "ctv2-g9-ck-a")
		setup(b, "ctv2-g9-ck-b")
		fx.ghost(a.surface, 60.5, 0.5)
		fx.ghost(b.surface, 60.5, 0.5)
	end)
	ctx.at(14, function()
		for _, c in ipairs({ a, b }) do
			start(c)
			c.cid = cid_of(c.v)
		end
		assign("g9-ck-a", "construction", a.surface, { a.v }, a.station,
			{ share(a.surface, "construction", 55, -5, 65, 5, { { "wooden-chest", "normal", 1 } }, 0) })
		assign("g9-ck-b", "construction", b.surface, { b.v }, b.station,
			{ share(b.surface, "construction", 55, -5, 65, 5, { { "wooden-chest", "normal", 1 } }, 0) })
	end)
	ctx.at(60, function()
		ct.runs.cancel_kind(a.surface.name, "construction")
		local ra, rb = ct.runs.get(a.cid), ct.runs.get(b.cid)
		ctx.expect(ra and ra.state == "returning" and ra.cancelled == true, "surface 1 returning, cancelled")
		ctx.expect(rb and rb.state ~= "returning" and not rb.cancelled, "surface 2 untouched")
	end)
end)

t.case("G9 messages to a run in transit answer unknown", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g9-transit")
		fx.ghost(c.surface, 60.5, 0.5)
	end)
	ctx.at(14, function()
		start(c)
		c.cid = cid_of(c.v)
		assign("g9-transit", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 55, -5, 65, 5, { { "wooden-chest", "normal", 1 } }, 0) })
	end)
	ctx.at(15, function()
		c.run = storage.ctron_pluginv2.runs[c.cid]
		c.run.in_transit = true
		c.state, c.load = c.run.state, serpent.line(c.run.load)
		fx.send("ct.job.cancel", { jid = "g9-transit" })
		fx.send("ct.job.station", { jid = "g9-transit", cid = c.cid, station = place_of(c.station), why = "short" })
		fx.send("ct.job.drop", { jid = "g9-transit", surface = c.surface.name, name = "wooden-chest",
			quality = "normal" })
	end)
	ctx.at(17, function()
		ctx.expect(#events_of("g9-transit", "unknown") == 3, "three unknown events: " .. #events_of("g9-transit", "unknown"))
		ctx.expect(c.run.state == c.state and serpent.line(c.run.load) == c.load, "state and load unchanged")
		c.run.in_transit = nil
	end)
end)

--- Two stations on one surface: A (robots only) and B (30 tiles east, robots and 10 wooden chests).
local function two_stations(c, name)
	c.surface = paved(name, -40, -40, 110, 40)
	c.station = fx.station(c.surface, 0, 0, { ["construction-robot"] = 60 })
	c.station_b = fx.station(c.surface, -30, 20, { ["construction-robot"] = 60, ["wooden-chest"] = 10 }) -- out of the ghost's reach
	c.v = fx.ctron(c.surface, -6, 0, { robots = 10 })
	fx.ghost(c.surface, 60.5, 0.5)
end

t.case("G9 a new station while loading walks there and loads", function(ctx)
	local c = {}
	ctx.at(10, function()
		two_stations(c, "ctv2-g9-station")
	end)
	ctx.at(14, function()
		start(c)
		c.cid = cid_of(c.v)
		assign("g9-station", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 55, -5, 65, 5, { { "wooden-chest", "normal", 10 } }, 0) })
	end)
	fx.wait(ctx, 16, 3000, "the run loading at A", function()
		charge(c.v)
		local run = ct.runs.get(c.cid)
		return run and run.state == "loading"
	end, function(k)
		ctx.at(k + 2, function()
			fx.send("ct.job.station", { jid = "g9-station", cid = c.cid, station = place_of(c.station_b),
				why = "short" })
		end)
		ctx.at(k + 4, function()
			ctx.expect(ct.runs.get(c.cid).station.sid == cid_of(c.station_b), "the run's station is B")
		end)
		fx.wait(ctx, k + 6, 4000, "the run leaving loading", function()
			charge(c.v)
			local run = ct.runs.get(c.cid)
			return run and run.state ~= "loading" and run.state ~= "to_station"
		end)
	end)
end)

t.case("G9 drop lets a loading run go with what it has", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g9-drop", { ["construction-robot"] = 60, ["wooden-chest"] = 4 })
		fx.ghost(c.surface, 60.5, 0.5)
	end)
	ctx.at(14, function()
		start(c)
		c.cid = cid_of(c.v)
		assign("g9-drop", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 55, -5, 65, 5, { { "wooden-chest", "normal", 10 } }, 0) })
	end)
	fx.wait(ctx, 16, 3000, "the run loading", function()
		charge(c.v)
		local run = ct.runs.get(c.cid)
		return run and run.state == "loading"
	end, function(k)
		ctx.at(k + 600, function()
			fx.send("ct.job.drop", { jid = "g9-drop", surface = c.surface.name, name = "wooden-chest",
				quality = "normal" })
		end)
		ctx.at(k + 604, function()
			local run = ct.runs.get(c.cid)
			ctx.expect(run.load["wooden-chest"] and run.load["wooden-chest"].normal == 4,
				"load is 4: " .. serpent.line(run.load))
		end)
		fx.wait(ctx, k + 606, 1200, "the run leaving loading", function()
			charge(c.v)
			local run = ct.runs.get(c.cid)
			return run and run.state ~= "loading"
		end)
	end)
end)

t.case("G9 detail lists members, requests and tasks under 3 KB", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g9-detail", { ["construction-robot"] = 60, ["wooden-chest"] = 4 })
		fx.ghost(c.surface, 60.5, 0.5)
	end)
	ctx.at(14, function()
		start(c)
		c.cid = cid_of(c.v)
		assign("g9-detail", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 55, -5, 65, 5, { { "wooden-chest", "normal", 10 } }, 0) })
	end)
	fx.wait(ctx, 16, 3000, "the run loading", function()
		charge(c.v)
		local run = ct.runs.get(c.cid)
		return run and run.state == "loading"
	end, function(k)
		ctx.at(k + 60, function()
			local d = ct.runs.detail("g9-detail")
			ctx.expect(d and #d.members == 1 and d.members[1].cid == c.cid, "one member")
			local found
			for _, r in ipairs(d.members[1].requests) do
				if r[1] == "wooden-chest" and r[2] == "normal" and r[3] == 10 and type(r[4]) == "number" then
					found = true
				end
			end
			ctx.expect(found, "the chest request: " .. serpent.line(d.members[1].requests))
			ctx.expect(#d.tasks > 0, "tasks listed")
			ctx.expect(#helpers.table_to_json(d) <= 3000, "under 3 KB")
			ctx.expect(ct.runs.detail("nope.1") == nil, "nil for an unknown job")
		end)
	end)
end)

-- A loading run on a station with 4 wooden chests, for the drop and detail cases below.
local function loading_run(ctx, c, name, after)
	ctx.at(10, function()
		setup(c, name, { ["construction-robot"] = 60, ["wooden-chest"] = 4 })
		fx.ghost(c.surface, 60.5, 0.5)
	end)
	ctx.at(14, function()
		start(c)
		c.cid = cid_of(c.v)
		c.jid = name
		assign(name, "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 55, -5, 65, 5, { { "wooden-chest", "normal", 10 } }, 0) })
	end)
	fx.wait(ctx, 16, 3000, "the run loading", function()
		charge(c.v)
		local run = ct.runs.get(c.cid)
		return run and run.state == "loading"
	end, after)
end

t.case("G9 drop only lowers or removes the lines the run asked for", function(ctx)
	local c = {}
	loading_run(ctx, c, "ctv2-g9-drop2", function(k)
		ctx.at(k + 600, function()
			local run = ct.runs.get(c.cid)
			local held = ct.logistics.held(c.v)["wooden-chest"].normal
			ctx.expect(held > 0, "the ctron holds chests: " .. held)
			-- A quality that was never requested gets no line, even though the ctron holds that name.
			run.load["wooden-chest"] = { normal = 10 }
			ct.runs.drop(c.jid, c.surface.name, "wooden-chest", "rare")
			ctx.expect(serpent.line(run.load["wooden-chest"]) == serpent.line({ normal = 10 }),
				"unrequested quality untouched: " .. serpent.line(run.load))
			-- Never raised above the want.
			run.load["wooden-chest"] = { normal = 1 }
			ct.runs.drop(c.jid, c.surface.name, "wooden-chest", "normal")
			ctx.expect(run.load["wooden-chest"].normal == 1, "not raised: " .. serpent.line(run.load))
			-- A drop of "any" quality lowers the line of every quality to what is held.
			run.load["wooden-chest"] = { normal = 10 }
			ct.runs.drop(c.jid, c.surface.name, "wooden-chest", "any")
			ctx.expect(run.load["wooden-chest"] and run.load["wooden-chest"].normal == held,
				"lowered to what is held: " .. serpent.line(run.load))
			-- Nothing held: the line goes.
			run.load["iron-plate"] = { normal = 5 }
			ct.runs.drop(c.jid, c.surface.name, "iron-plate", "normal")
			ctx.expect(run.load["iron-plate"] == nil, "emptied name removed")
		end)
	end)
end)

t.case("G9 detail stays under 3 KB with a big squad and keeps the leader", function(ctx)
	local c = {}
	loading_run(ctx, c, "ctv2-g9-bigsquad", function(k)
		ctx.at(k + 20, function()
			local lead = ct.runs.get(c.cid)
			local names = {}
			for name in pairs(prototypes.item) do
				names[#names + 1] = name
				if #names >= 30 then
					break
				end
			end
			for i = 1, 10 do
				local v = fx.ctron(c.surface, -6, 2 + i * 2, { robots = 0 })
				for _, name in ipairs(names) do
					v.get_inventory(defines.inventory.spider_trunk).insert({ name = name, count = 1 })
				end
				local r = util.table.deepcopy(lead)
				r.cid, r.role, r.unit, r.next = cid_of(v), "minion", v.unit_number, nil
				storage.ctron_pluginv2.runs[r.cid] = r
			end
			local d = ct.runs.detail(c.jid)
			ctx.expect(#helpers.table_to_json(d) <= 3000, "under 3 KB: " .. #helpers.table_to_json(d))
			ctx.expect(d.members[1].cid == c.cid, "the leader stays first")
			ctx.expect(#d.members >= 1 and #d.members < 11, "members trimmed: " .. #d.members)
		end)
	end)
end)

t.case("G9 balance_ammo never destroys wanted ammo when another ammo can't move to the trunk", function(ctx)
	local c = {}
	ctx.at(10, function()
		c.surface = paved("ctv2-g9-balance", -40, -40, 110, 40)
		c.v = fx.ctron(c.surface, 0, 0, { robots = 0 })
		local ammo = c.v.get_inventory(defines.inventory.spider_ammo)
		ammo[1].set_stack({ name = "explosive-rocket", count = 10 })
		ammo[2].set_stack({ name = "rocket", count = 60 })
		ammo[3].set_stack({ name = "rocket", count = 40 })
		c.v.get_inventory(defines.inventory.spider_trunk).insert({ name = "stone", count = 100000 })
		local cfg = util.table.deepcopy(ct.settings.of(c.surface.name))
		cfg.ammo, cfg.ammo_count = { "rocket", "normal" }, 100
		ct.runs.balance_ammo(c.v, cfg)
		ctx.expect(ammo.get_item_count("rocket") == 100, "no rocket lost: " .. ammo.get_item_count("rocket"))
		ctx.expect(ammo.get_item_count("explosive-rocket") == 10, "the other ammo stays: no room in the trunk")
		-- D8, R-206: with ammo_count 0 a bomb in a launcher still goes to the trunk.
		local w = fx.ctron(c.surface, 10, 0, { robots = 0 })
		w.get_inventory(defines.inventory.spider_ammo)[1].set_stack({ name = "atomic-bomb", count = 1 })
		cfg.ammo_count = 0
		ct.runs.balance_ammo(w, cfg)
		ctx.expect(fx.trunk_of(w).get_item_count("atomic-bomb") == 1, "the bomb is in the trunk")
		ctx.expect(w.get_inventory(defines.inventory.spider_ammo).get_item_count("atomic-bomb") == 0, "and out of the launcher")
		-- The owner's load: a bomb held a slot, so 300 rockets went to the slots and 100 to the trunk. All 400 end up in
		-- the launchers, 100 each, and the bomb in the trunk.
		local o = fx.ctron(c.surface, 20, 0, { robots = 0 })
		local oa = o.get_inventory(defines.inventory.spider_ammo)
		oa[1].set_stack({ name = "atomic-bomb", count = 10 })
		for k = 2, 4 do oa[k].set_stack({ name = "rocket", count = 100 }) end
		fx.trunk_of(o).insert({ name = "rocket", count = 100 })
		cfg.ammo_count = 400
		ct.runs.balance_ammo(o, cfg)
		local each = {}
		for k = 1, #oa do each[k] = oa[k].valid_for_read and oa[k].name .. ":" .. oa[k].count or "-" end
		ctx.expect(table.concat(each, " ") == "rocket:100 rocket:100 rocket:100 rocket:100", "400 in the launchers: "
			.. table.concat(each, " "))
		ctx.expect(fx.trunk_of(o).get_item_count("rocket") == 0 and fx.trunk_of(o).get_item_count("atomic-bomb") == 10,
			"no rocket left in the trunk, the bombs there")
	end)
end)
