local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ct = require("modules/ctron_pluginv2/ct")
local report = require("modules/ctron_pluginv2/report")

-- Every job event the module sends, in order; the originals still run.
local events = {}
local real_event = report.event
report.event = function(jid, ev, fields)
	events[#events + 1] = { jid = jid, ev = ev, fields = fields or {} }
	return real_event(jid, ev, fields)
end

local function events_of(jid, ev)
	local out = {}
	for _, e in ipairs(events) do
		if e.jid == jid and e.ev == ev then
			out[#out + 1] = e
		end
	end
	return out
end

local function cid_of(entity)
	return storage.ctron_pluginv2.by_unit[entity.unit_number]
end

local function place(station)
	return { sid = cid_of(station), inst = 4242, x = station.position.x, y = station.position.y }
end

--- The fixture's reactor has no fuel, so the roboports are filled by hand (SP-9).
local function charge(v)
	if v.valid then
		for _, eq in pairs(v.grid.equipment) do
			if eq.type == "roboport-equipment" then
				eq.energy = eq.max_energy
			end
		end
	end
end

local function dist(a, b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

-- G11 (P2 Task 8): a cargo run on one tile, loaded at network 1, delivered into network 2.

local function setup(c, name)
	c.surface = fx.surface(name)
	fx.ground(c.surface, -40, -40, 200, 40)
	c.from, c.from_chest = fx.station(c.surface, 0, 0, { ["iron-plate"] = 300 })
	c.to, c.to_chest = fx.station(c.surface, 150, 0, {})
	c.v = fx.ctron(c.surface, -6, 0, { robots = 10 })
	c.cid = cid_of(c.v)
end

local function start(c, jid)
	charge(c.v)
	ct.registry.set_state(c.cid, "idle")
	c.jid = jid
	c.seen = {}
	fx.send("ct.job.assign", { jid = jid, kind = "cargo", surface = c.surface.name, station = place(c.from),
		members = { c.cid }, work = {},
		cargo = { dest = place(c.to), items = { { "iron-plate", "normal", 100 } } } })
end

local function iron(station)
	return station.logistic_network.get_item_count({ name = "iron-plate", quality = "normal" })
end

--- Record the run's states as they pass.
local function watch(c)
	charge(c.v)
	local run = ct.runs.get(c.cid)
	if run then
		c.seen[run.state] = true
	end
	return run
end

--- The run is over: no iron aboard, no requests left, no failed event.
local function expect_clean(ctx, c, jid)
	ctx.expect(c.v.get_inventory(defines.inventory.spider_trunk).get_item_count("iron-plate") == 0, "no iron aboard")
	local point = c.v.get_logistic_point(defines.logistic_member_index.spidertron_requester)
	ctx.expect(#(point.filters or {}) == 0, "the requests are cleared: " .. serpent.line(point.filters))
	ctx.expect(#events_of(jid, "failed") == 0, "no failed event")
	ctx.expect(ct.registry.ctron(c.cid).state == "idle", "idle: " .. ct.registry.ctron(c.cid).state)
end

t.case("G11 cargo loads at the supplier, delivers at the destination and ends there", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g11-cargo")
	end)
	ctx.at(14, function()
		ctx.expect(c.from.logistic_network and c.to.logistic_network, "both stations have a network")
		ctx.expect(c.from.logistic_network ~= c.to.logistic_network, "the networks are separate")
		start(c, "g11-cargo")
	end)
	fx.wait(ctx, 16, 12000, "the done event", function()
		watch(c)
		return #events_of("g11-cargo", "done") > 0
	end, function(k)
		ctx.expect(c.seen.to_dest and c.seen.deliver, "passed to_dest and deliver: " .. serpent.line(c.seen))
		ctx.expect(iron(c.from) <= 200, "the supplier network gave it up: " .. iron(c.from))
		local d = dist(c.v.position, c.to.position)
		ctx.expect(d <= 15, "the ctron stands at the destination: " .. d)
		expect_clean(ctx, c, "g11-cargo")
		-- The last plates may still be on robots in flight when done fires.
		fx.wait(ctx, k + 2, 600, "the destination network holds the iron", function()
			return iron(c.to) >= 100
		end)
	end)
end)

t.case("G11 a cancelled cargo run returns its load to the supplier", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "ctv2-g11-cancel")
	end)
	ctx.at(14, function()
		start(c, "g11-cancel")
	end)
	-- Cancel only with the load aboard and the ctron well on its way.
	fx.wait(ctx, 16, 6000, "the load aboard, 50 tiles out", function()
		local run = watch(c)
		return run and run.state == "to_dest" and iron(c.from) <= 200 and dist(c.v.position, c.from.position) >= 50
	end, function(k)
		fx.send("ct.job.cancel", { jid = c.jid })
		fx.wait(ctx, k + 2, 8000, "the done event", function()
			watch(c)
			return #events_of("g11-cancel", "done") > 0
		end, function(k2)
			local d = dist(c.v.position, c.from.position)
			ctx.expect(d <= 15, "the ctron is back at the supplier: " .. d)
			-- The last plates may still be on robots in flight when done fires.
			fx.wait(ctx, k2 + 2, 600, "the supplier has its iron back", function()
				return iron(c.from) == 300
			end, function()
				ctx.expect(iron(c.to) == 0, "nothing reached the destination: " .. iron(c.to))
				expect_clean(ctx, c, "g11-cancel")
			end)
		end)
	end)
end)
