-- ctron_pluginv2's save module (spec §3, §5.1): the CC and UE gates, storage, and one lib composed from the feature
-- modules. v2 registers no on_tick of its own: recurring work runs on UE's scheduler (R-4).
if not script.active_mods["Constructron-Continued"] then
	log("[ctron_pluginv2] disabled: Constructron-Continued is not enabled")
	return {} -- an empty lib (R-7): the module loads and does nothing; event_handler.add_lib needs a table
end
local has_ue, ue = pcall(require, "modules/universal_edges")
if not has_ue or ue.api_version ~= 1 then
	log("[ctron_pluginv2] disabled: needs universal_edges Lua API version 1")
	return {}
end

local clusterio_api = require("modules/clusterio/api")
local ct = require("modules/ctron_pluginv2/ct")

-- Every feature module by its seam name (§5.1). Each returns { events, on_init?, on_load?, on_server_startup? } and
-- registers its own scheduler tasks and bridge handlers (through bridge.on) while it loads (R-106). A module that needs Clusterio's start
-- event uses the on_server_startup field, never events: the lib's handler for that event is set below.
ct.settings = require("modules/ctron_pluginv2/settings")
ct.registry = require("modules/ctron_pluginv2/registry")
ct.discovery = require("modules/ctron_pluginv2/discovery")
ct.logistics = require("modules/ctron_pluginv2/logistics")
ct.signals = require("modules/ctron_pluginv2/signals")
ct.tools = require("modules/ctron_pluginv2/tools")
ct.runs = require("modules/ctron_pluginv2/runs")
ct.combat = require("modules/ctron_pluginv2/combat")
ct.crossing = require("modules/ctron_pluginv2/crossing")
ct.travel = require("modules/ctron_pluginv2/travel")
ct.portals = require("modules/ctron_pluginv2/portals")
ct.report = require("modules/ctron_pluginv2/report")
ct.gui = require("modules/ctron_pluginv2/gui/gui")
--- The fixed order (R-106): for each event, one handler calls the modules' handlers in this order.
local ORDER = {
	ct.settings, ct.registry, ct.discovery, ct.logistics, ct.signals, ct.tools, ct.runs, ct.combat, ct.crossing,
	ct.travel, ct.portals, ct.report, ct.gui,
}

-- CC's repair filters (CC script/entity_processor.lua:194-202) plus "not a unit" (R-23). event_handler registers every
-- event in on_init and on_load before the libs' own (core/lualib/event_handler.lua:94-112), and a filter set after
-- registration is retained (API LuaBootstrap.set_event_filter), so it is set in both. SP-2 checks it.
local DAMAGE_FILTER = {
	{ filter = "name", name = "captive-biter-spawner", invert = true, mode = "and" },
	{ filter = "final-health", comparison = ">", value = 0, mode = "and" },
	{ filter = "robot-with-logistics-interface", invert = true, mode = "and" },
	{ filter = "vehicle", invert = true, mode = "and" },
	{ filter = "rolling-stock", invert = true, mode = "and" },
	{ filter = "type", type = "character", invert = true, mode = "and" },
	{ filter = "type", type = "fish", invert = true, mode = "and" },
	{ filter = "type", type = "unit", invert = true, mode = "and" },
}

local TABLES = {
	"ctrons", "by_unit", "by_reg", "stations", "cells", "runs", "slots", "dirty", "travel", "portals", "signals", "threat",
	"names", "schedulable",
}

--- storage.ctron_pluginv2 (§4.7), made at the first start; no migration code (brief).
local function init_storage()
	storage.ctron_pluginv2 = storage.ctron_pluginv2 or {}
	local s = storage.ctron_pluginv2
	for _, name in ipairs(TABLES) do
		s[name] = s[name] or {}
	end
	s.settings = s.settings or { defaults = {}, overrides = {}, effective = {} }
	s.ui = s.ui or { watches = {}, players = {} }
end

local lib = { events = {} }
for _, m in ipairs(ORDER) do
	for id, fn in pairs(m.events or {}) do
		local before = lib.events[id]
		lib.events[id] = before and function(event)
			before(event)
			fn(event)
		end or fn
	end
end

local function each(field, ...)
	for _, m in ipairs(ORDER) do
		if m[field] then
			m[field](...)
		end
	end
end

--- Only an event some module handles can take a filter.
local function filter_damage()
	if lib.events[defines.events.on_entity_damaged] then
		script.set_event_filter(defines.events.on_entity_damaged, DAMAGE_FILTER)
	end
end

function lib.on_init()
	init_storage()
	filter_damage()
	each("on_init")
end

function lib.on_load()
	filter_damage()
	each("on_load")
end

-- Clusterio's start event, in place of on_init for a patched save (host/modules/clusterio/api.lua:7-10).
lib.events[clusterio_api.events.on_server_startup] = function(event)
	init_storage()
	each("on_server_startup", event)
end

return lib
