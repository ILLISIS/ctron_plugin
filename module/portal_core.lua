-- The tile's portal graph (spec §7.4), pure lua5.2: sample positions, window runs, avoid keys, union-find and the
-- ct.portals payload. portals.lua probes the game and asks the pathfinder; this file decides.
local core = { STEP = 8, WINDOW = 128, END = 16, MIN_RUN = 2 }

--- Side a's sample positions on a side of length L (R-81).
function core.samples(L)
	local out = {}
	for x = core.END, L - core.END, core.STEP do
		out[#out + 1] = x
	end
	return out
end

--- Each window's longest run of >= MIN_RUN consecutive open samples (ties keep the first), keyed by k.
--- ponytail: one run per window; a second useful run split by water is lost; lower WINDOW to 64 if a real map
--- needs it (R-81).
function core.windows(L, open)
	local out = {}
	local lo, hi, k
	local function close()
		if lo and (hi - lo) / core.STEP + 1 >= core.MIN_RUN then
			local w = out[k]
			if not w or hi - lo > w.hi - w.lo then
				out[k] = { k = k, lo = lo, hi = hi, x = (lo + hi) / 2 }
			end
		end
		lo = nil
	end
	for _, x in ipairs(core.samples(L)) do
		local wk = math.floor(x / core.WINDOW)
		if open[x] and lo and wk == k then
			hi = x
		else
			close()
			if open[x] then
				lo, hi, k = x, x, wk
			end
		end
	end
	close()
	return out
end

--- The avoid key of a hop or window: "<edge>:<k>" (spec §7.5 step 3).
function core.key(edge, xa)
	return edge .. ":" .. math.floor(xa / core.WINDOW)
end

function core.uf(n)
	local p = {}
	for i = 1, n do
		p[i] = i
	end
	return p
end

function core.find(p, i)
	while p[i] ~= i do
		p[i] = p[p[i]]
		i = p[i]
	end
	return i
end

function core.union(p, i, j)
	local a, b = core.find(p, i), core.find(p, j)
	if a ~= b then
		p[math.max(a, b)] = math.min(a, b)
	end
end

local function dist2(a, b)
	local dx, dy = a.x - b.x, a.y - b.y
	return dx * dx + dy * dy
end

--- The nodes to test node j against (R-82): the nearest node of each component among nodes 1..j-1, nearest first.
function core.candidates(nodes, p, j)
	local best, order = {}, {}
	for i = 1, j - 1 do
		local r, d = core.find(p, i), dist2(nodes[i], nodes[j])
		if not best[r] then
			order[#order + 1] = r
			best[r] = { i = i, d = d }
		elseif d < best[r].d then
			best[r] = { i = i, d = d }
		end
	end
	local picks = {}
	for _, r in ipairs(order) do
		picks[#picks + 1] = best[r]
	end
	table.sort(picks, function(a, b)
		return a.d < b.d or (a.d == b.d and a.i < b.i)
	end)
	local out = {}
	for n, pick in ipairs(picks) do
		out[n] = pick.i
	end
	return out
end

--- The ct.portals payload (spec §7.4); the controller links every pair inside a component (R-150).
function core.report(surface, epoch, nodes, p)
	local comp_of, comps, out = {}, 0, {}
	for i, n in ipairs(nodes) do
		local r = core.find(p, i)
		if not comp_of[r] then
			comps = comps + 1
			comp_of[r] = comps
		end
		out[i] = { id = i, kind = n.kind, edge = n.edge, k = n.k, lo = n.lo, hi = n.hi, x = n.x, y = n.y,
			comp = comp_of[r], sid = n.sid }
	end
	return { surface = surface, epoch = epoch, nodes = out }
end

return core
