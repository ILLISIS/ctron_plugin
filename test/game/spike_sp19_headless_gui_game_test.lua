local t = require("modules/v2_test/testlib")
local fx = require("modules/v2_test/ctronv2")

t.case("SP-19 player and GUI in a headless run", function(ctx)
	ctx.expect_file("ctronv2-spikes/SP-19.txt")
	ctx.at(2, function()
		ctx.expect(game ~= nil, "game exists")
		fx.note("SP-19", "players ", #game.players, ", connected ", #game.connected_players)
		local ok, res = pcall(function() return game.create_test_player end)
		fx.note("SP-19", "game.create_test_player ok=", tostring(ok), " value=", tostring(res))
		ok, res = pcall(function() return game.simulation end)
		fx.note("SP-19", "game.simulation ok=", tostring(ok), " value=", tostring(res))
		local player = game.players[1]
		if player then
			ok, res = pcall(function() return player.gui.screen.add({ type = "frame", name = "sp19" }) end)
			fx.note("SP-19", "frame on players[1] ok=", tostring(ok), " value=", tostring(res))
		else
			fx.note("SP-19", "no player, no GUI attempt")
		end
	end)
end)
