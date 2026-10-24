-- Pure view models for the in-game UI (spec §8). No game objects, no storage: the shells in gui/*.lua read the game
-- and write elements; what they show is decided here, so it is unit-tested (R-109). Plain Lua 5.2 (luacheck).
local status_core = require("modules/ctron_pluginv2/status_core")

local view = {}

--- Type chip colours, CC's values (CC ui_main_screen.lua:258-265 → color_lib.lua; its second `purple`, which wins).
view.COLORS = {
	construction = { r = 0, g = 0.35, b = 0.65, a = 0.4 },
	deconstruction = { r = 1, g = 0, b = 0, a = 0.4 },
	upgrade = { r = 0, g = 0.65, b = 0, a = 0.4 },
	repair = { r = 90 / 255, g = 0, b = 45 / 255, a = 0.5 },
	destroy = { r = 0, g = 0, b = 0, a = 0.6 },
	cargo = { r = 0.55, g = 0.55, b = 0.55, a = 0.75 },
}

--- Severity → status icon (spec §8.7).
view.SEV_SPRITE = status_core.ICONS -- {ok = "utility/status_working", ...}, P0's table

--- Deep equality of plain data (view models, LocalisedStrings).
function view.same(a, b)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in pairs(a) do
		if not view.same(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function copy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in pairs(v) do
		out[k] = copy(x)
	end
	return out
end

function view.chip(kind)
	local color = kind and view.COLORS[kind]
	if not color then
		return nil
	end
	return { caption = { "ctron_gui_locale.job_card_" .. kind .. "_name" }, color = color }
end

--- A status code (spec §8.7) → {sprite, caption, sev}. status_core names the kind for "working" (CC's
--- job_type_<kind>). An unknown code shows as itself with the wait icon, so another phase's new code can't break a
--- screen (Review Focus 4).
function view.status(code, kind, arg)
	local info = code and status_core.info(code, kind)
	if not info then
		return { sprite = view.SEV_SPRITE.wait, caption = tostring(code or "?"), sev = "wait" }
	end
	local caption = { info.key }
	if type(arg) == "string" or type(arg) == "number" then
		caption[2] = arg
	end
	return { sprite = view.SEV_SPRITE[info.sev] or view.SEV_SPRITE.wait, caption = caption, sev = info.sev }
end

--- A row is local when its tile (`at` for jobs, ctrons, stations; `owner` for work and groups) is this one (R-95).
function view.is_local(row, here)
	return (row.at or row.owner) == here
end

function view.tile(row, here)
	if view.is_local(row, here) then
		return { "ctronv2.this_tile" }
	end
	return row.atName or row.ownerName or "?"
end

--- "<inst>.<unit>" → "#<unit>", how a ctron without a label is named.
function view.unit(cid)
	return "#" .. (string.match(tostring(cid), "%.(%d+)$") or tostring(cid))
end

--- Minutes since ms at the controller's `now` (stats.now, D-3); no countdown ticks between pushes (R-94).
function view.age(ms, now)
	if not (ms and now) then
		return nil
	end
	return { "ctronv2.age_min", math.floor(math.max(0, now - ms) / 60000) }
end

function view.due(due_ms, now)
	if not (due_ms and now) then
		return nil
	end
	return { "ctronv2.due_tooltip", math.floor(math.max(0, due_ms - now) / 1000) }
end

--- [[name, quality, count]] → one rich-text line (tooltips of missing items).
function view.items_text(items)
	local parts = {}
	for i, it in ipairs(items or {}) do
		parts[i] = "[item=" .. it[1] .. ",quality=" .. it[2] .. "] " .. it[3]
	end
	return table.concat(parts, "  ")
end

--- [[name, quality, count]] → slot view models for sprite-buttons (native number and quality, spec §8.9); name and q
--- ride along for click tags (drop a request, drop a waiting item).
--- One slot per tuple; with stacks (name → stack size) a total is split into full stacks and the rest, as the
--- inventory holds it. ponytail: a sum split by stack size, not the real slots (two half stacks show as one).
function view.slots(items, stacks)
	local out = {}
	for _, it in ipairs(items or {}) do
		local per = math.max(1, stacks and stacks[it[1]] or it[3]) -- never 0: the loop must end
		local left = it[3]
		repeat
			local n = math.min(left, per)
			out[#out + 1] = { sprite = "item/" .. it[1], quality = it[2], number = n, name = it[1], q = it[2] }
			left = left - n
		until left <= 0
	end
	return out
end

--- A job detail (§6.12: {job, members, tasks, station}, D-5) → the Job Details view model for member i (default 1,
--- the worker or leader). nil → {gone = true}: the window greys out with ctron_warnings.job_no_exist (Review Focus 5).
--- Ammo comes slot by slot; the trunk and trash come as totals, split here with stacks (name → stack size).
function view.detail(detail, i, stacks)
	if not detail then
		return { gone = true }
	end
	local members = detail.members or {}
	local m = members[i or 1] or members[1]
	local head = detail.job or {}
	local task = detail.tasks and detail.tasks[1]
	local vm = {
		chip = view.chip(head.kind),
		status = view.status(head.status, head.kind, head.arg),
		tasks = head.tasks and { "ctron_gui_locale.job_job_stat_tasks_label", head.tasks[1] .. "/" .. head.tasks[2] },
		station = detail.station,
		members = {},
		cid = m and m.cid,
		pos = m and { x = m.x, y = m.y },
		task = task and { x = task[1], y = task[2] },
		requests = {},
		ammo = view.slots(m and m.ammo),
		trunk = view.slots(m and m.trunk, stacks),
		trash = view.slots(m and m.trash, stacks),
	}
	for j, member in ipairs(members) do
		vm.members[j] = view.unit(member.cid)
	end
	for j, r in ipairs(m and m.requests or {}) do
		local more = r[3] - r[4]
		vm.requests[j] = { sprite = "item/" .. r[1], quality = r[2], number = more > 0 and more or nil, name = r[1], q = r[2] }
	end
	return vm
end

--- The Settings window's fields in display order (spec §8.6), with CC's locale stems
--- (ctron_gui_locale.<label>_label / _tooltip). Toggles go in a 3-column table, values in a 4-column one.
view.TOGGLES = {
	{ path = "kinds.construction", label = "settings_construction_jobs" },
	{ path = "kinds.rebuild", label = "settings_rebuild_jobs" },
	{ path = "kinds.deconstruction", label = "settings_deconstruction_jobs" },
	{ path = "kinds.upgrade", label = "settings_upgrade_jobs" },
	{ path = "kinds.repair", label = "settings_repair_jobs" },
	{ path = "kinds.destroy", label = "settings_destroy_jobs" },
	{ path = "zone_restriction", label = "settings_zone_restriction" },
	{ path = "horde", label = "settings_horde_mode" },
}
view.VALUES = {
	{ path = "robot", label = "settings_robot_selection", type = "item", filter = "robot" },
	{ path = "robot_count", label = "settings_robot_count", type = "int" },
	{ path = "repair_tool", label = "settings_repair_tool_selection", type = "item", filter = "repair" },
	{ path = "ammo", label = "settings_ammo_selection", type = "item", filter = "rocket" },
	{ path = "ammo_count", label = "settings_ammo_count", type = "int" },
	{ path = "atomic", label = "settings_atomic_selection", type = "item", filter = "rocket" },
	{ path = "atomic_count", label = "settings_atomic_count", type = "int" },
	{ path = "min_cluster", label = "settings_min_cluster_size", type = "int" },
	{ path = "minions", label = "settings_minion_count", type = "int" },
}

--- settings["kinds.destroy"] style lookup into the nested shape (D-7).
function view.get(settings, path)
	local group, key = string.match(path, "^(%w+)%.(.+)$")
	if group then
		return settings[group] and settings[group][key]
	end
	return settings[path]
end

--- One edit → a SettingsPatch (nested kinds, D-7).
function view.patch(path, value)
	local group, key = string.match(path, "^(%w+)%.(.+)$")
	if group then
		return { [group] = { [key] = value } }
	end
	return { [path] = value }
end

--- "Apply to all surfaces": every surface-scope value of the shown surface (spec §8.6, R-100); global keys stay out.
function view.all_patch(effective)
	local patch = {}
	for _, list in ipairs({ view.TOGGLES, view.VALUES }) do
		for _, f in ipairs(list) do
			local value = view.get(effective, f.path)
			if value ~= nil then
				local group, key = string.match(f.path, "^(%w+)%.(.+)$")
				if group then
					patch[group] = patch[group] or {}
					patch[group][key] = copy(value)
				else
					patch[f.path] = copy(value)
				end
			end
		end
	end
	return patch
end

--- CC's caps (CC ui.lua:726-842; spec §4.6).
view.CAPS = {
	robot_count = { 0, 10000 },
	ammo_count = { 0, 8000 },
	atomic_count = { 0, 1000 },
	min_cluster = { 1, 100 },
	minions = { 0, 100 },
}

--- Textfield text → the value to send, or nil for text that isn't a usable number. Counts are whole and clamped;
--- the start delay is typed in seconds (decimals allowed) and sent in ticks (CC ui.lua:863-865).
function view.clamp(key, text)
	local n = tonumber(text)
	if not n or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	if key == "job_start_delay" then
		return math.floor(math.max(0, n) * 60 + 0.5)
	end
	local cap = view.CAPS[key]
	if not cap then
		return nil
	end
	return math.min(cap[2], math.max(cap[1], math.floor(n)))
end

function view.delay_text(ticks)
	local s = ticks / 60
	if s == math.floor(s) then
		return string.format("%d", s)
	end
	return tostring(s)
end

--- Cargo slots are [[name, quality, min, max]] (spec §4.7); need slots add a fifth field, count.
local function find(slots, name, quality)
	for i, s in ipairs(slots) do
		if s[1] == name and s[2] == quality then
			return i
		end
	end
	return nil
end

--- Picking an item starts a new request unless it is already requested (CC ui.lua:1083-1090).
function view.cargo_pick(slots, name, quality)
	if find(slots, name, quality) then
		return nil, "ctron_warnings.item_already_requested"
	end
	return { name, quality }
end

--- Set (or add) the request for item {name, quality}; needs min < max (CC ui.lua:1130-1133). Empty text is 0.
--- Returns new slots; the input is never changed.
function view.cargo_set(slots, item, min_text, max_text)
	local min = math.floor(tonumber(min_text) or 0)
	local max = math.floor(tonumber(max_text) or 0)
	if min < 0 or min >= max then
		return nil, "ctron_warnings.min_value"
	end
	local out = {}
	for i, s in ipairs(slots) do
		out[i] = { s[1], s[2], s[3], s[4] }
	end
	local i = find(out, item[1], item[2]) or #out + 1
	out[i] = { item[1], item[2], min, max }
	return out
end

function view.cargo_remove(slots, name, quality)
	local out = {}
	for _, s in ipairs(slots) do
		if not (s[1] == name and s[2] == quality) then
			out[#out + 1] = { s[1], s[2], s[3], s[4] }
		end
	end
	return out
end

--- Request icons: number = max; tooltip "Below min · Bring max[ · count]"; the selected one is yellow (spec §8.4).
function view.request_buttons(slots, selected)
	local out = {}
	for i, s in ipairs(slots or {}) do
		local tip = { "", { "ctronv2.cargo_below" }, " " .. s[3] .. " · ", { "ctronv2.cargo_bring" }, " " .. s[4] }
		if s[5] then
			tip[#tip] = tip[#tip] .. " · " .. s[5]
		end
		local on = selected and selected[1] == s[1] and selected[2] == s[2]
		out[i] = {
			sprite = "item/" .. s[1], quality = s[2], number = s[4], tooltip = tip,
			style = on and "yellow_slot_button" or "slot_button", name = s[1], q = s[2],
		}
	end
	return out
end

--- A watch {surface, tile?, expand?} (spec §6.12) → its key in storage.ctron_pluginv2.ui.watches (D-1).
function view.wkey(w)
	return w.surface .. "|" .. (w.tile and tostring(w.tile) or "") .. "|" .. (w.expand or "")
end

--- One more viewer i of watch w. Returns true when i is its first viewer (the shell sends on: true), and the key.
function view.acquire(watches, w, i)
	local k = view.wkey(w)
	local W = watches[k]
	if not W then
		W = { surface = w.surface, tile = w.tile, expand = w.expand, viewers = {}, n = 0 }
		watches[k] = W
	end
	if W.viewers[i] then
		return false, k
	end
	W.viewers[i] = true
	W.n = W.n + 1
	return W.n == 1, k
end

--- Viewer i leaves watch key k. Returns the watch, already removed, when i was its last viewer (send on: false).
function view.release(watches, k, i)
	local W = watches[k]
	if not (W and W.viewers[i]) then
		return nil
	end
	W.viewers[i] = nil
	W.n = W.n - 1
	if W.n > 0 then
		return nil
	end
	watches[k] = nil
	return W
end

--- Apply one ct.ui.list part to mirror m (D-4). Verdicts: "done" (a push is complete: render), "partial" (more parts
--- to come: keep showing the last render), "gap" (out of order: re-watch for a full list), "skip" (no full list yet).
function view.apply(m, msg)
	if msg.full and msg.part == 1 then
		m = { rows = {}, stats = {}, bysec = {} }
	elseif not m then
		return nil, "skip"
	elseif not ((msg.seq == m.seq and msg.part == m.part + 1) or (m.ready and msg.seq == m.seq + 1 and msg.part == 1)) then
		return m, "gap"
	end
	m.seq, m.part = msg.seq, msg.part
	local function put(key, row)
		local old = m.rows[key]
		m.rows[key] = row
		if m.bysec then -- the incremental screen's index and dirty sections (SP-22); screen() builds them for a bare mirror
			for _, r in ipairs({ old or false, row or false }) do
				if r and r.sec then
					m.dirty = m.dirty or {}
					m.dirty[r.sec] = true
					if string.sub(key, 1, 2) ~= "n:" then
						m.bysec[r.sec] = m.bysec[r.sec] or {}
						m.bysec[r.sec][key] = nil
					end
				end
			end
			if row and row.sec and string.sub(key, 1, 2) ~= "n:" then
				m.bysec[row.sec][key] = row
			end
			if string.sub(key, 1, 2) == "c:" then
				m.dirty = m.dirty or {}
				m.dirty.c = true -- a job row shows its worker's label
			end
		end
	end
	for _, key in ipairs(msg.rm or {}) do
		put(key, nil)
	end
	for _, row in ipairs(msg.up or {}) do
		put(row.key, row)
	end
	m.stats = msg.stats or m.stats
	m.ready = msg.part >= msg.parts
	return m, m.ready and "done" or "partial"
end

view.SEC_TITLE = {
	attention = { "ctronv2.section_attention" },
	progress = { "ctron_gui_locale.inprogress_section_name" },
	finishing = { "ctron_gui_locale.finishing_section_name" },
	pending = { "ctron_gui_locale.pending_section_name" },
	ctrons = { "ctronv2.tab_ctrons" },
	stations = { "ctronv2.tab_stations" },
}
local JOB_SECS = { "attention", "progress", "finishing", "pending" }

local function remote_tip(row, here)
	if view.is_local(row, here) then
		return nil
	end
	return { "ctronv2.remote_tooltip", row.atName or row.ownerName or "?" }
end

local function job_vm(r, sec, rows, opts)
	local st = view.status(r.status, r.kind, r.arg)
	local lead = r.worker
	local c = lead and rows["c:" .. lead]
	local who = c and c.label or (lead and view.unit(lead)) or ""
	if (r.n or 1) > 1 then
		who = who .. " +" .. (r.n - 1) -- a squad: the leader plus its minions (R-153: rows carry worker and n)
	end
	local missing = r.missing and #r.missing > 0 and view.items_text(r.missing) or nil
	return {
		type = "job", id = string.sub(r.key, 3), kind = r.kind, chip = view.chip(r.kind),
		sprite = st.sprite, status = st.caption, tip = missing,
		tile = view.tile(r, opts.here), who = who,
		locate = view.is_local(r, opts.here), remote_tip = remote_tip(r, opts.here),
		cancel = opts.link_up and true or false, finishing = sec == "finishing",
	}
end

--- A work or group row's status code (spec §8.7): a backed-off cell says why (failed, no_progress, unreachable), an open
--- one why it waits (no_ctron by default), otherwise its state (delay, waiting_squad).
local function work_code(r)
	if r.st == "backoff" then
		return r.why or "backoff"
	elseif r.st == nil or r.st == "open" then
		return r.why or "no_ctron"
	end
	return r.st
end

local function group_vm(r, now, opts)
	local id = string.sub(r.key, 3)
	local st = view.status(work_code(r), r.kind)
	return {
		type = "group", id = id, kind = r.kind, chip = view.chip(r.kind), sprite = st.sprite, status = st.caption,
		tile = view.tile(r, opts.here), count = { "ctronv2.group_count", r.n }, age = view.age(r.oldestMs, now),
		open = opts.expand == id,
	}
end

--- A w: row: the expanded group's cells, or a backed-off or unreachable cell in Needs attention (P4 list.ts). A cell
--- shown before its first scan has no centre c yet, so it can't be located.
local function cell_vm(r, now, opts)
	local st = view.status(work_code(r), r.kind)
	local c = r.c
	return {
		type = "cell", id = string.sub(r.key, 3), kind = r.kind, chip = view.chip(r.kind), sprite = st.sprite,
		status = st.caption, tip = view.due(r.dueAtMs, now), tile = view.tile(r, opts.here),
		who = c and ("(" .. math.floor(c[1]) .. ", " .. math.floor(c[2]) .. ")") or "",
		pos = c and { x = c[1], y = c[2] } or nil,
		locate = c ~= nil and view.is_local(r, opts.here), remote_tip = remote_tip(r, opts.here),
		cancel = opts.link_up and true or false,
	}
end

--- A grey bar with a name, in the type label's column: an idle ctron, a station (cargo's grey).
local function name_chip(name)
	return { caption = name, color = view.COLORS.cargo }
end

local function ctron_vm(r, opts)
	local id = string.sub(r.key, 3)
	local code = r.state == "idle" and "idle" or r.state == "unfit" and (r.why or "unfit") or (r.status or "new")
	local st = view.status(code, r.kind, r.arg)
	local here = view.is_local(r, opts.here)
	local busy = r.state == "busy" and view.chip(r.kind)
	local name = r.label or view.unit(id)
	return {
		type = "ctron", id = id, jid = r.jid, chip = busy or name_chip(name),
		sprite = st.sprite, status = st.caption, tile = view.tile(r, opts.here), who = busy and name or "",
		pos = r.x and { x = r.x, y = r.y } or nil, locate = here, remote = here, details = r.jid ~= nil,
		remote_tip = remote_tip(r, opts.here),
	}
end

--- A need row's open order, a count per slot as list.ts sends it (R-166), → [[name, quality, count]]; a 0 is left out.
local function order_items(need)
	local items = {}
	for i, s in ipairs(need.slots or {}) do
		local n = need.order[i]
		if n and n > 0 then
			items[#items + 1] = { s[1], s[2], n }
		end
	end
	return items
end

local function station_vm(r, need, opts)
	local here = view.is_local(r, opts.here)
	-- A pending cargo order shows on its destination's need row, not as a job (R-156): no_supplier as the status,
	-- the order's items in the tooltip.
	local st = need and need.why and view.status(need.why)
	local order = need and need.order and order_items(need)
	return {
		type = "station", id = string.sub(r.key, 3), chip = name_chip(r.name), who = "", tile = view.tile(r, opts.here),
		sprite = st and st.sprite, status = st and st.caption,
		tip = order and #order > 0 and view.items_text(order) or nil,
		icons = view.request_buttons(need and need.slots), pos = { x = r.x, y = r.y }, locate = here,
		cargo = here or opts.link_up and true or false, -- a remote edit goes through the controller (R-192)
		remote_tip = remote_tip(r, opts.here),
	}
end

local function section(sec, list, more)
	local n = #list + (more or 0)
	return { sec = sec, title = { "", view.SEC_TITLE[sec], " (" .. n .. ")" }, more = more or 0, rows = list }
end

local function by_ord(a, b)
	if a.ord ~= b.ord then
		return a.ord < b.ord
	end
	return a.key < b.key
end

local function sorted(bucket)
	local list = {}
	for _, r in pairs(bucket or {}) do
		list[#list + 1] = r
	end
	table.sort(list, by_ord)
	return list
end

--- One section's rows as {key, vm} and, for pending, the number of waiting jobs.
local function build(name, m, by, opts, now)
	local list = {}
	if name == "pending" then
		local count = 0
		local cells = {}
		for _, r in ipairs(sorted(by.cells)) do
			local vm = cell_vm(r, now, opts)
			vm.nested = true -- under its group, so indented; a cell in Needs attention stands alone
			cells[#cells + 1] = { key = r.key, vm = vm }
		end
		for _, r in ipairs(sorted(by.pending)) do
			count = count + (r.n or 0)
			list[#list + 1] = { key = r.key, vm = group_vm(r, now, opts) }
			if opts.expand and r.key == "g:" .. opts.expand then
				for _, c in ipairs(cells) do
					list[#list + 1] = c
				end
				cells = {}
			end
		end
		for _, c in ipairs(cells) do
			list[#list + 1] = c
		end
		return list, count
	end
	for _, r in ipairs(sorted(by[name])) do
		local vm
		if name == "ctrons" then
			vm = ctron_vm(r, opts)
		elseif name == "stations" then
			vm = station_vm(r, m.rows["n:" .. string.sub(r.key, 3)], opts)
		elseif string.sub(r.key, 1, 2) == "w:" then
			vm = cell_vm(r, now, opts)
		else
			vm = job_vm(r, name, m.rows, opts)
		end
		list[#list + 1] = { key = r.key, vm = vm }
	end
	return list
end

local JOB_DEPS = { "attention", "progress", "finishing", "ctrons" }

--- A ready mirror → the Control Center's three tabs (D-2). The controller already chose, sorted (ord) and capped the
--- rows; this buckets them by sec, orders by ord (key breaks ties, so every client agrees), and builds the row view
--- models. opts = {here = instance id, expand = "<owner>|<kind>" or nil, link_up = bool}.
--- Incremental (SP-22): view.apply marks the sections a push touched; only those are rebuilt, the others keep their
--- row lists (same tables), which view.diff skips. A change of here, link_up, or the first screen rebuilds everything.
function view.screen(m, opts)
	local stats = m.stats or {}
	local more = stats.more or {}
	local now = stats.now
	local link_up = opts.link_up and true or false
	local c = m.scr
	local d = m.dirty or {}
	if not (m.bysec and c and c.here == opts.here and c.link_up == link_up) then
		m.bysec = {}
		for key, r in pairs(m.rows) do
			if r.sec and string.sub(key, 1, 2) ~= "n:" then
				m.bysec[r.sec] = m.bysec[r.sec] or {}
				m.bysec[r.sec][key] = r
			end
		end
		c = { here = opts.here, link_up = link_up, secs = {} }
		d = { all = true }
	end
	if c.expand ~= opts.expand then
		d.pending = true
	end
	if c.now ~= now then
		d.pending, d.attention = true, true -- ages and due times
	end
	if d.c then
		for _, n in ipairs(JOB_DEPS) do
			d[n] = true
		end
	end
	if d.cells then
		d.pending = true
	end
	c.expand, c.now = opts.expand, now
	local by = m.bysec
	for _, name in ipairs({ "attention", "progress", "finishing", "pending", "ctrons", "stations" }) do
		if d.all or d[name] or not c.secs[name] then
			local list, count = build(name, m, by, opts, now)
			c.secs[name] = { list = list, count = count }
		end
	end
	m.scr, m.dirty = c, nil
	local out = { jobs = {} }
	local jobs = 0
	for i, sec in ipairs(JOB_SECS) do
		local e = c.secs[sec]
		out.jobs[i] = section(sec, e.list, sec ~= "pending" and more[sec] or 0)
		if sec == "pending" then
			out.jobs[i].title = { "", view.SEC_TITLE.pending, " (" .. e.count .. ")" }
		else
			jobs = jobs + #e.list + (more[sec] or 0)
		end
	end
	out.ctrons = section("ctrons", c.secs.ctrons.list, more.ctrons)
	out.stations = section("stations", c.secs.stations.list, more.stations)
	out.badges = {
		jobs = tostring(jobs),
		ctrons = (stats.available or 0) .. "/" .. (stats.total or 0),
		stations = tostring(#c.secs.stations.list + (more.stations or 0)),
	}
	out.summary = { "ctronv2.summary", stats.available or 0, stats.total or 0, #(stats.tiles or {}) }
	out.total, out.available = stats.total or 0, stats.available or 0 -- CC's two stat cards
	out.waiting = view.slots(stats.waiting)
	out.surfaces = stats.surfaces or {}
	out.tiles = stats.tiles or {}
	return out
end

--- prev, nxt: arrays of {key, vm} for one section's rows, which the shell names by key. Returns the ops that turn
--- prev's children into next's, to apply in order: removes, then per position i an add at i, or a swap bringing the
--- key to i, plus an update when the vm changed. Nothing for an identical list (spec §8.1).
function view.diff(prev, nxt)
	if prev == nxt then
		return {} -- an untouched section hands back the same row list (view.screen)
	end
	local ops, keep, order, old = {}, {}, {}, {}
	for _, r in ipairs(nxt) do
		keep[r.key] = true
	end
	for _, r in ipairs(prev) do
		if keep[r.key] then
			order[#order + 1] = r.key
			old[r.key] = r.vm
		else
			ops[#ops + 1] = { op = "remove", key = r.key }
		end
	end
	-- ponytail: linear searches, O(n²) per section; sections are capped at 50 rows (R-92, R-134).
	for i, r in ipairs(nxt) do
		local at
		for j = i, #order do
			if order[j] == r.key then
				at = j
				break
			end
		end
		if not at then
			table.insert(order, i, r.key)
			ops[#ops + 1] = { op = "add", key = r.key, index = i, vm = r.vm }
		else
			if at ~= i then
				order[at], order[i] = order[i], order[at]
				ops[#ops + 1] = { op = "swap", a = i, b = at }
			end
			if not view.same(old[r.key], r.vm) then
				ops[#ops + 1] = { op = "update", key = r.key, vm = r.vm, old = old[r.key] }
			end
		end
	end
	return ops
end

return view
