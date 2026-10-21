-- ctron_pluginv2's RCON entry point (spec §3, §5.1, §9.1): seams for game tests and E2Es.
-- Messages normally travel on UE's bridge.
local ct = require("modules/ctron_pluginv2/ct")

ctronv2_rt = {
	--- /sc rcon.print(ctronv2_rt.state()): each storage table's entry count, as JSON; "{}" without CC (no storage).
	state = function()
		local out = {}
		for name, value in pairs(storage.ctron_pluginv2 or {}) do
			if type(value) == "table" then
				out[name] = table_size(value)
			end
		end
		return helpers.table_to_json(out)
	end,
	--- /sc ctronv2_rt.call("runs", "records"): a module's seam (module by its ct name, R-136), for game tests and E2Es.
	--- Returns every result of the seam, and prints the first as {"result": ...} for an RCON caller. An unknown module
	--- or function raises.
	call = function(module, fn, ...)
		local m = ct[module]
		if not (m and m[fn]) then
			error("ctronv2_rt.call: no seam ct." .. tostring(module) .. "." .. tostring(fn))
		end
		local results = table.pack(m[fn](...))
		local ok, json = pcall(helpers.table_to_json, { result = results[1] })
		rcon.print(ok and json or '{"result":"unencodable"}')
		return table.unpack(results, 1, results.n)
	end,
}
