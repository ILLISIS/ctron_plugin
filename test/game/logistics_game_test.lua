local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ct = require("modules/ctron_pluginv2/ct")
local station = require("modules/ctron_pluginv2/gui/station") -- the cargo editor's save (R-192)
local events_of, cid_of, share, assign = fx.events_of, fx.cid_of, fx.share, fx.assign
local charge, paved, trunk_of = fx.charge, fx.paved, fx.trunk_of

--- Section 1 of the ctron's requester point.
local function section(v)
	return v.get_logistic_point(defines.logistic_member_index.spidertron_requester).get_section(1)
end

-- G7 (P2 Task 4): the request protocol over a whole loading and unloading.

t.case("G7 loading writes section 1, sees the deliveries and clears", function(ctx)
	local c = {}
	ctx.at(10, function()
		c.surface = paved("ctv2-g7-load", -40, -40, 110, 40)
		c.station = fx.station(c.surface, 0, 0, { ["construction-robot"] = 60, ["wooden-chest"] = 50 })
		c.v = fx.ctron(c.surface, -6, 0, { robots = 10 })
		trunk_of(c.v).insert({ name = "iron-plate", count = 20 })
	end)
	ctx.at(14, function()
		charge(c.v)
		ct.registry.set_state(cid_of(c.v), "idle")
		assign("g7-load", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 60, -5, 70, 5, { { "wooden-chest", "normal", 10 } }, 0) })
	end)
	fx.wait(ctx, 16, 600, "the run loading", function()
		charge(c.v)
		local run = ct.runs.get(cid_of(c.v))
		return run and run.state == "loading"
	end, function()
		local want = {}
		for _, f in ipairs(section(c.v).filters) do
			want[f.value.name] = { f.min, f.max }
		end
		local chest, robot, plate = want["wooden-chest"], want["construction-robot"], want["iron-plate"]
		ctx.expect(chest and chest[1] == 10 and chest[2] == 10, "wooden-chest 10/10: " .. serpent.line(want))
		ctx.expect(robot and robot[1] == 50 and robot[2] == 50, "construction-robot 50/50: " .. serpent.line(want))
		ctx.expect(plate and plate[1] == 0 and plate[2] == 0, "iron-plate 0/0: " .. serpent.line(want))
	end)
	fx.wait(ctx, 700, 3000, "the run left loading", function()
		charge(c.v)
		local run = ct.runs.get(cid_of(c.v))
		return run == nil or run.state ~= "loading"
	end, function()
		ctx.expect(section(c.v).filters_count == 0, "section 1 cleared")
		ctx.expect(trunk_of(c.v).get_item_count("wooden-chest") == 10, "10 wooden chests aboard")
		ctx.expect(trunk_of(c.v).get_item_count("iron-plate") == 0, "no iron plate in the trunk")
		ctx.expect(c.v.get_inventory(defines.inventory.spider_trash).get_item_count("iron-plate") == 0,
			"no iron plate in the trash")
	end)
end)

t.case("G7 unloading keeps robots while the tile has cells", function(ctx)
	local c = {}
	ctx.at(10, function()
		c.surface = paved("ctv2-g7-keep", -40, -40, 110, 40)
		c.station = fx.station(c.surface, 0, 0, { ["construction-robot"] = 60, ["wooden-chest"] = 50 })
		c.v = fx.ctron(c.surface, -6, 0, { robots = 10 })
		fx.ghost(c.surface, 100.5, 30.5) -- far away: its cell makes the tile "have cells" (R-36)
	end)
	ctx.at(14, function()
		charge(c.v)
		ct.registry.set_state(cid_of(c.v), "idle")
		assign("g7-keep", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 10, -5, 20, 5, { { "wooden-chest", "normal", 4 } }, 0) })
		ctx.expect(ct.discovery.has_cells(c.surface.name), "the tile has a cell")
		-- Four ghosts for the four chests.
		for i = 1, 4 do
			fx.ghost(c.surface, 12.5 + i * 2, 0.5)
		end
	end)
	fx.wait(ctx, 16, 8000, "the done event", function()
		charge(c.v)
		return #events_of("g7-keep", "done") > 0
	end, function()
		local trunk = trunk_of(c.v)
		ctx.expect(trunk.get_item_count("construction-robot") == 50, "50 robots kept: " .. trunk.get_item_count("construction-robot"))
		local other = {}
		for _, it in ipairs(trunk.get_contents()) do
			if it.name ~= "construction-robot" then
				other[#other + 1] = it.name
			end
		end
		ctx.expect(#other == 0, "nothing else aboard: " .. serpent.line(other))
	end)
end)

t.case("G7 unload with fewer robots than robot_count completes", function(ctx)
	local c = {}
	ctx.at(10, function()
		c.surface = paved("ctv2-g7-few", -40, -40, 110, 40)
		c.station = fx.station(c.surface, 0, 0, { ["construction-robot"] = 60, ["wooden-chest"] = 2 })
		c.v = fx.ctron(c.surface, -6, 0, { robots = 5 })
		fx.ghost(c.surface, 100.5, 30.5) -- cells exist, so the unload keeps robots (R-36)
	end)
	ctx.at(14, function()
		charge(c.v)
		ct.registry.set_state(cid_of(c.v), "idle")
		assign("g7-few", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 50, -5, 70, 5, { { "wooden-chest", "normal", 2 } }, 0) })
		fx.ghost(c.surface, 60.5, 0.5) -- outside the station's own construction area
		fx.ghost(c.surface, 62.5, 0.5)
	end)
	-- The run lost robots on the way (a ctron's robots can die): only 5 are aboard when it unloads.
	local shrunk
	fx.wait(ctx, 16, 6000, "a done event", function()
		charge(c.v)
		local run = ct.runs.get(cid_of(c.v))
		if run and run.state == "returning" and not shrunk then
			shrunk = true
			trunk_of(c.v).remove({ name = "construction-robot", count = 45 })
		end
		return #events_of("g7-few", "done") > 0
	end, function()
		ctx.expect(shrunk, "the robots were taken off before the unload")
	end)
end)

t.case("G7 a stray item put in the trunk during unloading still ends in done", function(ctx)
	local c = {}
	ctx.at(10, function()
		c.surface = paved("ctv2-g7-stray", -40, -40, 110, 40)
		c.station = fx.station(c.surface, 0, 0, { ["construction-robot"] = 60, ["wooden-chest"] = 2 })
		c.v = fx.ctron(c.surface, -6, 0, { robots = 10 })
		fx.ghost(c.surface, 100.5, 30.5)
	end)
	ctx.at(14, function()
		charge(c.v)
		ct.registry.set_state(cid_of(c.v), "idle")
		assign("g7-stray", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 50, -5, 70, 5, { { "wooden-chest", "normal", 2 } }, 0) })
		fx.ghost(c.surface, 60.5, 0.5)
		fx.ghost(c.surface, 62.5, 0.5)
	end)
	-- After the unload's requests are written, an item no request names arrives (a returning robot's haul).
	local dropped
	fx.wait(ctx, 16, 8000, "a done event", function()
		charge(c.v)
		local run = ct.runs.get(cid_of(c.v))
		if run and run.state == "unloading" and not dropped then
			dropped = true
			trunk_of(c.v).insert({ name = "stone", count = 30 })
		end
		return #events_of("g7-stray", "done") > 0
	end, function()
		ctx.expect(dropped, "the stray item was added during unloading")
		ctx.expect(trunk_of(c.v).get_item_count("stone") == 0, "the stray item left the trunk")
	end)
end)

t.case("G7 a stray item put in the trunk during loading leaves and the load completes", function(ctx)
	local c = {}
	ctx.at(10, function()
		c.surface = paved("ctv2-g7-stray-load", -40, -40, 110, 40)
		c.station = fx.station(c.surface, 0, 0, { ["construction-robot"] = 60, ["wooden-chest"] = 10 })
		c.v = fx.ctron(c.surface, -6, 0, { robots = 10 })
		fx.ghost(c.surface, 60.5, 0.5)
	end)
	ctx.at(14, function()
		charge(c.v)
		ct.registry.set_state(cid_of(c.v), "idle")
		assign("g7-stray-load", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 50, -5, 70, 5, { { "wooden-chest", "normal", 10 } }, 0) })
	end)
	local dropped
	fx.wait(ctx, 16, 8000, "the run leaving loading", function()
		charge(c.v)
		local run = ct.runs.get(cid_of(c.v))
		if run and run.state == "loading" and not dropped then
			dropped = true
			trunk_of(c.v).insert({ name = "stone", count = 30 })
		end
		return dropped and run and run.state ~= "loading" and run.state ~= "to_station"
	end, function()
		ctx.expect(trunk_of(c.v).get_item_count("stone") == 0, "the stray item left the trunk")
		ctx.expect(trunk_of(c.v).get_item_count("wooden-chest") == 10, "the load is aboard")
	end)
end)

t.case("G7 a stray item is cleared again after loading is re-entered by a station change", function(ctx)
	local c = {}
	ctx.at(10, function()
		c.surface = paved("ctv2-g7-stray-reenter", -40, -40, 110, 40)
		c.station = fx.station(c.surface, 0, 0, { ["construction-robot"] = 60, ["wooden-chest"] = 10 })
		c.v = fx.ctron(c.surface, -6, 0, { robots = 10 })
		fx.ghost(c.surface, 60.5, 0.5)
	end)
	ctx.at(14, function()
		charge(c.v)
		ct.registry.set_state(cid_of(c.v), "idle")
		assign("g7-reenter", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 50, -5, 70, 5, { { "wooden-chest", "normal", 10 } }, 0) })
	end)
	local phase = 0
	fx.wait(ctx, 16, 12000, "the run leaving the second loading", function()
		charge(c.v)
		local run = ct.runs.get(cid_of(c.v))
		if not run then
			return false
		end
		if phase == 0 and run.state == "loading" then
			phase = 1
			trunk_of(c.v).insert({ name = "stone", count = 30 })
		elseif phase == 1 and run.state == "loading" and trunk_of(c.v).get_item_count("stone") == 0 then
			phase = 2 -- the first stray is gone: send the run to the same station again
			fx.send("ct.job.station", { jid = "g7-reenter", cid = cid_of(c.v), why = "short",
				station = { sid = cid_of(c.station), inst = ct.registry.here(), x = c.station.position.x,
					y = c.station.position.y } })
		elseif phase == 2 and run.state == "loading" then
			phase = 3
			trunk_of(c.v).insert({ name = "stone", count = 30 })
		end
		return phase == 3 and run.state ~= "loading" and run.state ~= "to_station"
	end, function()
		ctx.expect(trunk_of(c.v).get_item_count("stone") == 0, "the second stray left too")
	end)
end)

t.case("G7 a station that holds the items but delivers slowly doesn't emit short", function(ctx)
	local c = {}
	ctx.at(10, function()
		c.surface = paved("ctv2-g7-slow", -40, -40, 110, 40)
		c.station = fx.station(c.surface, 0, 0, { ["construction-robot"] = 60, ["wooden-chest"] = 50 })
		-- One logistic robot: most of the time some of the chests are in flight.
		c.station.get_inventory(defines.inventory.roboport_robot).remove({ name = "logistic-robot", count = 9 })
		c.v = fx.ctron(c.surface, -6, 0, { robots = 50 }) -- the full robot_count: the chests alone are missing
		fx.ghost(c.surface, 60.5, 0.5)
	end)
	ctx.at(14, function()
		charge(c.v)
		ct.registry.set_state(cid_of(c.v), "idle")
		assign("g7-slow", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 50, -5, 70, 5, { { "wooden-chest", "normal", 50 } }, 0) })
	end)
	-- short waits 900 ticks from the start of the visit (run_core.WAIT).
	fx.wait(ctx, 16, 3000, "the run loading", function()
		charge(c.v)
		local run = ct.runs.get(cid_of(c.v))
		return run and run.state == "loading"
	end, function(k)
		ctx.at(k + 1100, function()
			charge(c.v)
			local run = ct.runs.get(cid_of(c.v))
			ctx.expect(run and run.state == "loading", "still loading, so the wait was exercised")
			ctx.expect(#events_of("g7-slow", "short") == 0, "no short: " .. #events_of("g7-slow", "short"))
		end)
	end)
end)

t.case("G7 a station that lacks the item emits short", function(ctx)
	local c = {}
	ctx.at(10, function()
		c.surface = paved("ctv2-g7-lacks", -40, -40, 110, 40)
		c.station = fx.station(c.surface, 0, 0, { ["construction-robot"] = 60 })
		c.v = fx.ctron(c.surface, -6, 0, { robots = 10 })
		fx.ghost(c.surface, 60.5, 0.5)
	end)
	ctx.at(14, function()
		charge(c.v)
		ct.registry.set_state(cid_of(c.v), "idle")
		assign("g7-lacks", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 50, -5, 70, 5, { { "wooden-chest", "normal", 5 } }, 0) })
	end)
	fx.wait(ctx, 16, 3000, "a short event", function()
		charge(c.v)
		return #events_of("g7-lacks", "short") > 0
	end)
end)

t.case("G7 a player's section asking for an item the network lacks doesn't hold unloading", function(ctx)
	local c = {}
	ctx.at(10, function()
		c.surface = paved("ctv2-g7-player-section", -40, -40, 110, 40)
		c.station = fx.station(c.surface, 0, 0, { ["construction-robot"] = 60, ["wooden-chest"] = 2 })
		c.v = fx.ctron(c.surface, -6, 0, { robots = 10 })
		fx.ghost(c.surface, 60.5, 0.5)
	end)
	ctx.at(14, function()
		charge(c.v)
		ct.registry.set_state(cid_of(c.v), "idle")
		assign("g7-player", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 50, -5, 70, 5, { { "wooden-chest", "normal", 2 } }, 0) })
	end)
	-- Once the run is past loading, the player adds a section for 50 cliff explosives, which the network lacks.
	local added
	fx.wait(ctx, 16, 12000, "a done event", function()
		charge(c.v)
		local run = ct.runs.get(cid_of(c.v))
		if run and not added and run.state ~= "loading" and run.state ~= "to_station" then
			added = true
			local point = c.v.get_logistic_point(defines.logistic_member_index.spidertron_requester)
			local sec = point.add_section()
			sec.set_slot(1, { value = { type = "item", name = "cliff-explosives", quality = "normal",
				comparator = "=" }, min = 50 })
		end
		return #events_of("g7-player", "done") > 0
	end, function()
		ctx.expect(added, "the section was added")
		ctx.expect(ct.registry.ctron(cid_of(c.v)).state == "idle", "idle again")
	end)
end)

t.case("G7 ammo in the launcher slots that the run doesn't load doesn't hold loading", function(ctx)
	local c = {}
	ctx.at(10, function()
		c.surface = paved("ctv2-g7-ammo", -40, -40, 110, 40)
		c.station = fx.station(c.surface, 0, 0, { ["construction-robot"] = 60, ["wooden-chest"] = 2 })
		c.v = fx.ctron(c.surface, -6, 0, { robots = 10 })
		c.v.get_inventory(defines.inventory.spider_ammo).insert({ name = "rocket", count = 20 })
		fx.ghost(c.surface, 60.5, 0.5)
	end)
	ctx.at(14, function()
		charge(c.v)
		ct.registry.set_state(cid_of(c.v), "idle")
		assign("g7-ammo", "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 50, -5, 70, 5, { { "wooden-chest", "normal", 2 } }, 0) })
	end)
	local loaded
	fx.wait(ctx, 16, 6000, "the run leaving loading", function()
		charge(c.v)
		local run = ct.runs.get(cid_of(c.v))
		loaded = loaded or (run and run.state == "loading")
		return loaded and run and run.state ~= "loading" and run.state ~= "to_station"
	end, function()
		ctx.expect(true, "loading finished with unwanted launcher ammo aboard")
		fx.note("g7-ammo", "rockets left in the launchers: ", c.v.get_inventory(defines.inventory.spider_ammo).get_item_count("rocket"))
	end)
end)

t.case("G7 a removed mod's item in a station's saved slots doesn't raise and is left out of the need", function(ctx)
	ctx.expect_ipc("ctron_pluginv2:out", '"ct.ui.cargo"')
	local c = {}
	ctx.at(10, function()
		c.surface = paved("ctv2-g7-removed-item", -40, -40, 110, 40)
		c.station = fx.station(c.surface, 0, 0, { ["wooden-chest"] = 5 })
	end)
	ctx.at(14, function()
		local sid = cid_of(c.station)
		ct.logistics.set_slots(sid, { { "removed-mod-item", "normal", 5, 10 }, { "wooden-chest", "normal", 5, 10 } })
		local need = ct.logistics.need(sid)
		ctx.expect(need and #need.slots == 1 and need.slots[1][1] == "wooden-chest", "need: " .. serpent.line(need))
		-- a remote Control Center's edit (§8.4): slots and name, then an empty list clears them
		fx.send("ct.station.set", { sid = sid, slots = { { "iron-plate", "normal", 1, 2 } }, name = "Renamed" })
		ctx.expect(c.station.backer_name == "Renamed", "renamed: " .. c.station.backer_name)
		ctx.expect(#ct.logistics.slots(sid) == 1 and ct.logistics.slots(sid)[1][1] == "iron-plate", "slots set")
		fx.send("ct.station.set", { sid = sid, slots = {} })
		ctx.expect(#ct.logistics.slots(sid) == 0 and c.station.backer_name == "Renamed", "empty slots clear, name kept")
		-- the editor on a remote station writes no local slots; it sends the edit
		ct.logistics.set_slots(sid, { { "wooden-chest", "normal", 5, 10 } })
		local ed = { sid = sid, remote = { slots = {} } }
		station.save(ed, { { "iron-plate", "normal", 1, 2 } })
		ctx.expect(#ed.remote.slots == 1 and ct.logistics.slots(sid)[1][1] == "wooden-chest", "remote copy only")
	end)
end)

t.case("G7 an unchanged ctron record isn't marked again", function(ctx)
	local c = {}
	ctx.at(10, function()
		c.surface = paved("ctv2-g7-no-remark", -40, -40, 110, 40)
		c.v = fx.ctron(c.surface, 0, 0, { robots = 10 })
	end)
	ctx.at(14, function()
		local cid = cid_of(c.v)
		ct.registry.capacity(cid)
		local marks = 0
		local real = ct.report.mark
		ct.report.mark = function(kind, ...)
			marks = marks + (kind == "ctron" and 1 or 0)
			return real(kind, ...)
		end
		ct.registry.capacity(cid)
		ct.registry.set_state(cid, ct.registry.ctron(cid).state, ct.registry.ctron(cid).why)
		ct.report.mark = real
		ctx.expect(marks == 0, "no re-mark: " .. marks)
	end)
end)
