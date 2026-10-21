-- The UI hub (spec §8): per-player state, tags.ct dispatch, shared builders, watches and mirrors, the UI bridge
-- handlers, the ctron.gui periodic, alerts, and the shortcut and inputs. The screens (center, details, station,
-- settings) build windows from view_core's models and reach this module as ct.gui at run time (D-8); it requires
-- them, never the reverse. Nothing runs while no screen is open (R-93).
local ue = require("modules/universal_edges")
local ct = require("modules/ctron_pluginv2/ct")
local bridge = require("modules/ctron_pluginv2/bridge")
local status_core = require("modules/ctron_pluginv2/status_core")
local view = require("modules/ctron_pluginv2/gui/view_core")
local center = require("modules/ctron_pluginv2/gui/center")
local details = require("modules/ctron_pluginv2/gui/details")
local station = require("modules/ctron_pluginv2/gui/station")
local settings_ui = require("modules/ctron_pluginv2/gui/settings")

local gui = { events = {} }
gui.send = bridge.send

local function ui()
	local u = storage.ctron_pluginv2.ui
	u.ticking = u.ticking or {}
	return u
end

function gui.state(player)
	local players = ui().players
	local p = players[player.index]
	if not p then
		p = {}
		players[player.index] = p
	end
	return p
end

function gui.here()
	return ct.registry.here()
end

function gui.link_up()
	return ui().link_up ~= false
end

function gui.mirror(key)
	local W = ui().watches[key]
	return W and W.mirror
end

function gui.next_req()
	local u = ui()
	u.req = (u.req or 0) + 1
	return gui.here() .. ".ui." .. u.req
end

function gui.set_ticking(player, on)
	ui().ticking[player.index] = on and true or nil
end

function gui.warn(player, key)
	player.print({ key })
end

local function watch_msg(W, on)
	return { surface = W.surface, tile = W.tile, expand = W.expand, on = on }
end

--- Point viewer index at watch w, or at none (w = nil). The first viewer of a watch sends on: true, the last to
--- leave on: false (spec §6.12); a tile may hold several watches (R-134).
--- The watch a connected player holds while no Control Center is open: their surface, every tile. The list is then
--- already on the tile when the Control Center opens with that filter (owner, 2026-10-20: prefetch).
function gui.home(player)
	return player.connected and { surface = player.surface.name } or nil
end

function gui.watch(index, w)
	local u = ui()
	local p = u.players[index] or {}
	u.players[index] = p
	local k = w and view.wkey(w)
	if p.wk == k then
		return k
	end
	if p.wk then
		local gone = view.release(u.watches, p.wk, index)
		if gone then
			gui.send("ct.ui.watch", watch_msg(gone, false))
		end
		p.wk = nil
	end
	if w then
		local first
		first, k = view.acquire(u.watches, w, index)
		if first then
			gui.send("ct.ui.watch", watch_msg(w, true))
		end
		p.wk = k
	end
	return k
end

-- Action dispatch: every screen's `on` tables merge into one, keyed by the tags.ct action name.
local KINDS = { "click", "confirmed", "elem", "checked", "selection", "tab", "hover", "leave" }
local on = {}
for _, kind in ipairs(KINDS) do
	on[kind] = {}
end

local function merge(screen)
	for _, kind in ipairs(KINDS) do
		for name, fn in pairs(screen.on[kind]) do
			if on[kind][name] then
				error("duplicate gui action " .. name)
			end
			on[kind][name] = fn
		end
	end
end
merge(center)
merge(details)
merge(station)
merge(settings_ui)

local EVENT_KIND = {
	[defines.events.on_gui_click] = "click",
	[defines.events.on_gui_confirmed] = "confirmed",
	[defines.events.on_gui_elem_changed] = "elem",
	[defines.events.on_gui_checked_state_changed] = "checked",
	[defines.events.on_gui_selection_state_changed] = "selection",
	[defines.events.on_gui_selected_tab_changed] = "tab",
	[defines.events.on_gui_hover] = "hover",
	[defines.events.on_gui_leave] = "leave",
}
for id, kind in pairs(EVENT_KIND) do
	gui.events[id] = function(event)
		local element = event.element
		if not (element and element.valid) then
			return
		end
		local name = element.tags and element.tags.ct
		local fn = name and on[kind][name]
		if fn then
			local player = game.get_player(event.player_index)
			if player then
				fn(player, element, event)
			end
		end
	end
end

-- Builders (spec §8.2-§8.3). The ctron_* styles are CC's (its data/styles.lua): CC is loaded wherever v2 runs (R-187).
function gui.window(player, opts)
	local frame = player.gui.screen.add({ type = "frame", direction = "vertical", tags = { ct_window = opts.window } })
	frame.auto_center = true
	if opts.width then
		frame.style.width = opts.width
	end
	local bar = frame.add({ type = "flow", style = "ctron_title_bar_flow_style" })
	bar.drag_target = frame
	bar.add({ type = "label", style = "frame_title", caption = opts.caption, ignored_by_interaction = true })
	bar.add({ type = "empty-widget", style = "ctron_title_bar_drag_bar_style", ignored_by_interaction = true })
	local extras = bar.add({ type = "flow", direction = "horizontal" })
	extras.style.horizontal_spacing = 8
	bar.add({ type = "line", direction = "vertical", ignored_by_interaction = true }).style.height = 24
	bar.add({ type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
		tags = { ct = opts.close } })
	return frame, extras
end

function gui.set_chip(bar, chip)
	bar.visible = chip ~= nil
	if chip then
		bar.style.color = chip.color
		bar.label.caption = chip.caption
	end
end

--- The job type label: CC's coloured bar with its label on top (CC ui_main_screen.lua create_job_card).
function gui.chip(parent, chip, width)
	width = width or 180
	local bar = parent.add({ type = "progressbar", name = "chip", value = 1 })
	bar.style.width = width
	bar.style.bar_width = 30
	local text = bar.add({ type = "label", name = "label", style = "ctron_job_type_label_style" })
	text.style.width = width
	gui.set_chip(bar, chip)
	return bar
end

function gui.status(parent)
	local flow = parent.add({ type = "flow", name = "status", direction = "horizontal" })
	flow.style.vertical_align = "center"
	flow.add({ type = "sprite", name = "icon", style = "status_image" })
	local text = flow.add({ type = "label", name = "label" })
	text.style.horizontally_stretchable = true
	return flow
end

function gui.set_status(flow, sprite, caption, tooltip)
	flow.icon.sprite = sprite
	flow.label.caption = caption
	flow.label.tooltip = tooltip or ""
end

--- Written in place, never clear() (R-97); the table keeps its largest size.
--- memo[key], in the window's own storage state, is what was last written (nil memo: always write). It lives in
--- storage so every peer takes the same branch. empty: the sprite of an empty slot (CC's trash slots).
function gui.write_slots(tbl, slots, min, style, action, memo, key, empty)
	local was = memo and memo[key]
	if was and was.min == min and was.style == style and was.action == action and was.empty == empty
		and view.same(was.slots, slots) then
		return
	end
	if memo then
		memo[key] = { slots = slots, min = min, style = style, action = action, empty = empty }
	end
	local n = math.max(#slots, min or 0)
	local children = tbl.children
	for _ = #children + 1, n do
		tbl.add({ type = "sprite-button", style = style or "inventory_slot" })
	end
	for i, button in ipairs(tbl.children) do
		local s = slots[i]
		if s and s.name and not prototypes.item[s.name] then
			s = nil -- a removed mod's item: a blank slot, not a raise
		end
		button.sprite = s and s.sprite or empty or ""
		button.quality = s and s.quality and prototypes.quality[s.quality] or nil
		button.number = s and s.number or nil
		button.tooltip = s and s.tooltip or ""
		if action then
			button.tags = s and { ct = action, name = s.name, q = s.q } or {}
		end
		button.style = (s and s.style) or style or "inventory_slot"
	end
end

function gui.locate(player, surface, position, area, kind)
	if not position or not game.surfaces[surface] then
		gui.warn(player, "ctron_warnings.job_no_exist")
		return
	end
	player.set_controller({ type = defines.controllers.remote, position = position, surface = surface })
	local box = area or { left_top = { x = position.x - 2, y = position.y - 2 },
		right_bottom = { x = position.x + 2, y = position.y + 2 } }
	rendering.draw_rectangle({ color = view.COLORS[kind] or { 1, 1, 1 }, width = 4, filled = false,
		left_top = box.left_top, right_bottom = box.right_bottom, surface = surface, players = { player },
		time_to_live = 120 })
end

function gui.remote(player, entity)
	if not entity.valid then
		return
	end
	player.spidertron_remote_selection = { entity }
	local stack = player.cursor_stack
	if not (stack and player.clear_cursor()) then
		return
	end
	if stack.can_set_stack({ name = "spidertron-remote", count = 1 }) then
		stack.set_stack({ name = "spidertron-remote", count = 1 })
	end
end

function gui.cancel(_player, target, kind, surface, id, all)
	if not gui.link_up() then
		return
	end
	gui.send("ct.ui.cancel", { target = target, kind = kind, surface = surface, id = (not all) and id or nil })
end

function gui.open_settings(player, surface)
	settings_ui.open(player, surface)
end

function gui.open_cargo(player, sid, remote)
	station.open_window(player, sid, remote)
end

function gui.open_details(player, jid, row)
	details.open(player, jid, row)
end

function gui.on_settings()
	for index, p in pairs(ui().players) do
		local player = game.get_player(index)
		if player then
			if p.settings then
				settings_ui.refresh(player)
			end
			if p.center then
				center.on_settings(player)
			end
		end
	end
end

function gui.close_screens(player)
	center.close(player)
	details.close(player)
	settings_ui.close(player)
	station.close_window(player)
	local preview = gui.state(player).preview
	if preview and preview.frame and preview.frame.valid then
		preview.frame.destroy()
	end
end

-- Bridge handlers.
bridge.on("ct.ui.list", function(msg)
	if not (type(msg.watch) == "table" and type(msg.watch.surface) == "string") then
		return false
	end
	local W = ui().watches[view.wkey(msg.watch)]
	if not W then
		return -- a late push
	end
	local verdict
	W.mirror, verdict = view.apply(W.mirror, msg)
	if verdict == "gap" then
		W.mirror = nil
		gui.send("ct.ui.watch", watch_msg(W, false))
		gui.send("ct.ui.watch", watch_msg(W, true))
	elseif verdict == "done" then
		local s -- built only for an open Control Center: a prefetch watch just keeps its mirror current
		for index in pairs(W.viewers) do
			local player = game.get_player(index)
			if player and player.connected and gui.state(player).center then
				s = s or view.screen(W.mirror, { here = gui.here(), expand = W.expand, link_up = gui.link_up() })
				center.render(player, s)
			end
		end
	end
end)

bridge.on("ct.ui.detail", function(msg)
	for index, p in pairs(ui().players) do
		-- any reply for the window's job is shown, so one slower than the next ask still lands
		local d = p.details
		local job = msg.detail and msg.detail.job
		if d and (d.req == msg.req or job and job.key == "j:" .. d.jid) then
			local player = game.get_player(index)
			if player then
				details.on_detail(player, msg.detail)
			end
			return
		end
	end
end)

bridge.on("ct.ui.link", function(msg)
	ui().link_up = msg.up == true
	for index, p in pairs(ui().players) do
		local player = p.center and game.get_player(index)
		if player then
			center.render(player)
		end
	end
end)

ue.runtime.scheduler.periodic({ name = "ctron.gui", interval = 60, fn = function(tick)
	local u = storage.ctron_pluginv2 and storage.ctron_pluginv2.ui
	if not (u and u.ticking and next(u.ticking)) then
		return 0
	end
	local n = 0
	for index in pairs(u.ticking) do
		local player = game.get_player(index)
		if player and player.connected then
			details.tick(player, tick)
			n = n + 1
		end
	end
	return n
end })

--- One alert per ctron (spec §8.7, R-102): remove first, add when the new code is a problem.
function gui.on_status(entity, code, arg)
	if not entity.valid then
		return
	end
	local info = code and status_core.info(code)
	for _, player in pairs(entity.force.connected_players) do
		player.remove_alert({ entity = entity, type = defines.alert_type.custom })
		if info and info.sev == "problem" then
			player.add_custom_alert(entity, { type = "item", name = "constructron" },
				view.status(code, nil, arg).caption, true)
		end
	end
end

-- Shortcut and inputs (spec §8.7).
local function once(player)
	local p = gui.state(player)
	if p.input_tick == game.tick then
		return false
	end
	p.input_tick = game.tick
	return true
end

local function selection_tool(player)
	local stack = player.cursor_stack
	if not stack then
		return
	end
	if stack.valid_for_read and stack.name == "ctron-selection-tool" and not gui.state(player).center then
		player.clear_cursor()
		center.open(player)
	elseif player.clear_cursor() then
		stack.set_stack({ name = "ctron-selection-tool", count = 1 })
	end
end

local function input(fn)
	return function(event)
		local player = game.get_player(event.player_index)
		if player and once(player) then
			fn(player)
		end
	end
end

local open_ui = function(player) center.toggle(player) end
gui.events["ctron-open-ui"] = input(open_ui)
gui.events["ctron-get-selection-tool"] = input(selection_tool)
local SHORTCUT = { ["ctron-open-ui"] = open_ui, ["ctron-get-selection-tool"] = selection_tool }
gui.events[defines.events.on_lua_shortcut] = function(event)
	local fn = SHORTCUT[event.prototype_name]
	local player = fn and game.get_player(event.player_index)
	if player and once(player) then
		fn(player)
	end
end

-- Panels and windows.
gui.events[defines.events.on_gui_opened] = function(event)
	local entity = event.entity
	if not (entity and entity.valid) then
		return
	end
	local player = game.get_player(event.player_index)
	if not player then
		return
	end
	local names = storage.ctron_pluginv2.names
	if names.ctrons and names.ctrons[entity.name] then
		details.open_panel(player, entity)
	elseif names.stations and names.stations[entity.name] then
		station.open_panel(player, entity)
	end
end

gui.events[defines.events.on_gui_closed] = function(event)
	local player = game.get_player(event.player_index)
	if not player then
		return
	end
	local element = event.element
	local window = element and element.valid and element.tags and element.tags.ct_window
	if window == "center" then
		gui.close_screens(player)
	elseif window == "details" then
		details.close(player)
	elseif window == "settings" then
		settings_ui.close(player)
	elseif window == "cargo" then
		station.close_window(player)
	elseif event.entity then
		details.close_panel(player)
		station.close_panel(player)
	end
end

-- Joining, leaving and starting.
gui.events[defines.events.on_player_joined_game] = function(event)
	local player = game.get_player(event.player_index)
	if player then
		gui.watch(event.player_index, gui.home(player))
	end
end

gui.events[defines.events.on_player_changed_surface] = function(event)
	local player = game.get_player(event.player_index)
	if player and not gui.state(player).center then
		gui.watch(event.player_index, gui.home(player))
	end
end

gui.events[defines.events.on_player_left_game] = function(event)
	local player = game.get_player(event.player_index)
	if not player then
		return
	end
	gui.watch(event.player_index, nil)
	gui.set_ticking(player, false)
	gui.close_screens(player)
	details.close_panel(player)
	station.close_panel(player)
end

gui.events[defines.events.on_player_removed] = function(event)
	gui.watch(event.player_index, nil)
	ui().ticking[event.player_index] = nil
	ui().players[event.player_index] = nil
end

gui.events[defines.events.on_pre_surface_deleted] = function(event)
	local name = game.surfaces[event.surface_index].name
	for _, player in pairs(game.connected_players) do
		local p = gui.state(player)
		if p.center and p.center.surface == name then
			gui.close_screens(player)
		else
			if p.details and p.details.surface == name then
				details.close(player)
			end
			if p.settings and p.settings.surface == name then
				settings_ui.close(player)
			end
		end
	end
	local u = ui()
	for k, W in pairs(u.watches) do
		if W.surface == name then
			gui.send("ct.ui.watch", watch_msg(W, false))
			for index in pairs(W.viewers) do
				local p = u.players[index]
				if p then
					p.wk = nil
				end
			end
			u.watches[k] = nil
		end
	end
end

gui.on_init = ui

--- The instance plugin forgets its watches on every start, so ours reset too.
gui.on_server_startup = function()
	local u = ui()
	u.watches, u.ticking, u.link_up = {}, {}, nil
	for index, p in pairs(u.players) do
		for _, v in pairs(p) do
			if type(v) == "table" and v.frame and v.frame.valid then
				v.frame.destroy()
			end
		end
		u.players[index] = { clipboard = p.clipboard }
	end
end

return gui
