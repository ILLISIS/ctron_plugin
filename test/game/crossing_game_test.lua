-- G10 (P2 Task 7): a run rides UE's vehicle crossing: the cid and the run survive, the source drops silently, a refusal
-- gives the run back, an idle ctron crosses without one, and the run resumes its legs on the far side.
local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ct = require("modules/ctron_pluginv2/ct")
local ue = require("modules/universal_edges")
local connectors = require("modules/universal_edges/edges/connectors")
local crossing = require("modules/ctron_pluginv2/crossing")
local events_of, cid_of, share, assign, charge = fx.events_of, fx.cid_of, fx.share, fx.assign, fx.charge

-- The source's send answers too_big for an edge in this set; the original runs otherwise.
local too_big = {}
local ep_send = connectors.methods.send
connectors.methods.send = function(ep, dir, payload)
	if ep.type == "vehicle" and too_big[ep.edge] then
		return nil, "too_big"
	end
	return ep_send(ep, dir, payload)
end

-- The arrival is uncharged, so registry.fit fails and nothing paints it idle. A case that sets `fit_all` has every ctron
-- fit, so an idle repaint at arrival really happens unless crossing re-applies the run's paint.
local fit_all = false
-- unfit_on: a surface whose fit tests fail as live on the tick UE creates the ctron, before its logistic cell is up.
-- Per surface, ahead of fit_all: the cases run side by side in one save.
local unfit_on
local real_fit = ct.registry.fit
ct.registry.fit = function(entity)
	if unfit_on and entity.surface.name == unfit_on then
		return false, "no_roboports"
	elseif fit_all then
		return true
	end
	return real_fit(entity)
end

-- Every restored call UE makes, by edge: proves the refusal case really captured and gave back.
local restored = {}
ue.transfers.extend({ name = "ctronv2_g10_test", types = { vehicle = true },
	restored = function(ep, _, why)
		restored[ep.edge] = why
	end,
})

--- A case: its own surface with the looped edge, a station and a ctron near side a (y = 3000).
local function setup(c, name)
	c.surface = fx.surface("ctv2-g10-" .. name)
	c.ex = fx.pair(c.surface, "g10" .. name, 0)
	c.station = fx.station(c.surface, 32, 3030, { ["construction-robot"] = 60, ["wooden-chest"] = 50 })
	c.v = fx.ctron(c.surface, 26, 3030, { robots = 10 })
	c.cid = cid_of(c.v)
end

--- Make it idle (a later tick than setup, as G9's start).
local function start(c)
	charge(c.v)
	ct.registry.set_state(c.cid, "idle")
end

--- Force the crossing the way UE's own vehicle tests do: watch the entity and send it 3 tiles past side a's line.
local function force(v)
	ue.vehicles.watch(v)
	v.autopilot_destination = { v.position.x, fx.A - 3 }
end

--- Hand the ctron a construction run whose ghost is at (32.5, gy + 0.5) and wait for it in to_work. With `far`, the
--- share reaches up to side b's y = far and holds a second ghost there: no path joins the two regions, so the leg
--- before the crossing goes to the ghost on side a and the re-pick after it finds the nearer one.
local function run_to_work(ctx, c, jid, gy, from, done, far)
	ctx.at(from - 2, function()
		start(c)
	end)
	ctx.at(from, function()
		fx.ghost(c.surface, 32.5, gy + 0.5)
		if far then
			fx.ghost(c.surface, 32.5, far + 0.5)
		end
		assign(jid, "construction", c.surface, { c.v }, c.station,
			{ share(c.surface, "construction", 28, (far or gy) - 5, 38, gy + 5, { { "wooden-chest", "normal", 1 } }, 0) })
	end)
	fx.wait(ctx, from + 2, 3000, "the run in to_work", function()
		charge(c.v)
		local run = ct.runs.get(c.cid)
		local leg = run and storage.ctron_pluginv2.travel.units[c.v.unit_number]
		leg = leg and leg.leg
		-- Once the leg's path request is answered: a late reply would replace the forced destination.
		return run and run.state == "to_work" and leg and not leg.pending
	end, done)
end

--- Wait for the cid's entity to be a new one, then call done(offset, entity).
local function crossed(ctx, c, from, done)
	fx.wait(ctx, from, 600, "the ctron on side b", function()
		local rec = ct.registry.ctron(c.cid)
		return rec and rec.entity.valid and rec.entity ~= c.v and not c.v.valid and rec.entity
	end, function(k)
		local e = ct.registry.ctron(c.cid).entity
		charge(e)
		done(k, e)
	end)
end

t.case("G10 capture, materialize and commit keep the cid and the run", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "keep")
	end)
	run_to_work(ctx, c, "g10-keep", 3105, 16, function(k)
		local run = ct.runs.get(c.cid)
		c.jid, c.state = run.jid, run.state
		-- A landfill run walks to_work with logistics on; the arrival must not undo it.
		run.logi, c.v.enable_logistics_while_moving = true, true
		c.color = c.v.color
		fit_all = true
		force(c.v)
		crossed(ctx, c, k + 1, function(_, e)
			fit_all = false
			local now = ct.runs.get(c.cid)
			ctx.expect(e.position.y < fx.B + 10, "near side b: y = " .. e.position.y)
			ctx.expect(storage.ctron_pluginv2.by_unit[e.unit_number] == c.cid, "the cid follows the unit")
			ctx.expect(now and now.unit == e.unit_number, "the run's unit is the new one")
			ctx.expect(now.in_transit == nil, "not in transit")
			ctx.expect(now.jid == c.jid, "same job")
			ctx.expect(ct.registry.ctron(c.cid).entity == e, "the record holds the new entity")
			ctx.expect(#events_of(c.jid, "lost") == 0, "no lost event")
			ctx.expect(#ct.runs.of_job(c.jid) == 1, "one run for the job")
			ctx.expect(e.enable_logistics_while_moving == true, "logistics while moving kept")
			ctx.expect(serpent.line(e.color) == serpent.line(c.color), "the busy paint kept: " .. serpent.line(e.color))
		end)
	end)
end)

t.case("G10 commit deletes the source run silently", function(ctx)
	-- The looped fixture re-registers the cid before the source dies, so it can't show the source's drop. Capture by
	-- hand and destroy the entity as UE's commit does: a real source (another save) has no destination to replace it.
	local c = {}
	ctx.at(10, function()
		setup(c, "silent")
	end)
	run_to_work(ctx, c, "g10-silent", 3105, 16, function(k)
		c.jid = ct.runs.get(c.cid).jid
		ctx.expect(crossing.capture({ edge = "g10" }, c.v) ~= nil, "captured")
		c.v.destroy({ raise_destroy = true })
		ctx.at(k + 10, function()
			ctx.expect(#events_of(c.jid, "lost") == 0, "no lost event")
			ctx.expect(storage.ctron_pluginv2.runs[c.cid] == nil, "the run is gone")
			ctx.expect(ct.registry.ctron(c.cid) == nil, "the record is gone")
			ctx.expect(#ct.runs.of_job(c.jid) == 0, "no run for the job")
		end)
	end)
end)

t.case("G10 a refused crossing gives the run back", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "refuse")
		too_big[c.ex] = true
	end)
	run_to_work(ctx, c, "g10-refuse", 3105, 16, function(k)
		local run = ct.runs.get(c.cid)
		c.state = run.state
		force(c.v)
		fx.wait(ctx, k + 1, 600, "UE giving it back", function()
			return restored[c.ex]
		end, function()
			local now = ct.runs.get(c.cid)
			ctx.expect(restored[c.ex] == "too_big", "UE gave it back: " .. tostring(restored[c.ex]))
			ctx.expect(c.v.valid and ct.registry.ctron(c.cid).entity == c.v, "still the same entity")
			-- given back where UE captured it, a few tiles past side a's line (2.3 since the raid oracle's unit stopped
			-- colliding, UE's oracle revert 2026-10-20; side b is 1000 tiles away)
			ctx.expect(c.v.position.y > fx.A - 5, "on side a: y = " .. c.v.position.y)
			ctx.expect(now and now.in_transit == nil, "not in transit")
			ctx.expect(now.state == c.state, "the state is what it was: " .. tostring(now.state))
			ctx.expect(ct.registry.ctron(c.cid).in_transit == nil, "the record is not in transit")
		end)
	end)
end)

t.case("G10 an idle ctron crosses with its cid and no run", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "idle")
	end)
	ctx.at(14, function()
		start(c)
	end)
	ctx.at(16, function()
		force(c.v)
	end)
	crossed(ctx, c, 18, function(_, e)
		ctx.expect(storage.ctron_pluginv2.by_unit[e.unit_number] == c.cid, "same cid")
		local rec = ct.registry.ctron(c.cid)
		ctx.expect(rec.state ~= "busy" and rec.jid == nil, "not busy, no job: " .. tostring(rec.state))
		-- The fixture's reactor has no fuel, so the new entity needs its charge before it counts as fit.
		ct.registry.set_state(c.cid, "idle")
		ctx.expect(ct.registry.ctron(c.cid).state == "idle", "idle: " .. tostring(ct.registry.ctron(c.cid).state))
		ctx.expect(ct.runs.get(c.cid) == nil, "no run")
	end)
end)

local UNFIT = { no_roboports = true, no_power = true, bad_roboports = true, robots_out = true } -- registry.fit's

-- It also checks that registering the arrival raises none of the idle fit test's codes while that test fails, as it
-- does live on the creation tick (owner, 2026-10-21: "'missing roboports' shows when a constructron crosses an edge
-- whilst on a job"). A case of its own changed the shared save enough to fail G12's fight and add a minute to the run.
t.case("G10 the run resumes its legs after arrival; the arrival raises no unfit status", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "resume")
	end)
	run_to_work(ctx, c, "g10-resume", 3105, 16, function(k)
		c.jid = ct.runs.get(c.cid).jid
		local codes, on_status = {}, ct.gui.on_status
		ct.gui.on_status = function(entity, code, arg)
			if UNFIT[code] then -- the run's own statuses after the re-pick are its business
				codes[#codes + 1] = code
			end
			return on_status(entity, code, arg)
		end
		unfit_on = c.surface.name
		force(c.v)
		crossed(ctx, c, k + 1, function(k2)
			unfit_on = nil
			ct.gui.on_status = on_status
			ctx.expect(#codes == 0, "no unfit status at arrival: " .. table.concat(codes, ","))
			fx.wait(ctx, k2 + 1, 2400, "the run at_task", function()
				local rec = ct.registry.ctron(c.cid)
				charge(rec.entity)
				local run = ct.runs.get(c.cid)
				return run and run.state == "at_task"
			end, function()
				ctx.expect(#events_of(c.jid, "lost") == 0, "no lost event")
			end)
		end)
	end, 1960)
end)
