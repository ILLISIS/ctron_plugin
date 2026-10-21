local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local layouts = require("modules/v2_test/layouts")
local ue = require("modules/universal_edges")

local SP = "SP-15"
local REGION_B = { { 0, 1880 }, { 64, 2000 } }
local REGION_A = { { 0, 3000 }, { 64, 3120 } }

-- SP-15 (03 S7): does a walking ctron step from A (local +6) to S (local -3) and get captured with barriers from -6,
-- and does the 12-tick delay after arrival prevent a second, unplanned capture? (The rocket-powered type is Space
-- Exploration's, not in this mod set: not tested.)
local function ctron_in(surface, area)
	return surface.find_entities_filtered({ name = "constructron", area = area })[1]
end

--- One case at offset `base`: pair, ctron at A one step later, watch + order to S 30 ticks after that. `again` is
--- nil (record the capture only), "at once" (order the arrival back at the arrival tick) or a delay in ticks.
local function leg(name, tag, base, s, again)
	t.case(name, function(ctx)
		ctx.expect_file("ctronv2-spikes/SP-15.txt")
		ctx.at(base, function()
			local surface = fx.surface("sp15-" .. tag)
			fx.pair(surface, "sp15" .. tag, 0)
			ctx.at(base + 1, function()
				local v = fx.ctron(surface, 32, 3006)
				ctx.expect(v ~= nil, "ctron created at A")
				ctx.at(base + 31, function()
					ue.vehicles.watch(v)
					v.autopilot_destination = s
					local miny = v.position.y
					layouts.wait(t, ctx, base + 32, base + 31 + 1800, function()
						if v.valid then
							miny = math.min(miny, v.position.y)
							return false
						end
						return ctron_in(surface, REGION_B) ~= nil
					end, function(k)
						if not k then
							fx.json(SP, tag .. " capture", { S = s, captured = false, min_y = miny, min_local_y = miny - 3000 })
							return
						end
						local a = ctron_in(surface, REGION_B)
						local T = k
						fx.json(SP, tag .. " capture", { S = s, captured = true, offset = T - (base + 31), min_y = miny,
							min_local_y = miny - 3000, arrival = { x = a.position.x, y = a.position.y,
								destinations = #a.autopilot_destinations } })
						if again == nil then
							return
						end
						local un = a.unit_number
						local timeline = { ["T"] = storage.universal_edges.watch[un] ~= nil }
						local function order()
							if a.valid then
								a.autopilot_destination = nil
								a.autopilot_destination = { 32, 2003 }
							end
						end
						if again == "at once" then
							order()
						end
						layouts.wait(t, ctx, T + 1, T + 300, function()
							local d = game.tick - t.first_tick - T
							if again == d then
								order()
							end
							if d == 5 or d == 10 or d == 12 or d == 20 then
								timeline["T+" .. d] = storage.universal_edges.watch[un] ~= nil
							end
							return not a.valid and ctron_in(surface, REGION_A) ~= nil
						end, function(k2)
							fx.json(SP, tag .. " watch timeline (arrival unit in storage.universal_edges.watch)", timeline)
							fx.json(SP, tag .. " second capture", { order = tostring(again), captured_back = k2 ~= nil,
								after_ticks = k2 and k2 - T or nil })
						end)
					end)
				end)
			end)
		end)
	end)
end

leg("SP-15 capture: S at local -3", "capture", 3, { 32, 2997 })
leg("SP-15 deeper S: S at local -4.5", "deeper", 2500, { 32, 2995.5 })
leg("SP-15 at once: the next leg ordered on the arrival tick", "once", 5000, { 32, 2997 }, "at once")
leg("SP-15 after 12: the next leg ordered 12 ticks after arrival", "after12", 7500, { 32, 2997 }, 12)
