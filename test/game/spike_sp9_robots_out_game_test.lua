local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")

-- SP-9 (04 S3): is all_construction_robots - available_construction_robots the robots out, charging ones included?
local SP = "SP-9"

-- The fixture's reactor has no fuel (energy 0), so the roboports sit at 800 kJ; fill them so robots can leave.
local function charge(v)
	for _, eq in pairs(v.grid.equipment) do
		if eq.type == "roboport-equipment" then eq.energy = eq.max_energy end
	end
end

t.case("SP-9 robots out: all - available against deployed, charging and queued robots", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-9.txt")
	local v
	ctx.at(2, function()
		local surface = fx.surface("sp9-out")
		fx.ground(surface, -40, -40, 40, 40)
		v = fx.ctron(surface, 0, 0)
		v.get_inventory(defines.inventory.spider_trunk).insert({ name = "wooden-chest", count = 20 })
		ctx.expect(v ~= nil, "ctron")
	end)
	ctx.at(122, function()
		charge(v)
		local surface = v.surface
		for _, x in ipairs({ -8, -4, 0, 4, 8 }) do
			for _, y in ipairs({ -6, -2, 2, 6 }) do
				ctx.expect(fx.ghost(surface, x + 0.5, y + 0.5, "wooden-chest", true), "ghost " .. x .. "," .. y)
			end
		end
	end)
	ctx.at(130, function()
		local cell, g = v.logistic_cell, v.grid
		local eqs = {}
		for _, eq in pairs(g.equipment) do
			eqs[#eqs + 1] = { eq.name, eq.energy, eq.max_energy }
		end
		fx.json(SP, "setup", { construction_radius = cell and cell.construction_radius, logistic_radius = cell and cell.logistic_radius,
			mobile = cell and cell.mobile,
			equipment = eqs, trunk_chests = v.get_inventory(defines.inventory.spider_trunk).get_item_count("wooden-chest") })
	end)
	for k = 0, 90 do
		ctx.at(122 + k * 10, function()
			charge(v)
			local net, cell = v.logistic_network, v.logistic_cell
			if not (net and cell) then
				fx.note(SP, "no network or cell at t ", k * 10)
				return
			end
			local all, avail = net.all_construction_robots, net.available_construction_robots
			fx.json(SP, "sample", { t = k * 10, all = all, avail = avail, out = all - avail,
				deployed = #net.construction_robots, charging = cell.charging_robot_count,
				to_charge = cell.to_charge_robot_count, stationed = cell.stationed_construction_robot_count,
				ghosts = v.surface.count_entities_filtered({ type = "entity-ghost", area = { { -10, -10 }, { 10, 10 } } }) })
		end)
	end
end)
