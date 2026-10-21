-- UE vehicle-crossing hooks (spec §5.9): a ctron's run and travel state ride the capture body. The destination
-- reports the ctron and its job from materialized on; the source drops its copy when UE destroys the entity at
-- commit (runs.lua's on_object_destroyed sees in_transit and stays silent).
local ue = require("modules/universal_edges")
local ct = require("modules/ctron_pluginv2/ct")
local run_core = require("modules/ctron_pluginv2/run_core")

local crossing = { events = {} }

local function is_ctron(v)
	return v.valid and storage.ctron_pluginv2.names.ctrons[v.name]
end

local function copy(t)
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in pairs(t) do
		out[k] = copy(v)
	end
	return out
end

function crossing.capture(ep, v)
	if not is_ctron(v) then
		return nil
	end
	local cid = storage.ctron_pluginv2.by_unit[v.unit_number]
	if not cid then
		return nil
	end
	local data = { cid = cid }
	local run = ct.runs.get(cid)
	if run then
		data.run = copy(run)
		data.run.in_transit = nil
		data.tick = game.tick
		data.travel = ct.travel.export(v)
	end
	-- The flags go last: a raise above leaves the source untouched instead of a run dropped at commit with no body.
	if run then
		run.in_transit = true
		ct.runs.trace("ctronv2.cross", "captured", "info", run.jid, cid, { edge = ep.edge })
	end
	return data
end

function crossing.materialized(ep, v, data)
	if not is_ctron(v) then
		return
	end
	-- UE creates the entity without a built event (vehicle.lua:373), so registration happens here; no data (driven
	-- across by a player, say) means a fresh cid (R-121).
	local run = data and data.run
	local cid = ct.registry.register(v, data and data.cid, run ~= nil)
	if not run then
		return
	end
	run.cid, run.unit = cid, v.unit_number
	run_core.rebase(run, game.tick - data.tick) -- ticks are per save
	ct.runs.put(run)
	ct.report.mark("job", run.jid) -- early: a raise below still leaves the destination run reported
	-- register reset the logistics flag and painted the ctron idle: put back what the run depends on (R-121, §5.5).
	v.enable_logistics_while_moving = run.logi == true
	ct.registry.paint(v, run.role == "minion" and "minion" or run.kind)
	ct.registry.set_state(cid, "busy", nil, run.jid)
	if data.travel then
		ct.travel.import(v, data.travel, ep.edge) -- before the re-pick (P3)
	end
	if (run.state == "to_work" or run.state == "fight") and run.work_inst == ct.registry.here() then
		ct.runs.step(run, { type = "repick" }) -- §5.3: re-pick the nearest task, once travel has settled
	end
	ct.runs.trace("ctronv2.cross", "arrived", "info", run.jid, cid, { edge = ep.edge })
end

function crossing.restored(ep, v, why)
	if not is_ctron(v) then
		return
	end
	local cid = storage.ctron_pluginv2.by_unit[v.unit_number]
	local run = cid and ct.runs.get(cid)
	if run then
		run.in_transit = nil
	end
	ct.travel.restored(v, why) -- P3 walks back to A first (R-133), then re-routes
	ct.runs.trace("ctronv2.cross", "restored", why == "close" and "warn" or "error", run and run.jid, cid,
		{ edge = ep.edge, why = why })
end

ue.transfers.extend({
	name = "ctron_pluginv2", types = { vehicle = true },
	capture = crossing.capture, materialized = crossing.materialized, restored = crossing.restored,
})

return crossing
