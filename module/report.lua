-- What this tile tells the controller (spec §4.3, §9.1, §9.2; R-19, R-125): dirty sets flushed as ct.delta parts every
-- 60 ticks (cells before jobs), ct.snapshot in numbered parts on
-- request, and job events at once.
local ue = require("modules/universal_edges")
local bridge = require("modules/ctron_pluginv2/bridge")
local ct = require("modules/ctron_pluginv2/ct")
local items = require("modules/ctron_pluginv2/items_core")
local parts = require("modules/ctron_pluginv2/parts_core")

local report = { events = {} }

--- The delta order: cells before jobs (R-19).
local KINDS = { "ctron", "station", "cell", "need", "job" }
local LISTS = { ctron = "ctrons", station = "stations", cell = "cells", need = "needs", job = "jobs" }
local BUDGET = parts.BUDGET
-- Bytes of entries built per flush; the rest stays dirty for the next 60-tick flush (UPS: a burst must not be one tick).
local MAX_BYTES = 5000

local BUILD = {
	ctron = function(id) return ct.registry.record("ctron", id) end,
	station = function(id) return ct.registry.record("station", id) end,
	cell = function(id) return ct.discovery.record(id) end,
	need = function(id) return ct.logistics.need(id) end,
	job = function(id) return ct.runs.record(id) end,
}
local ALL = {
	ctron = function() return ct.registry.records("ctron") end,
	station = function() return ct.registry.records("station") end,
	cell = function() return ct.discovery.records() end,
	need = function() return ct.logistics.needs() end,
	job = function() return ct.runs.records() end,
}

local function S()
	return storage.ctron_pluginv2
end

local function start()
	local s = S()
	s.dirty = s.dirty or {}
	for _, name in ipairs({ "ctron", "station", "cell", "need", "job" }) do
		s.dirty[name] = s.dirty[name] or {}
	end
	s.snap = s.snap or 0
end

report.on_init = start
report.on_server_startup = start

--- Entries are { list, op, value } in deltas (op "up" with a record, "rm" with an id) and { list, value } in snapshots.
local function encode(entry)
	local json = entry.json
	if not json then
		local value = entry[#entry]
		json = type(value) == "table" and helpers.table_to_json(value) or '"' .. value .. '"'
		entry.json = json
	end
	return json
end

--- kind is "ctron", "station", "cell", "need" or "job".
function report.mark(kind, id)
	local s = S()
	if not (s and s.dirty) then
		return
	end
	s.dirty[kind][id] = true
end

local function flush()
	local s = S()
	if not (s and s.dirty) then
		return 0
	end
	local d = s.dirty
	local ctrons_changed = next(d.ctron) ~= nil
	local entries = {}
	local bytes = 0
	for _, kind in ipairs(KINDS) do
		for id in pairs(d[kind]) do
			if bytes >= MAX_BYTES then
				break
			end
			local r = BUILD[kind](id)
			local e = r and { LISTS[kind], "up", r } or { LISTS[kind], "rm", id }
			bytes = bytes + #encode(e) + 1
			entries[#entries + 1] = e
			d[kind][id] = nil
		end
	end
	if #entries == 0 then
		return 1
	end
	for _, part in ipairs(parts.pack(entries, encode, BUDGET)) do
		local payload = {}
		for _, e in ipairs(part) do
			local l = payload[e[1]]
			if not l then
				l = { up = {}, rm = {} }
				payload[e[1]] = l
			end
			local to = l[e[2]]
			to[#to + 1] = e[3]
		end
		bridge.send("ct.delta", payload)
	end
	if ctrons_changed then
		ct.signals.flush()
	end
	return #entries
end

ue.runtime.scheduler.periodic({ name = "ctron.flush", interval = 60, fn = flush })

function report.flush()
	return flush()
end

--- A full replace in numbered parts, then the cached portal reports (spec §9.2; R-85, R-125, R-136).
function report.snapshot()
	local s = S()
	if not (s and s.dirty) then
		return
	end
	s.snap = s.snap + 1
	local entries = { { "defaults", ct.settings.defaults() } }
	for _, kind in ipairs(KINDS) do
		for _, r in ipairs(ALL[kind]()) do
			entries[#entries + 1] = { LISTS[kind], r }
		end
	end
	local packed = parts.pack(entries, encode, BUDGET)
	for i, part in ipairs(packed) do
		local payload = { seq = s.snap, part = i, parts = #packed, ctrons = {}, stations = {}, cells = {}, needs = {}, jobs = {} }
		for _, e in ipairs(part) do
			if e[1] == "defaults" then
				payload.defaults = e[2]
			else
				local l = payload[e[1]]
				l[#l + 1] = e[2]
			end
		end
		bridge.send("ct.snapshot", payload)
	end
	for _, rep in pairs(ct.portals.reports()) do
		bridge.send("ct.portals", rep)
	end
	if next(s.dirty.ctron) then
		ct.signals.flush()
	end
	for _, name in ipairs({ "ctron", "station", "cell", "need", "job" }) do
		s.dirty[name] = {}
	end
end

local function as_tuples(map)
	if type(map) == "table" and map[1] == nil and next(map) ~= nil then
		return items.tuples(map)
	end
	return map
end

--- A job event goes at once, not with the deltas (§9.2). Item maps become tuples; missing is cut to 10 (§4.3).
function report.event(jid, ev, fields)
	local payload = { jid = jid, ev = ev, tick = game.tick }
	for k, v in pairs(fields or {}) do
		payload[k] = v
	end
	payload.items = as_tuples(payload.items)
	local missing = as_tuples(payload.missing)
	if type(missing) == "table" and #missing > 10 then
		local cut = {}
		for i = 1, 10 do
			cut[i] = missing[i]
		end
		missing = cut
	end
	payload.missing = missing
	bridge.send("ct.job.event", payload)
end

bridge.on("ct.snapshot.request", function()
	report.snapshot()
end)

return report
