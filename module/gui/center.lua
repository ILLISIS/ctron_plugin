-- Control Center (spec §8.2): three tabs of rows rendered from view.screen and patched in place with view.diff.
-- Reaches the hub as ct.gui at run time (D-8); the hub requires this module, never the reverse.
local ct = require("modules/ctron_pluginv2/ct")
local view = require("modules/ctron_pluginv2/gui/view_core")

local center = { on = { click = {}, confirmed = {}, elem = {}, checked = {}, selection = {}, tab = {}, hover = {}, leave = {} } }
local on = center.on

local JOB_SECS = { "attention", "progress", "finishing", "pending" }
local MAX_ICONS = 10 -- waiting for items, beside the stat cards
local ROW_ICONS = 6 -- a row's icons: more would push its buttons past the card
local TAB_HEIGHT = 630 -- ctron_main_content_style is 710 tall; the tab strip takes the rest

local function st_of(player)
	return ct.gui.state(player).center
end

local function debug_caption()
	return ct.settings.global().debug and { "ctronv2.debug_on" } or { "ctronv2.debug_off" }
end

-- Rows.

local function write_icons(row, icons)
	row.icons.clear()
	for i, icon in ipairs(icons or {}) do
		if i > ROW_ICONS then
			break
		end
		if prototypes.item[icon.name] then -- a removed mod's item has no sprite
			row.icons.add({ type = "sprite-button", style = "slot_button", sprite = icon.sprite,
				quality = icon.quality and prototypes.quality[icon.quality] and icon.quality or nil, number = icon.number,
				tooltip = icon.tooltip })
		end
	end
end

local function write_row(card, vm, old)
	local row = card.flow
	local function changed(f)
		return not view.same(vm[f], old[f])
	end
	if changed("chip") then
		ct.gui.set_chip(row.chip, vm.chip)
		row.pad.visible = vm.chip == nil
	end
	if changed("sprite") or changed("status") or changed("tip") then
		ct.gui.set_status(row.status, vm.sprite or "", vm.status or "", vm.tip)
	end
	for _, f in ipairs({ "tile", "who", "count", "age" }) do
		if changed(f) then
			row[f].caption = vm[f] or ""
			row[f].tooltip = vm[f] or "" -- the full text, should a name outgrow the column
		end
	end
	if changed("icons") then
		write_icons(row, vm.icons)
	end
	local buttons = row.buttons
	local b = buttons.center_locate
	if b then
		b.enabled = vm.locate and true or false
		b.tooltip = vm.remote_tip or { "ctron_gui_locale.job_locate_button_tooltip" }
	end
	b = buttons.center_cancel
	if b then
		b.enabled = vm.cancel and true or false
		b.tooltip = { "ctron_gui_locale.job_cancel_button_tooltip" }
	end
	b = buttons.center_remote
	if b then
		b.enabled = vm.remote and true or false
	end
	b = buttons.center_details
	if b then
		b.enabled = vm.details ~= false
	end
	b = buttons.center_cargo
	if b then
		b.enabled = vm.cargo and true or false
	end
	b = buttons.center_expand
	if b then
		b.sprite = vm.open and "utility/collapse" or "utility/expand"
	end
end

local BUTTONS = {
	job = { "locate", "details", "cancel" },
	group = { "expand" },
	cell = { "locate", "cancel" },
	ctron = { "locate", "remote", "details" },
	station = { "locate", "cargo" },
}
local BUTTON_CAPTION = {
	locate = "ctron_gui_locale.job_locate_button", details = "ctron_gui_locale.job_details_button",
	cancel = "ctron_gui_locale.job_cancel_button", remote = "ctron_gui_locale.job_remote_button",
}
local LABEL_WIDTH = { tile = 150, who = 150, count = 50, age = 60 } -- "gridworld_-10_-10", "(-12345, -67890)"
local STATUS_WIDTH = 240

local function build_row(parent, key, vm, index)
	local card = parent.add({ type = "frame", name = key, style = "ctron_job_card_style", index = index })
	card.style.horizontally_stretchable = true
	local row = card.add({ type = "flow", name = "flow", direction = "horizontal" })
	row.style.horizontally_stretchable = true
	row.style.vertical_align = "center"
	if vm.nested then
		row.style.left_padding = 24
	end
	ct.gui.chip(row, vm.chip)
	local pad = row.add({ type = "empty-widget", name = "pad", ignored_by_interaction = true }) -- the chip's width when it has none
	pad.style.width = 180
	local status = ct.gui.status(row) -- never hidden: its width keeps the columns lined up
	status.style.left_padding = 10
	status.style.width = STATUS_WIDTH
	status.label.style.horizontally_stretchable = false
	status.label.style.single_line = false -- a long status wraps instead of running into the tile column
	status.label.style.maximal_width = STATUS_WIDTH - 10 - 16 - 4 -- the padding, the 16 px icon, the flow's spacing
	for _, f in ipairs({ "tile", "who", "count", "age" }) do
		local label = row.add({ type = "label", name = f })
		label.style.width = LABEL_WIDTH[f]
		-- only pending groups have a count and an age; a station's name is in its bar, its requests take that column
		label.visible = vm.type == "group" or (f ~= "count" and f ~= "age" and not (f == "who" and vm.type == "station"))
	end
	local spacer = { type = "empty-widget", style = "ctron_job_section_title_bar_style", ignored_by_interaction = true }
	if vm.type == "station" then -- under the Requests header
		row.add({ type = "flow", name = "icons", direction = "horizontal" })
		row.add(spacer)
	else
		row.add(spacer)
		row.add({ type = "flow", name = "icons", direction = "horizontal" })
	end
	local buttons = row.add({ type = "flow", name = "buttons", direction = "horizontal" })
	for _, name in ipairs(BUTTONS[vm.type] or {}) do
		local action = "center_" .. name
		local tags = { ct = action, key = key }
		if name == "cargo" then
			buttons.add({ type = "button", name = action, style = "ctron_frame_button_style",
				caption = { "ctronv2.cargo_edit" }, tags = tags })
		elseif name == "expand" then
			buttons.add({ type = "sprite-button", name = action, style = "ctron_collapse_expand_button_style",
				sprite = "utility/expand", tags = tags })
		else
			local b = buttons.add({ type = "button", name = action, style = "ctron_frame_button_style",
				caption = { BUTTON_CAPTION[name] }, tags = tags })
			if name == "locate" then
				b.raise_hover_events = true
			end
		end
	end
	write_row(card, vm, {})
end

local function apply(sec_refs, prev, nxt)
	local rows = sec_refs.rows
	for _, op in ipairs(view.diff(prev, nxt)) do
		if op.op == "remove" then
			local row = rows[op.key]
			if row then
				row.destroy()
			end
		elseif op.op == "swap" then
			rows.swap_children(op.a, op.b)
		elseif op.op == "add" then
			build_row(rows, op.key, op.vm, op.index)
		elseif rows[op.key] then
			write_row(rows[op.key], op.vm, op.old)
		end
	end
end

-- Window.

--- A centred one-line card: "No jobs", "+N more".
local function add_note(parent, caption)
	local card = parent.add({ type = "frame", style = "ctron_job_card_style" })
	card.style.horizontally_stretchable = true
	local flow = card.add({ type = "flow", direction = "horizontal" })
	flow.style.horizontally_stretchable = true
	flow.style.horizontal_align = "center"
	return card, flow.add({ type = "label", caption = caption })
end

-- CC's create_job_section: titled frame, the rows flow, then the note cards (kept out of rows: the diff owns it).
local function add_section(parent, refs, sec)
	local frame = parent.add({ type = "frame", style = "ctron_job_status_section_style", direction = "vertical" })
	frame.style.horizontally_stretchable = true
	local head = frame.add({ type = "flow", style = "ctron_job_status_section_flow_style", direction = "horizontal" })
	head.style.top_padding = 2
	head.add({ type = "empty-widget", style = "ctron_job_section_title_bar_style", ignored_by_interaction = true })
	local title = head.add({ type = "label", style = "ctron_job_section_label_style" })
	title.style.width = 300 -- CC's 144 clips "Needs attention (3)"
	local toggle = head.add({ type = "sprite-button", style = "ctron_collapse_expand_button_style",
		sprite = "utility/collapse", tags = { ct = "center_collapse", sec = sec } })
	head.add({ type = "empty-widget", style = "ctron_job_section_title_bar_style", ignored_by_interaction = true })
	local body = frame.add({ type = "flow", direction = "vertical" })
	body.style.vertical_spacing = 0
	body.style.horizontally_stretchable = true
	local rows = body.add({ type = "flow", direction = "vertical" })
	rows.style.vertical_spacing = 0
	rows.style.horizontally_stretchable = true
	local none = sec == "ctrons" and { "ctronv2.no_ctrons" } or sec == "stations" and { "ctronv2.no_stations" }
		or { "ctron_gui_locale.main_no_jobs_label" }
	local empty = add_note(body, none)
	local more, more_label = add_note(body, "")
	more.visible = false
	refs.sec[sec] = { toggle = toggle, title = title, body = body, rows = rows, empty = empty, more = more,
		more_label = more_label }
end

-- Column headers, outside the scroll pane. Widths mirror build_row: the chip column, the status (STATUS_WIDTH, padding included).
local HEADERS = {
	jobs = { { "type", 180 }, { "status", STATUS_WIDTH }, { "tile", LABEL_WIDTH.tile }, { "who", LABEL_WIDTH.who },
		{ "areas", LABEL_WIDTH.count }, { "waiting", LABEL_WIDTH.age } },
	ctrons = { { "job_name", 180 }, { "status", STATUS_WIDTH }, { "tile", LABEL_WIDTH.tile }, { "name", LABEL_WIDTH.who } },
	stations = { { "station", 180 }, { "status", STATUS_WIDTH }, { "tile", LABEL_WIDTH.tile },
		{ "requests", LABEL_WIDTH.who + LABEL_WIDTH.count + LABEL_WIDTH.age } },
}

local function add_header(parent, name)
	local bar = parent.add({ type = "frame", style = "subheader_frame" })
	bar.style.horizontally_stretchable = true
	bar.style.left_padding = 13 -- the cards' frame padding
	for _, col in ipairs(HEADERS[name]) do
		local label = bar.add({ type = "label", style = "subheader_caption_label", caption = { "ctronv2.col_" .. col[1] },
			tooltip = { "ctronv2.col_" .. col[1] .. "_tooltip" } })
		label.style.width = col[2]
		label.style.horizontal_align = "left"
		label.style.left_padding = 0
	end
end

local function add_tab(pane, refs, name, caption)
	local tab = pane.add({ type = "tab", style = "tab", caption = caption })
	local content = pane.add({ type = "flow", direction = "vertical" })
	content.style.vertical_spacing = 0
	add_header(content, name)
	local scroll = content.add({ type = "scroll-pane", style = "ctron_main_scroll_section_style" })
	scroll.style.height = TAB_HEIGHT
	scroll.horizontal_scroll_policy = "never"
	pane.add_tab(tab, content)
	refs.tabs[name] = tab
	return scroll
end

function center.open(player)
	local p = ct.gui.state(player)
	if p.center and p.center.frame.valid then
		p.center.frame.bring_to_front()
		return
	end
	local st = { surface = player.surface.name, collapsed = {}, rendered = {}, tile_ids = { false } }
	local frame, extras = ct.gui.window(player, { window = "center", caption = { "ctron_gui_locale.main_title" },
		close = "center_close" })
	local refs = { tabs = {}, sec = {} }
	refs.surface = extras.add({ type = "drop-down", style = "ctron_surface_dropdown_style", items = { st.surface },
		selected_index = 1, tooltip = { "ctron_gui_locale.surface_selector_tooltip" }, tags = { ct = "center_surface" } })
	refs.tile = extras.add({ type = "drop-down", style = "ctron_surface_dropdown_style",
		items = { { "ctronv2.all_tiles" } }, selected_index = 1, tooltip = { "ctronv2.tile_filter_tooltip" },
		tags = { ct = "center_tile" } })
	refs.debug = extras.add({ type = "button", style = "ctron_frame_button_style", caption = debug_caption(),
		tooltip = { "ctron_gui_locale.debug_button_tooltip" }, tags = { ct = "center_debug" } })
	extras.add({ type = "button", style = "ctron_frame_button_style", caption = { "ctron_gui_locale.settings" },
		tags = { ct = "center_settings" } })

	refs.banner = frame.add({ type = "frame", style = "negative_subheader_frame" })
	refs.banner.add({ type = "label", caption = { "ctronv2.link_down" } })
	refs.banner.visible = not ct.gui.link_up()

	local top = frame.add({ type = "flow", direction = "horizontal" })
	top.style.horizontally_stretchable = true
	for _, stat in ipairs({ { "total", "ctron_gui_locale.stat_total_constructrons" },
		{ "available", "ctron_gui_locale.stat_available_constructrons" } }) do
		local card = top.add({ type = "frame", style = "ctron_stat_card_style", direction = "vertical" })
		card.add({ type = "label", style = "ctron_stat_card_label_style", caption = { stat[2] } })
		refs[stat[1]] = card.add({ type = "label", style = "ctron_stat_card_label_style" })
	end
	local waiting = top.add({ type = "flow", direction = "horizontal" })
	refs.waiting_box = waiting
	waiting.style.horizontally_stretchable = true
	waiting.style.horizontal_align = "right"
	waiting.style.vertical_align = "bottom"
	waiting.add({ type = "label", caption = { "ctronv2.waiting_for_items" },
		tooltip = { "ctronv2.waiting_for_items_tooltip" } })
	refs.waiting = waiting.add({ type = "flow", direction = "horizontal" })

	local body = frame.add({ type = "frame", style = "ctron_main_content_style", direction = "vertical" })
	local pane = body.add({ type = "tabbed-pane", style = "tabbed_pane", tags = { ct = "center_tab" } })
	refs.pane = pane
	local jobs = add_tab(pane, refs, "jobs", { "ctronv2.tab_jobs" })
	for _, sec in ipairs(JOB_SECS) do
		add_section(jobs, refs, sec)
	end
	add_section(add_tab(pane, refs, "ctrons", { "ctronv2.tab_ctrons" }), refs, "ctrons")
	add_section(add_tab(pane, refs, "stations", { "ctronv2.tab_stations" }), refs, "stations")

	player.opened = frame
	st.frame, st.refs = frame, refs
	p.center = st
	ct.gui.watch(player.index, { surface = st.surface })
	center.render(player)
end

local function index_of(list, v)
	for i, x in ipairs(list) do
		if x == v then
			return i
		end
	end
end

local function write_waiting(st, s)
	st.refs.waiting_box.visible = #s.waiting > 0
	if view.same(st.waiting, s.waiting) then
		return
	end
	local flow = st.refs.waiting
	flow.clear()
	for i, item in ipairs(s.waiting) do
		if i > MAX_ICONS then
			break
		end
		if prototypes.item[item.name] then -- a removed mod's item has no sprite
			flow.add({ type = "sprite-button", style = "slot_button", sprite = item.sprite,
				quality = item.quality and prototypes.quality[item.quality] and item.quality or nil, number = item.number,
				tooltip = { "ctronv2.waiting_for_items_tooltip" },
				tags = { ct = "center_drop", name = item.name, q = item.q } })
		end
	end
	st.waiting = s.waiting
end

local function write_dropdowns(player, st, s)
	local refs = st.refs
	local seen, surfaces = { [player.surface.name] = true, [st.surface] = true }, {}
	for _, name in ipairs(s.surfaces) do
		seen[name] = true
	end
	for name in pairs(seen) do
		surfaces[#surfaces + 1] = name
	end
	table.sort(surfaces)
	if not view.same(st.surface_items, surfaces) then
		refs.surface.items = surfaces
		refs.surface.selected_index = index_of(surfaces, st.surface) or 1
		st.surface_items = surfaces
	end

	local items, ids = { { "ctronv2.all_tiles" } }, { false }
	for _, t in ipairs(s.tiles) do
		items[#items + 1] = t[2]
		ids[#ids + 1] = t[1]
	end
	if st.tile and not index_of(ids, st.tile) then
		items[#items + 1] = st.tile_name or st.tile
		ids[#ids + 1] = st.tile
	end
	if not (view.same(st.tile_items, items) and view.same(st.tile_ids, ids)) then
		refs.tile.items = items
		refs.tile.selected_index = st.tile and index_of(ids, st.tile) or 1
		st.tile_items, st.tile_ids = items, ids
	end
end

function center.render(player, s)
	local st = st_of(player)
	if not (st and st.frame.valid) then
		return
	end
	local refs = st.refs
	refs.banner.visible = not ct.gui.link_up()
	local m = ct.gui.mirror(ct.gui.state(player).wk)
	if not (m and m.ready) then
		return
	end
	s = s or view.screen(m, { here = ct.gui.here(), expand = st.expand, link_up = ct.gui.link_up() })
	for name, text in pairs(s.badges) do
		refs.tabs[name].badge_text = text
	end
	refs.total.caption, refs.available.caption = s.total, s.available
	write_waiting(st, s)
	write_dropdowns(player, st, s)
	local sections = { s.jobs[1], s.jobs[2], s.jobs[3], s.jobs[4], s.ctrons, s.stations }
	for _, section in ipairs(sections) do
		local sec = refs.sec[section.sec]
		sec.title.caption = section.title
		sec.more.visible = section.more > 0
		sec.more_label.caption = { "ctronv2.more_rows", section.more }
		apply(sec, st.rendered[section.sec] or {}, section.rows)
		st.rendered[section.sec] = section.rows
		sec.empty.visible = #section.rows == 0 and section.more == 0
		sec.body.visible = not st.collapsed[section.sec]
	end
end

function center.on_settings(player)
	local st = st_of(player)
	if st and st.frame.valid then
		st.refs.debug.caption = debug_caption()
	end
end

function center.close(player)
	local p = ct.gui.state(player)
	local st = p.center
	if st then
		if st.frame.valid then
			st.frame.destroy()
		end
		p.center = nil
		ct.gui.watch(player.index, ct.gui.home(player))
	end
end

function center.toggle(player)
	if ct.gui.state(player).center then
		ct.gui.close_screens(player)
	else
		center.open(player)
	end
end

-- Actions.

local function rewatch(player, st)
	ct.gui.watch(player.index, { surface = st.surface, tile = st.tile or nil, expand = st.expand })
	center.render(player)
end

--- The mirror row an action button belongs to; warns when it is gone.
local function row_of(player, el)
	local m = ct.gui.mirror(ct.gui.state(player).wk)
	local r = m and el.tags.key and m.rows[el.tags.key]
	if not r then
		ct.gui.warn(player, "ctron_warnings.job_no_exist")
	end
	return r
end

local function centre(area)
	return { x = (area.left_top.x + area.right_bottom.x) / 2, y = (area.left_top.y + area.right_bottom.y) / 2 }
end

--- position, area, kind of a local row; nil when its entity is gone.
local function where(key, r)
	local id, tag = string.sub(key, 3), string.sub(key, 1, 2)
	if tag == "j:" then
		for _, run in ipairs(ct.runs.of_job(id)) do
			local rec = ct.registry.ctron(run.cid)
			if rec and rec.entity.valid then
				local area = run.work and run.work[1] and run.work[1].area
				return area and centre(area) or rec.entity.position, area, run.kind
			end
		end
	elseif tag == "w:" then
		if r.c then
			local x, y = r.c[1], r.c[2]
			return { x = x, y = y },
				{ left_top = { x = x - 40, y = y - 40 }, right_bottom = { x = x + 40, y = y + 40 } }, r.kind
		end
	elseif tag == "c:" then
		local rec = ct.registry.ctron(id)
		if rec and rec.entity.valid then
			return rec.entity.position
		end
	elseif tag == "s:" then
		return { x = r.x, y = r.y }
	end
end

local function drop_preview(player)
	local p = ct.gui.state(player)
	if p.preview and p.preview.frame and p.preview.frame.valid then
		p.preview.frame.destroy()
	end
	p.preview = nil
end

function on.click.center_close(player)
	ct.gui.close_screens(player)
end

function on.selection.center_surface(player, el)
	local st = st_of(player)
	if not st then
		return
	end
	st.surface = el.items[el.selected_index]
	st.tile, st.expand = nil, nil
	st.refs.tile.selected_index = 1
	rewatch(player, st)
end

function on.selection.center_tile(player, el)
	local st = st_of(player)
	if not st then
		return
	end
	st.tile = st.tile_ids[el.selected_index] or nil
	st.tile_name = el.items[el.selected_index]
	st.expand = nil
	rewatch(player, st)
end

function on.click.center_debug(player)
	if st_of(player) then
		ct.gui.send("ct.settings.set", { patch = { debug = not ct.settings.global().debug } })
	end
end

function on.click.center_settings(player)
	local st = st_of(player)
	if st then
		ct.gui.open_settings(player, st.surface)
	end
end

function on.click.center_collapse(player, el)
	local st = st_of(player)
	local sec = el.tags.sec
	local refs = st and st.refs.sec[sec]
	if not refs then
		return
	end
	st.collapsed[sec] = not st.collapsed[sec] or nil
	refs.body.visible = not st.collapsed[sec]
	refs.toggle.sprite = st.collapsed[sec] and "utility/expand" or "utility/collapse"
end

function on.click.center_expand(player, el)
	local st = st_of(player)
	if not (st and el.tags.key) then
		return
	end
	local id = string.sub(el.tags.key, 3)
	st.expand = st.expand ~= id and id or nil
	rewatch(player, st)
end

function on.click.center_locate(player, el)
	local st = st_of(player)
	local r = st and row_of(player, el)
	if r and view.is_local(r, ct.gui.here()) then
		ct.gui.locate(player, st.surface, where(el.tags.key, r))
	end
end

function on.hover.center_locate(player, el)
	local st = st_of(player)
	local m = st and ct.gui.mirror(ct.gui.state(player).wk)
	local r = m and el.tags.key and m.rows[el.tags.key]
	local surface = st and game.surfaces[st.surface]
	if not (r and surface and view.is_local(r, ct.gui.here())) then
		return
	end
	local position = where(el.tags.key, r)
	if not position then
		return
	end
	drop_preview(player)
	local f = player.gui.screen.add({ type = "frame", ignored_by_interaction = true })
	f.auto_center = true
	local inner = f.add({ type = "frame", style = "inside_deep_frame" })
	local cam = inner.add({ type = "camera", position = position, surface_index = surface.index, zoom = 0.3 })
	cam.style.width = 400
	cam.style.height = 400
	ct.gui.state(player).preview = { frame = f }
end

function on.leave.center_locate(player)
	drop_preview(player)
end

function on.click.center_details(player, el)
	local st = st_of(player)
	local r = st and row_of(player, el)
	if not r then
		return
	end
	local tag = string.sub(el.tags.key, 1, 2)
	local jid = tag == "j:" and string.sub(el.tags.key, 3) or tag == "c:" and r.jid or nil
	if jid then
		ct.gui.open_details(player, jid, { at = r.at, atName = r.atName, kind = r.kind, surface = st.surface,
			station = r.station })
	end
end

function on.click.center_cancel(player, el, event)
	local st = st_of(player)
	local r = st and row_of(player, el)
	if not r then
		return
	end
	local tag, id = string.sub(el.tags.key, 1, 2), string.sub(el.tags.key, 3)
	if tag == "j:" and r.sec == "finishing" then
		ct.gui.warn(player, "ctron_warnings.job_finished")
	elseif tag == "j:" or tag == "w:" then
		ct.gui.cancel(player, tag == "j:" and "job" or "work", r.kind, st.surface, id, event.control)
		if ct.gui.link_up() then -- R-191: grey the row at once; the next push rewrites it
			local row = el.parent.parent
			row.status.label.caption = { "ctronv2.cancelling" }
			for _, b in ipairs(el.parent.children) do
				b.enabled = false
			end
		end
	end
end

function on.click.center_remote(player, el)
	local r = row_of(player, el)
	if r and string.sub(el.tags.key, 1, 2) == "c:" and view.is_local(r, ct.gui.here()) then
		local rec = ct.registry.ctron(string.sub(el.tags.key, 3))
		if rec then
			ct.gui.remote(player, rec.entity)
		end
	end
end

function on.click.center_cargo(player, el)
	local r = row_of(player, el)
	if not (r and string.sub(el.tags.key, 1, 2) == "s:") then
		return
	end
	local sid = string.sub(el.tags.key, 3)
	if view.is_local(r, ct.gui.here()) then
		ct.gui.open_cargo(player, sid)
	elseif ct.gui.link_up() then
		local need = ct.gui.mirror(ct.gui.state(player).wk).rows["n:" .. sid]
		local slots = {}
		for i, s in ipairs(need and need.slots or {}) do
			slots[i] = { s[1], s[2], s[3], s[4] }
		end
		ct.gui.open_cargo(player, sid, { slots = slots, name = r.name, tile = r.atName })
	end
end

function on.click.center_drop(player, el)
	local st = st_of(player)
	if st then
		ct.gui.send("ct.ui.drop", { surface = st.surface, name = el.tags.name, quality = el.tags.q })
	end
end

function on.tab.center_tab(player, el)
	local st = st_of(player)
	if not st then
		return
	end
	st.tab = el.selected_tab_index
	-- Rows added while their tab was hidden were laid out with no width and don't show; hiding and showing a
	-- section's body lays it out again (seen live by test/preview/live.py, reproduced by run.sh's 14-15).
	for name, sec in pairs(st.refs.sec) do
		if not st.collapsed[name] then
			sec.body.visible = false
			sec.body.visible = true
		end
	end
end

return center
