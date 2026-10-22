-- The run state machine (spec §5.3, R-29..R-31, R-44, R-45): one table for every kind; a kind changes only the
-- at_task test. step(run, facts, cfg, ev) mutates the plain-data run and returns effects for runs.lua to apply.
-- Facts are read lazily by the shell, so a state pays only for what it reads.
local combat_core = require("modules/ctron_pluginv2/combat_core")

local run_core = {}

run_core.WAIT = 900 -- short and trash_full: one event per station visit (CC job.lua:1099-1114)
run_core.AT_TASK_LIMIT = 3600 -- R-146: per task since its last progress, a backstop for robots that never settle
run_core.LANDFILL = { "landfill", "foundation", "ice-platform" } -- first match (CC job.lua:926-937)
local POLL = { loading = 120, unloading = 120, deliver = 120, at_task = 60, fight = 60, follow = 60 }
run_core.POLL = POLL

local ENTER, HANDLE = {}, {} -- per state: what entering it does, and its poll and travel-event handler

local function enter(run, state, f, cfg, acts)
	run.state, run.since, run.next = state, f.tick, nil
	return ENTER[state](run, f, cfg, acts)
end

local function axis(lo, hi, r)
	local extent = math.max(hi - lo, 1)
	local n = math.ceil(extent / r / 2)
	local out = {}
	if n > 1 then
		for i = 1, n do
			out[i] = lo + r + (extent - 2 * r) * (i - 1) / (n - 1)
		end
	else
		out[1] = lo + extent / 2
	end
	return out
end

--- CC's task grid (utility_functions.lua:175-220): ceil(extent / 2r) points per axis, spread from r inside each edge,
--- or the middle when one point fits. The zig-zag order is dropped: tasks are picked nearest-first.
function run_core.grid(area, r)
	local lt, rb = area.left_top, area.right_bottom
	local xs, ys = axis(lt.x, rb.x, r), axis(lt.y, rb.y, r)
	local points = {}
	for _, y in ipairs(ys) do
		for _, x in ipairs(xs) do
			points[#points + 1] = { x = x, y = y }
		end
	end
	return points
end

local function add_item(load, name, quality, n)
	load[name] = load[name] or {}
	load[name][quality] = (load[name][quality] or 0) + n
end

--- Σ bring of the shares + the cargo items + the profile's full amounts (spec §5.3 adopt step 3).
function run_core.load_of(work, cargo, profile)
	local load = {}
	for _, share in ipairs(work or {}) do
		for _, it in ipairs(share.bring or {}) do
			add_item(load, it[1], it[2], it[3])
		end
	end
	for _, it in ipairs(cargo and cargo.items or {}) do
		add_item(load, it[1], it[2], it[3])
	end
	for name, qualities in pairs(profile) do
		for quality, n in pairs(qualities) do
			add_item(load, name, quality, n)
		end
	end
	return load
end

--- msg is a decoded ct.job.assign (R-153: one station, members a cid list with the worker or leader first); i is the
--- member's index in it. A minion assign (msg.lead, R-196) lists only minions, each built here with i = its index, and
--- carries no work (R-209). A destroy assign without lead is the leader's: runs.lua builds only i == 1 from it, and
--- members[2..] are its squad list.
function run_core.new(msg, i, ctx)
	local minion = msg.lead ~= nil
	local work = not minion and msg.work or {}
	local tasks = {}
	for _, share in ipairs(work) do
		for _, p in ipairs(run_core.grid(share.area, ctx.radius * 0.95)) do
			tasks[#tasks + 1] = p
		end
	end
	local load = run_core.load_of(work, msg.cargo, ctx.profile)
	local landfill
	for _, name in ipairs(run_core.LANDFILL) do
		if load[name] then
			landfill = name
			break
		end
	end
	local run = {
		jid = msg.jid, cid = msg.members[i], kind = msg.kind, surface = msg.surface, unit = ctx.unit,
		role = (minion or i > 1) and "minion" or (msg.kind == "destroy" and "leader" or "worker"),
		station = msg.station, work = work, work_inst = work[1] and tonumber(work[1].wid:match("^(%d+)|")),
		tasks = tasks, done_tasks = 0, total_tasks = #tasks, load = load, cargo = msg.cargo, landfill = landfill,
		radius = ctx.radius, reached = 0, sent = {}, status = "new", since = ctx.tick, ammo = ctx.ammo,
	}
	if minion then
		local l = msg.lead
		run.squad = { leader = l.cid, members = {}, lead = { inst = l.inst, x = l.x, y = l.y } }
		run.combat = { safe = {}, nuked = {} }
	elseif msg.kind == "destroy" then
		local squad = { leader = msg.members[1], members = {} }
		for j = 2, #msg.members do
			squad.members[#squad.members + 1] = msg.members[j]
		end
		run.squad, run.combat = squad, { safe = {}, nuked = {} }
	end
	return run
end

--- R-30: on the work's instance the nearest remaining task, deferred ones last; elsewhere the first task.
function run_core.pick(run, pos, here)
	local tasks = run.tasks
	if #tasks == 0 then
		return nil
	end
	if here ~= run.work_inst then
		return 1
	end
	local best, best_d, best_again
	for i, p in ipairs(tasks) do
		local dx, dy = p.x - pos.x, p.y - pos.y
		local d, again = dx * dx + dy * dy, p.again == true
		if not best or (best_again and not again) or (again == best_again and d < best_d) then
			best, best_d, best_again = i, d, again
		end
	end
	return best
end

--- CC's restock test (job.lua:1010-1034): neither the slots nor the trunk holds more than ceil(25 %) of ammo_count.
function run_core.ammo_low(f, cfg)
	if cfg.ammo_count <= 0 then
		return false
	end
	local threshold = math.ceil(cfg.ammo_count * 25 / 100)
	return f.ammo_slots <= threshold and f.ammo_trunk <= threshold
end

-- R-124: left is the work tile's own tick, so it is stamped (and the cells rescanned) only on the work's instance.
local function on_work(run, here)
	return run.work_inst ~= nil and here == run.work_inst
end

-- run.reduced holds the current reduced size (0 or 1), nil at full size; an op goes out only on a change.
local function roboports(run, acts, size)
	if (run.reduced or "full") == size then
		return
	end
	run.reduced = size ~= "full" and size or nil
	acts[#acts + 1] = { "roboports", size }
end

-- R-205: a squad run keeps radius 0 from start to unloading, so only unloading and release put the roboports back.
local function restore(run, acts)
	if not run.squad then
		roboports(run, acts, "full")
	end
	if run.logi then
		run.logi = nil
		acts[#acts + 1] = { "moving_logistics", false }
	end
end

local function first_wid(run)
	return run.work[1] and run.work[1].wid
end

--- A failure ends the run in place (§5.3 Ending, R-115, R-116).
local function fail(run, f, acts, why)
	if on_work(run, f.here) then
		run.left = run.left or f.tick
		acts[#acts + 1] = { "rescan" }
	end
	restore(run, acts)
	acts[#acts + 1] = { "emit", "failed", { cid = run.cid, why = why, wid = first_wid(run), left = run.left } }
	acts[#acts + 1] = { "release" }
	run.state, run.status, run.next = "ended", why, nil
end

--- unloading or deliver completed. Review 8: a run whose every task was dropped by travel ends failed.
local function finish(run, acts)
	acts[#acts + 1] = { "requests", "clear" }
	if run.fail_why and run.reached == 0 and not run.cancelled then
		acts[#acts + 1] = { "emit", "failed", { cid = run.cid, why = run.fail_why, wid = first_wid(run), left = run.left } }
	else
		acts[#acts + 1] = { "emit", "done", { cid = run.cid, left = run.left } }
	end
	acts[#acts + 1] = { "release" }
	run.state, run.next = "ended", nil
end

function run_core.lost(run, here, tick)
	local rescan = on_work(run, here)
	if rescan then
		run.left = run.left or tick
	end
	return { cid = run.cid, left = run.left }, rescan
end

local function waited(run, f)
	return f.tick - run.since >= run_core.WAIT
end

local function go_station(run, acts)
	local s = run.station
	acts[#acts + 1] = { "travel", { inst = s.inst, x = s.x, y = s.y }, { kind = "station", radius = 10 } }
	run.status = "moving"
end

ENTER.to_station = function(run, _, _, acts)
	if run.squad then
		roboports(run, acts, 0) -- CC destroy.lua:62, minion.lua:29
	else
		restore(run, acts)
	end
	go_station(run, acts)
end
ENTER.returning = ENTER.to_station

-- A station gone or unpowered on arrival, or unreachable: one other local station with a network, else fail (R-116).
local function fallback(run, f, acts, why)
	if not run.alt_tried and f.alt_station then
		run.alt_tried = true
		run.station = f.alt_station
		go_station(run, acts)
	else
		fail(run, f, acts, why)
	end
end

local function station_leg(next_state)
	return function(run, f, cfg, acts, ev)
		if ev and ev.type == "arrived" then
			if f.station_ok then
				return enter(run, next_state, f, cfg, acts)
			end
			return fallback(run, f, acts, "no_stations")
		elseif ev and ev.type == "failed" then
			return fallback(run, f, acts, ev.reason)
		end
	end
end
HANDLE.to_station = station_leg("loading")
HANDLE.returning = station_leg("unloading")

--- The ammo line a load built under cfg holds: { name, quality, count }, or false.
function run_core.ammo_of(cfg)
	return cfg.ammo_count > 0 and { cfg.ammo[1], cfg.ammo[2], cfg.ammo_count } or false
end

local function same(a, b)
	return a == b or a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

--- The load's ammo line follows the settings (ILLISIS/ctron_plugin#5): the restock test counts the configured ammo, so
--- a restock that loaded the run's first ammo turned straight back, again and again. run.ammo is the line the load
--- holds; nil (a run made before it was kept) takes the settings' line as its own.
local function ammo_line(run, cfg)
	local had, want = run.ammo, run_core.ammo_of(cfg)
	run.ammo = want
	if had == nil or same(had, want) then
		return
	end
	local qs = had and run.load[had[1]]
	if qs and qs[had[2]] then
		qs[had[2]] = qs[had[2]] > had[3] and qs[had[2]] - had[3] or nil
		if next(qs) == nil then
			run.load[had[1]] = nil
		end
	end
	if want then
		add_item(run.load, want[1], want[2], want[3])
	end
end

ENTER.loading = function(run, f, cfg, acts)
	ammo_line(run, cfg)
	run.sent = {}
	acts[#acts + 1] = { "requests", "load" }
	run.status, run.arg = "requesting", nil
	run.next = f.tick + POLL.loading
end

HANDLE.loading = function(run, f, cfg, acts, ev)
	if ev then
		return
	end
	if f.fulfilled then
		acts[#acts + 1] = { "requests", "clear" }
		acts[#acts + 1] = { "balance_ammo" }
		run.arg = nil
		if run.kind == "cargo" then
			return enter(run, "to_dest", f, cfg, acts)
		end
		-- R-198: a squad fights or follows from its station (CC destroy.lua:67, minion.lua:84)
		return enter(run, run.role == "leader" and "fight" or run.role == "minion" and "follow" or "to_work", f, cfg, acts)
	end
	if run.sent.trash then -- R-143: trash_full stays the status (and its items) for the rest of the visit
		run.status = "trash_full"
	else
		run.status, run.arg = run.sent.short and "short" or "awaiting_logistics", f.missing
	end
	if waited(run, f) then
		if not run.sent.short and not f.covers_missing then
			run.sent.short, run.status = true, "short"
			acts[#acts + 1] = { "emit", "short", { cid = run.cid, missing = f.missing } }
		end
		if not run.sent.trash and not f.trash_empty and f.trash_stuck then
			run.sent.trash, run.status, run.arg = true, "trash_full", f.trash_items
			acts[#acts + 1] = { "emit", "trash_full", { cid = run.cid, items = f.trash_items } }
		end
	end
	run.next = f.tick + POLL.loading
end

ENTER.to_work = function(run, f, cfg, acts)
	local i = run_core.pick(run, f.pos, f.here)
	if not i then
		return enter(run, "leave_work", f, cfg, acts)
	end
	run.task = i
	local p = run.tasks[i]
	local opts = { kind = "work", radius = 3, reach = run.radius }
	if run.landfill then
		opts.radius, opts.landfill = 0.8 * run.radius, run.radius -- robots fly over water (R-74)
		roboports(run, acts, 1)
		if not run.logi then
			run.logi = true
			acts[#acts + 1] = { "moving_logistics", true }
		end
	end
	acts[#acts + 1] = { "travel", { inst = run.work_inst, x = p.x, y = p.y }, opts }
	run.status = "moving"
end

-- CC's defer-then-drop (pathfinder.lua:264-275): the first failure defers the task, the second drops it.
local function task_failed(run, reason)
	local p = run.tasks[run.task]
	if p and not p.again then
		p.again = true
	elseif p then
		table.remove(run.tasks, run.task)
		run.fail_why = reason
	end
	run.task = nil
end

HANDLE.to_work = function(run, f, cfg, acts, ev)
	if ev and ev.type == "arrived" then
		run.reached = run.reached + 1
		return enter(run, "at_task", f, cfg, acts)
	elseif ev and ev.type == "failed" then
		task_failed(run, ev.reason)
		return enter(run, "to_work", f, cfg, acts)
	end
end

ENTER.at_task = function(run, f, _, acts)
	roboports(run, acts, "full")
	run.status, run.arg = "working", run.kind
	run.out_last, run.count_last, run.held_last, run.out_same, run.nonzero, run.checks = nil, nil, nil, 0, 0, 0
	run.task_since = f.tick
	run.next = f.tick + POLL.at_task
end

--- The current task is done: the next task, or leave_work when none is left.
local function pop(run, f, cfg, acts, state)
	table.remove(run.tasks, run.task)
	run.task = nil
	run.done_tasks = run.done_tasks + 1
	return enter(run, #run.tasks > 0 and (state or "to_work") or "leave_work", f, cfg, acts)
end

-- R-32, review 24, I1/I2: integers only. Progress is the remaining count or the trunk's item total moving: robots
-- emptying a full chest leave the count alone until the chest is empty. Robots out: stalled after 5 checks with out
-- and both unchanged. Repair has no count, so a check counts only while some robot is idle (out < robots); all busy is
-- progress. None out: nothing left in reach pops, something left on two checks in a row pops (the robots can't do it),
-- counted only while a roboport can spawn robots; repair pops on its second check with none out (CC). The 3600-tick
-- limit runs from the task's last progress and catches robots that are all stuck.
HANDLE.at_task = function(run, f, cfg, acts, ev)
	if ev then
		return
	end
	run.checks = run.checks + 1
	local count = run.kind ~= "repair" and f.count or nil
	local held = f.trunk_count
	local still = held == run.held_last and count == run.count_last
	if run.held_last and not still then
		run.task_since = f.tick
	end
	run.count_last, run.held_last = count, held
	local done
	if f.tick - run.task_since >= run_core.AT_TASK_LIMIT then
		done = true
	elseif f.out > 0 then
		run.nonzero = 0
		local busy = run.kind == "repair" and f.out >= f.robots
		run.out_same = not busy and still and f.out == run.out_last and run.out_same + 1 or 0
		run.out_last = f.out
		done = run.out_same >= 5
	else
		run.out_last, run.out_same = nil, 0
		if count == 0 then
			done = true
		elseif f.can_spawn then -- below spawn_minimum the robots stay docked although they could do the work
			run.nonzero = run.nonzero + 1 -- repair has no count: its second check with no robots out
			done = run.nonzero >= 2
		end
	end
	if done then
		return pop(run, f, cfg, acts)
	end
	run.next = f.tick + POLL.at_task
end

ENTER.leave_work = function(run, f, cfg, acts)
	if on_work(run, f.here) then
		run.left = f.tick
		acts[#acts + 1] = { "rescan" }
	end
	restore(run, acts)
	return enter(run, "returning", f, cfg, acts)
end

-- Combat ops: roboports through the tracking helper; the walks as travel: to the task and to a place on another tile
-- by route (R-201), to a leader on this tile locally, to a remote leader by route (R-199). A move to a place on this
-- tile is CC's direct autopilot.
local function combat_ops(run, f, acts, ops)
	for _, o in ipairs(ops) do
		if o[1] == "roboports" then
			roboports(run, acts, o[2])
		elseif o[1] == "goto_task" then
			local p = run.tasks[run.task]
			run.leg = "task"
			acts[#acts + 1] = { "travel", { inst = run.work_inst, x = p.x, y = p.y }, { kind = "work", radius = 3 } }
		elseif o[1] == "move" then
			local place = o[2]
			if place.inst == f.here then
				acts[#acts + 1] = { "move", place.x, place.y }
			else
				run.leg = "retreat" -- a failed one must not cost the task (review finding 6)
				acts[#acts + 1] = { "travel", { inst = place.inst, x = place.x, y = place.y }, { kind = "work", radius = 3 } }
			end
		elseif o[1] == "goto_lead" then
			acts[#acts + 1] = { "travel", run.squad.lead, { kind = "follow", radius = 10 } }
		elseif o[1] == "goto_leader" then
			local p = f.leader.pos
			acts[#acts + 1] = { "travel", { inst = f.here, x = p.x, y = p.y }, { kind = "follow", radius = 10 } }
		else
			acts[#acts + 1] = o
		end
	end
end

ENTER.fight = function(run, f, cfg, acts)
	run.task = run.task or run_core.pick(run, f.pos, f.here)
	if not run.task then
		return enter(run, "leave_work", f, cfg, acts)
	end
	roboports(run, acts, 0) -- CC destroy.lua:62
	run.status = "working"
	run.next = f.tick + POLL.fight
end

HANDLE.fight = function(run, f, cfg, acts, ev)
	if ev and ev.type == "failed" then
		if run.leg == "retreat" then
			-- only a failed walk to the task drops it: drop the place it routed to; the next poll picks the one before
			run.combat.safe[#run.combat.safe] = nil
			run.next = f.tick + POLL.fight
			return
		end
		task_failed(run, ev.reason)
		run.task = run_core.pick(run, f.pos, f.here)
		if not run.task then
			return enter(run, "leave_work", f, cfg, acts)
		end
		run.next = f.tick + POLL.fight
		return
	end
	local v, p = f.combat, run.tasks[run.task]
	v.task, v.tasks_left = p and { x = p.x, y = p.y, inst = run.work_inst }, #run.tasks
	v.minions = #run.squad.members
	local d = combat_core.fight(v, run.combat)
	combat_ops(run, f, acts, d.ops)
	run.status = d.status
	if d.to_station then
		return enter(run, "to_station", f, cfg, acts)
	elseif d.pop then
		run.reached = run.reached + 1 -- a leader never enters to_work: a popped task counts as reached (review finding 4)
		return pop(run, f, cfg, acts, "fight")
	end
	run.next = f.tick + POLL.fight
end

ENTER.follow = function(run, f, _, acts)
	roboports(run, acts, 0) -- CC minion.lua:29; restore() puts them back when the run leaves follow
	run.status = "following"
	run.next = f.tick + POLL.follow
end

local LEADER_GONE = { leave_work = true, returning = true, unloading = true, ended = true }

local function go_home(run, f, cfg, acts)
	acts[#acts + 1] = { "stop" }
	return enter(run, "returning", f, cfg, acts)
end

-- R-204: leave the squad (the leader stops waiting, the controller hears `left`), restock at the own station, and
-- come back through loading -> follow.
local function restock_minion(run, f, cfg, acts)
	acts[#acts + 1] = { "stop" }
	acts[#acts + 1] = { "leave_squad" }
	return enter(run, "to_station", f, cfg, acts)
end

-- 5.7 minion follow: home when the leader returns or ends; a minion that runs dry or fails to repair restocks and
-- rejoins (R-204). Travel callbacks just re-run the poll. A leader on another tile is the relay's business (R-199).
HANDLE.follow = function(run, f, cfg, acts, ev)
	if ev and ev.type == "failed" then -- retry at the next poll, not at once
		run.next = f.tick + POLL.follow
		return
	end
	local leader = f.leader
	if leader and LEADER_GONE[leader.state] then
		return go_home(run, f, cfg, acts)
	end
	local d = combat_core.follow(f.combat, run.combat)
	combat_ops(run, f, acts, d.ops)
	run.status = d.status
	if d.leave then
		return restock_minion(run, f, cfg, acts)
	end
	run.next = f.tick + POLL.follow
end

function run_core.leave_squad(run, cid)
	local members = run.squad and run.squad.members or {}
	for i = #members, 1, -1 do
		if members[i] == cid then
			table.remove(members, i)
		end
	end
end

ENTER.unloading = function(run, f, _, acts)
	roboports(run, acts, "full") -- R-205: a squad run gets its radius back at the station
	run.sent = {}
	acts[#acts + 1] = { "requests", "unload" }
	run.status, run.arg = "clearing", nil
	run.next = f.tick + POLL.unloading
end

HANDLE.unloading = function(run, f, cfg, acts, ev)
	if ev then
		return
	end
	if f.unloaded then
		return finish(run, acts)
	end
	if waited(run, f) and not f.trash_empty and f.trash_stuck and not run.sent.trash then
		if not run.drop_tried and f.drop_station then
			run.drop_tried = true
			run.station = f.drop_station
			return enter(run, "returning", f, cfg, acts)
		end
		run.sent.trash, run.status, run.arg = true, "trash_full", f.trash_items -- R-157: the record's missing
		acts[#acts + 1] = { "emit", "trash_full", { cid = run.cid, items = f.trash_items } }
	end
	run.next = f.tick + POLL.unloading
end

ENTER.to_dest = function(run, _, _, acts)
	local d = run.cargo.dest
	acts[#acts + 1] = { "travel", { inst = d.inst, x = d.x, y = d.y }, { kind = "station", radius = 3 } }
	run.status = "moving"
end

HANDLE.to_dest = function(run, f, cfg, acts, ev)
	if ev and ev.type == "arrived" then
		return enter(run, "deliver", f, cfg, acts)
	elseif ev and ev.type == "failed" then
		return fail(run, f, acts, ev.reason)
	end
end

ENTER.deliver = function(run, f, _, acts)
	run.sent = {}
	acts[#acts + 1] = { "requests", "deliver" }
	run.status = "delivering"
	run.next = f.tick + POLL.deliver
end

HANDLE.deliver = function(run, f, _, acts, ev)
	if ev then
		return
	end
	if f.delivered then
		return finish(run, acts)
	end
	if waited(run, f) and not f.trash_empty and f.trash_stuck and not run.sent.trash then
		run.sent.trash, run.status = true, "trash_full" -- R-117: a status, no event
	end
	run.next = f.tick + POLL.deliver
end

-- Interrupts (§5.3), in the spec's order after cancel. Returns true when one fired.
local function interrupt(run, f, cfg, acts)
	local s = run.state
	local working = s == "to_work" or s == "at_task"
	local restocks = s == "at_task" or s == "fight"
	if working and f.health < 0.6 then
		enter(run, "leave_work", f, cfg, acts)
		return true
	end
	if (s == "fight" or s == "follow") and f.health < 0.6 then
		run.combat.repairing = true -- combat_core repairs in place; no transition
	end
	if restocks and f.robots < 1 then
		enter(run, "to_station", f, cfg, acts)
		run.status = "missing_robots"
		return true
	end
	if (restocks or s == "follow") and run_core.ammo_low(f, cfg) then
		if s == "follow" then
			restock_minion(run, f, cfg, acts)
		else
			enter(run, "to_station", f, cfg, acts)
		end
		return true
	end
	if working and run.landfill and f.landfill_aboard == 0 and f.out == 0 then -- robots out still carry landfill
		enter(run, "leave_work", f, cfg, acts)
		run.status = "no_landfill"
		return true
	end
	return false
end

local function cancel(run, f, cfg, acts)
	if run.state == "returning" or run.state == "unloading" then
		return
	end
	acts[#acts + 1] = { "stop" }
	run.cancelled = true
	return enter(run, "returning", f, cfg, acts)
end

local function new_station(run, f, cfg, acts, station)
	run.station = station
	local s = run.state
	if s == "loading" or s == "to_station" then
		run.alt_tried = nil
		return enter(run, "to_station", f, cfg, acts)
	elseif s == "unloading" or s == "returning" then
		run.alt_tried = nil
		return enter(run, "returning", f, cfg, acts)
	end
end

--- A run that crossed to another save: every tick field but left (the work tile's own tick, review 2) moves by
--- delta = the destination's tick - the capture tick, so polls and deadlines keep their distance.
function run_core.rebase(run, delta)
	for _, k in ipairs({ "since", "next", "task_since" }) do
		if run[k] then
			run[k] = run[k] + delta
		end
	end
end

function run_core.start(run, f, cfg)
	local acts = {}
	enter(run, "to_station", f, cfg, acts)
	return acts
end

function run_core.step(run, f, cfg, ev)
	local acts = {}
	if run.state == "ended" then
		return acts
	end
	local t = ev and ev.type
	if t == "cancel" then
		cancel(run, f, cfg, acts)
	elseif t == "station" then
		new_station(run, f, cfg, acts, ev.station)
	elseif t == "repick" then
		-- Arrival at the work's tile through a crossing: the new leg's travel.go takes over travel's 12-tick settle
		-- (P3), so re-picking at once is safe. No stop first: a cancel would drop the settle.
		if run.state == "to_work" then
			run.task = nil
			enter(run, "to_work", f, cfg, acts)
		elseif run.state == "fight" then
			-- no travel: the next fight poll decides to hold, retreat or goto_task (review finding 5)
			run.task = run_core.pick(run, f.pos, f.here)
			if not run.task then
				enter(run, "leave_work", f, cfg, acts)
			end
		end
	elseif t == "leader_lost" then
		if run.state ~= "returning" and run.state ~= "unloading" then
			acts[#acts + 1] = { "stop" }
			enter(run, "returning", f, cfg, acts)
		end
	elseif not interrupt(run, f, cfg, acts) then
		local handle = HANDLE[run.state]
		if handle then
			handle(run, f, cfg, acts, ev)
		end
	end
	return acts
end

return run_core
