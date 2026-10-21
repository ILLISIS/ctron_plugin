local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ct = require("modules/ctron_pluginv2/ct")
local bridge = require("modules/ctron_pluginv2/bridge")
-- require works only while loading; control.lua's lib is the table event_handler got.
local lib = require("modules/ctron_pluginv2/control")

-- A down type only this file registers (at load, as every module does), to check that bridge.on reaches UE's inbox.
local echoed = {}
bridge.on("test.g1.echo", function(payload)
	echoed[#echoed + 1] = payload.n
end)

-- Spec §5.1 and §3's cross-phase seams, by ct module: each is a function on its module.
local SEAMS = {
	settings = { "of", "global", "apply", "defaults" },
	registry = { "here", "ctron", "ctron_of", "station", "stations_on", "register", "set_state", "fit", "rename" },
	discovery = { "clear", "rescan_now", "cell", "has_cells", "set_schedulable" },
	logistics = { "write_load", "write_unload", "write_deliver", "clear", "held", "fulfilled", "trash_empty", "cover",
		"answer", "slots", "set_slots" },
	report = { "mark", "snapshot", "flush", "event" },
	runs = { "adopt", "cancel", "cancel_kind", "set_station", "drop", "detail", "get", "of_job", "records", "record",
		"on_arrived", "on_failed" },
	travel = { "go", "cancel", "status", "export", "import", "restored" },
	portals = { "reports", "dirty" },
	gui = { "on_status", "on_settings", "open_details" },
}
local MODULES = { "settings", "registry", "discovery", "logistics", "signals", "tools", "runs", "combat", "crossing",
	"travel", "portals", "report", "gui" }
-- control.lua's init_storage tables.
local TABLES = { "ctrons", "by_unit", "by_reg", "stations", "cells", "runs", "slots", "settings", "dirty", "travel",
	"portals", "signals", "ui", "threat", "names", "schedulable" }

t.case("G1 smoke: v2 loads with UE and CC 2.1.0 (b1 applied); every seam is in ct; storage has its tables",
	function(ctx)
		ctx.at(2, function()
			ctx.expect(script.active_mods["Constructron-Continued"] == "2.1.0", "CC 2.1.0 is loaded")
			local barrier = prototypes.entity["ue-barrier"]
			ctx.expect(barrier ~= nil and not barrier.collision_mask.layers["constructron_pathing_layer"],
				"b1: UE's barrier lacks CC's pathing layer")
			for _, name in ipairs({ "constructron_pathing_proxy_1", "constructron_pathing_proxy_8",
				"constructron_pathing_proxy_10" }) do
				ctx.expect(prototypes.entity[name] ~= nil, name .. " exists")
			end
			for _, name in ipairs(MODULES) do
				ctx.expect(type(ct[name]) == "table", "ct." .. name)
			end
			for module, fns in pairs(SEAMS) do
				for _, fn in ipairs(fns) do
					ctx.expect(type(ct[module] and ct[module][fn]) == "function", "ct." .. module .. "." .. fn)
				end
			end
			ctx.expect(type(bridge.send) == "function" and type(bridge.on) == "function", "bridge.send and bridge.on")
			ctx.expect(lib.events[defines.events.on_tick] == nil, "no on_tick of its own (R-4)")
			local s = storage.ctron_pluginv2
			ctx.expect(s ~= nil, "storage.ctron_pluginv2 exists")
			for _, name in ipairs(TABLES) do
				ctx.expect(s ~= nil and type(s[name]) == "table", "storage table " .. name)
			end
			local state = helpers.json_to_table(ctronv2_rt.state())
			ctx.expect(state ~= nil and state.ctrons == 0 and state.runs == 0, "ctronv2_rt.state() counts nothing yet")
			-- A registered once task has state after the scheduler's first tick.
			ctx.expect(storage.universal_edges.scheduler.tasks["ctron.leg"] ~= nil, "UE once task ctron.leg is registered")
		end)
	end)

t.case("G1 inbox (R-159): bridge.on gets its message through UE's inbox, once per id; ctronv2_rt.call reaches a stub",
	function(ctx)
		ctx.at(3, function()
			local function batch(id, msg_type, n)
				return helpers.table_to_json({ { id = id, type = msg_type, payload = { n = n } } })
			end
			fx.send("test.g1.echo", { n = 1 })
			ue_rt.inbox("ctron_pluginv2", batch("9e510000.1", "test.g1.echo", 2))
			ue_rt.inbox("ctron_pluginv2", batch("9e510000.1", "test.g1.echo", 3)) -- a repeated id
			ue_rt.inbox("ctron_pluginv2", batch("9e510000.2", "test.g1.nobody", 5))
			ctx.expect(table.concat(echoed, ",") == "1,2", "delivered: " .. table.concat(echoed, ","))
			local g = ctronv2_rt.call("settings", "global")
			ctx.expect(g.job_start_delay == 300 and g.debug == false, "ctronv2_rt.call reaches the settings stub")
		end)
	end)

t.case("G1 handlers (Review Focus 4): v2's handlers survive an entity destroyed earlier in the event", function(ctx)
	ctx.at(5, function()
		local surface = fx.surface("v2-dead")
		fx.ground(surface, -10, -10, 10, 10)
		local v = fx.ctron(surface, 0, 0)
		local wall = surface.create_entity({ name = "stone-wall", position = { 5, 5 }, force = "player" })
		v.destroy()
		wall.destroy()
		for name, event in pairs({ on_spider_command_completed = { vehicle = v },
			on_entity_damaged = { entity = wall, final_health = 5 } }) do
			local handler = lib.events[defines.events[name]]
			ctx.expect(handler ~= nil, name .. " is handled")
			local ok, err = pcall(handler, event)
			ctx.expect(ok, name .. " survives a destroyed entity: " .. tostring(err))
		end
	end)
end)

t.case("G1 power: a fixture station's network has power, and a fixture ctron's roboports charge from its reactor",
	function(ctx)
		local v, station
		ctx.at(10, function()
			local surface = fx.surface("v2-power")
			fx.ground(surface, -30, -30, 30, 30)
			v = fx.ctron(surface, 0, 0)
			station = fx.station(surface, 15, 15)
		end)
		ctx.at(400, function()
			ctx.expect(station.energy > 0 and station.is_connected_to_electric_network ~= false, "the station has power")
			local charged = 0
			for _, e in pairs(v.grid.equipment) do
				if e.type == "roboport-equipment" and e.energy > 800e3 then
					charged = charged + 1
				end
			end
			ctx.expect(charged == 2, "both roboports hold more than their 800 kJ start charge: " .. charged)
		end)
	end)

t.case("G1 power, long: a fixture station still has power and a logistic network after 6000 ticks", function(ctx)
	local station, source
	ctx.at(10, function()
		local surface = fx.surface("v2-power-long")
		fx.ground(surface, -30, -30, 30, 30)
		station = fx.station(surface, 15, 15)
		source = surface.find_entities_filtered({ name = "electric-energy-interface" })[1]
	end)
	-- The cause of the ~5000-tick loss: the interface sat on the edge of the substation's supply area, so it fed
	-- nothing, and the station ran on its own 100 MJ buffer until that was spent.
	ctx.at(12, function()
		ctx.expect(station.electric_network_id ~= nil and station.electric_network_id == source.electric_network_id,
			"the station and the energy interface are on one electric network")
	end)
	ctx.at(6000, function()
		ctx.expect(station.valid and station.energy > 0, "the station has power")
		ctx.expect(station.valid and station.logistic_network ~= nil, "the station has a logistic network")
	end)
end)
