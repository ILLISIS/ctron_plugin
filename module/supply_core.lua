-- Player supply, pure (SP-24): what a character misses of its logistic requests, and the item-request-proxy plan by
-- which a ctron's robots hand it over and take the character's trash. Plain Lua 5.2 (luacheck). A slot is
-- {name, quality, count} or, empty, {count = 0, filter = the item a slot filter reserves it for}.
local items = require("modules/ctron_pluginv2/items_core")

local core = {}

local function count(map, name, quality)
	return map[name] and map[name][quality] or 0
end

local function sorted(t)
	local out = {}
	for k in pairs(t) do
		out[#out + 1] = k
	end
	table.sort(out)
	return out
end

--- What a character misses: per requested (name, quality), its compiled filters' minimums added up (a point's
--- sections add up, R-132), less what it holds and what robots already bring (`coming`).
-- ponytail: a quality range or "any quality" filter is left out, as a ctron loads one quality; read it as normal
-- quality if players ask for it.
function core.missing(filters, held, coming)
	local want = {}
	for _, f in ipairs(filters) do
		if f.name and (f.type == nil or f.type == "item") and f.comparator == "=" and f.quality and (f.count or 0) > 0 then
			items.add(want, f.name, f.quality, f.count)
		end
	end
	local out = {}
	for name, qs in pairs(want) do
		for quality, n in pairs(qs) do
			local short = n - count(held, name, quality) - count(coming, name, quality)
			if short > 0 then
				items.add(out, name, quality, short)
			end
		end
	end
	return out
end

--- A call's items: the missing map as tuples with stack sizes, the `max` kinds that fill the most slots (ties by name),
--- so the call fits one message (R-152's rule for a cell's bring).
function core.call_items(missing, stacks, max)
	local list = items.tuples(missing, stacks)
	local function slots(t)
		return math.ceil(t[3] / t[4])
	end
	table.sort(list, function(a, b)
		if slots(a) ~= slots(b) then
			return slots(a) > slots(b)
		end
		return a[1] < b[1] or a[1] == b[1] and a[2] < b[2]
	end)
	for i = #list, max + 1, -1 do
		list[i] = nil
	end
	return list
end

--- What a ctron hands over: of what the character misses, what the ctron holds beyond the items it keeps (its robots
--- and ammo).
function core.give(missing, held, keep)
	local out = {}
	for name, qs in pairs(missing) do
		for quality, n in pairs(qs) do
			local spare = count(held, name, quality) - count(keep, name, quality)
			if spare > 0 then
				items.add(out, name, quality, math.min(n, spare))
			end
		end
	end
	return out
end

--- The insert plan: give (an item map) into main's slots, topping up stacks of the same item and quality first, then
--- empty slots no filter reserves for another item. Returns {{name, quality, {{stack (0-based), count}...}}...}; what
--- has no room is left out.
function core.place(give, slots, stacks)
	local plan, used = {}, {}
	for _, name in ipairs(sorted(give)) do
		local stack = stacks[name] or 1
		for _, quality in ipairs(sorted(give[name])) do
			local left, into = give[name][quality], {}
			for pass = 1, 2 do
				for i, s in ipairs(slots) do
					if left <= 0 then
						break
					end
					local n = 0
					if not used[i] and pass == 1 and s.name == name and s.quality == quality then
						n = math.min(stack - s.count, left)
					elseif not used[i] and pass == 2 and not s.name and (s.filter == nil or s.filter == name) then
						n = math.min(stack, left)
					end
					if n > 0 then
						into[#into + 1] = { i - 1, n }
						used[i] = true
						left = left - n
					end
				end
			end
			if #into > 0 then
				plan[#plan + 1] = { name, quality, into }
			end
		end
	end
	return plan
end

--- The removal plan: every filled trash slot as {name, quality, stack (0-based), count}.
function core.take(trash)
	local out = {}
	for i, s in ipairs(trash) do
		if s.name and s.count > 0 then
			out[#out + 1] = { s.name, s.quality, i - 1, s.count }
		end
	end
	return out
end

--- One proxy's plan: {inserts, takes, n (entries), sig}. Two plans with one sig in a row mean the last proxy moved
--- nothing (it was cleared, or nothing it asked for could be done).
function core.plan(give, main, trash, stacks)
	local inserts, takes = core.place(give, main, stacks), core.take(trash)
	local parts = {}
	for _, e in ipairs(inserts) do
		for _, s in ipairs(e[3]) do
			parts[#parts + 1] = e[1] .. "/" .. e[2] .. "@" .. s[1] .. "+" .. s[2]
		end
	end
	for _, e in ipairs(takes) do
		parts[#parts + 1] = e[1] .. "/" .. e[2] .. "@t" .. e[3] .. "-" .. e[4]
	end
	return { inserts = inserts, takes = takes, n = #inserts + #takes, sig = table.concat(parts, ",") }
end

return core
