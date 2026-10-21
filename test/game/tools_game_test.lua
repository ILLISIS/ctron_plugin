local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ct = require("modules/ctron_pluginv2/ct")
local cells = require("modules/ctron_pluginv2/cells_core")

--- Make surface schedulable (and give it its own overrides patch, if any), keeping every other case's settings.
local function schedule(name, patch)
	local s = storage.ctron_pluginv2
	local o = helpers.json_to_table(helpers.table_to_json({ o = s.settings.overrides })).o or {}
	if patch then
		o[name] = patch
	end
	local list = { name }
	for other in pairs(s.schedulable) do
		if other ~= name then
			list[#list + 1] = other
		end
	end
	fx.send("ct.settings", { overrides = o, surfaces = list })
end

local function wid(surface, kind, x, y)
	return cells.wid(ct.registry.here(), surface.name, kind, cells.key(x, y))
end

local function select(kind, event)
	event.item = event.item or "ctron-selection-tool"
	event.entities = event.entities or {}
	event.tiles = event.tiles or {}
	ct.tools.events[defines.events[kind]](event)
end

t.case("G6 select: ghosts and proxies make construction tool cells, upgrade marks make upgrade tool cells; other items are ignored",
	function(ctx)
		ctx.at(10, function()
			local surface = fx.surface("ctv2-tool-1")
			fx.ground(surface, -10, -10, 240, 30)
			schedule(surface.name, { kinds = { upgrade = false } })
		end)
		ctx.at(12, function()
			local surface = game.surfaces["ctv2-tool-1"]
			local ghost = fx.ghost(surface, 10.5, 10.5, nil, true)
			local belt = surface.create_entity({ name = "transport-belt", position = { 100.5, 10.5 }, force = "player" })
			ctx.expect(belt.order_upgrade({ target = "fast-transport-belt", force = "player" }), "upgrade ordered")
			local other = fx.ghost(surface, 200.5, 10.5, nil, true)
			ctx.expect(ct.discovery.cell(wid(surface, "construction", 10.5, 10.5)) == nil, "quiet ghost: no cell yet")
			select("on_player_selected_area", { entities = { ghost, belt }, surface = surface })
			local c = ct.discovery.cell(wid(surface, "construction", 10.5, 10.5))
			ctx.expect(c and c.tool == true, "construction tool cell")
			c = ct.discovery.cell(wid(surface, "upgrade", 100.5, 10.5))
			ctx.expect(c and c.tool == true, "upgrade tool cell")
			select("on_player_selected_area", { item = "blueprint", entities = { other }, surface = surface })
			ctx.expect(ct.discovery.cell(wid(surface, "construction", 200.5, 10.5)) == nil, "other item: no cell")
		end)
	end)

t.case("G6 reverse select orders deconstruction of player and neutral entities and tiles, not enemies, even with deconstruction off",
	function(ctx)
		ctx.at(20, function()
			local surface = fx.surface("ctv2-tool-2")
			fx.ground(surface, -10, -10, 60, 30)
			schedule(surface.name, { kinds = { deconstruction = false } })
		end)
		ctx.at(22, function()
			local surface = game.surfaces["ctv2-tool-2"]
			local chest = fx.chest(surface, 10.5, 10.5, nil, "wooden-chest")
			local tree = surface.create_entity({ name = "tree-01", position = { 14, 10 }, force = "neutral" })
			local spawner = surface.create_entity({ name = "biter-spawner", position = { 30, 10 }, force = "enemy" })
			surface.set_tiles({ { name = "stone-path", position = { 20, 10 } } })
			select("on_player_reverse_selected_area", { entities = { chest, tree, spawner },
				tiles = { surface.get_tile(20, 10) }, surface = surface })
			ctx.expect(chest.to_be_deconstructed(), "chest ordered")
			ctx.expect(tree.to_be_deconstructed(), "tree ordered")
			ctx.expect(not spawner.to_be_deconstructed(), "spawner not ordered")
			ctx.expect(surface.count_entities_filtered({ name = "deconstructible-tile-proxy",
				position = { 20.5, 10.5 } }) == 1, "tile proxy")
			local c = ct.discovery.cell(wid(surface, "deconstruction", 10.5, 10.5))
			ctx.expect(c and c.tool == true, "deconstruction tool cell")
		end)
	end)

t.case("G6 alt reverse select makes destroy tool cells for spawners and worms only, with destroy off", function(ctx)
	ctx.at(30, function()
		local surface = fx.surface("ctv2-tool-3")
		fx.ground(surface, -10, -10, 240, 30)
		schedule(surface.name, { kinds = { destroy = false } })
	end)
	ctx.at(32, function()
		local surface = game.surfaces["ctv2-tool-3"]
		local function enemy(name, x)
			return surface.create_entity({ name = name, position = { x, 10 }, force = "enemy" })
		end
		local spawner, worm, biter = enemy("biter-spawner", 10), enemy("small-worm-turret", 100), enemy("small-biter", 200)
		select("on_player_alt_reverse_selected_area", { entities = { spawner, worm, biter }, surface = surface })
		for _, e in ipairs({ spawner, worm }) do
			local c = ct.discovery.cell(wid(surface, "destroy", e.position.x, e.position.y))
			ctx.expect(c and c.tool == true, e.name .. " destroy tool cell")
		end
		ctx.expect(ct.discovery.cell(wid(surface, "destroy", 200, 10)) == nil, "no cell for the biter")
	end)
end)

t.case("G6 alt select without a player opens nothing and raises nothing", function(ctx)
	ctx.at(40, function()
		local surface = fx.surface("ctv2-tool-4")
		fx.ground(surface, -10, -10, 40, 30)
		local ctron = fx.ctron(surface, 10.5, 10.5)
		local calls = 0
		local real = ct.gui.open_details
		ct.gui.open_details = function()
			calls = calls + 1
		end
		select("on_player_alt_selected_area", { entities = { ctron }, surface = surface })
		ct.gui.open_details = real
		ctx.expect(calls == 0, "open_details called " .. calls .. " times")
	end)
end)

t.case("G6 remote interface: scan-entity makes a cell and registers a ctron; names round-trip", function(ctx)
	ctx.at(50, function()
		local surface = fx.surface("ctv2-tool-5")
		fx.ground(surface, -10, -10, 40, 30)
		schedule(surface.name)
	end)
	ctx.at(52, function()
		local surface = game.surfaces["ctv2-tool-5"]
		local ghost = fx.ghost(surface, 10.5, 10.5, nil, true)
		remote.call("ctron", "scan-entity", ghost)
		local c = ct.discovery.cell(wid(surface, "construction", 10.5, 10.5))
		ctx.expect(c ~= nil and not c.tool, "construction cell, not tool")
		remote.call("ctron", "add-ctron-names", "spidertron")
		ctx.expect(remote.call("ctron", "get-ctron-names").spidertron == true, "name added")
		local spider = surface.create_entity({ name = "spidertron", position = { 20, 20 }, force = "player",
			raise_built = false })
		remote.call("ctron", "scan-entities", { spider })
		ctx.expect(ct.registry.ctron_of(spider) ~= nil, "spidertron registered")
		storage.ctron_pluginv2.names.ctrons.spidertron = nil
		spider.destroy({ raise_destroy = true })
		ctx.expect(remote.call("ctron", "get-station-names").service_station == true, "station names")
	end)
end)
