local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ct = require("modules/ctron_pluginv2/ct")
local events_of, cid_of, share, assign, paved, trunk_of = fx.events_of, fx.cid_of, fx.share, fx.assign, fx.paved,
	fx.trunk_of

-- E8 in one save (P6 E2E E8): one deconstruction cell of steel chests full of stone, 1.5 trunks of it, split into two
-- jobs for two fresh ctrons. Fresh roboports start below spawn_minimum (20 % of the buffer), so for ~700 ticks no robot
-- leaves; then the robots empty the chests a stone per trip, which takes far longer than 3600 ticks while the remaining
-- count stands still. Each run must stay at its task until the chests are gone.
t.case("G-E8 full chests split over two fresh ctrons", function(ctx)
	local c = {}
	ctx.at(10, function()
		c.surface = paved("ctv2-e8", -40, -80, 80, 30)
		c.station = fx.station(c.surface, 0, 0, {})
		c.station.get_inventory(defines.inventory.roboport_robot).insert({ name = "logistic-robot", count = 40 })
		c.v = { fx.ctron(c.surface, -6, -12, { robots = 50 }), fx.ctron(c.surface, 0, -12, { robots = 50 }) }
		c.stone, c.chests = 0, {}
		local left = math.ceil(1.5 * trunk_of(c.v[1]).count_empty_stacks())
		while left > 0 do
			local n = math.min(left, 48)
			local chest = fx.chest(c.surface, -5.5 + 2 * #c.chests, -49.5, { stone = n * 50 }, "steel-chest")
			chest.order_deconstruction(game.forces.player)
			c.chests[#c.chests + 1], c.stone, left = chest, c.stone + n * 50, left - n
		end
	end)
	ctx.at(14, function()
		local x2 = -6.5 + 2 * #c.chests
		for i, v in ipairs(c.v) do
			ct.registry.set_state(cid_of(v), "idle")
			assign("g-e8-" .. i, "deconstruction", c.surface, { v }, c.station,
				{ share(c.surface, "deconstruction", -6.5, -50.5, x2, -48.5, {}, 60) })
		end
	end)
	local function left_work(v)
		local run = ct.runs.get(cid_of(v))
		return not run or run.state == "returning" or run.state == "unloading"
	end
	-- Each ctron's stone is read the first poll it is seen leaving work, before its station's robots unload it (the
	-- runs needn't leave together), then emptied: the station's robots carry a stone per trip too, and unloading 5950
	-- stone would load the rest of the shared save.
	c.held = {}
	local function finish(k)
		local left = 0
		for _, chest in ipairs(c.chests) do
			left = left + (chest.valid and 1 or 0)
		end
		ctx.expect(left == 0, "every chest is gone when the runs leave: " .. left .. " left")
		ctx.expect(c.held[1] + c.held[2] == c.stone, "the trunks held the stone on leaving work: " .. c.held[1] .. " + "
			.. c.held[2] .. " of " .. c.stone)
		fx.wait(ctx, k + 1, 3000, "both done events", function()
			return #events_of("g-e8-1", "done") > 0 and #events_of("g-e8-2", "done") > 0
		end)
	end
	-- Polled every 60 ticks: fx.wait's per-tick steps pile up in the testlib, which sorts them all every tick.
	local function poll()
		local k = game.tick - ctx.first_tick
		for i, v in ipairs(c.v) do
			if not c.held[i] and left_work(v) then
				c.held[i] = trunk_of(v).get_item_count("stone")
				trunk_of(v).remove({ name = "stone", count = c.stone })
			end
		end
		if c.held[1] and c.held[2] then
			return finish(k)
		end
		ctx.expect(k < 20000, "both runs leaving work within 20000 ticks")
		if k < 20000 then
			ctx.at(k + 60, poll)
		end
	end
	ctx.at(16, poll)
end)
