-- Station panel and cargo editor (spec §8.4): the relative panel on the roboport window and the same editor in a
-- gui.screen window for the Control Center. Edits go straight to the tile and reach the controller with the next delta.
local ct = require("modules/ctron_pluginv2/ct")
local view = require("modules/ctron_pluginv2/gui/view_core")

local station = { on = { click = {}, confirmed = {}, elem = {}, checked = {}, selection = {}, tab = {}, hover = {}, leave = {} } }

local MAX_SLOTS = 30 -- a station's need record has to fit one message part (R-154)

local function hub()
	return ct.gui
end

local function live(sid)
	local rec = ct.registry.station(sid)
	local entity = rec and rec.entity
	if entity and entity.valid then
		return entity
	end
end

local function copy(slots)
	local out = {}
	for i, s in ipairs(slots) do
		out[i] = { s[1], s[2], s[3], s[4] }
	end
	return out
end

--- The slots an editor shows: the tile's own, or for a station on another tile the copy taken when the window opened.
local function slots_of(ed)
	return ed.remote and ed.remote.slots or ct.logistics.slots(ed.sid) or {}
end

--- Every write of the slots; a remote station's go to its tile through the controller.
local function save(ed, slots)
	if ed.remote then
		ed.remote.slots = slots
		ct.gui.send("ct.ui.cargo", { sid = ed.sid, slots = slots })
	else
		ct.logistics.set_slots(ed.sid, slots)
	end
end

station.save = save -- for the game test: a headless run has no player to click with

local function fill(ed)
	local slots = slots_of(ed)
	local tbl = ed.refs.slots
	tbl.clear()
	for _, b in ipairs(view.request_buttons(slots, ed.sel)) do
		-- an item from a removed mod stays in the saved slots but gets no button (an unknown sprite raises)
		if prototypes.item[b.name] then
			tbl.add({ type = "sprite-button", style = b.style, sprite = b.sprite, quality = prototypes.quality[b.quality] and b.quality or nil,
			number = b.number, tooltip = b.tooltip, mouse_button_filter = { "left", "right" },
			tags = { ct = "cargo_slot", host = ed.host, name = b.name, q = b.q } })
		end
	end
	if #slots < MAX_SLOTS then
		tbl.add({ type = "choose-elem-button", style = "slot_button", elem_type = "item-with-quality",
			tags = { ct = "cargo_pick", host = ed.host } })
	end
	-- fill out the last row like CC's grid; the cells are inert
	while #tbl.children % 10 ~= 0 do
		tbl.add({ type = "sprite-button", style = "slot_button", enabled = false })
	end
end

local function show_edit(ed, item, min, max)
	local refs = ed.refs
	refs.edit.visible = item ~= nil
	if item then
		refs.item.sprite = "item/" .. item[1]
		refs.min.text = min and tostring(min) or ""
		refs.max.text = max and tostring(max) or ""
	end
end

local function number_field(row, tooltip, host)
	local field = row.add({ type = "textfield", style = "ctron_cargo_textfield_style", numeric = true,
		allow_decimal = false, allow_negative = false, tooltip = { tooltip }, tags = { ct = "cargo_confirm", host = host } })
	field.style.width = 72 -- CC's 100 would make the edit row wider than the 10-slot grid above it (R-193)
	return field
end

--- CC's cargo screen (ui_cargo_screen.lua): name and copy/paste on top, the slots in a deep frame, the edit bar below.
local function build(parent, _player, sid, host, remote)
	local refs = {}
	local entity = live(sid)
	local top = parent.add({ type = "flow", direction = "horizontal" })
	top.style.vertical_align = "center"
	top.add({ type = "label", style = "ctron_station_label_style", caption = { "ctron_gui_locale.station_label_caption" } })
	refs.name = top.add({ type = "textfield", style = "stretchable_textfield",
		text = remote and remote.name or entity and entity.backer_name or "",
		tags = { ct = "cargo_rename", host = host } })
	top.add({ type = "sprite-button", style = "frame_action_button", sprite = "ctron_export",
		tooltip = { "ctron_gui_locale.copy_station_requests_tooltip" }, tags = { ct = "cargo_copy", host = host } })
	top.add({ type = "sprite-button", style = "frame_action_button", sprite = "ctron_import",
		tooltip = { "ctron_gui_locale.paste_station_requests_tooltip" }, tags = { ct = "cargo_paste", host = host } })

	parent.add({ type = "label", caption = { "ctron_gui_locale.cargo_requests_label" } })
	local deep = parent.add({ type = "frame", style = "inside_deep_frame", direction = "vertical" })
	deep.style.top_margin = 4
	deep.style.horizontally_stretchable = true
	refs.slots = deep.add({ type = "table", style = "ctron_logistic_table_style", column_count = 10 })

	refs.edit = parent.add({ type = "flow", direction = "horizontal" })
	refs.edit.visible = false
	refs.edit.style.vertical_align = "center"
	refs.edit.style.horizontal_align = "center"
	refs.edit.style.horizontally_stretchable = true
	refs.item = refs.edit.add({ type = "sprite" })
	refs.edit.add({ type = "label", caption = { "ctronv2.cargo_below" } })
	refs.min = number_field(refs.edit, "ctron_gui_locale.min_text_field_tooltip", host)
	refs.edit.add({ type = "label", caption = { "ctronv2.cargo_bring" } })
	refs.max = number_field(refs.edit, "ctron_gui_locale.max_text_field_tooltip", host)
	refs.edit.add({ type = "button", style = "ctron_frame_button_style", caption = { "ctron_gui_locale.confirm" },
		tags = { ct = "cargo_confirm", host = host } })
	refs.edit.add({ type = "sprite-button", style = "tool_button_red", sprite = "utility/trash",
		tags = { ct = "cargo_remove", host = host } })

	local ed = { sid = sid, host = host, refs = refs, remote = remote }
	fill(ed)
	return ed
end

function station.close_panel(player)
	local p = hub().state(player)
	if p.station and p.station.frame and p.station.frame.valid then
		p.station.frame.destroy()
	end
	p.station = nil
end

function station.close_window(player)
	local p = hub().state(player)
	if p.cargo and p.cargo.frame and p.cargo.frame.valid then
		p.cargo.frame.destroy()
	end
	p.cargo = nil
end

function station.open_panel(player, entity)
	station.close_panel(player)
	local sid = hub().here() .. "." .. entity.unit_number
	if not ct.registry.station(sid) then
		return
	end
	local frame = player.gui.relative.add({ type = "frame", direction = "vertical", caption = entity.localised_name,
		anchor = { gui = defines.relative_gui_type.roboport_gui, position = defines.relative_gui_position.right } })
	local body = frame.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
	hub().state(player).station = { frame = frame, ed = build(body, player, sid, "station") }
end

--- remote = {slots, name, tile} for a station on another tile. ponytail: the copy does not follow later mirror
--- updates, last write wins.
function station.open_window(player, sid, remote)
	station.close_window(player)
	if not (remote or live(sid)) then
		return hub().warn(player, "ctron_warnings.station_no_exist")
	end
	local title = { "ctron_gui_locale.cargo_title" }
	local frame = hub().window(player, { window = "cargo", close = "cargo_close",
		caption = remote and { "", title, " — " .. remote.tile } or title })
	local body = frame.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
	hub().state(player).cargo = { frame = frame, ed = build(body, player, sid, "cargo", remote) }
end

--- The editor an element belongs to; a station that has gone closes its host with a warning.
local function editor(player, el)
	local host = el.tags and el.tags.host
	local holder = host and hub().state(player)[host]
	local ed = holder and holder.ed
	if not ed then
		return nil
	end
	if not (ed.remote or live(ed.sid)) then
		hub().warn(player, "ctron_warnings.station_no_exist")
		if host == "station" then
			station.close_panel(player)
		else
			station.close_window(player)
		end
		return nil
	end
	return ed
end

local function clear_sel(ed)
	ed.sel = nil
	show_edit(ed, nil)
end

local function confirm(player, el)
	local ed = editor(player, el)
	if not (ed and ed.sel) then
		return
	end
	local new, warn = view.cargo_set(slots_of(ed), ed.sel, ed.refs.min.text, ed.refs.max.text)
	if warn then
		return hub().warn(player, warn)
	end
	save(ed, new)
	clear_sel(ed)
	fill(ed)
end

station.on.confirmed.cargo_rename = function(player, el)
	local ed = editor(player, el)
	if not ed then
		return
	end
	if ed.remote then
		ed.remote.name = el.text
		ct.gui.send("ct.ui.cargo", { sid = ed.sid, name = el.text })
	else
		ct.registry.rename(ed.sid, el.text)
	end
end

station.on.elem.cargo_pick = function(player, el)
	local ed = editor(player, el)
	if not ed then
		return
	end
	local v = el.elem_value
	el.elem_value = nil
	if not v then
		return
	end
	local item, warn = view.cargo_pick(slots_of(ed), v.name, v.quality or "normal")
	if warn then
		return hub().warn(player, warn)
	end
	ed.sel = item
	show_edit(ed, item)
	fill(ed)
end

station.on.click.cargo_slot = function(player, el, event)
	local ed = editor(player, el)
	if not ed then
		return
	end
	local name, q = el.tags.name, el.tags.q
	local slots = slots_of(ed)
	if event.button == defines.mouse_button_type.right then
		save(ed, view.cargo_remove(slots, name, q))
		if ed.sel and ed.sel[1] == name and ed.sel[2] == q then
			clear_sel(ed)
		end
	else
		ed.sel = { name, q }
		for _, s in ipairs(slots) do
			if s[1] == name and s[2] == q then
				show_edit(ed, ed.sel, s[3], s[4])
				break
			end
		end
	end
	fill(ed)
end

station.on.click.cargo_confirm = confirm
station.on.confirmed.cargo_confirm = confirm

station.on.click.cargo_remove = function(player, el)
	local ed = editor(player, el)
	if not (ed and ed.sel) then
		return
	end
	save(ed, view.cargo_remove(slots_of(ed), ed.sel[1], ed.sel[2]))
	clear_sel(ed)
	fill(ed)
end

station.on.click.cargo_copy = function(player, el)
	local ed = editor(player, el)
	if ed then
		hub().state(player).clipboard = copy(slots_of(ed))
	end
end

station.on.click.cargo_paste = function(player, el)
	local ed = editor(player, el)
	if not ed then
		return
	end
	local clip = hub().state(player).clipboard
	if not clip then
		return hub().warn(player, "ctron_warnings.no_requests_copied")
	end
	save(ed, copy(clip))
	fill(ed)
end

station.on.click.cargo_close = function(player)
	station.close_window(player)
end

return station
