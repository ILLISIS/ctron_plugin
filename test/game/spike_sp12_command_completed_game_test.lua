local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ue = require("modules/universal_edges")

local SP = "SP-12"
local EV = defines.events.on_spider_command_completed

-- SP-12 (03 S2, 04 S2): does on_spider_command_completed fire per destination or once at the end, for script-set
-- autopilots, and after UE's restore_body?
t.case("SP-12 command completed: per destination or at the end; after a crossing's restore", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-12.txt")
	local fired = {}

	local function since(n, unit)
		local out = {}
		for i = n + 1, #fired do
			if unit == nil or fired[i].unit == unit then
				out[#out + 1] = fired[i]
			end
		end
		return out
	end
	local function near(v, x, y, d)
		return v.valid and (v.position.x - x) ^ 2 + (v.position.y - y) ^ 2 <= d * d
	end

	ctx.at(2, function()
		local prev = script.get_event_handler(EV)
		script.on_event(EV, function(e)
			-- Other cases in this game send invalid vehicles through the handler (preflight F16).
			if e.vehicle and e.vehicle.valid then
				fired[#fired + 1] = { t = e.tick, unit = e.vehicle.unit_number, left = #e.vehicle.autopilot_destinations }
			end
			if prev then
				prev(e)
			end
		end)
	end)

	-- Phase 1: script-set destinations on open ground.
	ctx.at(3, function()
		local surface = fx.surface("sp12-open")
		fx.ground(surface, -10, -10, 70, 10)
		local v = fx.ctron(surface, 0, 0)
		ctx.expect(v ~= nil, "ctron created")
		fx.note(SP, "p1 ctron unit ", v.unit_number)
		v.autopilot_destination = { 20, 0 }
		fx.wait(ctx, 4, 1200, "ctron reaches (20, 0)", function()
			return near(v, 20, 0, 2)
		end, function(k)
			fx.json(SP, "p1 first destination, firings so far", since(0))
			local n = #fired
			ctx.at(k + 1, function()
				v.add_autopilot_destination({ 30, 0 })
				v.add_autopilot_destination({ 40, 0 })
				v.add_autopilot_destination({ 50, 0 })
				fx.wait(ctx, k + 2, 1800, "ctron reaches (50, 0)", function()
					return near(v, 50, 0, 2)
				end, function(k2)
					fx.json(SP, "p1 three queued destinations (30, 40, 50), firings since", since(n))
					fx.note(SP, "p1 done at offset ", k2)
				end)
			end)
		end)
	end)

	-- Phase 2: a crossing through a looped edge, then the restore.
	ctx.at(3, function()
		local surface = fx.surface("sp12-cross")
		local ex = fx.pair(surface, "sp12", 0)
		ctx.at(4, function()
			local w = fx.ctron(surface, 32, 3006)
			ctx.expect(w ~= nil, "crossing ctron created")
			local w_unit = w.unit_number
			fx.note(SP, "p2 ctron unit before the crossing ", w_unit)
			ctx.at(34, function()
				ue.vehicles.watch(w)
				w.autopilot_destination = { 32, 2997 }
				fx.wait(ctx, 35, 1800, "ctron crosses to region B", function()
					if w.valid then
						return false
					end
					return #surface.find_entities_filtered({ name = "constructron", area = { { 0, 1880 }, { 64, 2000 } } }) > 0
				end, function(k)
					local a = surface.find_entities_filtered({ name = "constructron", area = { { 0, 1880 }, { 64, 2000 } } })[1]
					local n = #fired
					fx.json(SP, "p2 arrival (edge " .. ex .. ")", { unit = a.unit_number, x = a.position.x, y = a.position.y,
						destinations = #a.autopilot_destinations, offset = k })
					ctx.at(k + 600, function()
						fx.json(SP, "p2 firings for the arrival's unit after 600 more ticks", since(n, a.unit_number))
						fx.json(SP, "p2 all firings since arrival", since(n))
						fx.json(SP, "p2 firings for the pre-crossing unit " .. w_unit, since(0, w_unit))
					end)
				end)
			end)
		end)
	end)
end)
