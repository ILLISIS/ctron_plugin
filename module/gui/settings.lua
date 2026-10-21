-- Settings (spec §8.6): the global start delay, the surface's toggles and values, Apply to all surfaces, a surface
-- drop-down. Every edit is a ct.settings.set; text commits on Enter or close, clamped. ct.settings refreshes the
-- fields without trampling one being edited.
local ct = require("modules/ctron_pluginv2/ct")
local view = require("modules/ctron_pluginv2/gui/view_core")

local M = { on = { click = {}, confirmed = {}, elem = {}, checked = {}, selection = {}, tab = {}, hover = {}, leave = {} } }

local function state(player)
	return ct.gui.state(player).settings
end

local function filters(kind)
	if kind == "robot" then
		return { { filter = "place-result", elem_filters = { { filter = "type", type = "construction-robot" } } } }
	elseif kind == "repair" then
		return { { filter = "type", type = "repair-tool" } }
	end
	-- Rocket-category ammo (spec §8.6, API LuaItemPrototype.ammo_category); replaces CC's after-the-fact check.
	local names = {}
	for name, proto in pairs(prototypes.get_item_filtered({ { filter = "type", type = "ammo" } })) do
		if proto.ammo_category and proto.ammo_category.name == "rocket" then
			names[#names + 1] = name
		end
	end
	if #names == 0 then
		return { { filter = "type", type = "ammo" } }
	end
	return { { filter = "name", name = names } }
end

-- CC's row order (ui_settings_screen.lua) for the surface table; each view.TOGGLES / view.VALUES path appears once.
local ORDER = { "horde", "robot", "robot_count", "zone_restriction", "kinds.construction", "kinds.deconstruction",
	"kinds.rebuild", "kinds.upgrade", "kinds.destroy", "kinds.repair", "repair_tool", "ammo", "ammo_count", "atomic",
	"atomic_count", "min_cluster", "minions" }

local FIELDS = {}
do
	local by_path = {}
	for _, f in ipairs(view.TOGGLES) do
		by_path[f.path] = f
	end
	for _, f in ipairs(view.VALUES) do
		by_path[f.path] = f
	end
	for i, path in ipairs(ORDER) do
		FIELDS[i] = assert(by_path[path], path)
		by_path[path] = nil
	end
	assert(next(by_path) == nil, "settings ORDER misses " .. tostring(next(by_path)))
end

local function text_paths()
	local paths = { "job_start_delay" }
	for _, f in ipairs(view.VALUES) do
		if f.type == "int" then
			paths[#paths + 1] = f.path
		end
	end
	return paths
end

--- Write the fields from the effective settings; a text field whose text differs from what was shown is mid-edit.
local function fill(player, all)
	local s = state(player)
	local eff = ct.settings.of(s.surface)
	local glob = ct.settings.global()
	for _, path in ipairs(text_paths()) do
		local el = s.refs[path]
		if el.valid and (all or el.text == s.shown[path]) then
			local text
			if path == "job_start_delay" then
				text = view.delay_text(glob.job_start_delay or 0)
			else
				text = tostring(view.get(eff, path) or 0)
			end
			el.text = text
			s.shown[path] = text
		end
	end
	for _, f in ipairs(view.TOGGLES) do
		local el = s.refs[f.path]
		if el.valid then
			el.state = view.get(eff, f.path) and true or false
		end
	end
	for _, f in ipairs(view.VALUES) do
		local el = s.refs[f.path]
		if f.type == "item" and el.valid then
			local v = view.get(eff, f.path)
			el.elem_value = v and { name = v[1], quality = v[2] } or nil
		end
	end
end

local function commit(player, path)
	local s = state(player)
	local el = s.refs[path]
	if not el.valid or el.text == s.shown[path] then
		return
	end
	local value = view.clamp(path, el.text)
	if value == nil then
		el.text = s.shown[path]
		return
	end
	if path == "job_start_delay" then
		ct.gui.send("ct.settings.set", { patch = { job_start_delay = value } })
		el.text = view.delay_text(value)
	else
		ct.gui.send("ct.settings.set", { surface = s.surface, patch = view.patch(path, value) })
		el.text = tostring(value)
	end
	s.shown[path] = el.text
end

local function commit_all(player)
	for _, path in ipairs(text_paths()) do
		commit(player, path)
	end
end

function M.close(player)
	local s = state(player)
	if s and s.frame.valid then
		commit_all(player)
		s.frame.destroy()
	end
	ct.gui.state(player).settings = nil
end

function M.open(player, surface)
	M.close(player)
	local frame, extras = ct.gui.window(player, { window = "settings",
		caption = { "ctron_gui_locale.settings_title" }, close = "settings_close" })
	local seen = { [surface] = true }
	for name in pairs(storage.ctron_pluginv2.schedulable) do
		seen[name] = true
	end
	local names = {}
	for name in pairs(seen) do
		names[#names + 1] = name
	end
	table.sort(names)
	local selected
	for i, name in ipairs(names) do
		if name == surface then
			selected = i
		end
	end
	extras.add({ type = "drop-down", name = "dropdown", style = "ctron_surface_dropdown_style", items = names, selected_index = selected,
		tooltip = { "ctron_gui_locale.surface_selector_tooltip" }, tags = { ct = "settings_surface" } })

	local refs = {}
	local body = frame.add({ type = "frame", style = "inside_shallow_frame", direction = "vertical" })
	-- CC's inner frame (ctron_settings_inner_frame_style) is 12 px wider than its 420 px table, a margin right of
	-- the fields; its fixed 770 px height becomes a bottom margin under the last row.
	body.style.minimal_width = 432
	body.style.bottom_padding = 8

	local function section(title, apply)
		body.add({ type = "line", direction = "horizontal", ignored_by_interaction = true })
		local head = body.add({ type = "flow", direction = "horizontal" })
		head.style.vertical_align = "center"
		head.style.minimal_height = 32 -- room above and below the Apply button, as in CC
		head.add({ type = "label", style = "caption_label", caption = title }).style.left_padding = 12
		if apply then
			head.add({ type = "empty-widget" }).style.horizontally_stretchable = true
			head.add({ type = "button", style = "ctron_frame_button_style",
				caption = { "ctron_gui_locale.settings_apply_button" },
				tooltip = { "ctron_gui_locale.settings_apply_button_tooltip" }, tags = { ct = "settings_apply" } }).style.right_margin = 12
		end
		body.add({ type = "line", direction = "horizontal", ignored_by_interaction = true })
		return body.add({ type = "table", style = "ctron_settings_table_style", column_count = 2 })
	end

	local function label(tbl, key)
		tbl.add({ type = "label", style = "ctron_settings_label_style", caption = { "ctron_gui_locale." .. key .. "_label" },
			tooltip = { "ctron_gui_locale." .. key .. "_tooltip" } })
	end

	local global = section({ "ctron_gui_locale.settings_global_settings_label" })
	label(global, "settings_job_start_delay")
	refs.job_start_delay = global.add({ type = "textfield", style = "ctron_settings_textfield_style", numeric = true,
		allow_decimal = true, allow_negative = false, lose_focus_on_confirm = true,
		tooltip = { "ctron_gui_locale.settings_job_start_delay_tooltip" },
		tags = { ct = "settings_text", path = "job_start_delay" } })

	local tbl = section({ "ctron_gui_locale.settings_surface_specific_label" }, true)
	for _, f in ipairs(FIELDS) do
		label(tbl, f.label)
		local tooltip = { "ctron_gui_locale." .. f.label .. "_tooltip" }
		if not f.type then
			refs[f.path] = tbl.add({ type = "checkbox", state = false, tooltip = tooltip,
				tags = { ct = "settings_toggle", path = f.path } })
		elseif f.type == "item" then
			refs[f.path] = tbl.add({ type = "choose-elem-button", style = "slot_button",
				elem_type = "item-with-quality", elem_filters = filters(f.filter),
				tags = { ct = "settings_item", path = f.path } })
		else
			refs[f.path] = tbl.add({ type = "textfield", style = "ctron_settings_textfield_style", numeric = true,
				allow_decimal = false, allow_negative = false, lose_focus_on_confirm = true, tooltip = tooltip,
				tags = { ct = "settings_text", path = f.path } })
		end
	end

	ct.gui.state(player).settings = { frame = frame, surface = surface, refs = refs, shown = {} }
	fill(player, true)
end

function M.refresh(player)
	local s = state(player)
	if s and s.frame.valid then
		fill(player, false)
	end
end

M.on.click.settings_close = function(player)
	M.close(player)
end

M.on.selection.settings_surface = function(player, el)
	local s = state(player)
	local name = s and el.items[el.selected_index]
	if not name then
		return
	end
	commit_all(player)
	s.surface = name
	fill(player, true)
end

M.on.checked.settings_toggle = function(player, el)
	local s = state(player)
	if s then
		ct.gui.send("ct.settings.set", { surface = s.surface, patch = view.patch(el.tags.path, el.state) })
	end
end

M.on.elem.settings_item = function(player, el)
	local s = state(player)
	if not s then
		return
	end
	local v = el.elem_value
	if not v then
		local old = view.get(ct.settings.of(s.surface), el.tags.path)
		el.elem_value = old and { name = old[1], quality = old[2] } or nil
		return
	end
	ct.gui.send("ct.settings.set", { surface = s.surface,
		patch = view.patch(el.tags.path, { v.name, v.quality or "normal" }) })
end

M.on.confirmed.settings_text = function(player, el)
	if state(player) then
		commit(player, el.tags.path)
	end
end

M.on.click.settings_apply = function(player)
	local s = state(player)
	if not s then
		return
	end
	commit_all(player)
	ct.gui.send("ct.settings.set", { surface = "*", patch = view.all_patch(ct.settings.of(s.surface)) })
end

return M
