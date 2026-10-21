local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ue = require("modules/universal_edges")
local bridge = require("modules/ctron_pluginv2/bridge")

-- Load time: UE refuses registration at run time. The source is nil until the case runs, so other runs pay nothing.
ue.runtime.scheduler.iterate({
	name = "spike.sp11", per_tick = 2, interval = 60,
	source = function() return storage.sp11 and storage.sp11.items end,
	fn = function(key, _, tick)
		local v = storage.sp11.visits
		v[key] = v[key] or {}
		v[key][#v[key] + 1] = tick
	end,
})

bridge.on("spike.sp11.del", function(p)
	for _, k in ipairs(p.keys) do
		storage.sp11.items[k] = nil
	end
end)

t.case("SP-11 iterate with entries deleted mid-walk", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-11.txt")
	local deleted, del_tick = {}, nil
	ctx.at(2, function()
		storage.sp11 = { items = {}, visits = {} }
		for i = 1, 12 do
			storage.sp11.items[string.format("k%02d", i)] = true
		end
	end)
	-- Two intervals pass, then wait for a walk under way.
	fx.wait(ctx, 130, 200, "a walk under way", function()
		local ts = storage.universal_edges.scheduler.tasks["spike.sp11"]
		return ts ~= nil and ts.cursor ~= nil
	end, function(k)
		local cursor = storage.universal_edges.scheduler.tasks["spike.sp11"].cursor
		local order = {}
		for key in pairs(storage.sp11.items) do
			order[#order + 1] = key
		end
		-- pairs order is what next walks; split it at the cursor.
		local visited, pending, seen = {}, {}, false
		for _, key in ipairs(order) do
			if key == cursor then
				seen = true
			elseif seen then
				pending[#pending + 1] = key
			else
				visited[#visited + 1] = key
			end
		end
		fx.json("SP-11", "walk", { cursor = cursor, visited = visited, pending = #pending, order = order })
		ctx.expect(#visited >= 1 and #pending >= 1, "the cursor is mid-walk")
		deleted = { cursor, visited[1], pending[#pending] }
		del_tick = game.tick
		fx.send("spike.sp11.del", { keys = deleted })
		fx.json("SP-11", "deleted", { tick = del_tick, keys = deleted })
		ctx.at(k + 300, function()
			local gone = {}
			for _, d in ipairs(deleted) do
				gone[d] = true
			end
			local report = { survivors = {}, deleted_visited = {} }
			local worst = 0
			for i = 1, 12 do
				local key = string.format("k%02d", i)
				local after, last_before = {}, nil
				for _, tick in ipairs(storage.sp11.visits[key] or {}) do
					if tick > del_tick then
						after[#after + 1] = tick
					else
						last_before = tick
					end
				end
				if gone[key] then
					report.deleted_visited[key] = after
				else
					local gap, prev = 0, last_before
					for _, tick in ipairs(after) do
						if prev and tick - prev > gap then
							gap = tick - prev
						end
						prev = tick
					end
					local dupes = 0
					for j = 2, #after do
						if after[j] - after[j - 1] < 30 then
							dupes = dupes + 1
						end
					end
					worst = math.max(worst, gap)
					report.survivors[key] = { visits = after, max_gap = gap, close_pairs = dupes }
				end
			end
			report.worst_gap = worst
			fx.json("SP-11", "report", report)
		end)
	end)
end)
