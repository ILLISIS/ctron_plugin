local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")

-- SP-5 (04 S7): what LuaLogisticNetwork.get_item_count counts, and how long after a 0/0 unload it stops rising.
local SP = "SP-5"

t.case("SP-5 members: get_item_count over storage, buffer, passive provider and requester chests", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-5.txt")
	local station
	ctx.at(2, function()
		local surface = fx.surface("sp5-members")
		fx.ground(surface, -40, -40, 40, 40)
		station = fx.station(surface, 0, 0, { ["iron-plate"] = 100 })
		ctx.expect(station ~= nil, "station")
		local items = { ["iron-plate"] = 100 }
		ctx.expect(fx.chest(surface, 5, 3, items, "passive-provider-chest"), "provider chest")
		ctx.expect(fx.chest(surface, 5, -3, items, "buffer-chest"), "buffer chest")
		ctx.expect(fx.chest(surface, 7, 0, items, "requester-chest"), "requester chest")
	end)
	ctx.at(122, function()
		local net = station.logistic_network
		ctx.expect(net ~= nil, "station has a network")
		if not net then return end
		fx.note(SP, "members all ", net.get_item_count("iron-plate"))
		fx.note(SP, "members storage ", net.get_item_count("iron-plate", "storage"))
		fx.note(SP, "members providers ", net.get_item_count("iron-plate", "providers"))
	end)
end)

t.case("SP-5 unload: net count after a spidertron's 0/0 request, with robots in flight", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-5.txt")
	local station, chest, v, net
	local prev, t0, last_rise
	ctx.at(2, function()
		local surface = fx.surface("sp5-unload")
		fx.ground(surface, -40, -40, 40, 40)
		station, chest = fx.station(surface, 0, 0)
		-- fx.station's power runs dry near tick 4470 (station.energy 0); this run is longer, so add a second source.
		local power = surface.create_entity({ name = "electric-energy-interface", position = { -5, 9 }, force = "player" })
		power.power_production, power.electric_buffer_size = 1e8 / 60, 1e10
		v = fx.ctron(surface, 6, 6)
		v.get_inventory(defines.inventory.spider_trunk).insert({ name = "iron-plate", count = 200 })
		ctx.expect(station ~= nil and v ~= nil, "station and ctron")
	end)
	ctx.at(122, function()
		net = station.logistic_network
		ctx.expect(net ~= nil, "station has a network")
		local point = v.get_logistic_point(defines.logistic_member_index.spidertron_requester)
		ctx.expect(point ~= nil, "requester point")
		point.trash_not_requested = false
		local section = point.get_section(1) or point.add_section()
		section.set_slot(1, { value = { name = "iron-plate", quality = "normal" }, min = 0, max = 0 })
		fx.json(SP, "unload slot", section.get_slot(1))
	end)
	for k = 0, 620 do
		ctx.at(122 + k * 10, function()
			net = station.logistic_network -- the object can be replaced when the network is rebuilt
			if not net then
				fx.note(SP, "no network at t ", k * 10, ", station valid ", tostring(station.valid), ", ctron valid ", tostring(v.valid),
					", cell ", tostring(v.valid and v.logistic_cell ~= nil), ", energy ", station.energy)
				return
			end
			local trunk = v.get_inventory(defines.inventory.spider_trunk).get_item_count("iron-plate")
			local trash = v.get_inventory(defines.inventory.spider_trash).get_item_count("iron-plate")
			local flying = 0
			for _, r in pairs(net.logistic_robots) do
				flying = flying + r.get_inventory(defines.inventory.robot_cargo).get_item_count("iron-plate")
			end
			local count = net.get_item_count("iron-plate")
			fx.json(SP, "unload", { t = k * 10, net = count, storage = net.get_item_count("iron-plate", "storage"),
				providers = net.get_item_count("iron-plate", "providers"),
				chest = chest.get_item_count("iron-plate"), trunk = trunk, trash = trash, flying = flying })
			if trunk == 0 and trash == 0 and not t0 then t0 = k * 10 end
			if prev and count > prev then last_rise = k * 10 end
			prev = count
		end)
	end
	ctx.at(122 + 6200 + 2, function()
		fx.note(SP, "unload t0 (trunk and trash 0) ", tostring(t0), ", last net rise ", tostring(last_rise),
			", lag ", tostring(t0 and last_rise and last_rise - t0))
	end)
end)
