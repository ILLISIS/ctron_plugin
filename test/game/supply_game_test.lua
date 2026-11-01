local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")
local ct = require("modules/ctron_pluginv2/ct")

-- Player supply (SP-24): a supply run loads at a station, finds the player, hands over what their requests miss
-- through item-request-proxies, takes their trash, and unloads at the station. A game test has no player, so a
-- character stands in for one (supply.stand_in); the controller's messages are sent by hand.
local MAIN, TRASH = defines.inventory.character_main, defines.inventory.character_trash
local IRON = { name = "iron-plate", quality = "normal" }

local function character_logistics()
	-- luacheck: ignore 122
	local force = game.forces.player
	force.character_logistic_requests = true
	if force.character_trash_slot_count < 10 then
		force.character_trash_slot_count = 10
	end
end

--- A station with `iron` plates and the robots a normal profile loads, a ctron beside it, and a character at (70, 0)
--- asking for 100 plates with 40 stone in its trash, standing in for player `name`.
local function setup(c, name, iron)
	character_logistics()
	c.name = name
	c.surface = fx.surface("ctv2-supply-" .. name)
	fx.ground(c.surface, -40, -40, 140, 40)
	c.station, c.chest = fx.station(c.surface, 0, 0, { ["iron-plate"] = iron, ["construction-robot"] = 60 })
	c.v = fx.ctron(c.surface, -6, 0, { robots = 10 })
	c.cid = fx.cid_of(c.v)
	c.char = assert(c.surface.create_entity({ name = "character", position = { 70, 0 }, force = "player" }))
	local section = c.char.get_requester_point().get_section(1) or c.char.get_requester_point().add_section()
	section.set_slot(1, { value = { name = "iron-plate", quality = "normal" }, min = 100 })
	c.char.get_inventory(TRASH)[1].set_stack({ name = "stone", count = 40 })
	ct.supply.stand_in(name, c.char)
	c.seen = {}
end

local function assign(c, jid, items)
	fx.charge(c.v)
	ct.registry.set_state(c.cid, "idle")
	c.jid = jid
	fx.send("ct.job.assign", { jid = jid, kind = "supply", surface = c.surface.name,
		station = { sid = fx.cid_of(c.station), inst = 4242, x = 0, y = 0 }, members = { c.cid }, work = {},
		supply = { player = c.name, items = items, trash = 1, place = { inst = 4242, x = 70, y = 0 } } })
end

local function watch(c)
	fx.charge(c.v)
	local run = ct.runs.get(c.cid)
	if run then
		c.seen[run.state] = true
	end
	return run
end

local function count(entity, index, item)
	return entity.valid and entity.get_inventory(index).get_item_count(item) or 0
end

--- Every iron plate on the surface: network (storage), ctron, character, robots in flight.
local function iron_total(c)
	local air = 0
	for _, r in pairs(c.surface.find_entities_filtered({ type = { "construction-robot", "logistic-robot" } })) do
		air = air + count(r, defines.inventory.robot_cargo, IRON)
	end
	return c.chest.get_item_count(IRON) + count(c.v, defines.inventory.spider_trunk, IRON)
		+ count(c.v, defines.inventory.spider_trash, IRON) + count(c.char, MAIN, IRON) + air, air
end

local function done(c)
	return #fx.events_of(c.jid, "done") > 0
end

t.case("supply: loads, hands the player what they miss, takes their trash and unloads at the station", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "sp1", 300)
		ctx.expect(serpent.line(ct.supply.missing(c.char)) == serpent.line({ ["iron-plate"] = { normal = 100 } }),
			"the character misses 100 plates: " .. serpent.line(ct.supply.missing(c.char)))
	end)
	ctx.at(14, function()
		assign(c, "sup-1", { { "iron-plate", "normal", 100, 100 } })
	end)
	fx.wait(ctx, 16, 12000, "the done event", function()
		watch(c)
		return done(c)
	end, function(k)
		ctx.expect(c.seen.to_player and c.seen.at_player, "passed to_player and at_player: " .. serpent.line(c.seen))
		ctx.expect(count(c.char, MAIN, IRON) == 100, "the character holds 100 plates: " .. count(c.char, MAIN, IRON))
		ctx.expect(c.char.get_inventory(TRASH).is_empty(), "its trash is empty")
		ctx.expect(c.char.item_request_proxy == nil, "no proxy is left on it")
		ctx.expect(#fx.events_of("sup-1", "short") == 0, "no short event")
		ctx.expect(ct.registry.ctron(c.cid).state ~= "busy", "the ctron is released")
		fx.wait(ctx, k + 2, 900, "the stone and the rest of the iron in the station's network", function()
			return c.chest.get_item_count("stone") == 40 and c.chest.get_item_count(IRON) == 200
		end)
	end)
end)

t.case("supply: the player leaving mid-delivery drops the proxy; the run waits, then finds them again", function(ctx)
	local c, run = {}, nil
	ctx.at(10, function()
		setup(c, "sp2", 300)
	end)
	ctx.at(14, function()
		assign(c, "sup-2", { { "iron-plate", "normal", 100, 100 } })
	end)
	fx.wait(ctx, 16, 12000, "robots carrying plates to the player", function()
		run = watch(c)
		local _, air = iron_total(c)
		return run and run.state == "at_player" and air > 0
	end, function(k)
		ct.supply.player_left("sp2")
		ct.supply.stand_in("sp2", nil) -- logged off: no longer on this tile
		ctx.expect(c.char.item_request_proxy == nil, "the proxy went at once")
		ctx.expect(run.state == "to_player" and run.status == "waiting_player", "it waits: " .. run.state .. " "
			.. run.status)
		fx.wait(ctx, k + 1, 1200, "every plate back on the ctron or the character", function()
			watch(c)
			local total, air = iron_total(c)
			return air == 0 and total == 300
		end, function(k2)
			ctx.expect(ct.runs.get(c.cid).status == "waiting_player", "still waiting")
			c.char.teleport({ 40, 20 })
			ct.supply.stand_in("sp2", c.char)
			fx.send("ct.supply.place", { jid = "sup-2", inst = 4242, x = 40, y = 20 })
			fx.wait(ctx, k2 + 2, 6000, "the done event", function()
				watch(c)
				return done(c)
			end, function()
				ctx.expect(count(c.char, MAIN, IRON) == 100, "100 plates in the end: " .. count(c.char, MAIN, IRON))
				ctx.expect(c.char.get_inventory(TRASH).is_empty(), "the trash taken")
			end)
		end)
	end)
end)

t.case("supply: a cancel while handing over drops the proxy; every plate is accounted for", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "sp3", 300)
	end)
	ctx.at(14, function()
		assign(c, "sup-3", { { "iron-plate", "normal", 100, 100 } })
	end)
	fx.wait(ctx, 16, 12000, "robots carrying plates to the player", function()
		local run = watch(c)
		local _, air = iron_total(c)
		return run and run.state == "at_player" and air > 0
	end, function(k)
		fx.send("ct.job.cancel", { jid = "sup-3" })
		ctx.expect(c.char.item_request_proxy == nil, "the proxy went with the cancel")
		fx.wait(ctx, k + 1, 8000, "the done event", function()
			watch(c)
			return done(c)
		end, function(k2)
			fx.wait(ctx, k2 + 1, 900, "the plates the player didn't get back in the network", function()
				local total, air = iron_total(c)
				return air == 0 and total == 300 and count(c.v, defines.inventory.spider_trunk, IRON) == 0
			end, function()
				ctx.expect(count(c.char, MAIN, IRON) < 100, "the cancel cut it short: " .. count(c.char, MAIN, IRON))
			end)
		end)
	end)
end)

t.case("supply: a station short of the items sends the ctron with what it has", function(ctx)
	local c = {}
	ctx.at(10, function()
		setup(c, "sp4", 30)
	end)
	ctx.at(14, function()
		assign(c, "sup-4", { { "iron-plate", "normal", 100, 100 } })
	end)
	fx.wait(ctx, 16, 12000, "the done event", function()
		watch(c)
		return done(c)
	end, function()
		ctx.expect(count(c.char, MAIN, IRON) == 30, "the 30 plates there were: " .. count(c.char, MAIN, IRON))
		ctx.expect(#fx.events_of("sup-4", "short") == 0, "no short event: no other station is asked")
		ctx.expect(c.char.get_inventory(TRASH).is_empty(), "the trash taken")
	end)
end)
