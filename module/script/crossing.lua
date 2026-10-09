-- The crossing glue (Constructron v2 spec §5): a constructron's job rides UE's vehicle crossing. The source keeps the
-- job, paused, until UE commits (entity_processor drops it then) or gives the constructron back (restored).
local ue = require("modules/universal_edges")
local entity_proc = require("modules/ctron_plugin/script/entity_processor")
local clusterio_handler = require("modules/ctron_plugin/clusterio_handler")
local trace = require("modules/ctron_plugin/script/trace")

--- The fields that don't ride (§5): made again on arrival, this tile's own, or other jobs. Every other field does, so
--- a field a later CC adds isn't dropped silently, as v1's fixed list dropped destroy jobs' state.
local STAYS = {
	job_index = true, surface_index = true, station = true,
	worker = true, worker_unit_number = true, worker_inventory = true, worker_ammo_slots = true,
	worker_trash_inventory = true, worker_logistic_cell = true, worker_logistic_network = true,
	path_request_id = true, path_request_params = true, pathfinding = true, custom_path = true,
	mobility_tick = true, robot_inactivity_counter = true,
	minion_jobs = true, primary_job = true, vassal_jobs = true, considered_spawners = true,
	in_transit = true, crossing = true, waiting = true, cross_wait_until = true,
}

local PLAIN = { string = true, number = true, boolean = true, table = true }

--- A copy holding only strings, numbers, booleans and tables: no LuaObjects (userdata), no metatables.
local function plain(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in pairs(v) do
		if PLAIN[type(x)] then
			out[k] = plain(x)
		end
	end
	return out
end

-- ponytail: a scan of every job per capture and per restore; index jobs by worker if a tile ever runs thousands
local function job_of(v)
	for _, job in pairs(storage.jobs) do
		local w = job.worker
		if w and w.valid and w.unit_number == v.unit_number then
			return job
		end
	end
end

local crossing = {}

--- capture(ep, v) (§5): a constructron's job, but a minion's (its goal is its leader, on this tile).
function crossing.capture(ep, v)
	if not storage.constructron_names[v.name] then
		return nil
	end
	local job = job_of(v)
	if not job or job.job_type == "minion" then
		return nil
	end
	local data = {}
	for k, x in pairs(job) do
		if not STAYS[k] and not string.find(k, "^last_") and PLAIN[type(x)] then
			data[k] = plain(x)
		end
	end
	local st = job.station
	if st and st.valid then
		data.station = { position = { x = st.position.x, y = st.position.y } }
	end
	local network = v.logistic_cell and v.logistic_cell.logistic_network
	trace.send("ctron.cross", "captured", "info", job, { edge = ep.edge, planned_edge = job.crossing and job.crossing.edge,
		state = job.state, robots_out = network and #network.construction_robots or 0 })
	job.in_transit = v.unit_number -- execute skips it; on_object_destroyed drops it at commit
	return data
end

--- materialized(ep, v, data, meta) (§5): register the arrival as a built constructron, and its job here.
function crossing.materialized(ep, v, data, meta)
	if not storage.constructron_names[v.name] then
		return
	end
	entity_proc.new_ctron_built(v, v.surface_index)
	if data then
		local job = clusterio_handler.transmute_job(data, v, v.surface_index)
		v.autopilot_destination = nil -- the leftover waypoint is P, mirrored: the job re-paths from here (§6.5)
		trace.send("ctron.cross", "arrived", "info", job, { edge = ep.edge, trace = meta.trace })
	end
end

--- restored(ep, v, why) (§7): UE gave v back. The job runs again; after a refusal it waits 5 minutes to retry.
function crossing.restored(ep, v, why)
	for _, job in pairs(storage.jobs) do
		if job.in_transit == v.unit_number then
			job.in_transit = nil
			if why ~= "close" then
				job.cross_wait_until = game.tick + 18000
			end
			trace.send("ctron.cross", "restored", why == "close" and "warn" or "error", job, { edge = ep.edge, why = why })
		end
	end
end

ue.transfers.extend({
	name = "constructron",
	types = { vehicle = true },
	capture = crossing.capture,
	materialized = crossing.materialized,
	restored = crossing.restored,
})

return crossing
