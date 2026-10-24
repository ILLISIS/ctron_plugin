-- Dev tool (run.sh): opens ctron_pluginv2's screens on sample data in a single-player scenario and screenshots each
-- into script-output/ctronv2/. The seams the screens call (ct.registry, ct.runs, ...) are fakes over two real entities.
local ue = require("modules/universal_edges")
local ct = require("modules/ctron_pluginv2/ct")
local gui = require("modules/ctron_pluginv2/gui/gui")
local center = require("modules/ctron_pluginv2/gui/center")
local station = require("modules/ctron_pluginv2/gui/station")

local HERE, OTHER = 4242, 7
local CID, SID, JID = "4242.11", "4242.21", "4242.31"

local function job(key, sec, ord, kind, at, status, extra)
	local r = { key = key, sec = sec, ord = ord, kind = kind, at = at, atName = at == HERE and "gw 0,0" or "gridworld_10_-3",
		worker = at .. "." .. (10 + ord), n = 1, state = "to_work", status = status, tasks = { ord, 6 },
		station = { sid = at .. ".21", name = "North yard", inst = at, x = -10, y = 0 } }
	for k, v in pairs(extra or {}) do
		r[k] = v
	end
	return r
end

local function rows()
	return {
		job("j:a1", "attention", 1, "construction", HERE, "short",
			{ missing = { { "assembling-machine-2", "normal", 12 }, { "fast-inserter", "normal", 40 } } }),
		job("j:a2", "attention", 2, "deconstruction", OTHER, "no_path"),
		{ key = "w:7|nauvis|upgrade|3", sec = "attention", ord = 3, kind = "upgrade", owner = OTHER, ownerName = "gridworld_10_-3",
			c = { -12345, -67890 }, st = "backoff", why = "no_progress", rem = 30, committed = 0, firstSeenMs = 0, tool = false },
		job("j:" .. JID, "progress", 1, "construction", HERE, "working"),
		job("j:p2", "progress", 2, "deconstruction", HERE, "moving", { n = 3 }),
		job("j:p3", "progress", 3, "upgrade", OTHER, "requesting"),
		job("j:p4", "progress", 4, "repair", OTHER, "crossing"),
		job("j:p5", "progress", 5, "destroy", HERE, "fleeing"),
		job("j:f1", "finishing", 1, "deconstruction", HERE, "clearing", { state = "returning" }),
		{ key = "g:4242|construction", sec = "pending", ord = 1, kind = "construction", owner = HERE,
			ownerName = "gw 0,0", n = 4, oldestMs = 0, st = "open" },
		{ key = "g:7|deconstruction", sec = "pending", ord = 2, kind = "deconstruction", owner = OTHER,
			ownerName = "gridworld_10_-3", n = 2, oldestMs = 0, st = "delay" },
		{ key = "w:4242|nauvis|construction|1", sec = "cells", ord = 1, kind = "construction", owner = HERE,
			ownerName = "gw 0,0", c = { 40, 12 }, st = "open", rem = 12, committed = 0, firstSeenMs = 0, tool = false },
		{ key = "w:4242|nauvis|construction|2", sec = "cells", ord = 2, kind = "construction", owner = HERE,
			ownerName = "gw 0,0", c = { -1234, 5678 }, st = "delay", dueAtMs = 400000, rem = 3, committed = 0,
			firstSeenMs = 0, tool = false },
		{ key = "c:" .. CID, sec = "ctrons", ord = 1, at = HERE, atName = "gw 0,0", name = "constructron", state = "busy",
			kind = "construction", jid = JID, status = "working", x = 10, y = 0 },
		{ key = "c:4242.12", sec = "ctrons", ord = 2, at = HERE, atName = "gw 0,0", name = "constructron", state = "idle",
			label = "Rosie", x = 4, y = 6 },
		{ key = "c:7.13", sec = "ctrons", ord = 3, at = OTHER, atName = "gridworld_-1_-1", name = "constructron", state = "unfit",
			why = "no_roboports", x = 300, y = 2 },
		{ key = "s:" .. SID, sec = "stations", ord = 1, at = HERE, atName = "gw 0,0", name = "North yard", x = -10, y = 0 },
		{ key = "n:" .. SID, slots = { { "iron-plate", "normal", 100, 500, 220 }, { "rail", "normal", 50, 200, 0 },
			{ "copper-plate", "normal", 100, 400 }, { "steel-plate", "normal", 50, 100 }, { "pipe", "normal", 50, 100 },
			{ "stone-brick", "normal", 50, 100 }, { "concrete", "normal", 50, 100 }, { "small-lamp", "normal", 10, 20 } },
			why = "no_supplier", order = { 0, 150, 0, 0, 0, 0, 0, 0 } },
		{ key = "s:7.22", sec = "stations", ord = 2, at = OTHER, atName = "gridworld_10_-3", name = "East depot", x = 290, y = 0 },
	}
end

local function list()
	return { watch = { surface = "nauvis" }, seq = 1, part = 1, parts = 1, full = true, up = rows(), rm = {},
		stats = { total = 3, available = 1, surfaces = { "nauvis" }, tiles = { { HERE, "gw 0,0" }, { OTHER, "gridworld_10_-3" } },
			more = {}, waiting = { { "assembling-machine-2", "normal", 12 }, { "fast-inserter", "normal", 40 } },
			now = 600000 } }
end

local E = {}

local function fakes()
	local slots = { { "iron-plate", "normal", 100, 500 }, { "rail", "normal", 50, 200 } }
	local effective = { kinds = { construction = true, rebuild = true, deconstruction = true, upgrade = true,
		repair = true, destroy = false }, zone_restriction = false, horde = false,
		robot = { "construction-robot", "normal" }, robot_count = 100, repair_tool = { "repair-pack", "normal" },
		ammo = { "rocket", "normal" }, ammo_count = 400, atomic = { "atomic-bomb", "normal" }, atomic_count = 10,
		min_cluster = 8, minions = 0 }
	local run = { cid = CID, jid = JID, surface = "nauvis", kind = "construction", status = "working",
		work = { { area = { left_top = { x = 30, y = -10 }, right_bottom = { x = 60, y = 20 } } } } }
	ct.gui = gui
	ct.registry = {
		here = function() return HERE end,
		ctron = function(cid) return cid == CID and { entity = E.ctron, state = "busy" } or nil end,
		ctron_of = function() return CID end,
		station = function() return { entity = E.station } end, -- the panel asks by unit number
		rename = function() end,
	}
	ct.runs = {
		of_job = function(jid) return jid == JID and { run } or {} end,
		get = function(cid) return cid == CID and run or nil end,
		record = function() return { kind = "construction", status = "awaiting_logistics", tasks = { 4, 6 } } end,
		detail = function()
			return {
				members = { { cid = CID, x = 10, y = 0,
					ammo = { { "rocket", "normal", 100 }, { "rocket", "normal", 100 }, { "rocket", "normal", 100 },
						{ "rocket", "normal", 100 } },
					trunk = { { "assembling-machine-2", "normal", 20 }, { "fast-inserter", "normal", 50 },
						{ "medium-electric-pole", "normal", 30 }, { "repair-pack", "normal", 50 },
						{ "construction-robot", "normal", 50 } },
					trash = { { "wood", "normal", 14 } },
					requests = { { "assembling-machine-2", "normal", 32, 20 }, { "fast-inserter", "normal", 50, 50 } } },
					{ cid = "4242.12", x = 14, y = 2 }, { cid = "4242.13", x = 6, y = 2 } }, -- a squad: the picker shows
				tasks = { { 45, 5 } }, station = { sid = SID },
			}
		end,
		drop = function() end,
	}
	ct.settings = {
		global = function() return { debug = false, job_start_delay = 900 } end,
		of = function() return effective end,
		stacks = setmetatable({}, { __index = function(_, name) return prototypes.item[name].stack_size end }),
	}
	ct.logistics = { slots = function() return slots end, set_slots = function(_, s) slots = s end }
end

local function shot(player, name)
	game.take_screenshot({ player = player, by_player = player, show_gui = true, path = "ctronv2/" .. name .. ".png" })
end

local function center_tab(player, i)
	local st = gui.state(player).center
	st.refs.pane.selected_tab_index = i
	center.on.tab.center_tab(player, st.refs.pane) -- as a click would: setting the index raises no event
end

local STEPS = {
	function(player)
		gui.open_details(player, JID) -- shown under the Control Center's list, so it goes first
		shot(player, "04-details")
	end,
	function(player)
		gui.close_screens(player)
		center.open(player)
		ue.handlers["ct.ui.list"](list())
		shot(player, "01-center-jobs")
	end,
	function(player)
		center_tab(player, 2)
		shot(player, "02-center-ctrons")
	end,
	function(player)
		center_tab(player, 3)
		shot(player, "03-center-stations")
	end,
	function(player)
		center_tab(player, 1) -- an empty section ("No jobs"), and a cancelled row
		local l = list()
		l.seq, l.up, l.stats.waiting = 2, {}, {} -- and nothing waited on: the label goes
		for _, r in ipairs(rows()) do
			if r.sec ~= "finishing" then
				l.up[#l.up + 1] = r
			end
		end
		ue.handlers["ct.ui.list"](l)
		local card = gui.state(player).center.refs.sec.attention.rows.children[1]
		center.on.click.center_cancel(player, card.flow.buttons.center_cancel, {})
		shot(player, "09-center-empty")
	end,
	-- Deltas as the live cluster sends them: one job in progress, then finishing, then gone, then a new one.
	function(player)
		gui.close_screens(player)
		center.open(player)
		local l = list()
		l.up = { job("j:J", "progress", 1, "construction", HERE, "working") }
		ue.handlers["ct.ui.list"](l)
		shot(player, "10-seq-progress")
	end,
	function(player)
		local l = list()
		l.full, l.seq, l.up = false, 2, { job("j:J", "finishing", 1, "construction", HERE, "clearing",
			{ state = "returning" }) }
		ue.handlers["ct.ui.list"](l)
		shot(player, "11-seq-finishing")
	end,
	function(player)
		local l = list()
		l.full, l.seq, l.up, l.rm = false, 3, {}, { "j:J" }
		ue.handlers["ct.ui.list"](l)
		shot(player, "12-seq-gone")
	end,
	function(player)
		local l = list()
		l.full, l.seq, l.up = false, 4, { job("j:K", "progress", 1, "deconstruction", HERE, "moving") }
		ue.handlers["ct.ui.list"](l)
		shot(player, "13-seq-new")
	end,
	-- The same while another tab is shown: the live camera saw rows laid out with no width (owner review, round 2).
	function(player)
		center_tab(player, 2)
		local l = list()
		l.full, l.seq, l.up, l.rm = false, 5, { job("j:L", "finishing", 1, "upgrade", HERE, "clearing",
			{ state = "returning" }) }, { "j:K" }
		ue.handlers["ct.ui.list"](l)
	end,
	function(player)
		center_tab(player, 1)
		shot(player, "14-seq-hidden")
	end,
	function(player)
		gui.close_screens(player)
		gui.open_cargo(player, SID)
		local slot = gui.state(player).cargo.ed.refs.slots.children[1] -- select it: the edit row shows
		station.on.click.cargo_slot(player, slot, { button = defines.mouse_button_type.left })
		shot(player, "05-cargo")
	end,
	function(player)
		gui.close_screens(player)
		gui.open_cargo(player, "9.9", { name = "Far mall", tile = "gridworld_1_0", slots = {
			{ "iron-plate", "normal", 100, 500 }, { "copper-plate", "normal", 0, 200 }, { "pipe", "normal", 10, 50 } } })
		local slot = gui.state(player).cargo.ed.refs.slots.children[1]
		station.on.click.cargo_slot(player, slot, { button = defines.mouse_button_type.left })
		shot(player, "15-cargo-remote")
	end,
	function(player)
		gui.close_screens(player)
		gui.open_settings(player, "nauvis")
		shot(player, "06-settings")
	end,
	function(player)
		gui.close_screens(player)
		player.opened = E.ctron
		log("preview: opened " .. tostring(player.opened and player.opened.name))
	end,
	function(player)
		shot(player, "07-ctron-panel")
	end,
	function(player)
		player.opened = E.station
	end,
	function(player)
		shot(player, "08-station-panel")
	end,
}

script.on_init(function()
	storage.ctron_pluginv2 = { ui = { players = {}, watches = {} }, schedulable = { nauvis = true },
		names = { ctrons = { constructron = true }, stations = { service_station = true } } }
end)

for id, fn in pairs(gui.events) do
	script.on_event(id, fn)
end

script.on_event(defines.events.on_tick, function(event)
	local player = game.get_player(1)
	if not player then
		return
	end
	if not E.ctron then
		fakes()
		local s = player.surface
		player.force.chart(s, { { -150, -150 }, { 150, 150 } })
		E.ctron = s.create_entity({ name = "constructron", position = { 10, 0 }, force = player.force })
		E.station = s.create_entity({ name = "service_station", position = { -10, 0 }, force = player.force })
		E.start = event.tick + 120 -- charting and the first renders
		return
	end
	local i = (event.tick - E.start) / 30 + 1
	if i == math.floor(i) and STEPS[i] then
		STEPS[i](player)
	elseif i == #STEPS + 1 then
		helpers.write_file("ctronv2/done", "")
	end
end)
