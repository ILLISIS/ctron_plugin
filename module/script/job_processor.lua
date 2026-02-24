
local debug_lib = require("modules/ctron_plugin/script/debug_lib")
local util_func = require("modules/ctron_plugin/script/utility_functions")
local clusterio_api = require("modules/clusterio/api")

local job = require("modules/ctron_plugin/script/job")
local construction_job = require("modules/ctron_plugin/script/job/construction")
local deconstruction_job = require("modules/ctron_plugin/script/job/deconstruction")
local upgrade_job = require("modules/ctron_plugin/script/job/upgrade")
local repair_job = require("modules/ctron_plugin/script/job/repair")
local destroy_job = require("modules/ctron_plugin/script/job/destroy")
local utility_job = require("modules/ctron_plugin/script/job/utility")
local cargo_job = require("modules/ctron_plugin/script/job/cargo")

local job_proc = {}

-------------------------------------------------------------------------------
--  Job processing
-------------------------------------------------------------------------------

job_proc.process_job_queue = function()
    -- job creation
    job_proc.make_jobs()
    -- job operation
    for job_index, job in pairs(storage.jobs) do
        job:execute(job_index)
    end
end

-------------------------------------------------------------------------------
--  Utility
-------------------------------------------------------------------------------

job_proc.make_jobs = function()
    for _, surface in pairs(game.surfaces) do
        job_proc.process_queues(surface.index)
    end
end

job_proc.job_types = {
    ["deconstruction"] = deconstruction_job,
    ["construction"] = construction_job,
    ["upgrade"] = upgrade_job,
    ["repair"] = repair_job,
    ["destroy"] = destroy_job
}

---@param surface_index uint
job_proc.process_queues = function(surface_index)
    local is_publisher = storage.mod_mode["publisher"]
    local is_subscriber = storage.mod_mode["subscriber"]
    local has_available = storage.available_ctron_count[surface_index] > 0
    if not (is_publisher or (is_subscriber and has_available)) then return end
    for job_type, job_class in pairs(job_proc.job_types) do
        job_proc.process_queue(surface_index, job_type, job_class)
    end
end

--- Process a single job queue
---@param surface_index uint
---@param job_type string
---@param job_class job
job_proc.process_queue = function(surface_index, job_type, job_class)
    local job_start_delay = storage.job_start_delay
    for _, chunk in pairs(storage[job_type .. '_queue'][surface_index]) do
        if ((game.tick - chunk.last_update_tick) > job_start_delay) then
            if job.find_chunk_entities(chunk, job_type) then
                -- find a worker to perform the prospective job
                local worker
                if storage.mod_mode["subscriber"] then
                    worker = job.get_worker(surface_index)
                    if not (worker and worker.valid) then break end
                end
                -- create job
                storage.job_index = storage.job_index + 1
                local job_index = storage.job_index
                local new_job = job_class.new(job_index, surface_index, job_type, worker)
                -- add robots as a required item to complete the job
                local robot_item = storage.desired_robot_name[surface_index]
                new_job["required_items"][robot_item.name] = {
                    [robot_item.quality] = storage.desired_robot_count[surface_index]
                }
                -- claim the chunk by the job
                new_job:claim_chunk(chunk)
                -- claim other chunks in proximity the claimed chunk
                if not storage.horde_mode[surface_index] then
                    new_job:claim_chunks_in_proximity()
                end
                if job_type == "destroy" then
                    break -- to allow minion assignment
                end
                if storage.mod_mode["publisher"] then
                    -- send the new job to the clusterio controller
                    log("[ctron_plugin] publishing new job to clusterio controller")
                    local job_key = tostring(storage.universal_edges.config.instance_id) .. "|" .. tostring(job_index)
                    local payload = {
                        instance_id = storage.universal_edges.config.instance_id,
                        job_type = new_job.job_type,
                        job = new_job,
                        job_key = job_key,
                    }
                    clusterio_api.send_json("ctron_plugin:job_add", payload)
                else
                    storage.jobs[job_index] = new_job
                end
            else
                -- clear the chunk from the queue
                storage[job_type .. "_queue"][surface_index][chunk.key] = nil
            end
        end
    end
end

return job_proc
