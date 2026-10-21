-- The tile's settings (spec §4.6, §5.10): CC's defaults from prototypes, the controller's overrides from ct.settings,
-- and the effective settings per surface name, cached until the next apply (R-43). Also the prototype lookups the
-- shells share. Nothing here runs per tick.
local core = require("modules/ctron_pluginv2/settings_core")
local ct = require("modules/ctron_pluginv2/ct")
local bridge = require("modules/ctron_pluginv2/bridge")

local settings = { events = {} }

local function S()
	return storage.ctron_pluginv2
end

--- stacks[item name] → stack size, 1 for a name with no item prototype. Prototypes only, so every peer agrees.
settings.stacks = setmetatable({}, {
	__index = function(t, name)
		local proto = prototypes.item[name]
		local size = proto and proto.stack_size or 1
		rawset(t, name, size)
		return size
	end,
})

--- allowed[item name] → CC's recipe filter (control.lua:259-268): a product of a non-hidden recipe, an autoplace
--- resource, or one of three exceptions. The prototype's hidden flag, never the force's recipe, so the answer can't
--- depend on when it was first asked.
settings.allowed = setmetatable({ ["raw-fish"] = true, wood = true, ["depleted-uranium-fuel-cell"] = true }, {
	__index = function(t, name)
		local ok = false
		local recipes = prototypes.get_recipe_filtered({
			{ filter = "has-product-item", elem_filters = { { filter = "name", name = name } } },
		})
		for _, recipe in pairs(recipes) do
			if recipe.hidden == false then
				ok = true
				break
			end
		end
		if not ok then
			local entity = prototypes.entity[name]
			ok = entity ~= nil and entity.autoplace_specification ~= nil
				and entity.mineable_properties.products ~= nil
		end
		rawset(t, name, ok)
		return ok
	end,
})

local valid -- the name sets for validation, built once

local function names()
	if valid then
		return valid
	end
	valid = { robot = {}, repair_tool = {}, ammo = {}, quality = {} }
	for name in pairs(prototypes.get_item_filtered({
		{ filter = "place-result", elem_filters = { { filter = "type", type = "construction-robot" } } },
	})) do
		valid.robot[name] = true
	end
	for name in pairs(prototypes.get_item_filtered({ { filter = "type", type = "repair-tool" } })) do
		valid.repair_tool[name] = true
	end
	for name, proto in pairs(prototypes.get_item_filtered({ { filter = "type", type = "ammo" } })) do
		if proto.ammo_category.name == "rocket" then
			valid.ammo[name] = true
		end
	end
	for name in pairs(prototypes.quality) do
		valid.quality[name] = true
	end
	return valid
end

--- The smallest name in set by <, so every peer picks the same one.
local function first(set)
	local best
	for name in pairs(set) do
		if not best or name < best then
			best = name
		end
	end
	return best
end

--- CC's defaults (control.lua:137-232). `want` if it is in set, else the first of set.
local function compute_defaults()
	local v = names()
	local function pick(want, set)
		return { v[set][want] and want or first(v[set]), "normal" }
	end
	local d = {
		job_start_delay = 300, debug = false,
		kinds = { construction = true, rebuild = true, deconstruction = true, upgrade = true, repair = true,
			destroy = false },
		horde = false, zone_restriction = false,
		robot = pick("construction-robot", "robot"), robot_count = 50,
		repair_tool = pick("repair-pack", "repair_tool"),
		ammo = pick("rocket", "ammo"), ammo_count = 0,
		atomic_count = 0, min_cluster = 8, minions = 1,
	}
	-- Only if the item exists (fixes 00 N15).
	if prototypes.item["atomic-bomb"] then
		d.atomic = { "atomic-bomb", "normal" }
	end
	return d
end

local function refresh()
	local st = S().settings
	st.global = core.global(st.defaults, st.overrides)
	st.effective = {}
end

local function start()
	local st = S().settings
	st.defaults = compute_defaults()
	st.overrides = st.overrides or {}
	refresh()
end

settings.on_init = start
settings.on_server_startup = start

--- The stored settings table, or nil before storage or defaults exist.
local function stored()
	local s = S()
	local st = s and s.settings
	return st and st.defaults and st.defaults.job_start_delay and st
end

local no_storage -- compute_defaults() for a read before storage exists, built once

function settings.defaults()
	local st = stored()
	if st then
		return st.defaults
	end
	no_storage = no_storage or compute_defaults()
	return no_storage
end

function settings.global()
	local st = stored()
	if st and st.global then
		return st.global
	end
	local d = settings.defaults()
	return { job_start_delay = d.job_start_delay, debug = d.debug }
end

--- The effective settings of the surface named `surface`; read-only for every caller.
function settings.of(surface)
	local st = stored()
	if not st then
		return settings.defaults()
	end
	local eff = st.effective[surface]
	if not eff then
		eff = core.effective(st.defaults, st.overrides, surface, names())
		st.effective[surface] = eff
	end
	return eff
end

--- msg is ct.settings' payload { overrides, surfaces }.
function settings.apply(msg)
	local st = S().settings
	local old = {}
	for _, surface in pairs(game.surfaces) do
		old[surface.name] = settings.of(surface.name)
	end
	st.overrides = msg.overrides or {}
	refresh()
	ct.discovery.set_schedulable(msg.surfaces or {})
	for name, was in pairs(old) do
		for _, kind in ipairs(core.turned_off(was, settings.of(name))) do
			ct.discovery.clear({ surface = name, kind = kind })
			ct.runs.cancel_kind(name, kind)
		end
	end
	ct.gui.on_settings()
end

bridge.on("ct.settings", function(payload)
	if type(payload.overrides) ~= "table" then
		return false
	end
	settings.apply(payload)
end)

settings.events[defines.events.on_pre_surface_deleted] = function(event)
	local st = stored()
	local surface = game.get_surface(event.surface_index)
	if st and surface then
		st.effective[surface.name] = nil
	end
end

return settings
