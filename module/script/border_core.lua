-- Hop-by-hop pathing (Constructron v2 spec §6.1), pure: where a constructron crosses its tile's border toward a goal
-- on another tile. A side is ue.edges.list()'s view, { id, active, deleted, frame = { origin, facing, length } }.
local geometry = require("modules/universal_edges/edges/geometry_core")
local crossing = require("modules/universal_edges/transports/crossing_core")

--- DEPTH: P lies 3 out, 2.5 past UE's capture threshold and 3 short of its barriers. END: P stays 16 from either end
--- of the side, off UE's corner margin, so the ±8 arrival box lands inside the partner's [0, L). STEP: the water
--- search's stride along the side (§6.2).
local core = { DEPTH = 3, END = 16, STEP = 16 }

--- plan(sides, goal, from) → nil when goal is on from's tile; { wait = "edge_inactive" } when every side goal lies
--- past is inactive or deleted; else { edge, frame, lx }: cross side edge at local x lx (P, before any water search).
function core.plan(sides, goal, from)
	local past = {}
	for _, side in ipairs(sides) do
		local f = side.frame
		local x0, y0 = geometry.to_local(f, from.x, from.y)
		-- The tile's sides: those from isn't beyond by more than FAR (in a one-save test, the far ends' sides drop out).
		if y0 >= -crossing.FAR then
			local x1, y1 = geometry.to_local(f, goal.x, goal.y)
			if y1 < 0 then
				-- t: how far along from → goal the line meets this side's line (0 when from is already past it)
				local t = y0 <= 0 and 0 or y0 / (y0 - y1)
				past[#past + 1] = { side = side, t = t, lx = x0 + (x1 - x0) * t }
			end
		end
	end
	if #past == 0 then
		return nil
	end
	-- The side the line leaves the tile through first; at a corner, the other one when that one is down (§6.3).
	table.sort(past, function(a, b)
		return a.t < b.t or (a.t == b.t and a.side.id < b.side.id)
	end)
	for _, p in ipairs(past) do
		if p.side.active and not p.side.deleted then
			local L = p.side.frame.length
			return { edge = p.side.id, frame = p.side.frame, lx = math.max(core.END, math.min(L - core.END, p.lx)) }
		end
	end
	return { wait = "edge_inactive" }
end

--- The local xs to try for P on a side of length L, from lx out by STEP each way, nearest first, within
--- [END, L - END]: 31 on a 512 side (§6.2).
function core.xs(lx, L)
	local out, k = { lx }, 1
	while true do
		local added = false
		for _, x in ipairs({ lx + k * core.STEP, lx - k * core.STEP }) do
			if x >= core.END and x <= L - core.END then
				out[#out + 1] = x
				added = true
			end
		end
		if not added then
			return out
		end
		k = k + 1
	end
end

--- P's world position for local x on frame f.
function core.point(f, x)
	return geometry.to_world(f, x, -core.DEPTH)
end

return core
