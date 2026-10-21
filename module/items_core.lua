-- Pure item maths (spec §5.4). An item map is {[name] = {[quality] = count}}; a tuple list is the wire form
-- {{name, quality, count[, stack]}...} (R-18); a request is {name, quality, min, max} for one logistic slot, with
-- quality nil for any quality and max nil for no upper bound.
local core = {}

function core.add(map, name, quality, count)
	local q = map[name]
	if not q then
		q = {}
		map[name] = q
	end
	q[quality] = (q[quality] or 0) + count
	return map
end

--- Inventory slots the map fills: Σ ceil(count / stack) per (name, quality) (CC utility_functions.lua:84-99).
function core.slots(map, stacks)
	local n = 0
	for name, qs in pairs(map) do
		local stack = stacks[name] or 1
		for _, count in pairs(qs) do
			n = n + math.ceil(count / stack)
		end
	end
	return n
end

function core.tuples(map, stacks)
	local out = {}
	for name, qs in pairs(map) do
		for quality, count in pairs(qs) do
			out[#out + 1] = stacks and { name, quality, count, stacks[name] or 1 } or { name, quality, count }
		end
	end
	return out
end

function core.map(tuples)
	local m = {}
	for _, t in ipairs(tuples or {}) do
		core.add(m, t[1], t[2], t[3])
	end
	return m
end

local function put(map, item, count)
	if item and count > 0 then
		core.add(map, item[1], item[2], count)
	end
end

--- A profile's full amounts under cfg (spec §5.4 "Profiles"; CC job.lua:919-924, destroy.lua:54-58, cargo.lua:162).
function core.full(profile, cfg)
	local m = {}
	if profile == "normal" then
		put(m, cfg.robot, cfg.robot_count)
		put(m, cfg.ammo, cfg.ammo_count)
	elseif profile == "destroy" then
		put(m, cfg.robot, 4)
		put(m, cfg.repair_tool, 16)
		put(m, cfg.ammo, cfg.ammo_count)
		put(m, cfg.atomic, cfg.atomic_count)
	elseif profile == "minion" then
		-- CC minion.lua:18-32: the destroy kit without the atomic line (R-197).
		put(m, cfg.robot, 4)
		put(m, cfg.repair_tool, 16)
		put(m, cfg.ammo, cfg.ammo_count)
	else
		put(m, cfg.ammo, cfg.ammo_count)
	end
	return m
end

function core.restock(full, held)
	local m = {}
	for name, qs in pairs(full) do
		for quality, count in pairs(qs) do
			local have = held[name] and held[name][quality] or 0
			if count > have then
				core.add(m, name, quality, count - have)
			end
		end
	end
	return m
end

function core.free(empty, restock, stacks)
	return math.max(0, empty - core.slots(restock, stacks))
end

--- Section 1 at loading: load items at min = max = n, every other held item at 0/0; a load item whose name is
--- allowed[name] == false (no visible recipe, CC job.lua:408-416) is dropped.
function core.load_list(load, held, allowed)
	local out = {}
	for name, qs in pairs(load) do
		if allowed[name] ~= false then
			for quality, n in pairs(qs) do
				out[#out + 1] = { name, quality, n, n }
			end
		end
	end
	for name, qs in pairs(held) do
		for quality in pairs(qs) do
			if not (load[name] and load[name][quality] and allowed[name] ~= false) then
				out[#out + 1] = { name, quality, 0, 0 }
			end
		end
	end
	return out
end

--- Section 1 at unloading (CC job.lua:846-871): every held item at 0/0; a kept item (robots, ammo) at 0..count, so
--- the surplus goes but a ctron short of robots or ammo isn't held at the station waiting for more (P2's request).
function core.unload_list(held, keep)
	local out = {}
	for name, qs in pairs(held) do
		for quality in pairs(qs) do
			out[#out + 1] = { name, quality, 0, keep[name] and keep[name][quality] or 0 }
		end
	end
	return out
end

function core.deliver_list(items)
	local out = {}
	for name, qs in pairs(items) do
		for quality in pairs(qs) do
			out[#out + 1] = { name, quality, 0, 0 }
		end
	end
	return out
end

local function have(held, name, quality)
	local qs = held[name]
	if not qs then
		return 0
	end
	if quality then
		return qs[quality] or 0
	end
	local n = 0
	for _, c in pairs(qs) do
		n = n + c
	end
	return n
end

--- What the requests still miss (an item map; any-quality shortfalls under "any") and whether anything is above
--- its max or held with no request naming it. Fulfilled = missing empty and excess false (CC job.lua:688-716, exact
--- as CC's >= and <=).
function core.unmet(requests, held)
	local missing, excess, named = {}, false, {}
	for _, r in ipairs(requests) do
		local h = have(held, r[1], r[2])
		if h < r[3] then
			core.add(missing, r[1], r[2] or "any", r[3] - h)
		end
		if r[4] and h > r[4] then
			excess = true
		end
		named[r[1] .. "/" .. (r[2] or "*")] = true
	end
	for name, qs in pairs(held) do
		for quality in pairs(qs) do
			if not (named[name .. "/" .. quality] or named[name .. "/*"]) then
				excess = true
			end
		end
	end
	return missing, excess
end

--- The launcher plan at the end of loading (R-40): want spread evenly over n slots, the remainder to the first
--- slots; every other ammo (other names and qualities, atomic bombs included) listed to move to the trunk.
function core.ammo_plan(slots, n, want)
	local move = {}
	for name, qs in pairs(slots) do
		for quality, count in pairs(qs) do
			if not (name == want[1] and quality == want[2]) then
				move[#move + 1] = { name, quality, count }
			end
		end
	end
	local total = slots[want[1]] and slots[want[1]][want[2]] or 0
	if total == 0 or n == 0 then
		return nil, move
	end
	local per = {}
	for i = 1, n do
		per[i] = math.floor(total / n) + (i <= total % n and 1 or 0)
	end
	return per, move
end

--- The one "this network has the items" answer (R-34): true when probe covers every item, the indexes it covers when
--- only some, nil when none.
function core.cover(probe, items)
	local hit = {}
	for i, item in ipairs(items) do
		if probe(item[1], item[2], item[3]) then
			hit[#hit + 1] = i
		end
	end
	if #hit == #items then
		return true
	end
	return #hit > 0 and hit or nil
end

return core
