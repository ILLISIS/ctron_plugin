local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")

-- SP-10 (00 S2, 04 S9): CC's reduced roboport swap in 2.1: take, then put "<eq>-reduced-1" at the same position.
local SP = "SP-10"

--- Swap every roboport equipment on the grid to `suffix` (add) or back (strip); records each step.
local function swap(v, tag, to_name)
	local grid = v.grid
	local list = {}
	for _, eq in pairs(grid.equipment) do
		if eq.type == "roboport-equipment" then list[#list + 1] = eq end
	end
	for i, eq in ipairs(list) do
		local name, position, energy, quality = eq.name, eq.position, eq.energy, eq.quality.name
		fx.json(SP, tag .. " before " .. i, { name = name, position = position, energy = energy, quality = quality })
		local item = grid.take({ equipment = eq })
		fx.json(SP, tag .. " take " .. i, item and { name = item.name, count = item.count, quality = item.quality } or {})
		local new = grid.put({ name = to_name(name), quality = quality, position = position })
		fx.json(SP, tag .. " put " .. i, new and { name = new.name, position = new.position, energy = new.energy } or {})
		if new then
			new.energy = energy
			fx.json(SP, tag .. " energy readback " .. i, { set = energy, read = new.energy })
		end
	end
end

t.case("SP-10 reduced roboports: swap to -reduced-1 and back, radius and energy", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-10.txt")
	local v
	ctx.at(2, function()
		local surface = fx.surface("sp10-swap")
		fx.ground(surface, -20, -20, 20, 20)
		v = fx.ctron(surface, 0, 0)
		ctx.expect(v ~= nil, "ctron")
	end)
	local function radius() return v.logistic_cell and v.logistic_cell.construction_radius end
	local function proto(name)
		local p = prototypes.equipment[name]
		local lp = p and p.logistic_parameters
		return lp and { construction_radius = lp.construction_radius, logistic_radius = lp.logistic_radius } or {}
	end
	ctx.at(122, function()
		fx.json(SP, "initial", { radius = radius(),
			reduced_1 = prototypes.equipment["personal-roboport-mk2-equipment-reduced-1"] ~= nil,
			reduced_0 = prototypes.equipment["personal-roboport-mk2-equipment-reduced-0"] ~= nil })
		for _, name in ipairs({ "personal-roboport-mk2-equipment", "personal-roboport-mk2-equipment-reduced-1",
			"personal-roboport-mk2-equipment-reduced-0" }) do
			fx.json(SP, "prototype " .. name, proto(name))
		end
		swap(v, "down", function(name) return name .. "-reduced-1" end)
		fx.json(SP, "after down, same tick", { radius = radius() })
	end)
	for _, dt in ipairs({ 1, 2, 10, 60 }) do
		ctx.at(122 + dt, function() fx.json(SP, "down +" .. dt, { radius = radius() }) end)
	end
	ctx.at(200, function()
		swap(v, "up", function(name) return (string.gsub(name, "%-reduced%-%d+$", "")) end)
		fx.json(SP, "after up, same tick", { radius = radius() })
	end)
	for _, dt in ipairs({ 1, 2, 10, 60 }) do
		ctx.at(200 + dt, function() fx.json(SP, "up +" .. dt, { radius = radius() }) end)
	end
end)
