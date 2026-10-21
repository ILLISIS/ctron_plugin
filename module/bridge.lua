-- ctron_pluginv2's end of UE's bridge (spec §9.1). Every module sends here and registers its down-message handlers
-- here, at load. The SP-1 fallback needs nothing more: it delivers through UE's own ue_rt.inbox (R-159).
local ue = require("modules/universal_edges")

local CHANNEL = "ctron_pluginv2"
local bridge = {}

--- send(type, payload) on the plugin's channel: UE queues it in storage and flushes it at the end of the tick.
bridge.send = ue.runtime.bridge.channel(CHANNEL)

--- Register fn(payload) for down messages of msg_type, while loading (UE raises at run time). A second registration
--- of a type replaces the first: each down type has one owner (spec §5.1).
function bridge.on(msg_type, fn)
	ue.runtime.bridge.on(CHANNEL, msg_type, fn)
end

return bridge
