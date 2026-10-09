local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local fx = require("modules/v2_test/ctron")

-- Hop-by-hop pathing (spec §6). These cases end before any capture: each turns its edge off once it has seen the plan
-- it wants, since a capture without the crossing glue (Task 6) would carry the constructron without its job.

local function S()
	return storage.universal_edges
end

t.case("pathing: a goal past a live side plans P where the straight line meets it, 3 out; the worker goes on the " ..
	"watch once its path to P arrives (§6.1, §6.4)", function(ctx)
	local surface, ex, v, job
	ctx.at(10, function()
		surface = fx.surface("ctron-p1")
		ex = fx.pair(surface, "ctron-p1", 0)
	end)
	ctx.at(12, function()
		v = fx.ctron(surface, 32, 3050)
		job = fx.job(v, { x = 40, y = 1950 }, fx.stand_in(32, 3100))
	end)
	fx.wait(ctx, 13, 600, "a path to P", function()
		return job.crossing ~= nil and v.autopilot_destination ~= nil
	end, function()
		local px = 32 + 8 * 50 / 1100 -- the line (32, 3050) → (40, 1950) meets y = 3000 here
		ctx.expect(job.crossing.edge == ex and math.abs(job.crossing.x - px) < 1e-6 and job.crossing.y == 2997,
			"P: " .. job.crossing.x .. ", " .. job.crossing.y)
		ctx.expect(S().watch[v.unit_number] == v, "on UE's watch")
		local border = fx.lines_of(job.key, "ctron.path", "border")
		ctx.expect(#border == 1 and border[1].fields.edge == ex and border[1].fields.moved == 0, "one border line")
		loop.activation("ctron-p1", false)
	end)
end)

t.case("pathing: an inactive side makes the job wait, logged once per episode; active again, it plans (§6.6)",
	function(ctx)
		local surface, v, job
		ctx.at(10, function()
			surface = fx.surface("ctron-p2")
			fx.pair(surface, "ctron-p2", 0)
		end)
		ctx.at(12, function()
			loop.activation("ctron-p2", false)
			v = fx.ctron(surface, 32, 3050)
			job = fx.job(v, { x = 40, y = 1950 }, fx.stand_in(32, 3100))
		end)
		fx.wait(ctx, 13, 300, "a wait", function()
			return job.waiting == "edge_inactive"
		end, function(k)
			ctx.at(k + 300, function() -- three more job passes
				ctx.expect(job.crossing == nil and v.autopilot_destination == nil and S().watch[v.unit_number] == nil,
					"not moving, not watched")
				ctx.expect(#fx.lines_of(job.key, "ctron.path", "waiting") == 1, "logged once")
				loop.activation("ctron-p2", true)
				fx.wait(ctx, k + 301, 300, "a plan once the side is back", function()
					return job.crossing ~= nil
				end, function()
					ctx.expect(job.waiting == nil, "the episode is over")
					loop.activation("ctron-p2", false)
				end)
			end)
		end)
	end)

--- A lake over x in [x1, x2] beside side a, from 5 out (short of UE's barriers, which water would remove) to 2 in: the
--- 10×10 box at any P there is wet.
local function lake(surface, x1, x2)
	local tiles = {}
	for x = x1, x2 do
		for y = fx.A - 5, fx.A + 2 do
			tiles[#tiles + 1] = { name = "water", position = { x, y } }
		end
	end
	surface.set_tiles(tiles)
end

t.case("G9: a lake on the projection moves P to the nearest dry spot, 16 along; a lake along the whole line waits " ..
	"no_dry_crossing (§6.2)", function(ctx)
	local wet, flooded = {}, {}
	ctx.at(10, function()
		wet.surface = fx.surface("ctron-g9a")
		wet.ex = fx.pair(wet.surface, "ctron-g9a", 0)
		lake(wet.surface, 26, 37) -- P (32, 2997) and its box are under water; P + 16 is dry
		flooded.surface = fx.surface("ctron-g9b")
		fx.pair(flooded.surface, "ctron-g9b", 0)
		lake(flooded.surface, -20, 83)
	end)
	ctx.at(12, function()
		for _, c in ipairs({ wet, flooded }) do
			c.v = fx.ctron(c.surface, 32, 3050)
			c.job = fx.job(c.v, { x = 32, y = 1950 }, fx.stand_in(32, 3100))
		end
	end)
	fx.wait(ctx, 13, 300, "a dry P", function()
		return wet.job.crossing ~= nil
	end, function()
		ctx.expect(wet.job.crossing.edge == wet.ex and wet.job.crossing.x == 48, "P moved to x = 48: " .. wet.job.crossing.x)
		local border = fx.lines_of(wet.job.key, "ctron.path", "border")
		ctx.expect(border[1] and border[1].fields.moved == 16, "logged moved = 16")
		loop.activation("ctron-g9a", false)
	end)
	fx.wait(ctx, 13, 300, "no dry P", function()
		return flooded.job.waiting == "no_dry_crossing"
	end, function()
		ctx.expect(flooded.job.crossing == nil and #fx.lines_of(flooded.job.key, "ctron.path", "waiting") == 1,
			"waiting, logged once")
		loop.activation("ctron-g9b", false)
	end)
end)

t.case("pathing: a station 4 across the line, 8 from the worker, is never reached from this side: the job plans a " ..
	"crossing instead of clearing its items there (§6.4, Review Focus 2)", function(ctx)
	local surface, ey, v, job
	ctx.at(10, function()
		surface = fx.surface("ctron-rf2")
		ey = select(2, fx.pair(surface, "ctron-rf2", 0))
	end)
	ctx.at(12, function()
		v = fx.ctron(surface, 32, fx.B - 4)
		job = fx.job(v, { x = 32, y = fx.B - 40 }, fx.stand_in(32, fx.B + 4))
		job.state, job.task_positions = "finishing", {}
	end)
	fx.wait(ctx, 13, 300, "a crossing plan home", function()
		return job.crossing ~= nil
	end, function()
		ctx.expect(job.crossing.edge == ey, "across B's side")
		ctx.expect(job.sub_state == nil and job.state == "finishing", "clear_items never ran")
		loop.activation("ctron-rf2", false)
	end)
end)

t.case("pathing: while the worker's robots are out, the job neither plans a crossing nor watches it; once they're " ..
	"back it does (§10, Review Focus 3)", function(ctx)
	local surface, v, job
	ctx.at(10, function()
		surface = fx.surface("ctron-rf3")
		fx.pair(surface, "ctron-rf3", 0)
	end)
	ctx.at(12, function()
		v = fx.ctron(surface, 32, 3050)
		for _, eq in pairs(v.grid.equipment) do -- charged: a roboport deploys no robots on the reactor's nothing
			eq.energy = eq.max_energy
		end
		v.get_inventory(defines.inventory.spider_trunk).insert({ name = "wooden-chest", count = 1 })
		fx.ghost(surface, 42.5, 3060.5, true) -- in the roboports' reach: its robots fly out to build it
	end)
	local function out()
		return #v.logistic_cell.logistic_network.construction_robots > 0
	end
	fx.wait(ctx, 13, 900, "robots out", out, function(k)
		job = fx.job(v, { x = 32, y = 1950 }, fx.stand_in(32, 3100))
		fx.wait(ctx, k + 1, 1800, "the robots back, then a plan", function()
			if out() then
				ctx.expect(job.crossing == nil and S().watch[v.unit_number] == nil, "no plan while robots are out")
			end
			return not out() and job.crossing ~= nil
		end, function()
			ctx.expect(#fx.lines_of(job.key, "ctron.path", "waiting") == 0, "a silent wait")
			loop.activation("ctron-rf3", false)
		end)
	end)
end)
