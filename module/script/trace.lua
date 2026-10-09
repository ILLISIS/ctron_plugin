-- The plugin's log lines (Constructron v2 spec §11): instance.ts logs each as "<op> <phase>", fields at the top level.
local clusterio_api = require("modules/clusterio/api")

local trace = {}

--- send(op, phase, level, job, fields): every line carries the job's key, its worker's unit number (fields.worker when
--- the worker is gone) and the tick. fields is a fresh table; it is sent as it is, with those added.
function trace.send(op, phase, level, job, fields)
	local out = fields or {}
	local w = job.worker
	out.op, out.phase, out.level, out.tick, out.job = op, phase, level, game.tick, job.key
	out.worker = out.worker or (w and w.valid and w.unit_number) or nil
	clusterio_api.send_json("ctron_plugin:trace", out)
end

return trace
