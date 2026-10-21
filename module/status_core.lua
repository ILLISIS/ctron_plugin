-- Status codes (spec §8.7, R-103), pure: each code's locale key and severity, shared by runs, travel, registry, the
-- scheduler's rows and the UI.
local core = {}

--- Severity → the utility sprite the UI shows for it.
core.ICONS = {
	ok = "utility/status_working", wait = "utility/status_yellow", problem = "utility/status_not_working",
	move = "utility/status_blue", idle = "utility/status_inactive",
}

--- code → { locale key, severity }.
core.CODES = {
	new = { "ctron_status.new", "wait" },
	moving = { "ctron_status.moving_to_pos", "move" },
	routing = { "ctron_status.awaiting_pathfinder", "wait" },
	crossing = { "ctronv2.crossing", "move" },
	waiting_robots = { "ctron_status.moving_to_robots", "wait" },
	requesting = { "ctron_status.requesting_items", "wait" },
	awaiting_logistics = { "ctron_status.awaiting_logistics", "wait" },
	short = { "ctronv2.short", "problem" },
	no_logi_robots = { "ctron_status.no_logi_robots", "problem" },
	no_logi_storage = { "ctron_status.no_logi_storage", "problem" },
	no_station_power = { "ctron_status.no_station_power", "problem" },
	no_stations = { "ctron_status.no_stations_found", "problem" },
	working = { "ctron_status.job_type_working", "ok" },
	delivering = { "ctron_status.delivering_cargo", "ok" },
	clearing = { "ctron_status.clearing_inventory", "ok" },
	dest_invalid = { "ctron_status.dest_station_invalid", "problem" },
	missing_robots = { "ctron_status.missing_robots", "problem" },
	no_landfill = { "ctron_status.no_landfill", "problem" },
	trash_full = { "ctronv2.trash_full", "problem" },
	no_path = { "ctron_status.no_path_found", "problem" },
	stuck = { "ctron_status.stuck", "problem" },
	no_route = { "ctronv2.no_route", "problem" },
	budget = { "ctronv2.no_route", "problem" },
	fleeing = { "ctron_status.fleeing", "wait" },
	minion_proximity = { "ctron_status.minion_proximity", "wait" },
	following = { "ctron_status.following_leader", "ok" },
	standing_ground = { "ctron_status.standing_gound", "ok" }, -- CC's spelling
	safe_position = { "ctron_status.safe_position", "ok" },
	repairing = { "ctron_status.job_type_repair", "ok" },
	idle = { "ctronv2.idle", "idle" },
	robots_out = { "ctron_status.moving_to_robots", "wait" },
	no_roboports = { "ctron_status.missing_roboports", "problem" },
	no_power = { "ctron_status.missing_power", "problem" },
	bad_roboports = { "ctron_status.bad_roboports", "problem" },
	delay = { "ctronv2.wait_delay", "wait" },
	no_ctron = { "ctron_gui_locale.job_status", "wait" },
	waiting_squad = { "ctronv2.wait_squad", "wait" },
	no_supplier = { "ctronv2.no_supplier", "wait" },
	unreachable = { "ctronv2.unreachable", "problem" },
	backoff = { "ctronv2.backoff", "problem" },
	failed = { "ctronv2.backoff", "problem" },
	no_progress = { "ctronv2.no_progress", "problem" },
}

--- { key, sev } for code, or nil for an unknown code. "working" names the job kind's CC key; cargo and no kind keep
--- job_type_working (CC has no cargo key).
function core.info(code, kind)
	local c = core.CODES[code]
	if not c then
		return nil
	end
	if code == "working" and kind and kind ~= "cargo" then
		return { key = "ctron_status.job_type_" .. kind, sev = c[2] }
	end
	return { key = c[1], sev = c[2] }
end

return core
