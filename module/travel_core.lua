-- Travel decisions (spec §7.2, §7.3, §7.5), pure lua5.2: request params, the leaves-tile check, path simplification,
-- the crossing points A, S and O, hop budgets and avoid lists. travel.lua reads the game and applies them.
local geometry = require("modules/universal_edges/edges/geometry_core")

local core = {
	BOX = { { -5, -5 }, { 5, 5 } }, -- CC's (job.lua:330); SP-14 may lower it
	SMALL_BOX = { { -1, -1 }, { 1, 1 } }, -- the ladder's last resort (CC pathfinder.lua:79-81)
	RES = -2, SMALL_RES = 0, MAX_GAP = 12, RADIUS = 2,
	SHORT = 12, -- a move this short sets the autopilot directly (CC job.lua:342)
	MERGE = 5, -- simplify merges waypoints closer than this (CC pathfinder.lua:54-110)
	LEAVE = 2, -- a waypoint more than this past a live line leaves the tile (R-71)
	FAR = geometry.DEPTH + geometry.SIZE / 2, -- 26: the far side of UE's barrier band
	A_Y = 6, S_Y = -3, -- approach and step-out points (R-78); SP-15's fallback is S_Y = -4.5
	END = 16, -- a hop's x stays this far from a side's ends (R-78)
	TRAVEL_CAP = 8, -- travel path requests in flight per tile (R-77)
	RETRY = 60, -- try_again_later re-queues after this many ticks
	WATCH = 120, PROGRESS = 2, -- the watchdog (R-76; CC job.lua:526-540)
	ROBOT_WAIT = 1800, CAPTURE_WAIT = 300, SETTLE = 12, -- R-79, §7.3 step 7, R-78
	AVOID = 18000, REROUTES = 3, ASK_RETRY = 300, -- R-80, R-87, R-148
}

local function copy_box(b)
	return { { b[1][1], b[1][2] }, { b[2][1], b[2][2] } }
end

--- The request_path fields that don't name game objects (spec §7.2); travel.lua adds surface, start, goal, force
--- and collision_mask.
function core.request_spec(small, background)
	return {
		bounding_box = copy_box(small and core.SMALL_BOX or core.BOX),
		path_resolution_modifier = small and core.SMALL_RES or core.RES,
		max_gap_size = core.MAX_GAP,
		radius = core.RADIUS,
		pathfind_flags = background and { cache = false, low_priority = true } or { cache = false },
	}
end

--- True when a waypoint lies more than LEAVE past a live side's line, inside the barrier band and the side's span
--- (spec §7.2, R-71). frames: the live sides' { origin, facing, length }.
function core.leaves_tile(path, frames)
	for _, f in ipairs(frames) do
		local lo, hi = -geometry.MARGIN, f.length + geometry.MARGIN
		for _, w in ipairs(path) do
			local x, y = geometry.to_local(f, w.position.x, w.position.y)
			if y < -core.LEAVE and y > -core.FAR and x >= lo and x <= hi then
				return true
			end
		end
	end
	return false
end

--- The autopilot points of a path (spec §7.2): the start is dropped, turns kept, points closer than MERGE to the
--- last kept one merged; the last point always stays.
function core.simplify(path)
	local n = #path
	if n == 1 then
		return { { x = path[1].position.x, y = path[1].position.y } }
	end
	local out = {}
	local lx, ly = path[1].position.x, path[1].position.y
	for i = 2, n do
		local p = path[i].position
		if i == n then
			out[#out + 1] = { x = p.x, y = p.y }
		else
			local q = path[i + 1].position
			local dx1, dy1, dx2, dy2 = p.x - lx, p.y - ly, q.x - p.x, q.y - p.y
			local straight = math.abs(dx1 * dy2 - dy1 * dx2) < 1e-6 and dx1 * dx2 + dy1 * dy2 > 0
			if not straight and dx1 * dx1 + dy1 * dy1 >= core.MERGE * core.MERGE then
				out[#out + 1] = { x = p.x, y = p.y }
				lx, ly = p.x, p.y
			end
		end
	end
	return out
end

--- The world points of hop x (side a's frame) on side `me` with frame f (spec §7.3): A inside, S past the line, O on
--- the line (the corridor probe).
function core.points(f, me, xa)
	local x = me == "a" and xa or f.length - xa
	local ax, ay = geometry.to_world(f, x, core.A_Y)
	local sx, sy = geometry.to_world(f, x, core.S_Y)
	local ox, oy = geometry.to_world(f, x, 0)
	return { x = ax, y = ay }, { x = sx, y = sy }, { x = ox, y = oy }
end

--- Captures a routed travel may make (R-87).
function core.budget(hops)
	return 2 * hops + 2
end

function core.avoid_add(avoid, key, tick)
	avoid[key] = tick + core.AVOID
end

--- The live avoid keys, sorted; expired ones are removed from avoid.
function core.avoid_list(avoid, tick)
	local out = {}
	for key, until_tick in pairs(avoid) do
		if until_tick <= tick then
			avoid[key] = nil
		else
			out[#out + 1] = key
		end
	end
	table.sort(out)
	return out
end

--- Whether an arrival pops route's current hop: the source was stepping out for it, or it came through its edge.
--- stepping covers UE's loopback, where the two sides of one edge have different ids.
function core.planned(route, stepping, edge)
	local hop = route and route.hops[route.i]
	return hop ~= nil and (stepping == true or hop.edge == edge)
end

function core.stuck(lx, ly, x, y, stickers)
	local dx, dy = x - lx, y - ly
	return dx * dx + dy * dy < core.PROGRESS * core.PROGRESS and not stickers
end

function core.near(ax, ay, bx, by, r)
	local dx, dy = ax - bx, ay - by
	return dx * dx + dy * dy <= r * r
end

function core.short(ax, ay, bx, by)
	return core.near(ax, ay, bx, by, core.SHORT)
end

function core.clamp_x(L, x)
	return math.max(core.END, math.min(L - core.END, x))
end

--- Where a ctron standing past a line walks back to: that side's A point at its local x (R-133), or nil.
function core.step_back(frames, wx, wy)
	for _, f in ipairs(frames) do
		local x, y = geometry.to_local(f, wx, wy)
		if y < 0 and y > -core.FAR and x >= 0 and x <= f.length then
			local ax, ay = geometry.to_world(f, x, core.A_Y)
			return { x = ax, y = ay }
		end
	end
end

return core
