local clusterio_api = require("modules/clusterio/api")

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

-- periodically send / receive new jobs to / from the controller
clusterio_handler.on_nth_tick_300 = function()
	if storage.mod_mode["publisher"] then -- send to controller
		for job_index, job in pairs(storage.jobs) do
			if job.state == "setup" then
				
			end
		end
	elseif storage.mod_mode["subscriber"] then -- pull from controller
		clusterio_api.send_json("ctron_plugin:job_claim", {})
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
	log (serpent.block(job))
	clusterio_handler.transmute_job(job, nil)
end

-- This is where we would handle any necessary transformations of job data
-- when receiving from the controller, such as converting entity references,
-- remapping surface indices, etc. For now we assume the job data is directly usable.
---@param job table
---@param worker LuaEntity?
clusterio_handler.transmute_job = function(job, worker)
	-- Allocate a new job index and spawn a fresh instance using the job class.
	storage.job_index = storage.job_index + 1
	local new_job_index = storage.job_index

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
		end
	end
	-- Add the job to storage.jobs for execution
	storage.jobs[new_job_index] = new_job
end

-- update station count and inform clusterio controller when a station is built
clusterio_handler.station_built = function(entity)
	if storage.station_names[entity.name] then
		log("[ctron_plugin] service station built")
		storage.ctron_plugin.station_count = storage.ctron_plugin.station_count + 1
		if storage.ctron_plugin.station_count > 0 then
			log("[ctron_plugin] service stations available, switching to subscriber mode")
			storage.mod_mode["publisher"] = false
			storage.mod_mode["subscriber"] = true
		end
		local payload = {
			instance_id = storage.universal_edges.config.instance_id,
			service_station_count = storage.ctron_plugin.station_count,
		}
		clusterio_api.send_json("ctron_plugin:service_station_count", payload)
	end
end

-- update station count and inform clusterio controller when a station is removed
clusterio_handler.station_removed = function()
	log("[ctron_plugin] service station removed")
	storage.ctron_plugin.station_count = math.max(0, storage.ctron_plugin.station_count - 1)
	if storage.ctron_plugin.station_count == 0 then
		log("[ctron_plugin] no service stations available, switching to publisher mode")
		storage.mod_mode["publisher"] = true
		storage.mod_mode["subscriber"] = false
	end
	local payload = {
		instance_id = storage.universal_edges.config.instance_id,
		service_station_count = storage.ctron_plugin.station_count,
	}
	clusterio_api.send_json("ctron_plugin:service_station_count", payload)
end

return clusterio_handler