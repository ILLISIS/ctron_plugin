local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")

local SP = "SP-14"
local EV = defines.events.on_script_path_request_finished
local GAPS = { 0, 6, 9, 12, 15 }
-- The brief's widths 6-15 were all followed at every G (water blocks the mask, max_gap_size is not in tiles), so the
-- wider ones find where it stops. W = 0 is the control: one island.
local WIDTHS = { 0, 2, 4, 6, 9, 12, 15, 24, 36, 48, 72 }

-- SP-14 (03 S3, S4, S6): the widest water gap a ctron follows, a 6x6 box over a 7-wide land bridge, cache = false
-- against true.
local results = {} -- request id -> { tick, path, try_again_later }
local chained = false

local function chain()
	if chained then
		return
	end
	chained = true
	local prev = script.get_event_handler(EV)
	script.on_event(EV, function(e)
		results[e.id] = { tick = e.tick, path = e.path, try_again_later = e.try_again_later }
		if prev then
			prev(e)
		end
	end)
end

--- CC's params (spec 7.2) with the case's box, gap, cache. Returns the request id and the tick it was asked.
local function request(surface, start, goal, box, gap, cache)
	local id = surface.request_path({
		bounding_box = box or { { -5, -5 }, { 5, 5 } },
		collision_mask = prototypes.entity["constructron_pathing_proxy_1"].collision_mask,
		start = start,
		goal = goal,
		force = "player",
		radius = 2,
		path_resolution_modifier = -2,
		max_gap_size = gap,
		pathfind_flags = { cache = cache },
	})
	return id, game.tick
end

local function all_done(ids)
	for _, id in ipairs(ids) do
		if not results[id] then
			return false
		end
	end
	return true
end

--- Pave (x1, y1)-(x2, y2), then turn every tile for which land(x, y) is false into water: no dry detour around a gap.
local function carve(surface, x1, y1, x2, y2, land)
	fx.ground(surface, x1, y1, x2, y2)
	local tiles = {}
	for x = x1, x2 - 1 do
		for y = y1, y2 - 1 do
			if not land(x, y) then
				tiles[#tiles + 1] = { name = "water", position = { x, y } }
			end
		end
	end
	surface.set_tiles(tiles)
end

local function last(path)
	return path[#path].position
end

--- Walk a ctron along path from its start; after `ticks` call done({ reached, x, y, stuck_since }). Stuck: the
--- position moved less than 0.1 over 90 ticks while the goal is more than 3 away.
local function walk(ctx, surface, path, goal, ticks, k, done)
	local v = fx.ctron(surface, path[1].position.x, path[1].position.y)
	ctx.expect(v ~= nil, "walker created")
	v.autopilot_destination = path[1].position
	for i = 2, #path do
		v.add_autopilot_destination(path[i].position)
	end
	local trail, stuck_since = {}, nil
	local function sample(k2)
		local p = v.position
		trail[#trail + 1] = { k2, p.x, p.y }
		local old = trail[#trail - 3]
		local d = math.sqrt((p.x - goal[1]) ^ 2 + (p.y - goal[2]) ^ 2)
		if old and not stuck_since and d > 3 and (p.x - old[2]) ^ 2 + (p.y - old[3]) ^ 2 < 0.01 then
			stuck_since = old[1]
		end
		if k2 - k >= ticks then
			done({ reached = d < 3, x = p.x, y = p.y, stuck_since = stuck_since })
		else
			ctx.at(k2 + 30, function() sample(k2 + 30) end)
		end
	end
	ctx.at(k + 30, function() sample(k + 30) end)
end

t.case("SP-14 gaps: the widest water gap a ctron follows and walks", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-14.txt")
	ctx.at(2, chain)
	ctx.at(3, function()
		local surface = fx.surface("sp14-gaps")
		local asked = {}
		local ids = {}
		for i, w in ipairs(WIDTHS) do
			local x0 = 200 * i
			-- Two islands, x0..x0+40 and x0+40+w..x0+90+w, y -20..20, in water.
			carve(surface, x0 - 20, -30, x0 + 40 + w + 70, 30, function(x, y)
				return y >= -20 and y < 20 and (x >= x0 and x < x0 + 40 or x >= x0 + 40 + w and x < x0 + 90 + w)
			end)
		end
		ctx.at(5, function()
			fx.json(SP, "setup: pathing proxy mask", prototypes.entity["constructron_pathing_proxy_1"].collision_mask)
			local wt = surface.get_tile(200 + 40, 0)
			fx.note(SP, "setup: tile at the first water cell is ", wt.name, ", layers ", helpers.table_to_json(wt.prototype.collision_mask.layers))
			for i, w in ipairs(WIDTHS) do
				local x0 = 200 * i
				for _, g in ipairs(GAPS) do
					local id = request(surface, { x0 + 10, 0 }, { x0 + 40 + w + 40, 0 }, nil, g, false)
					asked[#asked + 1] = { id = id, w = w, g = g, x0 = x0 }
					ids[#ids + 1] = id
				end
			end
			fx.wait(ctx, 6, 1800, "50 gap path results", function()
				return all_done(ids)
			end, function(k)
				local at12 = {}
				for _, a in ipairs(asked) do
					local r = results[a.id]
					local found = r.path ~= nil
					fx.json(SP, "gap W=" .. a.w .. " G=" .. a.g, { W = a.w, G = a.g, found = found,
						try_again_later = r.try_again_later or false, n = found and #r.path or 0,
						crosses = found and last(r.path).x > a.x0 + 40 + a.w or false })
					if a.g == 12 and found then
						at12[#at12 + 1] = a
					end
				end
				ctx.at(k + 1, function()
					local walking = #at12
					if walking == 0 then
						fx.note(SP, "gap walk: no G=12 path found for any W")
					end
					for _, a in ipairs(at12) do
						walk(ctx, surface, results[a.id].path, { a.x0 + 80 + a.w, 0 }, 1200, k + 1, function(res)
							res.W = a.w
							fx.json(SP, "gap walk W=" .. a.w, res)
						end)
					end
				end)
			end)
		end)
	end)
end)

t.case("SP-14 bridge: a 6x6 box over a 7-wide land bridge", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-14.txt")
	ctx.at(2, chain)
	ctx.at(3, function()
		local surface = fx.surface("sp14-bridge")
		-- Land at both ends (x < -30, x >= 30); between them a 60-long water strip crossed by a bridge, water all
		-- around. "7 wide" is the brief's (y in [-3, 4)); "15 wide" (y in [197, 212) at oy = 200) is the control.
		local rows = { { name = "7 wide", oy = 0, lo = -3, hi = 4 }, { name = "15 wide", oy = 200, lo = 197, hi = 212 } }
		for _, r in ipairs(rows) do
			carve(surface, -80, r.oy - 50, 80, r.oy + 50, function(x, y)
				return x >= -60 and x < 60 and y >= r.oy - 30 and y < r.oy + 30
					and (x < -30 or x >= 30 or (y >= r.lo and y < r.hi))
			end)
		end
		ctx.at(5, function()
			local asked = {}
			local ids = {}
			for _, r in ipairs(rows) do
				for _, box in ipairs({ { "6x6", { { -3, -3 }, { 3, 3 } } }, { "10x10", { { -5, -5 }, { 5, 5 } } } }) do
					local id = request(surface, { -35, r.oy }, { 35, r.oy }, box[2], 0, false)
					asked[#asked + 1] = { id = id, row = r, box = box[1] }
					ids[#ids + 1] = id
				end
			end
			fx.wait(ctx, 6, 1800, "bridge path results", function()
				return all_done(ids)
			end, function(k)
				ctx.at(k + 1, function()
					for _, a in ipairs(asked) do
						local rr = results[a.id]
						local tag = "bridge " .. a.row.name .. " " .. a.box
						fx.json(SP, tag, { found = rr.path ~= nil, try_again_later = rr.try_again_later or false,
							n = rr.path and #rr.path or 0 })
						if rr.path then
							walk(ctx, surface, rr.path, { 35, a.row.oy }, 1200, k + 1, function(res)
								fx.json(SP, tag .. " walk", res)
							end)
						end
					end
				end)
			end)
		end)
	end)
end)

t.case("SP-14 cache: latency of cache true against false; a stale no-path after landfill", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-14.txt")
	ctx.at(2, chain)
	local surface
	local function batch(n, cache)
		local ids, ask = {}, game.tick
		for _ = 1, n do
			ids[#ids + 1] = request(surface, { -30, 0 }, { 30, 0 }, nil, 0, cache)
		end
		return ids, ask
	end
	local function latency(tag, ids, ask)
		local lo, hi, retry, found = math.huge, 0, 0, 0
		for _, id in ipairs(ids) do
			local r = results[id]
			lo, hi = math.min(lo, r.tick - ask), math.max(hi, r.tick - ask)
			retry = retry + (r.try_again_later and 1 or 0)
			found = found + (r.path and 1 or 0)
		end
		fx.json(SP, tag, { min_ticks = lo, max_ticks = hi, try_again_later = retry, found = found, n = #ids })
	end
	-- Apart from the other two cases, so their requests don't queue ahead of these.
	ctx.at(4500, function()
		surface = fx.surface("sp14-cache")
		carve(surface, -60, -60, 60, 60, function(x, y)
			return x >= -40 and x < 40 and y >= -40 and y < 40
		end)
		ctx.at(4502, function()
			local ids_t, ask_t = batch(20, true)
			fx.wait(ctx, 4503, 1800, "20 cache=true results", function()
				return all_done(ids_t)
			end, function()
				latency("cache=true x20 latency", ids_t, ask_t)
				ctx.at(math.max(4502 + 600, game.tick - t.first_tick + 1), function()
					local ids_f, ask_f = batch(20, false)
					fx.wait(ctx, game.tick - t.first_tick + 1, 1800, "20 cache=false results", function()
						return all_done(ids_f)
					end, function(k)
						latency("cache=false x20 latency", ids_f, ask_f)
						ctx.at(k + 1, function()
							local tiles = {}
							for x = -10, 9 do
								for y = -40, 39 do
									tiles[#tiles + 1] = { name = "water", position = { x, y } }
								end
							end
							surface.set_tiles(tiles)
							local wet = request(surface, { -30, 0 }, { 30, 0 }, nil, 0, true)
							fx.wait(ctx, k + 2, 1800, "water-strip result", function()
								return results[wet] ~= nil
							end, function(k2)
								fx.json(SP, "water strip, cache=true", { found = results[wet].path ~= nil,
									try_again_later = results[wet].try_again_later or false })
								ctx.at(k2 + 1, function()
									for x = -10, 9 do
										for y = -40, 39 do
											tiles[(x + 10) * 80 + (y + 40) + 1] = { name = "landfill", position = { x, y } }
										end
									end
									surface.set_tiles(tiles)
									local base = game.tick
									local probes = {}
									local function probe(tag, cache)
										local id = request(surface, { -30, 0 }, { 30, 0 }, nil, 0, cache)
										probes[#probes + 1] = id
										fx.wait(ctx, game.tick - t.first_tick + 1, 1800, tag .. " result", function()
											return results[id] ~= nil
										end, function()
											fx.json(SP, "landfilled +" .. (game.tick - base) .. " " .. tag, {
												found = results[id].path ~= nil,
												try_again_later = results[id].try_again_later or false })
										end)
									end
									probe("cache=true at once", true)
									probe("cache=false at once", false)
									local now = game.tick - t.first_tick
									ctx.at(now + 60, function() probe("cache=true at +60", true) end)
									ctx.at(now + 600, function() probe("cache=true at +600", true) end)
									ctx.at(now + 700, function() probe("cache=false at +700", false) end)
								end)
							end)
						end)
					end)
				end)
			end)
		end)
	end)
end)
