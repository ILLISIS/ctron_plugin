local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")

t.case("SP-4 item-request-proxy and ghost: which field holds module requests with quality", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-4.txt")
	ctx.at(2, function()
		local surface = fx.surface("sp4-proxy")
		fx.ground(surface, -20, -20, 20, 20)
		local machine = surface.create_entity({ name = "assembling-machine-2", position = { 0, 0 }, force = "player" })
		ctx.expect(machine ~= nil, "machine created")
		local plan = { { id = { name = "speed-module", quality = "uncommon" }, items = { in_inventory = {
			{ inventory = defines.inventory.crafter_modules, stack = 0 },
			{ inventory = defines.inventory.crafter_modules, stack = 1 } } } } }
		local proxy = surface.create_entity({ name = "item-request-proxy", position = machine.position, force = "player",
			target = machine, modules = plan })
		ctx.expect(proxy ~= nil, "proxy created")
		if proxy then
			fx.json("SP-4", "proxy item_requests", proxy.item_requests)
			fx.json("SP-4", "proxy insert_plan", proxy.insert_plan)
			fx.note("SP-4", "proxy registered: ", tostring(proxy.is_registered_for_construction()),
				", proxy_target == machine: ", tostring(proxy.proxy_target == machine))
		end
		local ghost = surface.create_entity({ name = "entity-ghost", inner_name = "assembling-machine-2",
			position = { 10, 0 }, force = "player" })
		ctx.expect(ghost ~= nil, "ghost created")
		if ghost then
			ghost.insert_plan = plan
			fx.json("SP-4", "ghost item_requests", ghost.item_requests)
			fx.json("SP-4", "ghost insert_plan", ghost.insert_plan)
			local items = {}
			for _, i in ipairs(ghost.ghost_prototype.items_to_place_this or {}) do
				items[#items + 1] = { name = i.name, count = i.count }
			end
			fx.json("SP-4", "ghost items_to_place_this", items)
		end
	end)
end)
