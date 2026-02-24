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

-- periodically try to assign queued constructrons to their jobs
clusterio_handler.on_nth_tick_30 = function()
	for job_key, worker in pairs(storage.ctron_plugin.queued_constructrons or {}) do
		if not storage.ctron_plugin.queued_jobs[job_key] then return end
		local queued_entry = storage.ctron_plugin.queued_jobs[job_key]
		if not (worker and worker.valid and worker.logistic_cell) then return end

		-- Decode the job from its JSON string representation.
		local job = helpers.json_to_table(queued_entry.job_json) --[[@as table]]
		if not job then
			log("[ctron_plugin] failed to decode job JSON")
			return
		end
		log("----- Job key is: " .. job_key)
		clusterio_handler.transmute_job(job, worker)
		storage.ctron_plugin.queued_constructrons[job_key] = nil
		storage.ctron_plugin.queued_jobs[job_key] = nil
	end
end

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
		new_job.worker_logistic_cell = worker.logistic_cell
		new_job.worker_logistic_network = worker.logistic_cell.logistic_network
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

clusterio_handler.script_built = function(event)
	local entity = event.created_entity or event.entity
	if not (entity and entity.valid) then return end
	if storage.constructron_names[entity.name] then
		log("[ctron_plugin] constructron built")
		local job_key = clusterio_handler.calculate_job_key(entity)
		log("----- Job key is: " .. job_key)
		storage.ctron_plugin.queued_constructrons[job_key] = entity
	end
end

clusterio_handler.script_removed = function(event)
	local entity = event.entity
	if not (entity and entity.valid) then return end
	if not storage.constructron_names[entity.name] then return end
	log("[ctron_plugin] constructron removed")
	local job_key = clusterio_handler.calculate_job_key(entity)
	log("----- Job key is: " .. job_key)
	-- get ctron job
	local outgoing_job
	for _, job in pairs(storage.jobs) do
		if job.worker and (job.worker.unit_number == entity.unit_number) then
			outgoing_job = job
			break
		end
	end
	if outgoing_job then
		-- sythesize job.station
		outgoing_job.station = {
			position = table.deepcopy(outgoing_job.station.position),
			valid = true,
			logistic_network = {}
		}
		local payload = {
			source_instance_id = storage.universal_edges.config.instance_id,
			destination_instance_id = clusterio_handler.get_destination_instance_id_for_entity(entity),
			job_type = outgoing_job.job_type,
			job = outgoing_job,
			job_key = job_key,
		}
		-- send job to clusterio controller
		clusterio_api.send_json("ctron_plugin:job_route", payload)
		-- remove job from storage.jobs
		storage.jobs[outgoing_job.job_index] = nil
	end
end

--------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------

---@param entity LuaEntity
---@return string
clusterio_handler.calculate_job_key = function(entity)
	local pos = entity.position
	local surface_index = (entity.surface and entity.surface.index) or nil
	-- round to reduce floating differences
	return string.format("%d|%.2f,%.2f", surface_index, pos.x, pos.y)
end

-- Find the closest active universal edge and return the remote instance id.
---@param entity LuaEntity
---@return number? destination_instance_id
clusterio_handler.get_destination_instance_id_for_entity = function(entity)
	if not (storage and storage.universal_edges and storage.universal_edges.edges) then
		return nil
	end

	local best_edge = nil
	local best_dist2 = nil

	local ex = entity.position.x
	local ey = entity.position.y
	local surface_name = entity.surface.name

	for _edge_id, edge in pairs(storage.universal_edges.edges) do
		if edge.active then
			local local_target = nil
			if storage.universal_edges.config and storage.universal_edges.config.instance_id == edge.source.instanceId then
				local_target = edge.source
			else
				local_target = edge.target
			end
			if local_target and local_target.surface == surface_name then
				-- Edge coordinate space: [x along edge, y distance from edge]
				local dx = ex - local_target.origin[1]
				local dy = ey - local_target.origin[2]

				-- Rotate by -direction to align with edge space
				local dir = local_target.direction % 16
				local rx, ry = dx, dy
				if dir == 4 then
					rx, ry = dy, -dx
				elseif dir == 8 then
					rx, ry = -dx, -dy
				elseif dir == 12 then
					rx, ry = -dy, dx
				end

				-- Clamp along edge segment [0, length]
				local cx = rx
				if cx < 0 then cx = 0 end
				if cx > edge.length then cx = edge.length end

				local ddx = rx - cx
				local ddy = ry
				local dist2 = ddx * ddx + ddy * ddy
				if not best_dist2 or dist2 < best_dist2 then
					best_dist2 = dist2
					best_edge = edge
				end
			end
		end
	end

	if not best_edge then
		return nil
	end

	-- Destination is the remote target for this edge
	local local_instance_id = storage.universal_edges.config and storage.universal_edges.config.instance_id
	if local_instance_id == best_edge.source.instanceId then
		return best_edge.target.instanceId
	else
		return best_edge.source.instanceId
	end
end

return clusterio_handler