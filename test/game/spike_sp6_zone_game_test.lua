local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")

t.case("SP-6 find_logistic_networks_by_construction_area: cost and ctron's own cell", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-6.txt")
	local surface, station, ctron1, ctron2
	ctx.at(2, function()
		surface = fx.surface("sp6-zone")
		fx.ground(surface, -60, -60, 220, 60)
		station = fx.station(surface, 0, 0)
		ctron1 = fx.ctron(surface, 150, 0)
		ctron2 = fx.ctron(surface, 20, 0)
		ctx.expect(ctron1.valid and ctron2.valid, "ctrons created")
	end)
	ctx.at(130, function()
		local points = { { 10, 0, "station only" }, { 150, 5, "lone ctron" }, { 20, 2, "station and second ctron" },
			{ 300, 0, "neither" }, { -8, 0, "station only, west" } }
		for _, pt in ipairs(points) do
			local nets = surface.find_logistic_networks_by_construction_area({ pt[1], pt[2] }, "player")
			local out = {}
			for _, net in ipairs(nets) do
				local owners = {}
				for _, cell in ipairs(net.cells) do
					owners[#owners + 1] = cell.owner.type
				end
				out[#out + 1] = { id = net.network_id, cells = #net.cells, owners = owners }
			end
			fx.json("SP-6", pt[3], { point = { pt[1], pt[2] }, n = #nets, nets = out })
		end
		local scell = station.logistic_cell
		fx.note("SP-6", "station cell: ", tostring(scell ~= nil), ", construction_radius: ",
			scell and scell.construction_radius or -1, ", type ", station.type)
		for i, v in ipairs({ ctron1, ctron2 }) do
			local cell = v.logistic_cell
			fx.note("SP-6", "ctron ", i, " construction_radius: ", cell and cell.construction_radius or -1)
		end
		local p = helpers.create_profiler()
		for _ = 1, 1000 do local _ = surface.find_logistic_networks_by_construction_area({ 10, 0 }, "player") end
		p.stop()
		p.divide(1000)
		fx.note("SP-6", "call per call ", p)
	end)
end)
