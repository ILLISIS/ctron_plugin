-- "pure" Lua runs on plain Lua 5.2 (unit tests); everything under module/ and test/game/ runs inside Factorio.
std = "lua52"
max_line_length = 140
exclude_files = { "**/node_modules/**", "**/dist/**" }
stds.factorio = {
	-- storage is the one Factorio global our code writes: each plugin owns storage[<plugin name>].
	globals = { "storage" },
	read_globals = {
		"game", "script", "defines", "helpers", "prototypes", "settings", "remote",
		"commands", "rendering", "rcon", "log", "serpent", "table_size", "localised_print",
		"clusterio_private",
	},
}
files["**/module/**/*.lua"] = { std = "lua52+factorio" }
-- A *_core.lua that touches a Factorio global fails lint: that is what keeps the cores unit-testable (spec §3).
files["**/module/**/*_core.lua"] = { std = "lua52" }
files["module/globals.lua"] = { globals = { "ctronv2_rt" } }
files["**/test/game/**/*.lua"] = { std = "lua52+factorio", read_globals = { "ue_rt", "ctronv2_rt" } }
files["test/no_cc/**/*.lua"] = { std = "lua52+factorio", read_globals = { "ctronv2_rt" } }
files["test/preview/**/*.lua"] = { std = "lua52+factorio" }
