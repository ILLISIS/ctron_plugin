local clusterio_api = require("modules/clusterio/api")
local border = require("modules/ctron_plugin/script/border")
local trace = require("modules/ctron_plugin/script/trace")

local construction_job = require("modules/ctron_plugin/script/job/construction")
local deconstruction_job = require("modules/ctron_plugin/script/job/deconstruction")
local upgrade_job = require("modules/ctron_plugin/script/job/upgrade")
local repair_job = require("modules/ctron_plugin/script/job/repair")
local destroy_job = require("modules/ctron_plugin/script/job/destroy")
local utility_job = require("modules/ctron_plugin/script/job/utility")
local cargo_job = require("modules/ctron_plugin/script/job/cargo")

local clusterio_handler = {}

clusterio_handler.job_types = {
    ["deconstruction"] = deconstruction_job,
    ["construction"] = construction_job,
    ["upgrade"] = upgrade_job,
    ["repair"] = repair_job,
    ["destroy"] = destroy_job,
    ["utility"] = utility_job,
    ["cargo"] = cargo_job
}

--------------------------------------------------------------------
-- Main functions
--------------------------------------------------------------------

-- v2 (spec §8, §14 Q5): claim a job for this instance's subscriber surfaces that have an idle constructron
clusterio_handler.on_nth_tick_300 = function()
	local surfaces = {}
	for _, surface in pairs(game.surfaces) do
		local s = surface.index
		if (storage.stations_count[s] or 0) > 0 and (storage.available_ctron_count[s] or 0) > 0 then
			surfaces[#surfaces + 1] = surface.name
		end
	end
	if next(surfaces) then
		clusterio_api.send_json("ctron_plugin:job_claim", { surfaces = surfaces })
	end
end

-- called via RCON by instance.ts when a job_claim response is received from the controller
---@param job_json string
clusterio_handler.on_job_claimed = function(job_json)
	log("[ctron_plugin] job claimed from clusterio controller")
	local job = helpers.json_to_table(job_json) --[[@as table]]
	if not job then
		log("[ctron_plugin] on_job_claimed: failed to decode job_json")
		return
	end
	-- v2 (spec §8): the publisher's surface index means nothing here; its surface name maps the job and its chunks
	local surface = game.surfaces[job.surface_name]
	if not surface then
		-- ponytail: the controller already dropped it, so the job is lost (no re-publish)
		trace.send("ctron.pool", "claim_dropped", "warn", job, { surface = job.surface_name })
		return
	end
	local new_job = clusterio_handler.transmute_job(job, nil, surface.index)
	trace.send("ctron.pool", "claimed", "info", new_job, { surface = job.surface_name })
end

-- This is where we would handle any necessary transformations of job data
-- when receiving from the controller, such as converting entity references,
-- remapping surface indices, etc. For now we assume the job data is directly usable.
---@param job table
---@param worker LuaEntity?
---@param surface_index uint the job's surface here: a claim maps it by name, a crossing takes the arrival's (spec §5, §8)
---@return table
clusterio_handler.transmute_job = function(job, worker, surface_index)
	-- Allocate a new job index and spawn a fresh instance using the job class.
	storage.job_index = storage.job_index + 1
	local new_job_index = storage.job_index
	job.surface_index = surface_index
	for _, chunk in pairs(job.chunks or {}) do
		chunk.surface_index = surface_index
	end

	local job_type = job.job_type
	local job_class = clusterio_handler.job_types and clusterio_handler.job_types[job_type]

	-- Create the new job instance (this sets correct metatables and runs constructor defaults)
	local new_job = job_class.new(new_job_index, job.surface_index, job_type, worker)

	-- Copy incoming scalar/table state onto the fresh instance.
	-- Do not overwrite runtime-only references that we rebind below.
	for k, v in pairs(job) do
		if k ~= "job_index"
		and k ~= "worker"
		and k ~= "worker_unit_number"
		and k ~= "worker_logistic_cell"
		and k ~= "worker_logistic_network"
		and k ~= "worker_inventory"
		and k ~= "worker_ammo_slots"
		and k ~= "worker_trash_inventory"
		then
			new_job[k] = v
		end
	end

	-- Re-bind runtime-only references (always from the actual worker)
	if worker then
		new_job.job_index = new_job_index
		new_job.worker = worker
		new_job.worker_unit_number = worker.unit_number
		if worker.logistic_cell then
			new_job.worker_logistic_cell = worker.logistic_cell
			new_job.worker_logistic_network = worker.logistic_cell.logistic_network
		end
		new_job.worker_inventory = worker.get_inventory(defines.inventory.spider_trunk)
		new_job.worker_ammo_slots = worker.get_inventory(defines.inventory.spider_ammo)
		new_job.worker_trash_inventory = worker.get_inventory(defines.inventory.spider_trash)
	end

	-- set station entity if possible
	if job.station and job.station.position then
		local station = game.surfaces[job.surface_index].find_entities_filtered{
			position = job.station.position,
			name = "service_station",
			radius = 1
		}[1]
		if station and station.valid then
			new_job.station = station
		elseif worker and border.off_tile(worker, job.station.position) then
			-- v2 (spec §5): the station is on another tile. A stand-in steers the trip home; it is never reached here
			-- (§6.4), so nothing reads its network.
			new_job.station = { position = job.station.position, valid = true, logistic_network = {} }
		end
	end
	-- Add the job to storage.jobs for execution
	storage.jobs[new_job_index] = new_job
	return new_job
end

-- v2 (spec §8): this instance's service stations by surface name, to the controller, whenever one is built or removed
clusterio_handler.send_stations = function()
	local stations = {}
	for _, surface in pairs(game.surfaces) do
		local count = storage.stations_count[surface.index] or 0
		if count > 0 then
			stations[surface.name] = count
		end
	end
	clusterio_api.send_json("ctron_plugin:stations", { stations = stations })
end
clusterio_handler.station_built = clusterio_handler.send_stations
clusterio_handler.station_removed = clusterio_handler.send_stations

return clusterio_handler