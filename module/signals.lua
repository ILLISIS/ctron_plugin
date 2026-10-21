-- Station signals (spec §5.11, R-47): one hidden ctron-combinator per surface on this tile, wired red and green to every
-- station, outputting signal-C = ctrons registered here on the surface and signal-A = the idle ones. Counts are this
-- tile's. Rewritten by report's flush only when a ctron record changed, and then only if a count did.
local ct = require("modules/ctron_pluginv2/ct")

local signals = { events = {} }

local function S()
	return storage.ctron_pluginv2
end

local function connect(c, station)
	for _, id in ipairs({ defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green }) do
		c.get_wire_connector(id, true).connect_to(station.get_wire_connector(id, true), false)
	end
end

--- The surface's combinator; made next to `near` (a station entity) when missing and near is given.
local function combinator(surface, near)
	local s = S().signals
	local rec = s[surface.name]
	if rec and rec.entity.valid then
		return rec.entity
	end
	if not near then
		return nil
	end
	local c = surface.create_entity({ name = "ctron-combinator",
		position = { near.position.x + 1, near.position.y + 1 }, direction = defines.direction.west,
		force = near.force })
	if not c then
		return nil
	end
	s[surface.name] = { entity = c, c = -1, a = -1 }
	for _, sid in ipairs(ct.registry.stations_on(surface.name)) do
		connect(c, ct.registry.station(sid).entity)
	end
	return c
end

function signals.wire(station)
	local c = combinator(station.surface, station)
	if c then
		connect(c, station)
	end
end

local function write(entity, c, a)
	local cb = entity.get_or_create_control_behavior()
	local section = cb.get_section(1) or cb.add_section()
	section.filters = {
		{ value = { type = "virtual", name = "signal-C", quality = "normal" }, min = c },
		{ value = { type = "virtual", name = "signal-A", quality = "normal" }, min = a },
	}
end

function signals.flush()
	local s = S()
	local counts = {}
	for _, rec in pairs(s.ctrons) do
		if rec.entity.valid then
			local n = rec.entity.surface.name
			local k = counts[n] or { c = 0, a = 0 }
			counts[n] = k
			k.c = k.c + 1
			if rec.state == "idle" then
				k.a = k.a + 1
			end
		end
	end
	for name, rec in pairs(s.signals) do
		local surface = game.get_surface(name)
		if surface then
			if not rec.entity.valid then
				local sid = ct.registry.stations_on(name)[1]
				if sid then
					combinator(surface, ct.registry.station(sid).entity)
					rec = s.signals[name]
				end
			end
			local k = counts[name] or { c = 0, a = 0 }
			if rec.entity.valid and (rec.c ~= k.c or rec.a ~= k.a) then
				write(rec.entity, k.c, k.a)
				rec.c, rec.a = k.c, k.a
			end
		end
	end
end

-- CC destroys cloned combinators: one per surface.
signals.events[defines.events.on_entity_cloned] = function(event)
	local d = event.destination
	if d and d.valid and d.name == "ctron-combinator" then
		d.destroy()
	end
end

signals.events[defines.events.on_pre_surface_deleted] = function(event)
	local s = S()
	local surface = s and game.get_surface(event.surface_index)
	if surface then
		s.signals[surface.name] = nil
	end
end

return signals
