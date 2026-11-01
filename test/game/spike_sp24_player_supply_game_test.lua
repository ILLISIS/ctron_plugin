local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")

-- SP-24 (player supply): can a constructron's own robots fill a character's missing logistic requests and empty its
-- trash through an item-request-proxy whose target is the character? A probe: it records answers and asserts only its
-- setup. Ctrons and stations here are never raised as built, so the module never registers or commands them.
local SP = "SP-24"
local MAIN, TRASH = defines.inventory.character_main, defines.inventory.character_trash
local IRON, COPPER_UC = { name = "iron-plate" }, { name = "copper-plate", quality = "uncommon" }
local STONE, WOOD = { name = "stone" }, { name = "wood" }

--- A constructron as fx.ctron builds it, not raised, holding items in its trunk.
local function ctron(surface, x, y, robots, items)
	local v = assert(surface.create_entity({ name = "constructron", position = { x, y }, force = "player" }))
	v.grid.put({ name = "fission-reactor-equipment" })
	v.grid.put({ name = "personal-roboport-mk2-equipment" })
	v.grid.put({ name = "personal-roboport-mk2-equipment" })
	local trunk = fx.trunk_of(v)
	if robots > 0 then
		trunk.insert({ name = "construction-robot", count = robots })
	end
	for _, it in ipairs(items or {}) do
		trunk.insert(it)
	end
	fx.charge(v)
	return v
end

local function character(surface, x, y)
	return assert(surface.create_entity({ name = "character", position = { x, y }, force = "player" }))
end

--- One BlueprintInsertPlan entry: id into inventory at slots { { stack (0-based), count }, ... }.
local function plan(id, inventory, slots)
	local pos = {}
	for _, s in ipairs(slots) do
		pos[#pos + 1] = { inventory = inventory, stack = s[1], count = s[2] }
	end
	return { id = id, items = { in_inventory = pos } }
end

--- An item-request-proxy on char; returns the proxy (or nil) and "ok" or the error.
local function proxy(char, inserts, removals)
	local ok, res = pcall(function()
		return char.surface.create_entity({ name = "item-request-proxy", position = char.position, force = "player",
			target = char, modules = inserts, removal_plan = removals })
	end)
	return ok and res or nil, ok and (res and "ok" or "nil") or tostring(res)
end

local function inv_count(entity, index, item)
	local inv = entity.valid and entity.get_inventory(index)
	return inv and inv.get_item_count(item) or 0
end

--- Where item is on the surface: ctron trunk+trash, character main, trash, robot cargo, ground, anything else.
local function where(surface, v, char, item)
	local w = { 0, 0, 0, 0, 0, 0 }
	if v and v.valid then
		w[1] = inv_count(v, defines.inventory.spider_trunk, item) + inv_count(v, defines.inventory.spider_trash, item)
	end
	if char and char.valid then
		w[2], w[3] = inv_count(char, MAIN, item), inv_count(char, TRASH, item)
	end
	for _, r in pairs(surface.find_entities_filtered({ type = { "construction-robot", "logistic-robot" } })) do
		w[4] = w[4] + inv_count(r, defines.inventory.robot_cargo, item)
	end
	for _, g in pairs(surface.find_entities_filtered({ name = "item-on-ground" })) do
		local s = g.stack
		if s.valid_for_read and s.name == item.name and s.quality.name == (item.quality or "normal") then
			w[5] = w[5] + s.count
		end
	end
	local skip = { [v and v.valid and v.unit_number or 0] = true, [char and char.valid and char.unit_number or 0] = true }
	for _, e in pairs(surface.find_entities_filtered({ type = { "container", "logistic-container", "car",
		"spider-vehicle", "character", "roboport" } })) do
		if not skip[e.unit_number] then
			for i = 1, e.get_max_inventory_index() do
				w[6] = w[6] + inv_count(e, i, item)
			end
		end
	end
	return w, w[1] + w[2] + w[3] + w[4] + w[5] + w[6]
end

--- Robots in the air by "<robot>><network owner>".
local function flying(surface)
	local by = {}
	for _, r in pairs(surface.find_entities_filtered({ type = { "construction-robot", "logistic-robot" } })) do
		local net = r.logistic_network
		local cell = net and net.cells[1]
		local k = r.name .. ">" .. (cell and cell.owner and cell.owner.name or "none")
		by[k] = (by[k] or 0) + 1
	end
	return by
end

local function proxy_state(p)
	if not p then
		return "none"
	end
	if not p.valid then
		return "gone"
	end
	local n, rm = 0, 0
	for _, r in pairs(p.item_requests) do
		n = n + r.count
	end
	for _, entry in pairs(p.removal_plan or {}) do
		for _, pos in pairs(entry.items.in_inventory or {}) do
			rm = rm + (pos.count or 1)
		end
	end
	return "req " .. n .. " rm " .. rm
end

--- From offset from to `to`, every `every` ticks: charge, then note state() when it changed. Item totals are checked
--- against the first sample; a change is noted as LOST/GAINED.
local function watch(ctx, tag, from, to, every, s)
	local last, base = nil, nil
	for k = from, to, every do
		ctx.at(k, function()
			local surface = s.ctron().surface
			for _, e in ipairs(s.charge()) do
				fx.charge(e)
			end
			local state, totals = { proxy = proxy_state(s.proxy()), fly = flying(surface) }, {}
			for name, item in pairs(s.items) do
				local w, total = where(surface, s.ctron(), s.char(), item)
				state[name] = table.concat(w, "/")
				totals[name] = total
			end
			if s.extra then
				s.extra(state)
			end
			base = base or totals
			for name, total in pairs(totals) do
				if total ~= base[name] then
					state.conservation = (state.conservation or "") .. name .. " " .. base[name] .. "->" .. total .. " "
				end
			end
			local json = helpers.table_to_json(state)
			if json ~= last then
				fx.note(SP, tag, " t=", k, " ", json)
				last = json
			end
		end)
	end
end

--- Force-wide character logistics; recorded once, before any case changes them.
local force_noted = false
local function character_logistics()
	-- luacheck: ignore 122
	local f = game.forces.player
	if not force_noted then
		fx.json(SP, "force before", { character_logistic_requests = f.character_logistic_requests,
			character_trash_slot_count = f.character_trash_slot_count,
			storage_bonus = f.worker_robots_storage_bonus, speed = f.worker_robots_speed_modifier })
		force_noted = true
	end
	f.character_logistic_requests = true
	if f.character_trash_slot_count < 10 then
		f.character_trash_slot_count = 10
	end
end

-- Locations in every state line: ctron/main/trash/air/ground/other.

t.case("SP-24a deliver into main (top-up and quality) and pick up trash, one proxy", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-24.txt")
	local surface, v, char, p
	ctx.at(2, function()
		character_logistics()
		surface = fx.paved("sp24-a", -30, -30, 30, 30)
		v = ctron(surface, 0, 0, 10, { { name = "iron-plate", count = 200 },
			{ name = "copper-plate", quality = "uncommon", count = 100 } })
		char = character(surface, 6, 0)
		char.get_inventory(MAIN)[1].set_stack({ name = "iron-plate", count = 30 })
		local trash = char.get_inventory(TRASH)
		ctx.expect(trash ~= nil and #trash >= 2, "character has trash slots")
		trash[1].set_stack({ name = "stone", count = 40 })
		trash[2].set_stack({ name = "wood", count = 20 })
	end)
	ctx.at(10, function()
		local res
		p, res = proxy(char, { plan(IRON, MAIN, { { 0, 50 } }), plan(COPPER_UC, MAIN, { { 2, 20 } }) },
			{ plan(STONE, TRASH, { { 0, 40 } }), plan(WOOD, TRASH, { { 1, 20 } }) })
		fx.note(SP, "a create ", res)
		if p then
			fx.json(SP, "a item_requests", p.item_requests)
			fx.json(SP, "a removal_plan", p.removal_plan)
		end
	end)
	watch(ctx, "a", 10, 6000, 30, { items = { iron = IRON, copper_uc = COPPER_UC, stone = STONE, wood = WOOD },
		ctron = function() return v end, char = function() return char end, proxy = function() return p end,
		charge = function() return { v } end })
	ctx.at(6001, function()
		local m = char.get_inventory(MAIN)
		local function slot(i) return m[i].valid_for_read and (m[i].name .. " " .. m[i].quality.name .. " " .. m[i].count) or "empty" end
		fx.note(SP, "a final main[1]=", slot(1), " main[3]=", slot(3), " trash empty=", tostring(char.get_inventory(TRASH).is_empty()))
	end)
end)

t.case("SP-24a2 removal only (no modules)", function(ctx)
	local surface, v, char, p
	ctx.at(2, function()
		character_logistics()
		surface = fx.paved("sp24-a2", -30, -30, 30, 30)
		v = ctron(surface, 0, 0, 10)
		char = character(surface, 6, 0)
		char.get_inventory(TRASH)[1].set_stack({ name = "stone", count = 40 })
	end)
	ctx.at(10, function()
		local res
		p, res = proxy(char, nil, { plan(STONE, TRASH, { { 0, 40 } }) })
		fx.note(SP, "a2 create ", res)
	end)
	watch(ctx, "a2", 10, 3000, 30, { items = { stone = STONE }, ctron = function() return v end,
		char = function() return char end, proxy = function() return p end, charge = function() return { v } end })
end)

t.case("SP-24b request more than the slot holds", function(ctx)
	local surface, v, char, p
	ctx.at(2, function()
		surface = fx.paved("sp24-b", -30, -30, 30, 30)
		v = ctron(surface, 0, 0, 10, { { name = "iron-plate", count = 200 } })
		char = character(surface, 6, 0)
		char.get_inventory(MAIN)[1].set_stack({ name = "iron-plate", count = 90 })
	end)
	ctx.at(10, function()
		local res
		p, res = proxy(char, { plan(IRON, MAIN, { { 0, 50 } }) })
		fx.note(SP, "b create ", res)
	end)
	watch(ctx, "b", 10, 3000, 30, { items = { iron = IRON }, ctron = function() return v end,
		char = function() return char end, proxy = function() return p end, charge = function() return { v } end })
end)

--- SP-24c: time to deliver 1000 items of 8 kinds with `robots` robots, default robot research.
local LOAD = { { "iron-plate", 200 }, { "copper-plate", 200 }, { "electronic-circuit", 200 }, { "steel-plate", 100 },
	{ "iron-gear-wheel", 100 }, { "transport-belt", 100 }, { "inserter", 50 }, { "stone-brick", 50 } }
for _, robots in ipairs({ 10, 50 }) do
	local tag = "c" .. robots
	t.case("SP-24" .. tag .. " 1000 items, 8 kinds, " .. robots .. " robots", function(ctx)
		local surface, v, char, p, started, first, done
		ctx.at(2, function()
			surface = fx.paved("sp24-" .. tag, -30, -30, 30, 30)
			local items = {}
			for _, it in ipairs(LOAD) do
				items[#items + 1] = { name = it[1], count = it[2] }
			end
			v = ctron(surface, 0, 0, robots, items)
			char = character(surface, 6, 0)
		end)
		ctx.at(10, function()
			local inserts, slot = {}, 0
			for _, it in ipairs(LOAD) do
				local size, left, slots = prototypes.item[it[1]].stack_size, it[2], {}
				while left > 0 do
					slots[#slots + 1] = { slot, math.min(size, left) }
					left, slot = left - math.min(size, left), slot + 1
				end
				inserts[#inserts + 1] = plan({ name = it[1] }, MAIN, slots)
			end
			local res
			p, res = proxy(char, inserts)
			started = game.tick
			fx.note(SP, tag, " create ", res, " slots used ", slot)
		end)
		for k = 11, 30000, 30 do
			ctx.at(k, function()
				if p == nil or started == nil then
					return
				end
				fx.charge(v)
				local got = char.get_inventory(MAIN).get_item_count()
				if got > 0 and not first then
					first = game.tick - started
				end
				if not p.valid and not done then
					done = true
					fx.note(SP, tag, " done after ", game.tick - started, " ticks, first item after ", first or -1,
						", main holds ", got)
				end
				if k + 30 > 30000 and p.valid then
					fx.note(SP, tag, " NOT done at ", game.tick - started, " ticks, main holds ", got, " ", proxy_state(p))
				end
			end)
		end
	end)
end

t.case("SP-24d ctron follows a character that walks and stops", function(ctx)
	local surface, v, char, p
	ctx.at(2, function()
		surface = fx.paved("sp24-d", -90, -30, 90, 30)
		v = ctron(surface, 0, 0, 10, { { name = "iron-plate", count = 300 } })
		char = character(surface, 6, 0)
	end)
	ctx.at(10, function()
		v.follow_target = char
		local res
		p, res = proxy(char, { plan(IRON, MAIN, { { 0, 100 }, { 1, 100 } }) })
		fx.note(SP, "d create ", res, " follow ", tostring(v.follow_target == char))
	end)
	-- Walk 300 ticks, stand 240, alternating east and west, from offset 30 to 5430.
	for k = 30, 5430 do
		ctx.at(k, function()
			local phase = math.floor((k - 30) / 540)
			local walking = (k - 30) % 540 < 300
			char.walking_state = { walking = walking,
				direction = phase % 2 == 0 and defines.direction.east or defines.direction.west }
		end)
	end
	watch(ctx, "d", 10, 6000, 60, { items = { iron = IRON }, ctron = function() return v end,
		char = function() return char end, proxy = function() return p end, charge = function() return { v } end,
		extra = function(s)
			s.char_x = math.floor(char.position.x * 10) / 10
			s.gap = math.floor(math.sqrt((v.position.x - char.position.x) ^ 2 + (v.position.y - char.position.y) ^ 2) * 10) / 10
			s.walking = char.walking_state.walking
		end })
end)

--- SP-24e/f/g: start a 100-plate delivery, and once robots carry plates, break it with `cut`.
local function interrupted(tag, desc, cut)
	t.case("SP-24" .. tag .. " " .. desc, function(ctx)
		local surface, v, char, p
		local s = { char = function() return char end }
		ctx.at(2, function()
			surface = fx.paved("sp24-" .. tag, -30, -30, 30, 30)
			v = ctron(surface, 0, 0, 10, { { name = "iron-plate", count = 200 } })
			char = character(surface, 6, 0)
		end)
		ctx.at(10, function()
			local res
			p, res = proxy(char, { plan(IRON, MAIN, { { 0, 100 } }) })
			fx.note(SP, tag, " create ", res)
		end)
		fx.wait(ctx, 11, 2000, tag .. " robots carry plates", function()
			fx.charge(v)
			return (where(surface, v, char, IRON))[4] > 0
		end, function()
			local w = where(surface, v, char, IRON)
			fx.note(SP, tag, " cut at tick ", game.tick, " ", table.concat(w, "/"))
			char = cut(char, p) or char
		end)
		watch(ctx, tag, 10, 4000, 30, { items = { iron = IRON }, ctron = function() return v end,
			char = s.char, proxy = function() return p end, charge = function() return { v } end,
			extra = function(st) st.char_valid = char.valid end })
	end)
end
interrupted("e", "proxy destroyed with plates in the air", function(_, p) p.destroy() end)
interrupted("f", "character destroyed with plates in the air", function(char) char.destroy() end)
interrupted("g", "target slot taken by another item with plates in the air", function(char)
	char.get_inventory(MAIN)[1].set_stack({ name = "copper-plate", count = 5 })
end)

t.case("SP-24h character inside a service station's network", function(ctx)
	local surface, v, char, p, chest
	ctx.at(2, function()
		character_logistics()
		surface = fx.paved("sp24-h", -40, -40, 40, 40)
		local station = assert(surface.create_entity({ name = "service_station", position = { 0, 0 }, force = "player" }))
		local power = surface.create_entity({ name = "electric-energy-interface", position = { -5, -3 }, force = "player" })
		power.power_production, power.electric_buffer_size = 1e9 / 60, 1e10
		surface.create_entity({ name = "substation", position = { -5, 0 }, force = "player" })
		local bots = station.get_inventory(defines.inventory.roboport_robot)
		bots.insert({ name = "logistic-robot", count = 10 })
		bots.insert({ name = "construction-robot", count = 10 })
		chest = fx.chest(surface, 5, 0, { ["iron-plate"] = 500, ["copper-plate"] = 500 })
		v = ctron(surface, 0, 10, 10, { { name = "iron-plate", count = 200 } })
		char = character(surface, 6, 10)
		-- A vanilla request for copper, beside the proxy's iron: does the station also serve the character?
		local point = char.get_requester_point()
		local section = point.get_section(1) or point.add_section()
		section.set_slot(1, { value = { name = "copper-plate", quality = "normal" }, min = 100, max = 100 })
		fx.json(SP, "h cells", { station_logistic_r = station.logistic_cell.logistic_radius,
			station_construction_r = station.logistic_cell.construction_radius,
			char_network = char.logistic_network ~= nil, ctron_network_same = v.logistic_network == station.logistic_network })
	end)
	ctx.at(120, function()
		local res
		p, res = proxy(char, { plan(IRON, MAIN, { { 5, 50 } }) })
		fx.note(SP, "h create ", res)
	end)
	watch(ctx, "h", 120, 3000, 30, { items = { iron = IRON, copper = { name = "copper-plate" } },
		ctron = function() return v end, char = function() return char end, proxy = function() return p end,
		charge = function() return { v } end,
		extra = function(s) s.chest_iron = chest.get_item_count("iron-plate") end })
end)

t.case("SP-24i character driving a car", function(ctx)
	local surface, v, char, p
	ctx.at(2, function()
		surface = fx.paved("sp24-i", -30, -30, 30, 30)
		v = ctron(surface, 0, 0, 10, { { name = "iron-plate", count = 200 } })
		char = character(surface, 6, 0)
		local car = surface.create_entity({ name = "car", position = { 6, 4 }, force = "player" })
		car.set_driver(char)
		fx.note(SP, "i driving ", tostring(char.driving), " vehicle ", char.vehicle and char.vehicle.name or "none")
	end)
	ctx.at(10, function()
		local res
		p, res = proxy(char, { plan(IRON, MAIN, { { 0, 50 } }) })
		fx.note(SP, "i create ", res)
	end)
	watch(ctx, "i", 10, 3000, 30, { items = { iron = IRON }, ctron = function() return v end,
		char = function() return char end, proxy = function() return p end, charge = function() return { v } end })
end)

t.case("SP-24j character with its own roboport and robots", function(ctx)
	local surface, v, char, p
	ctx.at(2, function()
		character_logistics()
		surface = fx.paved("sp24-j", -30, -30, 30, 30)
		v = ctron(surface, 0, 0, 10, { { name = "iron-plate", count = 200 } })
		char = character(surface, 6, 0)
		char.get_inventory(defines.inventory.character_armor).insert({ name = "power-armor-mk2" })
		char.grid.put({ name = "fission-reactor-equipment" })
		char.grid.put({ name = "personal-roboport-mk2-equipment" })
		char.get_inventory(MAIN)[1].set_stack({ name = "construction-robot", count = 10 })
		char.get_inventory(TRASH)[1].set_stack({ name = "stone", count = 40 })
		fx.charge(char)
	end)
	ctx.at(10, function()
		local res
		p, res = proxy(char, { plan(IRON, MAIN, { { 3, 30 } }) }, { plan(STONE, TRASH, { { 0, 40 } }) })
		fx.note(SP, "j create ", res, " char cell ", tostring(char.logistic_cell ~= nil))
	end)
	watch(ctx, "j", 10, 3000, 30, { items = { iron = IRON, stone = STONE }, ctron = function() return v end,
		char = function() return char end, proxy = function() return p end, charge = function() return { v, char } end })
end)

t.case("SP-24k read a character's requests, auto-trash, then fill what is missing", function(ctx)
	local surface, v, char, p, point
	ctx.at(2, function()
		character_logistics()
		surface = fx.paved("sp24-k", -30, -30, 30, 30)
		v = ctron(surface, 0, 0, 10, { { name = "iron-plate", count = 300 },
			{ name = "copper-plate", quality = "uncommon", count = 100 }, { name = "transport-belt", count = 100 } })
		char = character(surface, 6, 0)
		point = char.get_requester_point()
		ctx.expect(point ~= nil, "character has a requester point")
		local section = point.get_section(1) or point.add_section()
		section.set_slot(1, { value = { name = "iron-plate", quality = "normal" }, min = 100, max = 150 })
		section.set_slot(2, { value = { name = "copper-plate", quality = "uncommon", comparator = "=" }, min = 50 })
		section.set_slot(3, { value = { name = "transport-belt", quality = "normal" }, min = 20, max = 20 })
		point.trash_not_requested = true
		local main = char.get_inventory(MAIN)
		main.insert({ name = "copper-plate", quality = "uncommon", count = 10 })
		main.insert({ name = "transport-belt", count = 60 })
		main.insert({ name = "wood", count = 30 })
		fx.json(SP, "k point", { enabled = point.enabled, mode = point.mode, exact = point.exact,
			trash_not_requested = point.trash_not_requested, sections = point.sections_count, filters = point.filters })
	end)
	ctx.at(300, function()
		local main, trash = char.get_inventory(MAIN), char.get_inventory(TRASH)
		fx.json(SP, "k after 300 ticks", { main = main.get_contents(), trash = trash.get_contents(),
			targeted_deliver = point.targeted_items_deliver, targeted_pickup = point.targeted_items_pickup })
		-- Missing = min - held, per compiled filter; each item into the next empty main slots.
		local inserts, missing, taken = {}, {}, {}
		for _, f in pairs(point.filters or {}) do
			local id = { name = f.name, quality = f.quality }
			local short = f.count - main.get_item_count(id)
			if f.name and short > 0 then
				local slots, size = {}, prototypes.item[f.name].stack_size
				for i = 1, #main do
					if short <= 0 then break end
					if not main[i].valid_for_read and not taken[i] then
						slots[#slots + 1] = { i - 1, math.min(size, short) }
						short = short - math.min(size, short)
						taken[i] = true
					end
				end
				missing[#missing + 1] = { name = f.name, quality = f.quality, short = f.count - main.get_item_count(id) }
				inserts[#inserts + 1] = plan(id, MAIN, slots)
			end
		end
		local removals = {}
		for i = 1, #trash do
			local s = trash[i]
			if s.valid_for_read then
				removals[#removals + 1] = plan({ name = s.name, quality = s.quality.name }, TRASH, { { i - 1, s.count } })
			end
		end
		fx.json(SP, "k missing", missing)
		local res
		p, res = proxy(char, inserts, removals)
		fx.note(SP, "k create ", res)
	end)
	ctx.at(301, function()
		fx.json(SP, "k targeted after proxy", { deliver = point.targeted_items_deliver, pickup = point.targeted_items_pickup })
	end)
	watch(ctx, "k", 300, 4000, 60, { items = { iron = IRON, copper_uc = COPPER_UC, belt = { name = "transport-belt" },
		wood = WOOD }, ctron = function() return v end, char = function() return char end, proxy = function() return p end,
		charge = function() return { v } end })
end)

--- SP-24d2: why SP-24d delivered nothing. Walk 120 ticks, stand 600, alternating east and west; the ctron follows
--- (mode "follow", with enable_logistics_while_moving left as is, true or false) or stays put ("still").
for _, mode in ipairs({ "default", "true", "false", "still" }) do
	local tag = "d2-" .. mode
	t.case("SP-24" .. tag .. " walk and stop, logistics while moving " .. mode, function(ctx)
		local surface, v, char, p
		ctx.at(2, function()
			surface = fx.paved("sp24-" .. tag, -60, -30, 60, 30)
			v = ctron(surface, 0, 0, 10, { { name = "iron-plate", count = 300 } })
			char = character(surface, 6, 0)
		end)
		ctx.at(10, function()
			fx.note(SP, tag, " enable_logistics_while_moving default ", tostring(v.enable_logistics_while_moving))
			if mode == "true" or mode == "false" then
				v.enable_logistics_while_moving = mode == "true"
			end
			if mode ~= "still" then
				v.follow_target = char
			end
			local res
			p, res = proxy(char, { plan(IRON, MAIN, { { 0, 100 } }) })
			fx.note(SP, tag, " create ", res)
		end)
		for k = 30, 5790 do
			ctx.at(k, function()
				local phase = math.floor((k - 30) / 720)
				char.walking_state = { walking = (k - 30) % 720 < 120,
					direction = phase % 2 == 0 and defines.direction.east or defines.direction.west }
			end)
		end
		watch(ctx, tag, 10, 6000, 60, { items = { iron = IRON }, ctron = function() return v end,
			char = function() return char end, proxy = function() return p end, charge = function() return { v } end,
			extra = function(s)
				s.walking = char.walking_state.walking
				s.gap = math.floor(math.sqrt((v.position.x - char.position.x) ^ 2 + (v.position.y - char.position.y) ^ 2))
				local n, energy, far = 0, 0, 0
				for _, r in pairs(surface.find_entities_filtered({ type = "construction-robot" })) do
					n = n + 1
					energy = energy + r.energy
					far = math.max(far, math.floor(math.sqrt((r.position.x - char.position.x) ^ 2 + (r.position.y - char.position.y) ^ 2)))
				end
				s.robots, s.energy_kj, s.farthest = n, n > 0 and math.floor(energy / n / 1000) or 0, far
			end })
	end)
end

t.case("SP-24l trash pickup into a full trunk", function(ctx)
	local surface, v, char, p
	ctx.at(2, function()
		character_logistics()
		surface = fx.paved("sp24-l", -30, -30, 30, 30)
		v = ctron(surface, 0, 0, 10)
		fx.trunk_of(v).insert({ name = "stone-brick", count = 100000 })
		char = character(surface, 6, 0)
		char.get_inventory(TRASH)[1].set_stack({ name = "stone", count = 40 })
		fx.note(SP, "l trunk free slots ", fx.trunk_of(v).count_empty_stacks())
	end)
	ctx.at(10, function()
		local res
		p, res = proxy(char, nil, { plan(STONE, TRASH, { { 0, 40 } }) })
		fx.note(SP, "l create ", res)
	end)
	ctx.at(1500, function()
		fx.trunk_of(v).remove({ name = "stone-brick", count = 500 })
		fx.note(SP, "l freed 10 slots at 1500")
	end)
	watch(ctx, "l", 10, 3500, 30, { items = { stone = STONE }, ctron = function() return v end,
		char = function() return char end, proxy = function() return p end, charge = function() return { v } end })
end)

t.case("SP-24m ctron short of the requested items, topped up later", function(ctx)
	local surface, v, char, p
	ctx.at(2, function()
		surface = fx.paved("sp24-m", -30, -30, 30, 30)
		v = ctron(surface, 0, 0, 10, { { name = "iron-plate", count = 20 } })
		char = character(surface, 6, 0)
	end)
	ctx.at(10, function()
		local res
		p, res = proxy(char, { plan(IRON, MAIN, { { 0, 50 } }) })
		fx.note(SP, "m create ", res)
	end)
	ctx.at(1500, function()
		fx.trunk_of(v).insert({ name = "iron-plate", count = 30 })
		fx.note(SP, "m added 30 at 1500")
	end)
	watch(ctx, "m", 10, 3500, 30, { items = { iron = IRON }, ctron = function() return v end,
		char = function() return char end, proxy = function() return p end, charge = function() return { v } end })
end)
