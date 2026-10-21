local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")

local SP = "SP-13"
local EV = defines.events.on_script_path_request_finished

-- SP-13 (03 S1): with CC and b1, is constructron_pathing_layer off ue-barrier, and can a path near a live side reach
-- past local -2? Would the leaves-tile check (R-71) reject it?
t.case("SP-13 barrier path: pathing layer on ue-barrier; reach of a path near a live side", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-13.txt")
	local asked = {} -- request id -> goal
	local seen = 0

	ctx.at(2, function()
		local barrier = prototypes.entity["ue-barrier"]
		ctx.expect(barrier ~= nil, "ue-barrier exists")
		fx.json(SP, "ue-barrier layers", barrier.collision_mask.layers)
		fx.note(SP, "constructron_pathing_layer on ue-barrier: ", tostring(barrier.collision_mask.layers["constructron_pathing_layer"] == true))
		fx.note(SP, "ue_world_barrier exists: ", tostring(prototypes.entity["ue_world_barrier"] ~= nil))
		local prev = script.get_event_handler(EV)
		script.on_event(EV, function(e)
			local goal = asked[e.id]
			if goal then
				local path = e.path
				local min_y
				for _, wp in ipairs(path or {}) do
					local ly = wp.position.y - 3000
					min_y = (min_y == nil or ly < min_y) and ly or min_y
				end
				fx.json(SP, "result " .. goal.label, { goal = goal.pos, found = path ~= nil, try_again_later = e.try_again_later or false,
					n = path and #path or 0, min_local_y = min_y, would_reject = min_y ~= nil and min_y < -2 })
				seen = seen + 1
			end
			if prev then
				prev(e)
			end
		end)
	end)

	ctx.at(3, function()
		local surface = fx.surface("sp13-barrier")
		fx.pair(surface, "sp13", 0)
		ctx.at(63, function()
			local barriers = surface.count_entities_filtered({ name = "ue-barrier" })
			fx.note(SP, "ue-barrier entities on the surface after 60 ticks: ", barriers)
			ctx.expect(barriers > 0, "UE built barriers")
			local function ask(label, goal)
				local id = surface.request_path({
					bounding_box = { { -5, -5 }, { 5, 5 } },
					collision_mask = prototypes.entity["constructron_pathing_proxy_1"].collision_mask,
					start = { 10, 3010 },
					goal = goal,
					force = "player",
					radius = 2,
					path_resolution_modifier = -2,
					max_gap_size = 12,
					pathfind_flags = { cache = false },
				})
				asked[id] = { label = label, pos = goal }
			end
			ask("past the line (local y -10)", { 54, 2990 })
			ask("along the line (local y +10)", { 54, 3010 })
			fx.wait(ctx, 64, 1800, "both path results", function()
				return seen >= 2
			end)
		end)
	end)
end)
