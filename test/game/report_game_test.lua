local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ct = require("modules/ctron_pluginv2/ct")

--- The constant-combinator signal count of name on combinator c (0 when unset).
local function signal(c, name)
	local section = c.get_or_create_control_behavior().get_section(1)
	for _, f in ipairs(section and section.filters or {}) do
		if f.value and f.value.name == name then
			return f.min
		end
	end
	return 0
end

--- Fill the ctron's roboports: the fixture's reactor has no fuel, so without this no robot leaves (SP-9).
local function charge(v)
	for _, eq in pairs(v.grid.equipment) do
		if eq.type == "roboport-equipment" then
			eq.energy = eq.max_energy
		end
	end
end

--- A paved surface for one case.
local function paved(name)
	local surface = fx.surface(name)
	fx.ground(surface, -40, -40, 80, 80)
	return surface
end

local function near(a, b)
	return math.abs(a - b) < 0.01
end

t.case("registry: a built ctron and station get ids, CC's setup and dirty records", function(ctx)
	-- A reactor's output reads 0 in the tick it is put, so the state is checked two ticks after the build.
	local v, st, cid, sid
	local marks, real = {}, ct.report.mark
	ctx.at(10, function()
		local surface = paved("ctv2-reg-1")
		ct.report.mark = function(kind, id)
			marks[#marks + 1] = kind .. ":" .. id
		end
		local ok, err = pcall(function()
			v = fx.ctron(surface, 0, 0, { robots = 0 })
			st = fx.station(surface, 20, 0)
		end)
		ct.report.mark = real
		assert(ok, err)
		cid = ct.registry.ctron_of(v)
		sid = ct.registry.here() .. "." .. st.unit_number
		local seen = {}
		for _, m in ipairs(marks) do
			seen[m] = true
		end
		ctx.expect(seen["ctron:" .. cid] and seen["station:" .. sid], "both marked: " .. serpent.line(marks))
	end)
	ctx.at(12, function()
		local surface = v.surface
		do
			ctx.expect(cid == ct.registry.here() .. "." .. v.unit_number, "cid " .. tostring(cid))
			ctx.expect(ct.registry.ctron(cid) ~= nil, "ctron record")
			ct.registry.set_state(cid, "idle")
			ctx.expect(ct.registry.ctron(cid).state == "idle", "state " .. serpent.line(ct.registry.ctron(cid).why))
			ctx.expect(v.enable_logistics_while_moving == false, "logistics while moving off")
			ctx.expect(v.request_from_buffers == true, "requests from buffer chests")
			ctx.expect(v.vehicle_automatic_targeting_parameters.auto_target_without_gunner == true, "targeting")
			ctx.expect(near(v.color.r, 1) and near(v.color.a, 0.25), "idle colour " .. serpent.line(v.color))
			ctx.expect(ct.registry.station(sid) ~= nil, "station record")
			local listed = false
			for _, id in ipairs(ct.registry.stations_on(surface.name)) do
				listed = listed or id == sid
			end
			ctx.expect(listed, "station listed on its surface")
			ctx.expect(st.get_or_create_control_behavior().read_logistics == false, "read_logistics off")
			ctx.expect(ct.registry.register(v) == cid, "register is idempotent")
		end
	end)
end)

t.case("registry: fitness reasons in CC's order, re-checked on equipment events", function(ctx)
	local v, cid
	ctx.at(20, function()
		local surface = paved("ctv2-reg-2")
		v = surface.create_entity({ name = "constructron", position = { 0, 10 }, force = "player",
			raise_built = true })
		cid = ct.registry.ctron_of(v)
		local rec = ct.registry.ctron(cid)
		ctx.expect(rec.state == "unfit" and rec.why == "no_roboports", "empty grid: " .. serpent.line(rec))
		v.grid.put({ name = "personal-roboport-mk2-equipment" })
	end)
	-- The logistic cell follows the grid by a tick, so each handler runs a tick after its change.
	ctx.at(21, function()
		ct.registry.events[defines.events.on_equipment_inserted]({ grid = v.grid })
		local rec = ct.registry.ctron(cid)
		ctx.expect(rec.state == "unfit" and rec.why == "no_power", "roboport only: " .. serpent.line(rec))
		v.grid.put({ name = "fission-reactor-equipment" })
	end)
	ctx.at(30, function()
		ct.registry.events[defines.events.on_equipment_inserted]({ grid = v.grid })
		ctx.expect(ct.registry.ctron(cid).state == "idle", "reactor: " .. serpent.line(ct.registry.ctron(cid)))
		v.grid.take({ equipment = v.grid.find("personal-roboport-mk2-equipment") })
	end)
	ctx.at(31, function()
		ct.registry.events[defines.events.on_equipment_removed]({ grid = v.grid })
		local rec = ct.registry.ctron(cid)
		ctx.expect(rec.state == "unfit" and rec.why == "no_roboports", "roboport out: " .. serpent.line(rec))
	end)
end)

t.case("registry: capacity per profile from settings", function(ctx)
	ctx.at(30, function()
		local surface = paved("ctv2-reg-3")
		local v = fx.ctron(surface, 0, 20, { robots = 0 })
		local cid = ct.registry.ctron_of(v)
		ct.registry.set_state(cid, "idle")
		local rec = ct.registry.ctron(cid)
		local empty = v.get_inventory(defines.inventory.spider_trunk).count_empty_stacks()
		local n = rec.restock.normal["construction-robot"]
		ctx.expect(n and n.normal == 50, "normal restock " .. serpent.line(rec.restock.normal))
		ctx.expect(rec.free.normal == empty - 1, "free.normal " .. rec.free.normal .. " of " .. empty)
		local d = rec.restock.destroy
		ctx.expect(d["construction-robot"].normal == 4 and d["repair-pack"].normal == 16, "destroy restock")
		ctx.expect(d["atomic-bomb"] == nil, "no atomic bombs")
		ctx.expect(next(rec.restock.cargo) == nil, "cargo restock empty")
		local r = ct.registry.record("ctron", cid)
		local tuple = r.restock.normal[1]
		ctx.expect(#r.restock.normal == 1 and tuple[1] == "construction-robot" and tuple[2] == "normal"
			and tuple[3] == 50, "record restock " .. serpent.line(r.restock.normal))
		ctx.expect(r.free.cargo == empty, "free.cargo " .. tostring(r.free.cargo))
	end)
end)

t.case("registry: rename, removal and records", function(ctx)
	local cid, sid, unit
	ctx.at(40, function()
		local surface = paved("ctv2-reg-4")
		local v = fx.ctron(surface, 0, 0, { robots = 0 })
		local st = fx.station(surface, 20, 0)
		cid, sid, unit = ct.registry.ctron_of(v), ct.registry.here() .. "." .. st.unit_number, v.unit_number
		ct.registry.rename(sid, "ctv2-dock")
		ctx.expect(ct.registry.record("station", sid).name == "ctv2-dock", "renamed")
		ct.registry.rename(sid, string.rep("é", 40))
		ctx.expect(ct.registry.record("station", sid).name == string.rep("é", 30), "cut to 30 characters")
		v.destroy({ raise_destroy = true })
		st.destroy({ raise_destroy = true })
	end)
	ctx.at(50, function()
		ctx.expect(ct.registry.ctron(cid) == nil, "ctron record gone")
		ctx.expect(ct.registry.record("ctron", cid) == nil, "no ctron record")
		ctx.expect(ct.registry.station(sid) == nil, "station record gone")
		ctx.expect(storage.ctron_pluginv2.by_unit[unit] == nil, "by_unit dropped")
	end)
end)

t.case("registry: an idle ctron with robots out is unfit until they come back", function(ctx)
	local v, cid
	ctx.at(60, function()
		local surface = paved("ctv2-reg-5")
		v = fx.ctron(surface, 0, 40, { robots = 10 })
		cid = ct.registry.ctron_of(v)
		v.get_inventory(defines.inventory.spider_trunk).insert({ name = "wooden-chest", count = 5 })
		for i = 1, 5 do
			fx.ghost(surface, 6 + i, 40 + i)
		end
		fx.wait(ctx, 61, 600, "robots dispatched", function()
			charge(v)
			local net = v.logistic_cell.logistic_network
			return net.all_construction_robots - net.available_construction_robots > 0
		end, function(k)
			ct.registry.set_state(cid, "idle")
			local rec = ct.registry.ctron(cid)
			ctx.expect(rec.state == "unfit" and rec.why == "robots_out", "robots out: " .. serpent.line(rec.why))
			fx.wait(ctx, k + 1, 3000, "the ctron fit again", function()
				charge(v)
				return ct.registry.ctron(cid).state == "idle"
			end)
		end)
	end)
end)

t.case("signals: one combinator per surface, wired to every station, counting ctrons and idle ones", function(ctx)
	local surface, s1, s2, cids
	ctx.at(80, function()
		surface = paved("ctv2-reg-6")
		s1 = fx.station(surface, 20, 0)
		s2 = fx.station(surface, 20, 20)
		cids = {}
		for i = 1, 3 do
			cids[i] = ct.registry.ctron_of(fx.ctron(surface, 0, i * 4, { robots = 0 }))
		end
	end)
	ctx.at(82, function()
		for i = 1, 3 do
			ct.registry.set_state(cids[i], "idle")
		end
		ct.registry.set_state(cids[3], "busy", nil, "j1")
		ct.signals.flush()
		ctx.expect(surface.count_entities_filtered({ name = "ctron-combinator" }) == 1, "one combinator")
		local c = surface.find_entities_filtered({ name = "ctron-combinator" })[1]
		ctx.expect(signal(c, "signal-C") == 3 and signal(c, "signal-A") == 2,
			"C " .. signal(c, "signal-C") .. " A " .. signal(c, "signal-A"))
		for _, st in ipairs({ s1, s2 }) do
			local conn = st.get_wire_connector(defines.wire_connector_id.circuit_red, false)
			ctx.expect(conn and conn.connection_count >= 1, "station wired")
		end
		c.destroy()
		fx.station(surface, 20, 40)
		ct.signals.flush()
		local c2 = surface.find_entities_filtered({ name = "ctron-combinator" })[1]
		ctx.expect(c2 ~= nil and signal(c2, "signal-C") == 3, "combinator rebuilt and rewritten")
	end)
end)

t.case("registry: a ctron equipped by script turns fit at the next idle pass", function(ctx)
	ctx.at(90, function()
		local surface = paved("ctv2-reg-7")
		local v = surface.create_entity({ name = "constructron", position = { 0, 0 }, force = "player",
			raise_built = true })
		local cid = ct.registry.ctron_of(v)
		local rec = ct.registry.ctron(cid)
		ctx.expect(rec.state == "unfit" and rec.why == "no_roboports", "starts unfit")
		v.grid.put({ name = "personal-roboport-mk2-equipment" })
		v.grid.put({ name = "fission-reactor-equipment" })
		fx.wait(ctx, 91, 700, "fit after the idle pass", function()
			return ct.registry.ctron(cid).state == "idle"
		end)
	end)
end)

t.case("registry: the old entity's death doesn't delete a cid re-registered by a crossing", function(ctx)
	local v1, v2, cid, u1
	ctx.at(100, function()
		local surface = paved("ctv2-reg-8")
		v1 = fx.ctron(surface, 0, 60, { robots = 0 })
		cid, u1 = ct.registry.ctron_of(v1), v1.unit_number
		v2 = surface.create_entity({ name = "constructron", position = { 10, 60 }, force = "player" })
		ctx.expect(ct.registry.register(v2, cid) == cid, "register returns the carried cid")
		ctx.expect(ct.registry.ctron(cid).entity == v2, "record replaced")
		v1.destroy({ raise_destroy = true })
	end)
	ctx.at(110, function()
		ctx.expect(ct.registry.ctron(cid) and ct.registry.ctron(cid).entity == v2, "record kept")
		ctx.expect(ct.registry.ctron_of(v2) == cid, "ctron_of v2")
		ctx.expect(storage.ctron_pluginv2.by_unit[u1] == nil, "old by_unit dropped")
		v2.destroy({ raise_destroy = true })
	end)
	ctx.at(120, function()
		ctx.expect(ct.registry.ctron(cid) == nil, "gone with its own entity")
	end)
end)

--- Section 1's filters of ctron v as "name/quality" → {min, max}.
local function section1(v)
	local out = {}
	local sec = v.get_logistic_point(defines.logistic_member_index.spidertron_requester).get_section(1)
	for _, f in ipairs(sec and sec.filters or {}) do
		if f.value then
			out[f.value.name .. "/" .. (f.value.quality or "normal")] = { f.min, f.max }
		end
	end
	return out
end

local function same(a, b)
	return serpent.line(a, { sortkeys = true }) == serpent.line(b, { sortkeys = true })
end

t.case("logistics: write_load, write_unload, write_deliver and clear own section 1", function(ctx)
	ctx.at(110, function()
		local v = fx.ctron(paved("ctv2-log-1"), 0, 0, { robots = 10 })
		v.get_inventory(defines.inventory.spider_trunk).insert({ name = "wood", count = 7 })
		ct.logistics.write_load(v, { ["iron-plate"] = { normal = 50 } })
		ctx.expect(same(section1(v), { ["iron-plate/normal"] = { 50, 50 }, ["wood/normal"] = { 0, 0 },
			["construction-robot/normal"] = { 0, 0 } }), "load " .. serpent.line(section1(v)))
		local point = v.get_logistic_point(defines.logistic_member_index.spidertron_requester)
		ctx.expect(point.trash_not_requested == false, "trash_not_requested")
		ct.logistics.write_unload(v, { ["construction-robot"] = { normal = 10 } })
		ctx.expect(same(section1(v), { ["wood/normal"] = { 0, 0 }, ["construction-robot/normal"] = { 0, 10 } }),
			"unload " .. serpent.line(section1(v)))
		ct.logistics.write_deliver(v, { wood = { normal = 7 } })
		ctx.expect(same(section1(v), { ["wood/normal"] = { 0, 0 } }), "deliver " .. serpent.line(section1(v)))
		ct.logistics.clear(v)
		ctx.expect(next(section1(v)) == nil, "clear " .. serpent.line(section1(v)))
	end)
end)

t.case("logistics: held counts trunk and ammo slots; trash_empty", function(ctx)
	ctx.at(120, function()
		local v = fx.ctron(paved("ctv2-log-2"), 0, 0, { robots = 3 })
		v.get_inventory(defines.inventory.spider_ammo).insert({ name = "rocket", count = 20 })
		ctx.expect(same(ct.logistics.held(v), { ["construction-robot"] = { normal = 3 }, rocket = { normal = 20 } }),
			"held " .. serpent.line(ct.logistics.held(v)))
		ctx.expect(ct.logistics.trash_empty(v) == true, "trash empty")
		v.get_inventory(defines.inventory.spider_trash).insert({ name = "wood", count = 1 })
		ctx.expect(ct.logistics.trash_empty(v) == false, "trash holds wood")
	end)
end)

t.case("logistics: fulfilled is exact against every section's merged filters", function(ctx)
	ctx.at(130, function()
		local v = fx.ctron(paved("ctv2-log-3"), 0, 0, { robots = 0 })
		local trunk = v.get_inventory(defines.inventory.spider_trunk)
		trunk.insert({ name = "iron-plate", count = 10 })
		ct.logistics.write_load(v, { ["iron-plate"] = { normal = 10 } })
		ctx.expect(ct.logistics.fulfilled(v) == true, "fulfilled")
		local point = v.get_logistic_point(defines.logistic_member_index.spidertron_requester)
		point.add_section().set_slot(1, { value = { type = "item", name = "repair-pack", quality = "normal",
			comparator = "=" }, min = 5 })
		local ok, missing = ct.logistics.fulfilled(v)
		ctx.expect(ok == false and missing["repair-pack"] and missing["repair-pack"].normal == 5,
			"missing " .. serpent.line(missing))
		point.remove_section(2)
		trunk.insert({ name = "iron-plate", count = 1 })
		ok, missing = ct.logistics.fulfilled(v)
		ctx.expect(ok == false and next(missing) == nil, "excess " .. serpent.line(missing))
	end)
end)

t.case("logistics: cover answers all, some and none for supply, and drop", function(ctx)
	local st
	ctx.at(140, function()
		st = fx.station(paved("ctv2-log-4"), 20, 20, { ["iron-plate"] = 100 })
	end)
	ctx.at(200, function()
		local net = st.logistic_network
		ctx.expect(net ~= nil, "network formed")
		local c = ct.logistics.cover
		ctx.expect(c(net, { { "iron-plate", "normal", 50 } }, "supply") == true, "all")
		ctx.expect(same(c(net, { { "iron-plate", "normal", 50 }, { "copper-plate", "normal", 1 } }, "supply"), { 1 }),
			"some")
		ctx.expect(c(net, { { "copper-plate", "normal", 1 } }, "supply") == nil, "none")
		ctx.expect(c(net, { { "wood", "normal", 10 } }, "drop") == true, "drop")
	end)
end)

t.case("logistics: a stock query answers one record per (entry, network), grouped at answer time, in parts", function(ctx)
	local sidA, sidB, sidC
	local function sid_of(st)
		return ct.registry.here() .. "." .. st.unit_number
	end
	ctx.at(150, function()
		local surface = fx.surface("ctv2-log-5")
		fx.ground(surface, -40, -40, 400, 40)
		local a = fx.station(surface, 0, 0, { ["iron-plate"] = 100 })
		local b = fx.station(surface, 10, 0)
		local c = fx.station(surface, 300, 0, { ["copper-plate"] = 100 })
		sidA, sidB, sidC = sid_of(a), sid_of(b), sid_of(c)
	end)
	--- The queued ct.stock.reply messages of req, and their records concatenated (parts checked to run 1..n).
	local function replies(req)
		local msgs, r = {}, {}
		for _, msg in ipairs(storage.universal_edges.bridge.out.ctron_pluginv2 or {}) do
			if msg.type == "ct.stock.reply" and msg.payload.req == req then
				msgs[#msgs + 1] = msg
			end
		end
		table.sort(msgs, function(x, y) return x.payload.part < y.payload.part end)
		for i, msg in ipairs(msgs) do
			ctx.expect(msg.payload.part == i and msg.payload.parts == #msgs, "parts run 1..n")
			ctx.expect(#helpers.table_to_json(msg) + 30 < 3500, "part " .. i .. " under 3,500 bytes")
			for _, rec in ipairs(msg.payload.r) do
				r[#r + 1] = rec
			end
		end
		return r, #msgs
	end
	--- The records of qid that hold one of this case's stations.
	local function mine(records, qid)
		local out = {}
		local ours = { [sidA] = true, [sidB] = true, [sidC] = true }
		for _, rec in ipairs(records) do
			if rec.qid == qid then
				for _, sid in ipairs(rec.sids) do
					if ours[sid] then
						out[#out + 1] = rec
						break
					end
				end
			end
		end
		return out
	end
	local function has(rec, sid)
		for _, x in ipairs(rec.sids) do
			if x == sid then
				return true
			end
		end
		return false
	end
	ctx.at(210, function()
		fx.send("ct.stock.query", { req = "q1", q = {
			{ qid = "a", mode = "supply", items = { { "iron-plate", "normal", 10 } } },
			{ qid = "b", mode = "supply", items = { { "iron-plate", "normal", 10 }, { "copper-plate", "normal", 10 } } },
			{ qid = "c", mode = "supply", items = { { "iron-plate", "normal", 10 } }, exclude_sid = sidA },
		} })
		local r = replies("q1")
		local a = mine(r, "a")
		ctx.expect(#a == 1 and #a[1].sids == 2 and has(a[1], sidA) and has(a[1], sidB) and a[1].cover == true,
			"a " .. serpent.line(a))
		local b = mine(r, "b")
		ctx.expect(#b == 2, "b " .. serpent.line(b))
		for _, rec in ipairs(b) do
			if has(rec, sidA) then
				ctx.expect(same(rec.cover, { 1 }), "b at A " .. serpent.line(rec))
			else
				ctx.expect(has(rec, sidC) and same(rec.cover, { 2 }), "b at C " .. serpent.line(rec))
			end
		end
		for _, rec in ipairs(mine(r, "c")) do
			ctx.expect(not has(rec, sidA), "c excludes A's network " .. serpent.line(rec))
		end
		local q = {}
		for e = 1, 12 do
			local list = {}
			for i = 1, 30 do
				list[i] = { i % 2 == 1 and "iron-plate" or "copper-plate", "normal", 1 }
			end
			q[e] = { qid = "e" .. e, mode = "supply", items = list }
		end
		fx.send("ct.stock.query", { req = "q2", q = q })
		local r2, n = replies("q2")
		local count = 0
		for e = 1, 12 do
			count = count + #mine(r2, "e" .. e)
		end
		ctx.expect(n > 1, "more than one part: " .. n)
		ctx.expect(count == 24, "24 records: " .. count)
	end)
end)

t.case("logistics: cargo slots report a need when a count or a slot changes, and rm when cleared", function(ctx)
	local sid, chest
	ctx.at(160, function()
		local st
		st, chest = fx.station(paved("ctv2-log-6"), 20, 20, { ["iron-plate"] = 30 })
		sid = ct.registry.here() .. "." .. st.unit_number
	end)
	ctx.at(220, function()
		ct.logistics.set_slots(sid, { { "iron-plate", "normal", 50, 100 } })
		local need = ct.logistics.need(sid)
		ctx.expect(need and same(need.slots, { { "iron-plate", "normal", 50, 100, 30, 100 } }),
			"need " .. serpent.line(need))
		local many = {}
		for i = 1, 35 do
			many[i] = { "iron-plate", "normal", i, i }
		end
		ct.logistics.set_slots(sid, many)
		ctx.expect(#ct.logistics.slots(sid) == 30, "30 kept")
		ct.logistics.set_slots(sid, { { "iron-plate", "normal", 50, 100 } })
		chest.insert({ name = "iron-plate", count = 10 })
		fx.wait(ctx, 221, 700, "the needs pass saw 40", function()
			return ct.logistics.need(sid).slots[1][5] == 40
		end, function()
			ct.logistics.set_slots(sid, nil)
			ctx.expect(ct.logistics.need(sid) == nil, "need gone")
			ctx.expect(same(ct.logistics.slots(sid), {}), "slots empty")
		end)
	end)
end)

t.case("registry: capacity counts what the ctron holds", function(ctx)
	ctx.at(170, function()
		local v = fx.ctron(paved("ctv2-log-7"), 0, 0, { robots = 10 })
		v.get_inventory(defines.inventory.spider_ammo).insert({ name = "rocket", count = 30 })
		local cid = ct.registry.ctron_of(v)
		ctx.expect(ct.registry.capacity(cid) ~= nil, "capacity")
		local restock = ct.registry.ctron(cid).restock.normal
		ctx.expect(same(restock, { ["construction-robot"] = { normal = 40 } }), "restock " .. serpent.line(restock))
	end)
end)

--- Make surface schedulable, keeping every other case's settings.
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

--- n scanned construction cells with 20-item bring lists on surface (a name), straight into storage; returns their wids.
local function fake_cells(surface, n)
	local s, here, out = storage.ctron_pluginv2, ct.registry.here(), {}
	for i = 1, n do
		local bring = {}
		for j = 1, 20 do
			bring[j] = { "item-number-" .. j, "normal", 100 + j, 50 }
		end
		local x = i * 80 + 0.5
		local wid = here .. "|" .. surface .. "|construction|fake" .. i
		s.cells[wid] = { key = 0, kind = "construction", surface = surface, min = { x = x, y = 0.5 }, max = { x = x + 10, y = 10.5 },
			t = 0, since = 0, tool = false, dirty = false, scanned = 1, bring = bring, out = 3, n = 9 }
		out[#out + 1] = wid
	end
	return out
end

--- Every queued message of type, encoded with an id as UE's flush would add one, is under 3,500 bytes.
local function all_small(msg_type)
	for _, msg in ipairs(storage.universal_edges.bridge.out.ctron_pluginv2 or {}) do
		if msg.type == msg_type and #helpers.table_to_json(msg) + #'"id":"00000000.0000",' >= 3500 then
			return false
		end
	end
	return true
end

--- The payloads of the queued messages of msg_type, in send order.
local function queued(msg_type)
	local out = {}
	for _, msg in ipairs(storage.universal_edges.bridge.out.ctron_pluginv2 or {}) do
		if msg.type == msg_type then
			out[#out + 1] = msg.payload
		end
	end
	return out
end

--- Forget the queued messages, so a case reads only its own.
local function drain()
	storage.universal_edges.bridge.out.ctron_pluginv2 = {}
end

--- The set of values under key in every payload's list (a list of strings or records with field).
local function union(payloads, path, field)
	local set = {}
	for _, p in ipairs(payloads) do
		local l = p
		for _, k in ipairs(path) do
			l = l and l[k]
		end
		for _, v in ipairs(l or {}) do
			set[field and v[field] or v] = true
		end
	end
	return set
end

--- Flush until every dirty set is empty (a burst drains over several flushes); the messages stay queued.
local function flush_all()
	local d = storage.ctron_pluginv2.dirty
	for _ = 1, 20 do
		ct.report.flush()
		if next(d.cell) == nil and next(d.job) == nil then
			return
		end
	end
end

t.case("G4 snapshot: numbered parts under 3,500 bytes carry every record kind, defaults in part 1", function(ctx)
	local name, cid, sid, wids = "ctv2-rep-1", nil, nil, nil
	ctx.at(300, function()
		local surface = paved(name)
		schedule(name)
		cid = ct.registry.ctron_of(fx.ctron(surface, 0, 0, { robots = 0 }))
		local st = fx.station(surface, 20, 0)
		sid = ct.registry.here() .. "." .. st.unit_number
	end)
	ctx.at(360, function()
		ct.logistics.set_slots(sid, { { "iron-plate", "normal", 10, 20 } })
		wids = fake_cells(name, 40)
		drain()
		fx.send("ct.snapshot.request", {})
		local snaps = queued("ct.snapshot")
		ctx.expect(#snaps >= 2, "parts " .. #snaps)
		for i, p in ipairs(snaps) do
			ctx.expect(p.seq == snaps[1].seq and p.part == i and p.parts == #snaps, "numbering " .. i)
			ctx.expect((p.defaults ~= nil) == (i == 1), "defaults only in part 1")
		end
		ctx.expect(snaps[1].defaults.robot_count == 50, "defaults " .. serpent.line(snaps[1].defaults))
		ctx.expect(union(snaps, { "ctrons" }, "cid")[cid], "cid")
		ctx.expect(union(snaps, { "stations" }, "sid")[sid], "sid")
		ctx.expect(union(snaps, { "needs" }, "sid")[sid], "need")
		local cs = union(snaps, { "cells" }, "wid")
		for _, w in ipairs(wids) do
			ctx.expect(cs[w], "cell " .. w)
		end
		ctx.expect(all_small("ct.snapshot"), "all under 3,500")
		for _, w in ipairs(wids) do
			storage.ctron_pluginv2.cells[w] = nil
		end
	end)
end)

t.case("G4 delta: marked records go up in parts under 3,500 bytes, cells before jobs, removals as rm", function(ctx)
	ctx.at(310, function()
		local name = "ctv2-rep-2"
		paved(name)
		schedule(name)
	end)
	ctx.at(312, function()
		local name = "ctv2-rep-2"
		local wids = fake_cells(name, 40)
		for _, w in ipairs(wids) do
			ct.report.mark("cell", w)
		end
		ct.report.mark("job", "jt")
		drain()
		flush_all()
		local deltas = queued("ct.delta")
		ctx.expect(#deltas >= 2, "parts " .. #deltas)
		local up = union(deltas, { "cells", "up" }, "wid")
		for _, w in ipairs(wids) do
			ctx.expect(up[w], "up " .. w)
		end
		ctx.expect(union(deltas, { "jobs", "rm" })["jt"], "jt removed")
		local seen_jobs = false
		for _, p in ipairs(deltas) do
			ctx.expect(not (seen_jobs and p.cells), "a cells list after a jobs list")
			seen_jobs = seen_jobs or p.jobs ~= nil
		end
		ctx.expect(all_small("ct.delta"), "all under 3,500")
		for _, w in ipairs(wids) do
			storage.ctron_pluginv2.cells[w] = nil
			ct.report.mark("cell", w)
		end
		drain()
		flush_all()
		local rm = union(queued("ct.delta"), { "cells", "rm" })
		for _, w in ipairs(wids) do
			ctx.expect(rm[w], "rm " .. w)
		end
	end)
end)

t.case("G4 the periodic flush empties the dirty sets within 60 ticks", function(ctx)
	ctx.at(320, function()
		fx.ctron(paved("ctv2-rep-3"), 0, 0, { robots = 0 })
		ctx.expect(next(storage.ctron_pluginv2.dirty.ctron) ~= nil, "marked")
	end)
	ctx.at(381, function()
		ctx.expect(next(storage.ctron_pluginv2.dirty.ctron) == nil, "flushed")
	end)
	ctx.expect_ipc("ctron_pluginv2:out", '"ct.delta"')
end)

t.case("G4 a status-only job change goes out in the next flush", function(ctx)
	ctx.at(330, function()
		ct.report.mark("job", "js")
		drain()
		ct.report.flush()
		ctx.expect(union(queued("ct.delta"), { "jobs", "rm" })["js"], "sent")
	end)
end)

t.case("G4 job events go at once; item maps become tuples, missing capped at 10", function(ctx)
	ctx.at(340, function()
		local m = {}
		for i = 1, 12 do
			m["item-number-" .. i] = { normal = i }
		end
		drain()
		ct.report.event("j1", "short", { cid = "4242.1", missing = m })
		local ev = queued("ct.job.event")[1]
		ctx.expect(ev and ev.jid == "j1" and ev.ev == "short" and ev.tick == game.tick and ev.cid == "4242.1", "fields")
		ctx.expect(#ev.missing == 10, "capped " .. #ev.missing)
		for _, tp in ipairs(ev.missing) do
			ctx.expect(type(tp[1]) == "string" and tp[2] == "normal" and type(tp[3]) == "number", "tuple")
		end
	end)
end)

t.case("G4 a 40-heavy-cell burst drains over several flushes, cells before jobs, none over the cap", function(ctx)
	ctx.at(345, function()
		local name = "ctv2-rep-8"
		paved(name)
		schedule(name)
	end)
	ctx.at(347, function()
		local wids = fake_cells("ctv2-rep-8", 40)
		for _, w in ipairs(wids) do
			ct.report.mark("cell", w)
		end
		ct.report.mark("job", "jb")
		local up, last_cell, job_at, flushes = {}, 0, nil, 0
		repeat
			flushes = flushes + 1
			drain()
			ct.report.flush()
			local bytes = 0
			for _, p in ipairs(queued("ct.delta")) do
				bytes = bytes + #helpers.table_to_json(p)
				for _, c in ipairs(p.cells and p.cells.up or {}) do
					up[c.wid] = true
					last_cell = flushes
				end
				if p.jobs and p.jobs.rm[1] == "jb" then
					job_at = flushes
				end
			end
			ctx.expect(bytes <= 5000 + 3500, "flush " .. flushes .. " built " .. bytes .. " bytes")
		until flushes >= 20 or (next(storage.ctron_pluginv2.dirty.cell) == nil and next(storage.ctron_pluginv2.dirty.job) == nil)
		ctx.expect(flushes >= 3, "drained over " .. flushes .. " flushes")
		for _, w in ipairs(wids) do
			ctx.expect(up[w], "arrived " .. w)
			storage.ctron_pluginv2.cells[w] = nil
		end
		ctx.expect(job_at and job_at >= last_cell, "job after the cells: " .. tostring(job_at) .. " vs " .. last_cell)
	end)
end)

t.case("SP-7 report: a 40-cell delta and a 20-item stock query on a 500-chest network", function(ctx)
	local name = "ctv2-rep-7"
	local items = { "iron-plate", "copper-plate", "coal", "stone", "wood", "iron-ore", "copper-ore", "steel-plate",
		"iron-gear-wheel", "copper-cable", "electronic-circuit", "pipe", "stone-brick", "plastic-bar", "sulfur",
		"iron-stick", "firearm-magazine", "landfill", "solid-fuel", "wooden-chest" }
	local st
	ctx.at(350, function()
		local surface = fx.surface(name)
		fx.ground(surface, -60, -60, 120, 120)
		schedule(name)
	end)
	ctx.at(352, function()
		local wids = fake_cells(name, 40)
		for _, w in ipairs(wids) do
			ct.report.mark("cell", w)
		end
		drain()
		local p = helpers.create_profiler()
		ct.report.flush()
		-- UE's end-of-tick flush encodes every queued message again (bridge.lua flush): count that in the window.
		for _, msg in ipairs(storage.universal_edges.bridge.out.ctron_pluginv2) do
			local _ = #helpers.table_to_json(msg)
		end
		p.stop()
		fx.note("sp7", "report flush 40 cells + UE encode, ", #queued("ct.delta"), " parts: ", p)
		for _, w in ipairs(wids) do
			storage.ctron_pluginv2.cells[w] = nil
		end
		local surface = game.surfaces[name]
		local rp = surface.create_entity({ name = "roboport", position = { 0, 12 }, force = "player" })
		rp.get_inventory(defines.inventory.roboport_robot).insert({ name = "logistic-robot", count = 10 })
		st = fx.station(surface, 0, 0)
		local n = 0
		for i = 0, 21 do
			for j = 0, 21 do
				local pos = { -9 + 2 * i + 0.5, -9 + 2 * j + 0.5 }
				if surface.can_place_entity({ name = "storage-chest", position = pos, force = "player" }) then
					local c = surface.create_entity({ name = "storage-chest", position = pos, force = "player" })
					c.insert({ name = items[(n % 20) + 1], count = 10 })
					n = n + 1
				end
			end
		end
		fx.note("sp7", "chests placed: ", n)
	end)
	fx.wait(ctx, 353, 600, "the network formed", function()
		return st and st.valid and st.logistic_network ~= nil
	end, function()
		local list = {}
		for i, item in ipairs(items) do
			list[i] = { item, "normal", 5 }
		end
		local q = { { qid = "s", mode = "supply", items = list } }
		local p = helpers.create_profiler()
		ct.logistics.answer("sp7", q)
		p.stop()
		fx.note("sp7", "stock query 20 items, 500 chests: ", p)
	end)
end)
