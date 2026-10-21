-- Pure settings logic (spec §4.6, §5.10): effective = defaults ⊕ overrides["*"] ⊕ overrides[surface]. Each layer
-- applies only valid values, so an invalid item name or a bad type falls back to the layer below (R-43). The global
-- keys count only under "*". The controller computes the same merge (cluster/settings.ts).
local core = {}

core.KINDS = { "construction", "rebuild", "deconstruction", "upgrade", "repair", "destroy" }
-- Turning these off clears their cells and cancels their runs; rebuild off only stops discovery (CC ui.lua:701-719).
local CLEARS = { construction = true, deconstruction = true, upgrade = true, repair = true, destroy = true }
local BOOLS = { "horde", "zone_restriction" }
-- CC's caps (ui.lua:726-842).
local INTS = {
	robot_count = { 0, 10000 }, ammo_count = { 0, 8000 }, atomic_count = { 0, 1000 }, min_cluster = { 1, 100 },
	minions = { 0, 100 },
}
-- Each item key and the name set it must be in.
local ITEMS = { robot = "robot", repair_tool = "repair_tool", ammo = "ammo", atomic = "ammo" }

local function copy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in pairs(v) do
		out[k] = copy(x)
	end
	return out
end

local function layer(eff, patch, valid, globals)
	if type(patch) ~= "table" then
		return
	end
	if globals then
		if type(patch.job_start_delay) == "number" then
			eff.job_start_delay = math.max(0, math.floor(patch.job_start_delay))
		end
		if type(patch.debug) == "boolean" then
			eff.debug = patch.debug
		end
	end
	if type(patch.kinds) == "table" then
		for _, k in ipairs(core.KINDS) do
			if type(patch.kinds[k]) == "boolean" then
				eff.kinds[k] = patch.kinds[k]
			end
		end
	end
	for _, k in ipairs(BOOLS) do
		if type(patch[k]) == "boolean" then
			eff[k] = patch[k]
		end
	end
	for k, range in pairs(INTS) do
		if type(patch[k]) == "number" then
			eff[k] = math.max(range[1], math.min(range[2], math.floor(patch[k])))
		end
	end
	for k, set in pairs(ITEMS) do
		local v = patch[k]
		if type(v) == "table" and type(v[1]) == "string" and valid[set][v[1]] and valid.quality[v[2] or "normal"] then
			eff[k] = { v[1], v[2] or "normal" }
		end
	end
end

--- The effective settings of surface (a fresh table); surface nil gives the "*" view.
function core.effective(defaults, overrides, surface, valid)
	local eff = copy(defaults)
	overrides = overrides or {}
	layer(eff, overrides["*"], valid, true)
	if surface then
		layer(eff, overrides[surface], valid, false)
	end
	return eff
end

--- The global settings, { job_start_delay (ticks, ≥ 0), debug }.
function core.global(defaults, overrides)
	local eff = { job_start_delay = defaults.job_start_delay, debug = defaults.debug, kinds = {} }
	layer(eff, overrides and overrides["*"], { robot = {}, repair_tool = {}, ammo = {}, quality = {} }, true)
	return { job_start_delay = eff.job_start_delay, debug = eff.debug }
end

--- The kinds on in old and off in new whose cells are cleared and runs cancelled, in core.KINDS order.
function core.turned_off(old, new)
	local off = {}
	for _, k in ipairs(core.KINDS) do
		if CLEARS[k] and old.kinds[k] and not new.kinds[k] then
			off[#off + 1] = k
		end
	end
	return off
end

return core
