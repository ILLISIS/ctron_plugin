-- Player supply on the tile (owner's design, SP-24): the panel on the character screen, a player's call and cancel,
-- where players are, the controller's state of each call, and the item-request-proxies a supply run hands over with.
-- The ctron's part (to the player, following them, handing over) is a run (run_core, runs).
local ue = require("modules/universal_edges")
local ct = require("modules/ctron_pluginv2/ct")
local bridge = require("modules/ctron_pluginv2/bridge")
local items = require("modules/ctron_pluginv2/items_core")
local core = require("modules/ctron_pluginv2/supply_core")

local supply = { events = {} }

local PANEL = "ctronv2_supply"
local MOVED = 32 -- an open call's player is reported again once this far from where they were last reported
local MAX_KINDS = 30 -- a call names at most 30 kinds, so it fits one message (R-152, R-154)
local OPEN = { waiting = true, loading = true, coming = true, delivering = true }
local leaving -- the player whose leave is being handled: no longer on this tile for the runs

local function S()
	local s = storage.ctron_pluginv2
	return s and s.supply
end

local function start()
	local s = storage.ctron_pluginv2
	s.supply = s.supply or {}
	local u = s.supply
	u.calls = u.calls or {} -- player name -> { st, why }, the controller's word on their call
	u.sent = u.sent or {} -- player name -> { surface, x, y }, where they were last reported
	u.stand_in = u.stand_in or {} -- game tests: player name -> a character standing in for them
end
supply.on_init = start
supply.on_server_startup = start

--- The character of the connected player called name, unless they are leaving, or a game test's stand-in.
function supply.character(name)
	if name == leaving then
		return nil
	end
	local player = game.get_player(name)
	if player and player.connected then
		return player.character
	end
	local c = S().stand_in[name]
	return c and c.valid and c or nil
end

function supply.stand_in(name, character)
	S().stand_in[name] = character
end

local function held_of(char)
	local map = {}
	for _, c in ipairs(char.get_main_inventory().get_contents()) do
		items.add(map, c.name, c.quality, c.count)
	end
	local cursor = char.player and char.player.cursor_stack
	if cursor and cursor.valid_for_read then
		items.add(map, cursor.name, cursor.quality.name, cursor.count)
	end
	return map
end

--- What char misses of its logistic requests (an item map); nothing while its logistics are off.
function supply.missing(char)
	local point = char.get_requester_point()
	if not (point and point.enabled) then
		return {}
	end
	local coming = {}
	for _, c in ipairs(point.targeted_items_deliver or {}) do
		items.add(coming, c.name, c.quality, c.count)
	end
	return core.missing(point.filters or {}, held_of(char), coming)
end

local function main_slots(char)
	local inv, out = char.get_main_inventory(), {}
	for i = 1, #inv do
		local s = inv[i]
		if s.valid_for_read then
			out[i] = { name = s.name, quality = s.quality.name, count = s.count }
		else
			local f = inv.get_filter(i)
			out[i] = { count = 0, filter = type(f) == "table" and f.name or f }
		end
	end
	return out
end

local function trash_slots(char)
	local inv, out = char.get_inventory(defines.inventory.character_trash), {}
	for i = 1, inv and #inv or 0 do
		local s = inv[i]
		out[i] = s.valid_for_read and { name = s.name, quality = s.quality.name, count = s.count } or { count = 0 }
	end
	return out
end

--- The next proxy for char from a ctron whose trunk holds `held` and which keeps `keep` (supply_core.plan).
function supply.plan(char, held, keep)
	local give = core.give(supply.missing(char), held, keep)
	return core.plan(give, main_slots(char), trash_slots(char), ct.settings.stacks)
end

--- An item-request-proxy on char: the plan's inserts into its main inventory, its takes out of its trash (SP-24a).
--- A refusal is logged, not raised: a script error ends the tile without a save, and the next poll plans again.
function supply.make_proxy(char, force, plan)
	local modules, removal = {}, {}
	for _, e in ipairs(plan.inserts) do
		local at = {}
		for i, s in ipairs(e[3]) do
			at[i] = { inventory = defines.inventory.character_main, stack = s[1], count = s[2] }
		end
		modules[#modules + 1] = { id = { name = e[1], quality = e[2] }, items = { in_inventory = at } }
	end
	for _, e in ipairs(plan.takes) do
		removal[#removal + 1] = { id = { name = e[1], quality = e[2] },
			items = { in_inventory = { { inventory = defines.inventory.character_trash, stack = e[3], count = e[4] } } } }
	end
	local ok, proxy = pcall(char.surface.create_entity, { name = "item-request-proxy", position = char.position,
		force = force, target = char, modules = #modules > 0 and modules or nil,
		removal_plan = #removal > 0 and removal or nil })
	if not ok then
		log("[ctron_pluginv2] supply proxy refused: " .. tostring(proxy))
	end
	return ok and proxy or nil
end

--- Every proxy on the player's character goes: robots carrying for it take their items back (SP-24e), and none is left
--- for another network to fill. Only supply makes proxies that target a character.
function supply.drop_proxy(name)
	local player = game.get_player(name)
	local char = player and player.connected and player.character or S().stand_in[name]
	for _ = 1, 4 do
		local p = char and char.valid and char.item_request_proxy
		if not p then
			return
		end
		p.destroy()
	end
end

-- The panel, on the character screen (relative to controller_gui): one line of state and one button.
local LINES = {
	none = "ctronv2.supply_none", waiting = "ctronv2.supply_waiting", loading = "ctronv2.supply_loading",
	coming = "ctronv2.supply_coming", delivering = "ctronv2.supply_delivering",
}

local function panel(player)
	local frame = player.gui.relative[PANEL]
	if frame and frame.valid then
		return frame
	end
	frame = player.gui.relative.add({ type = "frame", name = PANEL, direction = "vertical",
		caption = { "ctronv2.supply_title" },
		anchor = { gui = defines.relative_gui_type.controller_gui, position = defines.relative_gui_position.right } })
	local body = frame.add({ type = "frame", name = "body", style = "inside_shallow_frame_with_padding",
		direction = "vertical" })
	-- Not "text": a child named like a LuaGuiElement property is refused (Factorio raises on add), and body.text
	-- would read the property, not the label.
	local line = body.add({ type = "label", name = "line" })
	line.style.single_line = false
	line.style.maximal_width = 220
	body.add({ type = "button", name = "button" })
	return frame
end

function supply.render(player)
	local c = S().calls[player.name] or { st = "none" }
	local body = panel(player).body
	local open = OPEN[c.st]
	body.line.caption = { not open and c.why and "ctronv2.supply_" .. c.why or LINES[c.st] or LINES.none }
	body.button.caption = { open and "ctronv2.supply_cancel" or "ctronv2.supply_call" }
	body.button.tags = { ct_supply = open and "cancel" or "call" }
end

local function report_at(player)
	local char = player.character
	local pos = char and char.position or player.physical_position
	local surface = (char and char.surface or player.physical_surface).name
	S().sent[player.name] = { surface = surface, x = pos.x, y = pos.y }
	bridge.send("ct.supply.at", { player = player.name, surface = surface, x = pos.x, y = pos.y })
end

--- The player's call, as their button makes it: what they miss and how many trash slots hold something. With nothing
--- to bring or take, or no link to the controller, nobody is called. Returns the panel's state.
function supply.call(player)
	local char = player.character
	if not char then
		return { st = "none", why = "no_character" }
	end
	if not ct.gui.link_up() then
		return { st = "none", why = "no_link" }
	end
	local list = core.call_items(supply.missing(char), ct.settings.stacks, MAX_KINDS)
	local trash = #core.take(trash_slots(char))
	if #list == 0 and trash == 0 then
		return { st = "none", why = "nothing" }
	end
	local p = char.position
	S().sent[player.name] = { surface = char.surface.name, x = p.x, y = p.y }
	bridge.send("ct.supply.call", { player = player.name, surface = char.surface.name, x = p.x, y = p.y, items = list,
		trash = trash })
	return { st = "waiting" }
end

supply.events[defines.events.on_gui_click] = function(event)
	local el = event.element
	local what = el and el.valid and el.tags and el.tags.ct_supply
	local player = what and game.get_player(event.player_index)
	if not player then
		return
	end
	local s = S()
	if what == "cancel" then
		bridge.send("ct.supply.cancel", { player = player.name })
		s.calls[player.name] = { st = "none", why = "cancelled" }
	else
		s.calls[player.name] = supply.call(player)
	end
	supply.render(player)
end

-- Where players are: on joining and changing surface, and while their call is open (the periodic below). A leave
-- first drops the proxies on them, before inventory_sync copies their inventory to the next tile.
supply.events[defines.events.on_player_joined_game] = function(event)
	local player = game.get_player(event.player_index)
	if player and S() then
		report_at(player)
		supply.render(player)
	end
end

supply.events[defines.events.on_player_changed_surface] = function(event)
	local player = game.get_player(event.player_index)
	if player and player.connected and S() then
		report_at(player)
	end
end

--- name leaves this tile: their runs here drop their proxies and wait, and the controller hears they left.
function supply.player_left(name)
	local s = S()
	leaving = name
	ct.runs.player_left(name)
	leaving = nil
	s.calls[name], s.sent[name] = nil, nil
	bridge.send("ct.supply.at", { player = name })
end

supply.events[defines.events.on_pre_player_left_game] = function(event)
	local player = game.get_player(event.player_index)
	if player and S() then
		supply.player_left(player.name)
	end
end

supply.events[defines.events.on_player_died] = function(event)
	local player = game.get_player(event.player_index)
	local s = S()
	local c = player and s and s.calls[player.name]
	if c and OPEN[c.st] then -- owner: a death ends the call
		bridge.send("ct.supply.cancel", { player = player.name, why = "died" })
		s.calls[player.name] = { st = "none", why = "died" }
		supply.render(player)
	end
end

--- Every connected player again, for a controller that restarted (report.snapshot).
function supply.report_all()
	for _, player in pairs(game.connected_players) do
		report_at(player)
	end
end

ue.runtime.scheduler.periodic({ name = "ctron.supply", interval = 300, fn = function()
	local s = S()
	if not (s and next(s.calls)) then
		return 0
	end
	local n = 0
	for name, c in pairs(s.calls) do
		local player = OPEN[c.st] and game.get_player(name)
		if player and player.connected then
			local char, last = player.character, s.sent[name]
			local pos = char and char.position or player.physical_position
			if not last or last.surface ~= player.physical_surface.name
				or (pos.x - last.x) ^ 2 + (pos.y - last.y) ^ 2 > MOVED * MOVED then
				report_at(player)
			end
			n = n + 1
		end
	end
	return math.max(n, 1)
end })

bridge.on("ct.supply.state", function(p)
	if type(p.player) ~= "string" or type(p.st) ~= "string" then
		return false
	end
	S().calls[p.player] = { st = p.st, why = p.why }
	local player = game.get_player(p.player)
	if player and player.connected then
		supply.render(player)
	end
end)

return supply
