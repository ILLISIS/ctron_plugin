local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")

-- SP-8 (00 S1; 04 S5, S6): the request protocol on a spidertron.
local SP = "SP-8"

-- The spidertron's requester point and its section 1.
local function request_point(v)
	local point = v.get_logistic_point(defines.logistic_member_index.spidertron_requester)
	return point, point and (point.get_section(1) or point.add_section())
end

t.case("SP-8 fresh force: set_slot on a force without logistic-system", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-8.txt")
	local f, v
	ctx.at(2, function()
		f = game.create_force("sp8-fresh")
		local surface = fx.surface("sp8-fresh")
		fx.ground(surface, -40, -40, 40, 40)
		fx.station(surface, 0, 0, { ["iron-plate"] = 200 }, { force = f.name })
		v = fx.ctron(surface, 6, 0, { force = f.name })
		ctx.expect(v ~= nil, "ctron")
	end)
	ctx.at(122, function()
		local point, section = request_point(v)
		ctx.expect(point ~= nil and section ~= nil, "requester point and section 1")
		if not (point and section) then return end
		local ok, err = pcall(section.set_slot, 1,
			{ value = { name = "iron-plate", quality = "normal" }, min = 50, max = 50 })
		fx.json(SP, "fresh set_slot", { ok = ok, err = not ok and tostring(err) or nil })
		fx.json(SP, "fresh get_slot(1)", section.get_slot(1))
		fx.json(SP, "fresh", { sections_count = point.sections_count, filters_count = section.filters_count,
			researched = f.technologies["logistic-system"].researched })
	end)
	-- Is the stored request honoured? Sample the trunk, and the cell's network, for 900 ticks.
	for k = 0, 15 do
		ctx.at(122 + k * 60, function()
			fx.json(SP, "fresh load", { t = k * 60, iron = v.get_inventory(defines.inventory.spider_trunk).get_item_count("iron-plate"),
				network = v.logistic_network ~= nil })
		end)
	end
end)

t.case("SP-8 protocol: exact loading, 0/0 unload, trash_not_requested, rockets in ammo (force player)", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-8.txt")
	local T0, T1 = 122, 122 + 2400 + 2
	local station, chest, v, point, section
	local reached
	local function inv(id) return v.get_inventory(id) end
	ctx.at(2, function()
		local surface = fx.surface("sp8-protocol")
		fx.ground(surface, -40, -40, 40, 40)
		station, chest = fx.station(surface, 0, 0, { ["iron-plate"] = 200, rocket = 100 })
		-- A second power source, as in SP-5.
		local power = surface.create_entity({ name = "electric-energy-interface", position = { -5, 9 }, force = "player" })
		power.power_production, power.electric_buffer_size = 1e8 / 60, 1e10
		v = fx.ctron(surface, 6, 0)
		inv(defines.inventory.spider_trunk).insert({ name = "stone", count = 30 })
		ctx.expect(station ~= nil and v ~= nil, "station and ctron")
	end)
	ctx.at(T0, function()
		point, section = request_point(v)
		ctx.expect(point ~= nil and section ~= nil, "requester point and section 1")
		point.trash_not_requested = false
		section.set_slot(1, { value = { name = "iron-plate", quality = "normal" }, min = 50, max = 50 })
		section.set_slot(2, { value = { name = "rocket", quality = "normal" }, min = 20, max = 20 })
		fx.json(SP, "protocol get_slot(1)", section.get_slot(1))
		fx.json(SP, "protocol get_slot(2)", section.get_slot(2))
	end)
	for k = 0, 80 do
		ctx.at(T0 + k * 30, function()
			local trunk, ammo = inv(defines.inventory.spider_trunk), inv(defines.inventory.spider_ammo)
			local s = { t = k * 30, iron = trunk.get_item_count("iron-plate"), rocket_trunk = trunk.get_item_count("rocket"),
				rocket_ammo = ammo and ammo.get_item_count("rocket") or -1, stone = trunk.get_item_count("stone"),
				trash = inv(defines.inventory.spider_trash).get_contents(), targeted = point.targeted_items_deliver }
			fx.json(SP, "load", s)
			if not reached and s.iron == 50 and s.rocket_trunk + s.rocket_ammo == 20 then
				reached = k * 30
				fx.note(SP, "load: iron 50 and rockets 20 first at t ", reached)
			end
		end)
	end
	ctx.at(T1, function()
		section.set_slot(1, { value = { name = "iron-plate", quality = "normal" }, min = 0, max = 0 })
		section.clear_slot(2)
		fx.json(SP, "unload get_slot(1)", section.get_slot(1))
		fx.json(SP, "unload get_slot(2)", section.get_slot(2))
	end)
	for k = 0, 60 do
		ctx.at(T1 + k * 30, function()
			fx.json(SP, "unload", { t = k * 30, iron = inv(defines.inventory.spider_trunk).get_item_count("iron-plate"),
				trash_iron = inv(defines.inventory.spider_trash).get_item_count("iron-plate"),
				rocket = inv(defines.inventory.spider_trunk).get_item_count("rocket")
					+ inv(defines.inventory.spider_ammo).get_item_count("rocket"),
				chest_iron = chest.get_item_count("iron-plate") })
		end)
	end
end)
