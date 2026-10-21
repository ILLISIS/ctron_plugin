-- Pure work-cell logic (spec §5.2): CC's 80×80 keys, the bbox an event grows, the quiet period, forced rescans, the
-- 20-tile strip plan, in-place totals, the repair memory and the capped destroy flood. A cell is plain data in
-- storage.ctron_pluginv2.cells; no LuaObjects.
local items = require("modules/ctron_pluginv2/items_core")

local core = { STRIP = 20, REPAIR_CAP = 256, FLOOD_CAP = 200, BRING_CAP = 30 }

--- CC's cell key (entity_processor.lua:16-18).
function core.key(x, y)
	return (math.floor(x / 80) + 12500) * 25000 + (math.floor(y / 80) + 12500)
end

function core.wid(inst, surface, kind, key)
	return inst .. "|" .. surface .. "|" .. kind .. "|" .. key
end

--- An event at (x, y): create the cell or grow its bbox, re-arm t, mark it dirty. A tool cell stays one.
function core.touch(cells, wid, kind, surface, key, x, y, tick, tool)
	local c = cells[wid]
	if not c then
		c = { key = key, kind = kind, surface = surface, min = { x = x, y = y }, max = { x = x, y = y }, since = tick,
			tool = tool or false }
		cells[wid] = c
	else
		local x0, y0, x1, y1 = c.min.x, c.min.y, c.max.x, c.max.y
		c.min.x, c.min.y = math.min(x0, x), math.min(y0, y)
		c.max.x, c.max.y = math.max(x1, x), math.max(y1, y)
		if c.strip and (c.min.x ~= x0 or c.min.y ~= y0 or c.max.x ~= x1 or c.max.y ~= y1) then
			-- the strip plan under a running scan moved: drop it, so it restarts over the new bbox
			c.strip, c.acc, c.scan_start = nil, nil, nil
		end
		c.tool = c.tool or tool or false
	end
	c.t, c.dirty = tick, true
	return c
end

--- A scan may start: forced, or quiet for delay ticks since the last event (CC job_processor.lua:62).
function core.ready(c, tick, delay)
	return c.forced or tick >= c.t + delay
end

--- Ticks left of the quiet period; 0 once a scan has caught up with every event (at least 1 while dirty).
function core.due(c, tick, delay)
	if not c.dirty then
		return 0
	end
	return math.max(1, c.t + delay - tick)
end

--- rescan_now (R-127): skip the quiet period and drop any scan in progress.
function core.force(c)
	c.forced, c.strip, c.acc = true, nil, nil
end

function core.strips(c)
	return math.floor((c.max.x - c.min.x) / core.STRIP) + 1
end

--- Strip i's search area, padded half a tile so entities on the bbox's edge are found, and its left edge.
function core.strip_area(c, i)
	local lo = c.min.x + core.STRIP * (i - 1)
	return { left_top = { x = lo - 0.5, y = c.min.y - 0.5 }, right_bottom = { x = lo + core.STRIP + 0.5, y = c.max.y + 0.5 } }, lo
end

--- Whether an entity at (x, y) counts in the strip starting at lo: one strip per position, and, except for destroy
--- cells (grown by the flood), only positions in the cell's own 80×80 square, so neighbouring cells never share one.
function core.owns(c, lo, x, y)
	return x >= lo and x < lo + core.STRIP and (c.kind == "destroy" or core.key(x, y) == c.key)
end

function core.begin(c, tick)
	c.strip, c.scan_start, c.acc = 1, tick, { bring = {}, out = {}, n = 0 }
end

local function merge(into, map)
	for name, qs in pairs(map) do
		for quality, n in pairs(qs) do
			items.add(into, name, quality, n)
		end
	end
end

--- One entity found by the scan in progress, with the items it needs and the trash it leaves. With its position
--- (x, y) the scan's found extent grows; a caller whose entities don't set the area (destroy, remembered repairs)
--- leaves it out.
function core.count(c, bring, out, x, y)
	local acc = c.acc
	merge(acc.bring, bring)
	merge(acc.out, out)
	acc.n = acc.n + 1
	if x then
		if acc.lo then
			acc.lo.x, acc.lo.y = math.min(acc.lo.x, x), math.min(acc.lo.y, y)
			acc.hi.x, acc.hi.y = math.max(acc.hi.x, x), math.max(acc.hi.y, y)
		else
			acc.lo, acc.hi = { x = x, y = y }, { x = x, y = y }
		end
	end
end

local function slots_of(t)
	return math.ceil(t[3] / t[4])
end

--- The 30 bring kinds with the most slots, ties by name then quality (R-152): one record must fit one message part,
--- and the rest show up in a later scan once jobs have taken these.
local function capped(list)
	table.sort(list, function(a, b)
		local sa, sb = slots_of(a), slots_of(b)
		if sa ~= sb then
			return sa > sb
		end
		if a[1] ~= b[1] then
			return a[1] < b[1]
		end
		return a[2] < b[2]
	end)
	for i = #list, core.BRING_CAP + 1, -1 do
		list[i] = nil
	end
	return list
end

--- End the scan (spec §5.2 step 4). An event since the scan began keeps the cell dirty (it goes up re-armed and is
--- scanned again). True when the cell found nothing and nothing new came: it can go.
function core.finish(c, stacks, allowed)
	local bring = {}
	for name, qs in pairs(c.acc.bring) do
		if allowed[name] ~= false then
			bring[name] = qs
		end
	end
	c.bring, c.out, c.n = capped(items.tuples(bring, stacks)), items.slots(c.acc.out, stacks), c.acc.n
	c.scanned, c.dirty = c.scan_start, c.t >= c.scan_start
	-- The bbox shrinks to what the scan found (so later jobs get only the remaining work). Not when an event arrived
	-- since the scan began: its position may lie outside the found extent, and the next scan tightens instead.
	if c.acc.lo and not c.dirty then
		c.min, c.max = c.acc.lo, c.acc.hi
	end
	c.forced, c.strip, c.scan_start, c.acc = nil, nil, nil, nil
	return c.n == 0 and not c.dirty
end

--- A damaged entity on a repair cell (R-24): kept as {name, x, y} by position up to REPAIR_CAP; past it the memory is
--- off for good (ents = false) and the rescan scans the area as CC does.
function core.remember(c, x, y, name)
	if c.ents == false then
		return
	end
	c.ents = c.ents or {}
	local k = x .. "," .. y
	if not c.ents[k] then
		c.nents = (c.nents or 0) + 1
		if c.nents > core.REPAIR_CAP then
			c.ents, c.nents = false, nil
			return
		end
	end
	c.ents[k] = { name, x, y }
end

--- Breadth-first from seeds over near(e) (R-26), entities as {id, x, y}; at most cap of them, each once.
function core.flood(seeds, near, cap)
	local seen, list, head = {}, {}, 1
	local function visit(e)
		if not seen[e.id] and #list < cap then
			seen[e.id] = true
			list[#list + 1] = e
		end
	end
	for _, e in ipairs(seeds) do
		visit(e)
	end
	while head <= #list and #list < cap do
		for _, e in ipairs(near(list[head])) do
			visit(e)
		end
		head = head + 1
	end
	return list
end

function core.extent(list)
	local lo, hi = { x = list[1].x, y = list[1].y }, { x = list[1].x, y = list[1].y }
	for _, e in ipairs(list) do
		lo.x, lo.y = math.min(lo.x, e.x), math.min(lo.y, e.y)
		hi.x, hi.y = math.max(hi.x, e.x), math.max(hi.y, e.y)
	end
	return lo, hi
end

--- The other cells' keys a flood reached, first seen first; their destroy cells are absorbed (CC :635-638).
function core.absorbed(list, key)
	local out, seen = {}, { [key] = true }
	for _, e in ipairs(list) do
		local k = core.key(e.x, e.y)
		if not seen[k] then
			seen[k] = true
			out[#out + 1] = k
		end
	end
	return out
end

--- The cell's wire record (spec §4.3): totals, area and centre only once a scan has completed.
function core.record(c, wid, tick, delay)
	local r = { wid = wid, surface = c.surface, kind = c.kind, since = c.since, due = core.due(c, tick, delay), tool = c.tool }
	if c.scanned then
		r.scanned, r.n, r.bring, r.out = c.scanned, c.n, c.bring, c.out
		r.area = { left_top = { x = c.min.x, y = c.min.y }, right_bottom = { x = c.max.x, y = c.max.y } }
		r.center = { x = (c.min.x + c.max.x) / 2, y = (c.min.y + c.max.y) / 2 }
	end
	return r
end

return core
