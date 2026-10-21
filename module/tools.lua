-- The selection tool, CC's remote interface and CC's welcome line (spec §5.11, R-48; CC entity_processor.lua:365-435,
-- control.lua:357-359, 480-542). Tool selections make `tool` cells that bypass the kind toggles and the zone.
local ct = require("modules/ctron_pluginv2/ct")

local tools = { events = {} }

local TOOL = "ctron-selection-tool"
local GHOSTS = { ["entity-ghost"] = true, ["tile-ghost"] = true, ["item-request-proxy"] = true }

local function player_of(event)
	return event.player_index and game.get_player(event.player_index) or nil
end

tools.events[defines.events.on_player_selected_area] = function(event)
	if event.item ~= TOOL then
		return
	end
	for _, e in pairs(event.entities) do
		if e.valid then
			if GHOSTS[e.type] then
				ct.discovery.touch("construction", e, true)
			elseif e.to_be_upgraded() then
				ct.discovery.touch("upgrade", e, true)
			end
		end
	end
end

tools.events[defines.events.on_player_reverse_selected_area] = function(event)
	if event.item ~= TOOL then
		return
	end
	local player = player_of(event)
	local force = player and player.force or "player"
	for _, e in pairs(event.entities) do
		if e.valid and (e.force.name == "player" or e.force.name == "neutral") then
			e.order_deconstruction(force, player)
			ct.discovery.touch("deconstruction", e, true)
		end
	end
	for _, tile in pairs(event.tiles) do
		if tile.valid then
			tile.order_deconstruction(force, player)
			ct.discovery.touch("deconstruction", tile, true)
		end
	end
end

tools.events[defines.events.on_player_alt_reverse_selected_area] = function(event)
	if event.item ~= TOOL then
		return
	end
	for _, e in pairs(event.entities) do
		if e.valid and e.force.name == "enemy" and (e.type == "unit-spawner" or e.type == "turret") then
			ct.discovery.touch("destroy", e, true)
		end
	end
end

tools.events[defines.events.on_player_alt_selected_area] = function(event)
	if event.item ~= TOOL then
		return
	end
	local player = player_of(event)
	if not player then
		return
	end
	for _, e in pairs(event.entities) do
		local cid = e.valid and ct.registry.ctron_of(e)
		local run = cid and ct.runs.get(cid)
		if run then
			ct.gui.open_details(player, run.jid)
			return
		end
	end
end

tools.events[defines.events.on_research_finished] = function(event)
	if event.research.name == "spidertron" then
		game.print("Welcome to [item=constructron]! Please see the games tips and tricks for more information about "
			.. "Constructrons use!")
	end
end

local function scan(e)
	local event = { entity = e, name = defines.events.script_raised_built, tick = game.tick }
	ct.registry.events[defines.events.script_raised_built](event)
	ct.discovery.events[defines.events.script_raised_built](event)
end

-- CC's runtime is off under UE, but a second add_interface would raise.
if not remote.interfaces["ctron"] then
	remote.add_interface("ctron", {
		["scan-entity"] = scan,
		["scan-entities"] = function(list)
			for _, e in pairs(list) do
				scan(e)
			end
		end,
		["add-ctron-names"] = function(name)
			storage.ctron_pluginv2.names.ctrons[name] = true
		end,
		["add-station-names"] = function(name)
			storage.ctron_pluginv2.names.stations[name] = true
		end,
		["get-ctron-names"] = function()
			return storage.ctron_pluginv2.names.ctrons
		end,
		["get-station-names"] = function()
			return storage.ctron_pluginv2.names.stations
		end,
	})
end

return tools
