
local debug_lib = require("modules/ctron_plugin/script/debug_lib")
local util_func = require("modules/ctron_plugin/script/utility_functions")
local clusterio_api = require("modules/clusterio/api")
local trace = require("modules/ctron_plugin/script/trace")

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
    -- v2 (spec §8): a surface with stations here is a subscriber surface: its jobs are made here, with a worker. Any
    -- other is a publisher surface: its jobs go to the controller, while some instance subscribes on that surface.
    local subscriber = (storage.stations_count[surface_index] or 0) > 0
    if subscriber and not (storage.available_ctron_count[surface_index] > 0) then return end
    if not subscriber and not storage.ctron_plugin.subscribed[game.surfaces[surface_index].name] then return end
    for job_type, job_class in pairs(job_proc.job_types) do
        job_proc.process_queue(surface_index, job_type, job_class, subscriber)
    end
end

--- Process a single job queue
---@param surface_index uint
---@param job_type string
---@param job_class job
---@param subscriber boolean this instance subscribes on the surface (spec §8)
job_proc.process_queue = function(surface_index, job_type, job_class, subscriber)
    local job_start_delay = storage.job_start_delay
    for _, chunk in pairs(storage[job_type .. '_queue'][surface_index]) do
        if ((game.tick - chunk.last_update_tick) > job_start_delay) then
            if job.find_chunk_entities(chunk, job_type) then
                -- find a worker to perform the prospective job
                local worker
                if subscriber then
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
                if not subscriber then
                    -- v2 (spec §8): to the controller, for an instance subscribed on this surface's name to claim
                    local surface_name = game.surfaces[surface_index].name
                    new_job.surface_name = surface_name
                    clusterio_api.send_json("ctron_plugin:job_add", {
                        job_key = new_job.key, job_type = new_job.job_type, surface_name = surface_name, job = new_job,
                    })
                    trace.send("ctron.pool", "published", "info", new_job, { surface = surface_name })
                else
                    storage.jobs[job_index] = new_job
                end
                if job_type == "destroy" then
                    break -- to allow minion assignment
                end
            else
                -- clear the chunk from the queue
                storage[job_type .. "_queue"][surface_index][chunk.key] = nil
            end
        end
    end
end

return job_proc
