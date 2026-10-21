local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ct = require("modules/ctron_pluginv2/ct")
local events_of, cid_of, share, assign, charge, paved = fx.events_of, fx.cid_of, fx.share, fx.assign, fx.charge, fx.paved

-- G8 (P2 Task 4): the at_task poll: the count pop, the two-check rule, and SP-9's robots-out arithmetic.

--- A surface with a station at (0, 0) stocked with `chests` wooden chests, and an idle ctron beside it, assigned a
--- construction job over x 45..60 (one task point).
local function setup(c, name, chests, jid, bring)
	c.surface = paved(name, -40, -40, 110, 40)
	c.station = fx.station(c.surface, 0, 0, { ["construction-robot"] = 60, ["wooden-chest"] = chests })
	c.v = fx.ctron(c.surface, -6, 0, { robots = 10 })
	c.jid, c.bring = jid, bring
end

local function start(c)
	charge(c.v)
	ct.registry.set_state(cid_of(c.v), "idle")
	assign(c.jid, "construction", c.surface, { c.v }, c.station,
		{ share(c.surface, "construction", 45, -5, 60, 5, { { "wooden-chest", "normal", c.bring } }, 0) })
end

--- Watch the run: note the tick it is first in at_task, and call done(entered, run) the tick it leaves.
local function at_task_span(ctx, c, from, limit, what, done, sample)
	fx.wait(ctx, from, limit, what, function()
		charge(c.v)
		local run = ct.runs.get(cid_of(c.v))
		if run and run.state == "at_task" then
			c.entered = c.entered or game.tick
			if sample then
				sample()
			end
		end
		return c.entered ~= nil and (run == nil or run.state ~= "at_task")
	end, function()
		done(game.tick - c.entered, ct.runs.get(cid_of(c.v)))
	end)
end

t.case("G8 count pop", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g8-count", 4, "g8-count", 4)
		for i = 1, 4 do
			fx.ghost(c.surface, 49.5 + i * 2, 0.5)
		end
	end)
	ctx.at(14, function()
		start(c)
	end)
	at_task_span(ctx, c, 16, 6000, "the run leaving at_task", function(span, run)
		ctx.expect(span <= 900, "left at_task " .. span .. " ticks after entering")
		ctx.expect(run and run.done_tasks == run.total_tasks, "every task done: " .. serpent.line(run and { run.done_tasks, run.total_tasks }))
		ctx.expect(c.surface.count_entities_filtered({ type = "entity-ghost" }) == 0, "the ghosts are built")
	end)
end)

t.case("G8 unbuildable pop", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g8-unbuildable", 2, "g8-unbuildable", 2)
		fx.ghost(c.surface, 52.5, 0.5, "iron-chest") -- the share brings only wooden chests
	end)
	ctx.at(14, function()
		start(c)
	end)
	local out = 0
	at_task_span(ctx, c, 16, 6000, "the run leaving at_task", function(span)
		ctx.expect(span <= 200, "left at_task " .. span .. " ticks after entering")
		ctx.expect(out == 0, "no robots went out: " .. out)
	end, function()
		local net = c.v.logistic_network
		out = math.max(out, net and net.all_construction_robots - net.available_construction_robots or 0)
	end)
end)

t.case("G8 robots-out arithmetic", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g8-out", 20, "g8-out", 20)
		for i = 0, 4 do
			for j = 0, 3 do
				fx.ghost(c.surface, 48.5 + i * 2, -3.5 + j * 2)
			end
		end
	end)
	ctx.at(14, function()
		start(c)
	end)
	local samples, bad = 0, {}
	fx.wait(ctx, 16, 8000, "the done event", function()
		charge(c.v)
		if game.tick % 60 == 0 then
			local net = c.v.valid and c.v.logistic_network
			if net then
				local out = net.all_construction_robots - net.available_construction_robots
				if out > 0 then
					samples = samples + 1
					if out ~= #net.construction_robots then
						bad[#bad + 1] = out .. " vs " .. #net.construction_robots
					end
				end
			end
		end
		return #events_of("g8-out", "done") > 0
	end, function()
		ctx.expect(samples > 0, "robots were seen out")
		ctx.expect(#bad == 0, "all - available == #construction_robots: " .. serpent.line(bad))
	end)
end)

-- SP-7 (P2 Task 10): the run paths of §5.12's cost table, 1000 iterations each, in the tick the run first polls at_task.
t.case("SP-7 run costs", function(ctx)
	ctx.expect_file("ctronv2-spikes/sp7.txt")
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-sp7", 40, "sp7", 40)
		for i = 0, 19 do
			for j = 0, 9 do
				fx.ghost(c.surface, 42.5 + i, -5.5 + j)
			end
		end
	end)
	ctx.at(14, function()
		start(c)
	end)
	local N = 1000
	local function time(label, fn)
		local p = helpers.create_profiler()
		for _ = 1, N do
			fn()
		end
		p.stop()
		p.divide(N)
		fx.note("sp7", label, ": ", p)
	end
	fx.wait(ctx, 16, 6000, "the run polling at_task", function()
		charge(c.v)
		local run = ct.runs.get(cid_of(c.v))
		return run ~= nil and run.state == "at_task"
	end, function()
		local run = ct.runs.get(cid_of(c.v))
		local trunk = fx.trunk_of(c.v)
		-- Fill the trunk with one of each of many item types: the full-trunk case.
		while not trunk.is_full() do
			for name in pairs(prototypes.item) do
				trunk.insert({ name = name, count = 1 })
			end
		end
		local entity = c.v
		local tick = game.tick
		time("loading check, ct.logistics.fulfilled on a full trunk", function()
			ct.logistics.fulfilled(entity)
		end)
		time("get_contents of the full trunk", function()
			local _ = trunk.get_contents()
		end)
		time("(parts) ct.settings.of + registry.ctron + registry.here", function()
			ct.settings.of(run.surface)
			ct.registry.ctron(run.cid)
			ct.registry.here()
		end)
		local saved_next = run.next
		run.next = tick + 600
		time("sleeping-run visit", function()
			local _ = run.next and tick >= run.next and not run.in_transit
		end)
		local radius = entity.logistic_cell.construction_radius
		local out, count
		local sink = {}
		local filter = { type = { "entity-ghost", "tile-ghost", "item-request-proxy" }, force = entity.force }
		time("at_task check, out arithmetic + count_entities_filtered", function()
			local net = entity.logistic_network
			out = net.all_construction_robots - net.available_construction_robots
			filter.position, filter.radius = entity.position, radius
			count = entity.surface.count_entities_filtered(filter)
		end)
		fx.note("sp7", "last out/count: ", tostring(out), "/", tostring(count), " ", #sink)
		fx.note("sp7", "ghosts in surface: ", tostring(c.surface.count_entities_filtered({ type = "entity-ghost" })),
			", trunk full: ", tostring(trunk.is_full()), ", radius: ", tostring(radius))
		-- step mutates the poll counters (and could pop the task): put them back each iteration.
		local checks, nonzero, out_same, out_last, count_last, task_since =
			run.checks, run.nonzero, run.out_same, run.out_last, run.count_last, run.task_since
		local status = run.status
		time("whole ct.runs.step(run) in at_task", function()
			ct.runs.step(run)
			run.status = status
			run.checks, run.nonzero, run.out_same, run.out_last, run.count_last, run.task_since =
				checks, nonzero, out_same, out_last, count_last, task_since
			run.state, run.next = "at_task", tick + 600
		end)
		local cfg = ct.settings.of(run.surface)
		fx.note("sp7", "ammo_count: ", tostring(cfg.ammo_count), " ammo: ", serpent.line(cfg.ammo))
		time("(parts) trunk get_item_count (ammo)", function()
			sink[1] = trunk.get_item_count({ name = cfg.ammo[1], quality = cfg.ammo[2] })
		end)
		time("(parts) health+position+radius", function()
			sink[1], sink[2], sink[3] = entity.get_health_ratio(), entity.position, entity.logistic_cell.construction_radius
		end)
		time("(parts) ct.report.mark(job)", function()
			ct.report.mark("job", run.jid)
		end)
		time("(parts) ct.gui.on_status", function()
			ct.gui.on_status(entity, run.status)
		end)
		fx.note("sp7", "run state after: ", run.state)
		run.next = saved_next
	end)
end)
