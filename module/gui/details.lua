-- Job Details and the ctron panel (spec §8.3, §8.5). Reaches the hub as ct.gui at run time (D-8).
local ct = require("modules/ctron_pluginv2/ct")
local view = require("modules/ctron_pluginv2/gui/view_core")

local details = { on = { click = {}, confirmed = {}, elem = {}, checked = {}, selection = {}, tab = {}, hover = {}, leave = {} } }
local click, selection = details.on.click, details.on.selection

local function label(parent, caption)
	return parent.add({ type = "label", caption = caption })
end

local function button(parent, name, tags, style)
	local key = "ctron_gui_locale." .. name
	return parent.add({ type = "button", style = style, caption = { key }, tooltip = { key .. "_tooltip" }, tags = tags })
end

local function station_caption(name)
	return "[item=service_station] " .. name
end

local function same_pos(a, b)
	return a and b and a.x == b.x and a.y == b.y
end

local function centre(area)
	return { x = (area.left_top.x + area.right_bottom.x) / 2, y = (area.left_top.y + area.right_bottom.y) / 2 }
end

-- Job Details ---------------------------------------------------------------------------------------------------

local function fill(player, detail)
	local p = ct.gui.state(player)
	local d = p.details
	if not (d and d.frame.valid) then
		return
	end
	local refs = d.refs
	d.written = d.written or {}
	d.last = detail
	local vm = view.detail(detail, d.member, ct.settings.stacks)
	if vm.gone then
		d.gone = true
		ct.gui.set_status(refs.status, view.SEV_SPRITE.problem, { "ctron_warnings.job_no_exist" })
		refs.locate.enabled, refs.remote_btn.enabled, refs.cancel.enabled = false, false, false
		return
	end
	if d.gone then
		-- a remote reply came back after an empty one: the job lives on
		d.gone = false
		refs.locate.enabled, refs.remote_btn.enabled = d.here, d.here
	end
	local can_cancel = ct.gui.link_up()
	if refs.cancel.enabled ~= can_cancel then
		refs.cancel.enabled = can_cancel
	end
	ct.gui.set_chip(refs.chip, vm.chip)
	ct.gui.set_status(refs.status, vm.status.sprite, vm.status.caption)
	refs.tasks.caption = vm.tasks or ""
	local dd = refs.member
	refs.member_row.visible = #vm.members > 1
	if not view.same(dd.items, vm.members) then
		dd.items = vm.members
		dd.selected_index = math.min(d.member, #vm.members)
	end
	ct.gui.write_slots(refs.requests, vm.requests, 20, "slot_button", "details_request", d.written, "requests")
	ct.gui.write_slots(refs.ammo, vm.ammo, 4, nil, nil, d.written, "ammo")
	ct.gui.write_slots(refs.trunk, vm.trunk, 80, nil, nil, d.written, "trunk")
	ct.gui.write_slots(refs.trash, vm.trash, 20, nil, nil, d.written, "trash", "utility/empty_trash_slot")

	local job = detail.job
	if not d.here then
		if job then
			refs.where.caption = job.atName or ""
			refs.station.caption = job.station and station_caption(job.station.name) or ""
		end
		if vm.pos then
			refs.remote.caption = { "ctronv2.remote_job", d.atName or "?", math.floor(vm.pos.x), math.floor(vm.pos.y) }
		end
		return
	end
	local station = vm.station and ct.registry.station(vm.station.sid)
	if station and station.entity and station.entity.valid then
		refs.station.caption = station_caption(station.entity.backer_name)
	end
	local worker = vm.cid and ct.registry.ctron(vm.cid)
	local entity = worker and worker.entity
	if entity and entity.valid and refs.worker_map.entity ~= entity then
		refs.worker_map.entity = entity
	end
	local at = vm.task or vm.pos
	if at and not same_pos(refs.job_map.position, at) then
		refs.job_map.position = at
	end
end

local function map(parent, key, surface, action)
	local deep = parent.add({ type = "frame", style = "minimap_frame", direction = "vertical" })
	return deep.add({ type = "minimap", style = "ctron_minimap_style", surface_index = surface.index, zoom = 2,
		tooltip = { "ctron_gui_locale." .. key .. "_tooltip" }, tags = { ct = action } })
end

local function line(parent)
	parent.add({ type = "line", direction = "horizontal", ignored_by_interaction = true })
end

-- CC's ui_job_screen.lua: the left pane holds the buttons, the minimaps and the task count, the right the slot tables.
local function build_body(frame, d, refs)
	local body = frame.add({ type = "frame", style = "inside_deep_frame", direction = "horizontal" })
	local left = body.add({ type = "frame", style = "ctron_job_left_pane_style", direction = "vertical" })
	left.style.height = 0 -- ponytail: CC pins 770; the content sets the height here
	local controls = left.add({ type = "flow", direction = "horizontal" })
	refs.locate = button(controls, "job_locate_button", { ct = "details_locate" }, "ctron_frame_button_style")
	refs.remote_btn = button(controls, "job_remote_button", { ct = "details_remote" }, "ctron_frame_button_style")
	refs.cancel = button(controls, "job_cancel_button", { ct = "details_cancel" }, "ctron_frame_button_style")
	refs.locate.enabled, refs.remote_btn.enabled = d.here, d.here
	-- A squad's member picker sits here, not in the strip, where it cut the status short (live review).
	refs.member_row = left.add({ type = "flow", direction = "horizontal", visible = false })
	refs.member_row.style.vertical_align = "center"
	label(refs.member_row, { "ctronv2.squad_member" })
	refs.member = refs.member_row.add({ type = "drop-down", tags = { ct = "details_member" } })
	line(left)
	if d.here then
		local surface = game.surfaces[d.surface]
		label(left, { "ctron_gui_locale.job_worker_minimap_label" })
		refs.worker_map = map(left, "job_worker_minimap", surface, "details_follow")
		line(left)
		label(left, { "ctron_gui_locale.job_job_minimap_label" })
		refs.job_map = map(left, "job_job_minimap", surface, "details_jobmap")
	else
		refs.remote = label(left, "")
		refs.remote.style.single_line = false
		refs.remote.style.maximal_width = 240
	end
	refs.tasks = label(left, "")
	local right = body.add({ type = "frame", style = "ctron_job_right_pane_style", direction = "vertical" })
	right.style.height = 0
	label(right, { "ctron_gui_locale.job_worker_ammo_label" })
	refs.ammo = right.add({ type = "table", style = "ctron_ammo_table_style", column_count = 10 })
	label(right, { "ctron_gui_locale.job_worker_inventory_label" })
	local scroll = right.add({ type = "scroll-pane", direction = "vertical" })
	scroll.style.maximal_height = 320
	refs.trunk = scroll.add({ type = "table", style = "ctron_inventory_table_style", column_count = 10 })
	label(right, { "ctron_gui_locale.job_worker_logistic_trash_label" })
	refs.trash = right.add({ type = "table", style = "ctron_trash_table_style", column_count = 10 })
	label(right, { "ctron_gui_locale.job_worker_logistic_requests_label" })
	local pane = right.add({ type = "scroll-pane", style = "deep_slots_scroll_pane", direction = "vertical" })
	refs.requests = pane.add({ type = "table", style = "ctron_logistic_table_style", column_count = 10 })
end

local function worker(d)
	local vm = view.detail(d.last, d.member, ct.settings.stacks)
	local rec = vm.cid and ct.registry.ctron(vm.cid)
	local e = rec and rec.entity
	return e and e.valid and e or nil
end

local function job_area(d)
	local run = ct.runs.of_job(d.jid)[1]
	return run and run.work and run.work[1] and run.work[1].area
end

-- The panel refresh is shared with tick, so it is defined before it.
local function refresh_panel(player)
	local p = ct.gui.state(player)
	local c = p.ctron
	if not (c.frame.valid and c.entity.valid) then
		details.close_panel(player)
		return
	end
	local refs = c.refs
	c.cid = c.cid or ct.registry.ctron_of(c.entity)
	local rec = c.cid and ct.registry.ctron(c.cid)
	local run = c.cid and ct.runs.get(c.cid)
	local code = run and run.status or rec and rec.state == "unfit" and rec.why or "idle"
	local st = view.status(code, run and run.kind, run and run.arg)
	ct.gui.set_chip(refs.chip, run and view.chip(run.kind))
	ct.gui.set_status(refs.status, st.sprite, st.caption)
	local busy = run ~= nil
	refs.details.visible, refs.locate.visible, refs.cancel.visible = busy, busy, busy
	refs.remote.visible = true
	refs.cancel.enabled = ct.gui.link_up()
end

function details.tick(player, tick)
	local p = ct.gui.state(player)
	local d = p.details
	if d and not (d.frame and d.frame.valid) then
		p.details, d = nil, nil
	end
	-- a remote job stays polled after an empty reply: the controller also answers null on a crossing or a timeout
	if d and (d.here and not d.gone or not d.here) then
		if d.here then
			local got = ct.runs.detail(d.jid)
			-- The remote reply's shape, built locally (D-5, P5-15); a new table, so runs' own data is never written.
			fill(player, got and { job = ct.runs.record(d.jid), members = got.members, tasks = got.tasks,
				station = got.station })
		elseif tick >= (d.next_ask or 0) then
			d.req = ct.gui.next_req()
			d.next_ask = tick + 60 -- R-191: one ask per 60 ticks, the rate the controller allows (1/s)
			ct.gui.send("ct.ui.detail.ask", { req = d.req, jid = d.jid })
		end
	end
	if p.ctron then
		refresh_panel(player)
	end
	ct.gui.set_ticking(player, p.details ~= nil or p.ctron ~= nil)
end

function details.close(player)
	local p = ct.gui.state(player)
	if p.details and p.details.frame and p.details.frame.valid then
		p.details.frame.destroy()
	end
	p.details = nil
	ct.gui.set_ticking(player, p.ctron ~= nil)
end

function details.open(player, jid, row)
	details.close(player)
	local runs = ct.runs.of_job(jid)
	local run = runs[1]
	local here = row and row.at == ct.gui.here() or (not row and #runs > 0)
	local d = { jid = jid, here = here, member = 1, surface = run and run.surface or row and row.surface,
		kind = run and run.kind or row and row.kind, at = row and row.at, atName = row and row.atName }
	if not (d.surface and game.surfaces[d.surface]) then
		ct.gui.warn(player, "ctron_warnings.job_no_exist")
		return
	end
	local frame = ct.gui.window(player, { window = "details", caption = { "ctron_gui_locale.job_title" },
		close = "details_close" })
	local refs = {}
	local strip = frame.add({ type = "frame", style = "subheader_frame" })
	refs.chip = ct.gui.chip(strip, view.chip(d.kind))
	refs.status = ct.gui.status(strip)
	refs.status.label.style.horizontally_stretchable = false -- the status in full; a long station name gives way
	strip.style.horizontally_stretchable = true
	strip.style.width = 700 -- the body's width: the strip does not stretch to it by itself
	strip.add({ type = "line", direction = "vertical" }).style.height = 24
	refs.where = label(strip, d.here and { "ctronv2.this_tile" } or d.atName or "")
	strip.add({ type = "line", direction = "vertical" }).style.height = 24
	refs.station = label(strip, "")
	refs.station.style.horizontally_squashable = true
	strip.add({ type = "empty-widget" }).style.horizontally_stretchable = true
	build_body(frame, d, refs)

	-- Shift-select from the world has nothing open; from the Control Center or the panel, leave that window open.
	if not player.opened then
		player.opened = frame
	end
	d.frame, d.refs = frame, refs
	ct.gui.state(player).details = d
	ct.gui.set_ticking(player, true)
	details.tick(player, game.tick)
end

function details.on_detail(player, detail)
	local d = ct.gui.state(player).details
	if d and not d.here then
		fill(player, detail)
	end
end

local function current(player)
	local d = ct.gui.state(player).details
	return d and d.frame.valid and d or nil
end

click.details_close = function(player)
	details.close(player)
end

selection.details_member = function(player, el)
	local d = current(player)
	if d then
		d.member = el.selected_index
		fill(player, d.last)
	end
end

click.details_follow = function(player)
	local d = current(player)
	local e = d and d.here and worker(d)
	if e then
		player.centered_on = e
	end
end

local function locate(player)
	local d = current(player)
	if not (d and d.here) then
		return
	end
	local area = job_area(d)
	local e = worker(d)
	local position = area and centre(area) or e and e.position
	ct.gui.locate(player, d.surface, position, area, d.kind)
end
click.details_jobmap, click.details_locate = locate, locate

click.details_remote = function(player)
	local d = current(player)
	local e = d and d.here and worker(d)
	if e then
		ct.gui.remote(player, e)
	end
end

click.details_cancel = function(player, _, event)
	local d = current(player)
	if d then
		ct.gui.cancel(player, "job", d.kind, d.surface, d.jid, event.control)
	end
end

click.details_request = function(player, el)
	local d = current(player)
	local name, q = el.tags.name, el.tags.q
	if not (d and name) then
		return
	end
	if d.here then
		ct.runs.drop(d.jid, d.surface, name, q)
	else
		ct.gui.send("ct.ui.drop", { jid = d.jid, surface = d.surface, name = name, quality = q })
	end
end

-- The ctron panel -----------------------------------------------------------------------------------------------

function details.close_panel(player)
	local p = ct.gui.state(player)
	if p.ctron and p.ctron.frame and p.ctron.frame.valid then
		p.ctron.frame.destroy()
	end
	p.ctron = nil
	ct.gui.set_ticking(player, p.details ~= nil)
end

function details.open_panel(player, entity)
	details.close_panel(player)
	local frame = player.gui.relative.add({ type = "frame", direction = "vertical", caption = entity.localised_name,
		anchor = { gui = defines.relative_gui_type.spider_vehicle_gui, position = defines.relative_gui_position.right } })
	frame.style.minimal_width = 160
	local refs = {}
	local inner = frame.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
	refs.chip = ct.gui.chip(inner, nil, 160)
	refs.status = ct.gui.status(inner)
	local grid = inner.add({ type = "table", column_count = 2 })
	local style = "ctron_frame_button_style"
	refs.details = button(grid, "job_details_button", { ct = "ctron_details" }, style)
	refs.locate = button(grid, "job_locate_button", { ct = "ctron_locate" }, style)
	refs.remote = button(grid, "job_remote_button", { ct = "ctron_remote" }, style)
	refs.cancel = button(grid, "job_cancel_button", { ct = "ctron_cancel" }, style)
	for _, b in pairs({ refs.details, refs.locate, refs.remote, refs.cancel }) do
		b.style.horizontally_stretchable = true
	end
	ct.gui.state(player).ctron = { frame = frame, refs = refs, entity = entity, cid = ct.registry.ctron_of(entity) }
	refresh_panel(player)
	ct.gui.set_ticking(player, true)
end

local function panel(player)
	local c = ct.gui.state(player).ctron
	return c and c.frame.valid and c.entity.valid and c or nil
end

click.ctron_details = function(player)
	local c = panel(player)
	local run = c and c.cid and ct.runs.get(c.cid)
	if run then
		ct.gui.open_details(player, run.jid)
	end
end

click.ctron_locate = function(player)
	local c = panel(player)
	local run = c and c.cid and ct.runs.get(c.cid)
	if not run then
		return
	end
	local area = run.work and run.work[1] and run.work[1].area
	ct.gui.locate(player, c.entity.surface.name, area and centre(area) or c.entity.position, area, run.kind)
end

click.ctron_remote = function(player)
	local c = panel(player)
	if c then
		ct.gui.remote(player, c.entity)
	end
end

click.ctron_cancel = function(player, _, event)
	local c = panel(player)
	local run = c and c.cid and ct.runs.get(c.cid)
	if run then
		ct.gui.cancel(player, "job", run.kind, run.surface, run.jid, event.control)
	end
end

return details
