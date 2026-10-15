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
files["**/module/**/*_core.lua"] = { std = "lua52" }
files["**/test/game/**/*.lua"] = { std = "lua52+factorio", read_globals = { "ctron_plugin_on_job_claimed" } }
-- module/ is a fork of Constructron-Continued's runtime (Constructron v2 spec §9.1), kept as CC writes it so each
-- re-sync is a plain diff: luacheck checks only its syntax. This plugin's own files in it are linted in full.
files["module/**/*.lua"] = { ignore = { "." } }
for _, name in ipairs({ "border_core", "border", "crossing", "trace" }) do
	files["module/script/" .. name .. ".lua"] = { enable = { "." } }
end
files["test/no_cc/**/*.lua"] = { std = "lua52+factorio" }
-- G6 and G11 claim a job through the module's RCON entry point (spec §12).
for _, name in ipairs({ "pool", "cargo" }) do
	files["test/game/" .. name .. "_game_test.lua"] = { read_globals = { "ctron_plugin_on_job_claimed" } }
end
