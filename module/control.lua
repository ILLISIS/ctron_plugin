local clusterio_api = require("modules/clusterio/api")

log("[ctron_plugin] loaded")

-- Returns the Clusterio instance id provided by the host (used to attribute job events).
local function get_instance_id()
	-- Preferred: use clusterio_api global bridge if present
	if storage and storage.clusterio and storage.clusterio.globals then
		return storage.clusterio.globals.ctron_plugin_instance_id
	end
	return nil
end

-- Builds a stable-ish key for correlating a transferred Constructron from destroy->spawn.
-- Option B: key off the destroyed entity position (UE spawns at same position).
---@param entity LuaEntity
---@return string?
local function job_key_from_entity(entity)
	if not (entity and entity.valid) then return nil end
	local pos = entity.position
	if not pos then return nil end
	local surface_index = (entity.surface and entity.surface.index) or nil
	if not surface_index then return nil end
	-- round to reduce floating differences
	return string.format("%d|%.2f,%.2f", surface_index, pos.x, pos.y)
end

-- Caches a job locally when a Constructron is transferred out, so it can be applied
-- to the corresponding Constructron when it spawns in on this instance.
local function remember_job_for_transfer(entity, job)
	storage.ctron_plugin = storage.ctron_plugin or {}
	storage.ctron_plugin.pending = storage.ctron_plugin.pending or {}
	storage.ctron_plugin.pending_by_key = storage.ctron_plugin.pending_by_key or {}

	local key = job_key_from_entity(entity)
	if not key then
		log("[ctron_plugin] could not compute job key")
		return
	end

	storage.ctron_plugin.pending_by_key[key] = {
		job_type = job.job_type,
		job = job,
		unit_number = entity.unit_number,
		created_tick = game.tick,
		job_key = key,
	}

	log("[ctron_plugin] remembered pending job")
end

-- Queue of constructrons waiting for delivered job payload.
local function ensure_waiting_tables()
	storage.ctron_plugin = storage.ctron_plugin or {}
	storage.ctron_plugin.waiting = storage.ctron_plugin.waiting or {}
end

local function enqueue_waiting_constructron(job_key, entity)
	ensure_waiting_tables()
	storage.ctron_plugin.waiting[job_key] = {
		surface_index = entity.surface.index,
		position = { x = entity.position.x, y = entity.position.y },
		created_tick = game.tick,
		-- Don't attempt immediately on spawn; equipment comes later.
		-- Attempt assignment at +30/+60/+90 ticks.
		next_try_tick = game.tick + 30,
		tries = 0,
		give_up_tick = game.tick + 180,
	}
end

local function find_constructron_at(entry)
	local surface = game.surfaces[entry.surface_index]
	if not surface then return nil end
	local pos = entry.position
	if not pos then return nil end
	local ent = surface.find_entity("constructron", pos)
	if ent and ent.valid then return ent end
	return nil
end

local function try_apply_delivered_job(job_key, entry)
	local entity = find_constructron_at(entry)
	if not (entity and entity.valid) then
		-- entity gone or moved, drop
		return true
	end

	local resp = nil
	if storage.ctron_plugin and storage.ctron_plugin.delivered then
		resp = storage.ctron_plugin.delivered[job_key]
	end

	if not resp or not resp.ok then
		return false
	end

	-- Only pop once we're actually going to try applying.
	storage.ctron_plugin.delivered[job_key] = nil

	if resp.job == nil and resp.job_json ~= nil then
		local ok, decoded = pcall(helpers.json_to_table, resp.job_json)
		if ok then
			resp.job = decoded
		else
			log("[ctron_plugin] failed to decode delivered job_json")
			log(tostring(decoded))
			return true -- drop on decode error
		end
	end

	log("[ctron_plugin] applying delivered job (deferred)")
	local ok, err = pcall(remote.call, "ctron", "set-job", resp.job, entity)
	if not ok then
		-- Constructron may not be fully initialized yet.
		log("[ctron_plugin] set-job failed (will retry)")
		log(tostring(err))
		-- Put it back so we can retry at the next scheduled slot.
		storage.ctron_plugin.delivered[job_key] = resp
		return false
	end

	log("[ctron_plugin] set-job ok")
	entity.active = true
	return true
end

local function on_tick(event)
	if not (storage.ctron_plugin and storage.ctron_plugin.waiting) then return end
	if not next(storage.ctron_plugin.waiting) then return end

	for job_key, entry in pairs(storage.ctron_plugin.waiting) do
		if (entry.give_up_tick ~= nil) and game.tick >= entry.give_up_tick then
			local entity = find_constructron_at(entry)
			if entity and entity.valid then
				entity.active = true
			end
			storage.ctron_plugin.waiting[job_key] = nil
			goto continue
		end

		-- Only attempt at 60/120/180 ticks after enqueue.
		if game.tick < (entry.next_try_tick or 0) then
			goto continue
		end

		entry.tries = (entry.tries or 0) + 1
		entry.next_try_tick = game.tick + 60

		local done = try_apply_delivered_job(job_key, entry)
		if done then
			storage.ctron_plugin.waiting[job_key] = nil
		end

		::continue::
	end
end

-- Handles Constructron spawn/build events: if the Constructron corresponds to a pending
-- transfer, apply the cached job via Constructron's remote interface and notify controller.
local function on_built(event)
	local entity = event.entity
	if not entity or not entity.valid then return end
	if entity.name ~= "constructron" then return end
	log("[ctron_plugin] constructron built")
	local job_key = job_key_from_entity(entity)
	if not job_key then
		log("[ctron_plugin] could not compute job key (transfer-in)")
		return
	end

	-- Temporarily disable until we apply the job.
	-- entity.active = false

	-- Always queue on spawn; do not attempt to set the job immediately.
	-- Equipment (and Constructron internals) may not be ready until later.
	log("[ctron_plugin] queued delivered job apply (spawn)")
	enqueue_waiting_constructron(job_key, entity)
end

-- Find the closest active universal edge and return the remote instance id.
---@param entity LuaEntity
---@return number? destination_instance_id
local function get_destination_instance_id_for_entity(entity)
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

-- Handles Constructron destroy-on-transfer events: fetch the current job from Constructron,
-- cache it locally for later matching, and forward it to the controller for UI visibility.
local function script_raised_destroy(event)
	local entity = event.entity
	if not entity or not entity.valid then return end
	if entity.name ~= "constructron" then return end

	log("[ctron_plugin] constructron destroyed (transfer-out)")

	local instance_id = get_instance_id()
	if not instance_id then
		log("[ctron_plugin] instance_id not set; ignoring")
		return
	end

	local destination_instance_id = get_destination_instance_id_for_entity(entity)
	if not destination_instance_id then
		log("[ctron_plugin] could not determine destination instance (no nearby active edge)")
		return
	end

	log("[ctron_plugin] calling get-job")
	local job = remote.call("ctron", "get-job", entity.unit_number)
	if job then
		log("[ctron_plugin] get-job returned a job")

		-- Set a dummy station
		job.station = {
			position = table.deepcopy(job.station.position),
			valid = true,
			logistic_network = {}
		}

		-- Compute key now so failures are obvious in logs.
		local key = job_key_from_entity(entity)
		if not key then
			log("[ctron_plugin] could not compute job key (transfer-out)")
		else
			log("[ctron_plugin] computed job key")
		end

		-- Remember for destination matching.
		remember_job_for_transfer(entity, job)

		-- Tell clusterio controller about the job and its destination.
		log("[ctron_plugin] sending job_route to controller")
		local payload = {
			source_instance_id = instance_id,
			destination_instance_id = destination_instance_id,
			job_type = job.job_type,
			job = job,
			job_key = key,
		}
		clusterio_api.send_json("ctron_plugin:job_route", payload)
		remote.call("ctron", "remove-job", job.job_index)
	else
		log("[ctron_plugin] get-job returned nil")
	end

	-- Remove job from source instance.
	log("[ctron_plugin] removing job from source")
	pcall(remote.call, "ctron", "remove-job", entity.unit_number)
end

-- event_handler library interface
return {
	events = {
		[defines.events.on_built_entity] = on_built,
		[defines.events.script_raised_destroy] = script_raised_destroy,
		[defines.events.script_raised_built] = on_built,
		[defines.events.on_tick] = on_tick,
	},
}
