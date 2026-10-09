-- Hop-by-hop pathing in the game (Constructron v2 spec §6): the border plan on a worker's surface, the water search,
-- the off-tile test, and the watch while a constructron heads for a crossing.
local ue = require("modules/universal_edges")
local core = require("modules/ctron_plugin/script/border_core")
local trace = require("modules/ctron_plugin/script/trace")

local border = {}

--- plan(worker, goal) → nil (goal on worker's tile), { wait = reason } or { edge, x, y, moved }: P, on dry ground
--- (§6.1, §6.2). Water carries CC's pathing layer, and the proxy is the path's 10×10 box.
function border.plan(worker, goal)
	local plan = core.plan(ue.edges.list(worker.surface_index), goal, worker.position)
	if not plan or plan.wait then
		return plan
	end
	for _, x in ipairs(core.xs(plan.lx, plan.frame.length)) do
		local wx, wy = core.point(plan.frame, x)
		if worker.surface.can_place_entity({ name = "constructron_pathing_proxy_10", position = { wx, wy } }) then
			return { edge = plan.edge, x = wx, y = wy, moved = x - plan.lx }
		end
	end
	return { wait = "no_dry_crossing" }
end

--- off_tile(entity, position): position lies past a side of entity's tile, so it is never "reached" here (§6.4).
function border.off_tile(entity, position)
	return core.plan(ue.edges.list(entity.surface_index), position, entity.position) ~= nil
end

--- goal(job, position) → where job's worker heads for position (§6.4): position itself when it's on this tile, P
--- when it's past a side, or nil while the job waits. A wait (an inactive side, no dry P, or a refusal's 5 minutes,
--- §7) is logged once per episode; a wait for the worker's robots to come back is silent (§10).
function border.goal(job, position)
	local worker = job.worker
	local plan = border.plan(worker, position)
	if not plan then
		job.crossing, job.waiting = nil, nil
		return position
	end
	local why = plan.wait
	if not why and job.cross_wait_until and game.tick < job.cross_wait_until then
		why = "refused"
	end
	if why then
		if job.waiting ~= why then
			job.waiting = why
			trace.send("ctron.path", "waiting", "warn", job, { reason = why })
		end
		return nil
	end
	job.waiting = nil -- the episode is over: a side came back, or the 5 minutes passed
	local network = worker.logistic_cell and worker.logistic_cell.logistic_network
	if network and next(network.construction_robots) then
		return nil
	end
	job.crossing = { edge = plan.edge, x = plan.x, y = plan.y }
	ue.vehicles.watch(worker) -- clears a rejected mark too (D-3)
	trace.send("ctron.path", "border", "verbose", job, { edge = plan.edge, x = plan.x, y = plan.y, moved = plan.moved })
	return { x = plan.x, y = plan.y }
end

--- watch(job): once a path to P arrives, the worker goes on UE's watch again; UE dropped it while the path was being
--- computed, since it then had no autopilot (§6.4).
function border.watch(job)
	if job.crossing and job.worker and job.worker.valid then
		ue.vehicles.watch(job.worker)
	end
end

return border
