local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local fx = require("modules/v2_test/ctron")

-- Cross-tile cargo (research option 1, spec §13 phase 5). In one save every station shares a surface, so "local" can't
-- tell tiles apart: the publish decision (the first case) and the trip (G11, G12) are tested separately.

local function request(station, in_transit, min)
	storage.station_requests[station.unit_number][1] = { name = "iron-plate", quality = "normal", min = min or 10,
		max = 20, in_transit_count = in_transit }
end

local function plates(surface, x, y)
	local chest = surface.find_entities_filtered({ name = "storage-chest", position = { x, y }, radius = 1 })[1]
	return chest and chest.get_item_count("iron-plate") or 0
end

local function cargo_jobs(surface)
	local out = {}
	for _, job in ipairs(fx.jobs(surface)) do
		if job.job_type == "cargo" then
			out[#out + 1] = job
		end
	end
	return out
end

local function published(surface)
	local out = {}
	for _, line in ipairs(fx.lines) do
		if line.op == "ctron.pool" and line.phase == "published" and line.fields.surface == surface.name then
			out[#out + 1] = line
		end
	end
	return out
end

t.case("cargo: a request no other station here can supply is published, one another station can supply is served " ..
	"here", function(ctx)
	local alone, shared, st1, st2
	ctx.at(10, function()
		alone, shared = fx.surface("ctron-cargo1"), fx.surface("ctron-cargo2")
		for _, surface in ipairs({ alone, shared }) do
			loop.ground(-20, -20, 300, 120, surface.name)
		end
		st1 = fx.station(alone, 10, 10, {})
		fx.ctron(alone, 10, 22)
		st2 = fx.station(shared, 10, 10, {})
		fx.station(shared, 200, 10, { ["iron-plate"] = 50 })
		fx.ctron(shared, 10, 22)
	end)
	ctx.at(12, function()
		request(st1, 0)
		request(st2, 0)
	end)
	fx.wait(ctx, 13, 1300, "both prospected", function()
		return #published(alone) == 1 and #cargo_jobs(shared) == 1
	end, function()
		local lines = published(alone)
		ctx.expect(lines[1].fields.cargo == true, "the published line says cargo")
		ctx.expect(#cargo_jobs(alone) == 0, "no cargo job kept where it was published")
		ctx.expect(storage.station_requests[st1.unit_number][1].in_transit_count > 0, "the slot is in transit")
		ctx.expect(#published(shared) == 0, "the supplied request is not published")
	end)
end)

--- A cargo job as the pool hands it to B: 20 iron plates for the station at (32, 3100), claimed without a worker.
local function claim(key, surface)
	ctron_plugin_on_job_claimed(helpers.table_to_json({
		key = key, job_type = "cargo", state = "setup", surface_name = surface.name,
		required_items = { ["iron-plate"] = { normal = 20 } },
		task_positions = { { x = 32, y = 3100 } },
		destination_station = { position = { x = 32, y = 3100 }, valid = true },
		station = {}, trash_items = {}, chunks = {},
	}))
end

--- A in region A (y > 3000) with a request of 20 in transit, B in region B with 50 plates and a constructron.
local function trip_fixture(ctx, name, state)
	ctx.at(10, function()
		state.surface = fx.surface(name)
		state.edge = { fx.pair(state.surface, name, 0) }
		state.a = fx.station(state.surface, 32, 3100, {})
		state.b = fx.station(state.surface, 32, 1950, { ["iron-plate"] = 50 })
		state.v = fx.ctron(state.surface, 32, 1940)
	end)
	ctx.at(12, function()
		request(state.a, 20)
		claim(state.key, state.surface)
	end)
end

local function home(state)
	local near = state.surface.find_entities_filtered({ name = "constructron", position = { 32, 1950 }, radius = 16 })
	return #near == 1 and not storage.constructron_statuses[near[1].unit_number].busy
end


t.case("G11: a supplier's constructron loads at its station, crosses, delivers into the requester's network and " ..
	"comes home", function(ctx)
	local state = { key = "4243|9" }
	trip_fixture(ctx, "ctron-g11", state)
	fx.wait(ctx, 13, 15000, "the cargo delivered and the constructron home", function()
		return plates(state.surface, 37, 3100) == 20 and fx.by_key(state.key) == nil and home(state)
	end, function()
		ctx.expect(storage.station_requests[state.a.unit_number][1].in_transit_count == 0, "the slot is no longer in transit")
		ctx.expect(fx.phases(state.key, "ctron.cross") == "captured,arrived,handed_off,captured,arrived,handed_off",
			"out and back: " .. fx.phases(state.key, "ctron.cross"))
	end)
end)

t.case("G12: the destination station removed mid-trip sends the cargo home", function(ctx)
	local state = { key = "4243|10" }
	local destroyed
	trip_fixture(ctx, "ctron-g12", state)
	fx.wait(ctx, 13, 15000, "the cargo back in B's network and the job done", function()
		local job = fx.by_key(state.key)
		if not destroyed and job and job.in_transit then
			destroyed = true
			state.a.destroy({ raise_destroy = true })
		end
		return destroyed and job == nil and plates(state.surface, 37, 1950) == 50 and home(state)
	end, function()
		local captured = fx.lines_of(state.key, "ctron.cross", "captured")
		ctx.expect(#captured == 2, "two crossings: " .. fx.phases(state.key, "ctron.cross"))
		ctx.expect(captured[1].fields.edge == state.edge[2] and captured[2].fields.edge == state.edge[1],
			"the second crossing goes B-ward")
	end)
end)
