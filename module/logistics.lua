-- A ctron's logistic requests and the stations' stock (spec §4.3 need, §5.4, §5.8, §6.5; R-33, R-34, R-118, R-132,
-- R-140): section 1 of the requester point, holdings, exact fulfilment against the point's merged filters, the one
-- `cover` probe, the ct.stock.query answer, and the stations' cargo slots with the 600-tick needs pass.
local items = require("modules/ctron_pluginv2/items_core")
local ct = require("modules/ctron_pluginv2/ct")
local ue = require("modules/universal_edges")
local bridge = require("modules/ctron_pluginv2/bridge")
local parts = require("modules/ctron_pluginv2/parts_core")

local logistics = { events = {} }

local MAX_SLOTS = 30 -- R-154: a need record must fit one message part

local function S()
	return storage.ctron_pluginv2
end

local function start()
	local s = S()
	s.needs = s.needs or {}
end

logistics.on_init = start
logistics.on_server_startup = start

local function point_of(entity)
	return entity.get_logistic_point(defines.logistic_member_index.spidertron_requester)
end

--- Section 1 of the entity's requester point: never a shared group (a group's slots belong to every entity in it).
local function section(entity)
	local point = point_of(entity)
	if not point then
		return nil
	end
	point.trash_not_requested = false
	local sec = point.get_section(1) or point.add_section()
	if sec.group ~= "" then
		sec.group = ""
	end
	return sec
end

local function write(entity, requests)
	local sec = section(entity)
	if not sec then
		return
	end
	local filters = {}
	for i, r in ipairs(requests) do
		filters[i] = { value = { type = "item", name = r[1], quality = r[2], comparator = "=" }, min = r[3],
			max = r[4] }
	end
	sec.filters = filters
end

function logistics.held(entity)
	local map = {}
	for _, inv in ipairs({ defines.inventory.spider_trunk, defines.inventory.spider_ammo }) do
		for _, c in ipairs(entity.get_inventory(inv).get_contents()) do
			items.add(map, c.name, c.quality, c.count)
		end
	end
	return map
end

function logistics.write_load(entity, load)
	write(entity, items.load_list(load, logistics.held(entity), ct.settings.allowed))
end

function logistics.write_unload(entity, keep)
	write(entity, items.unload_list(logistics.held(entity), keep))
end

function logistics.write_deliver(entity, cargo)
	write(entity, items.deliver_list(cargo))
end

function logistics.clear(entity)
	write(entity, {})
end

function logistics.trash_empty(entity)
	return entity.get_inventory(defines.inventory.spider_trash).is_empty()
end

--- The point's compiled filters as items_core requests, merged per (name, quality): counts add, a missing max is no
--- bound. A quality range (comparator other than "=") counts as any quality.
-- ponytail: a range's min is checked against the total over all qualities, a little lenient; split per quality if
-- players ever request ranges from a ctron.
local function requests_of(point)
	local by, out = {}, {}
	for _, f in ipairs(point.filters or {}) do
		if f.name and (f.type == nil or f.type == "item") then
			local quality = f.comparator == "=" and f.quality or nil
			local key = f.name .. "/" .. (quality or "*")
			local r = by[key]
			if not r then
				r = { f.name, quality, 0, 0 }
				by[key] = r
				out[#out + 1] = r
			end
			r[3] = r[3] + (f.count or 0)
			if r[4] and f.max_count then
				r[4] = r[4] + f.max_count
			else
				r[4] = nil
			end
		end
	end
	return out
end

--- ok, missing, held, excess: the point's merged filters are the truth (R-132), so `load` is unused.
function logistics.fulfilled(entity, _load)
	local point = point_of(entity)
	if not point then
		return false, {}, {}, true
	end
	local held = logistics.held(entity)
	local missing, excess = items.unmet(requests_of(point), held)
	local ok = next(missing) == nil and not excess and #point.targeted_items_deliver == 0
		and logistics.trash_empty(entity)
	return ok, missing, held, excess
end

--- true when net has every item, the indexes of the ones it has when only some, nil when none (R-34).
function logistics.cover(net, list, mode)
	local probe
	if mode == "supply" then
		probe = function(n, q, c)
			return net.can_satisfy_request({ name = n, quality = q }, c, true)
		end
	else
		probe = function(n, q, c)
			return net.select_drop_point({ stack = { name = n, quality = q, count = c } }) ~= nil
		end
	end
	return items.cover(probe, list)
end

--- Answer a ct.stock.query: this tile's stations grouped by network now, one record per (entry, network) that
--- covers something, sent in parts. The query carries no surface; the controller ignores sids it doesn't want.
function logistics.answer(req, q)
	local s = S()
	local groups, by_id = {}, {}
	for sid, rec in pairs(s.stations) do
		local e = rec.entity
		local net = e.valid and e.logistic_network
		if net then
			local g = by_id[net.network_id]
			if not g then
				g = { net = net, sids = {} }
				by_id[net.network_id] = g
				groups[#groups + 1] = g
			end
			g.sids[#g.sids + 1] = sid
		end
	end
	local records = {}
	for _, entry in ipairs(q) do
		local skip
		local ex = entry.exclude_sid and s.stations[entry.exclude_sid]
		if ex and ex.entity.valid and ex.entity.logistic_network then
			skip = ex.entity.logistic_network.network_id
		end
		for _, g in ipairs(groups) do
			if g.net.network_id ~= skip then
				local c = logistics.cover(g.net, entry.items, entry.mode)
				if c ~= nil then
					records[#records + 1] = { qid = entry.qid, sids = g.sids, cover = c }
				end
			end
		end
	end
	local packed = parts.pack(records, helpers.table_to_json)
	if #packed == 0 then
		packed[1] = {}
	end
	for i, r in ipairs(packed) do
		bridge.send("ct.stock.reply", { req = req, part = i, parts = #packed, r = r })
	end
end

bridge.on("ct.stock.query", function(p)
	if type(p.req) ~= "string" or type(p.q) ~= "table" then
		return false
	end
	logistics.answer(p.req, p.q)
end)

function logistics.slots(sid)
	return S().slots[sid] or {}
end

local function same(a, b)
	if not b or #a ~= #b then
		return false
	end
	for i, x in ipairs(a) do
		local y = b[i]
		for j = 1, 6 do
			if x[j] ~= y[j] then
				return false
			end
		end
	end
	return true
end

--- Recompute one station's need; marks it when it changed.
local function check(sid)
	local s = S()
	local rec = s.stations[sid]
	if not (rec and rec.entity.valid) then
		return false
	end
	local net = rec.entity.logistic_network
	local old = s.needs[sid]
	if not net then
		if old then
			s.needs[sid] = nil
			ct.report.mark("need", sid)
		end
		return true
	end
	local slots = {}
	for _, slot in ipairs(s.slots[sid]) do
		local name, quality = slot[1], slot[2]
		-- A removed mod's item can still sit in saved slots; get_item_count raises on it.
		if prototypes.item[name] then
			slots[#slots + 1] = { name, quality, slot[3], slot[4], net.get_item_count({ name = name, quality = quality }),
				ct.settings.stacks[name] }
		end
	end
	if not (old and same(slots, old.slots)) then
		s.needs[sid] = { sid = sid, surface = rec.entity.surface.name, slots = slots }
		ct.report.mark("need", sid)
	end
	return true
end

function logistics.set_slots(sid, slots)
	local s = S()
	if slots == nil or #slots == 0 then
		s.slots[sid] = nil
		s.needs[sid] = nil
		ct.report.mark("need", sid)
		return
	end
	local kept = {}
	for i = 1, math.min(#slots, MAX_SLOTS) do
		local x = slots[i]
		kept[i] = { x[1], x[2], x[3], x[4] }
	end
	s.slots[sid] = kept
	check(sid)
end

--- A remote Control Center's edit of a station this tile holds (§8.4); a station that has gone is ignored.
bridge.on("ct.station.set", function(p)
	if type(p.sid) ~= "string" then
		return false
	end
	if not ct.registry.station(p.sid) then
		return
	end
	if type(p.slots) == "table" then
		logistics.set_slots(p.sid, p.slots)
	end
	if type(p.name) == "string" then
		ct.registry.rename(p.sid, p.name)
	end
end)

function logistics.need(sid)
	return S().needs[sid]
end

function logistics.needs()
	local out = {}
	for _, need in pairs(S().needs) do
		out[#out + 1] = need
	end
	return out
end

ue.runtime.scheduler.periodic({ name = "ctron.needs", interval = 600, fn = function()
	local n = 0
	local ids = {}
	for sid in pairs(S().slots) do
		ids[#ids + 1] = sid
	end
	for _, sid in ipairs(ids) do
		if check(sid) then
			n = n + 1
		end
	end
	return math.max(n, 1)
end })

return logistics
