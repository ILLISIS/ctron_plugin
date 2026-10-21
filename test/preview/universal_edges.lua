-- The preview's stand-in for UE's save module: no scheduler, no bridge traffic, handlers kept for control.lua to call.
local handlers = {}
return {
	handlers = handlers,
	runtime = {
		scheduler = { periodic = function() end },
		bridge = {
			channel = function() return function() end end,
			on = function(_, msg_type, fn) handlers[msg_type] = fn end,
		},
	},
}
