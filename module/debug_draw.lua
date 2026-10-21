-- Debug drawing (spec §5.11; CC's debug_lib.lua): status text above ctrons, job areas and task points, path lines.
-- Every call returns at once while the debug setting is off.
local ct = require("modules/ctron_pluginv2/ct")

local draw = {}
local TTL = 600 -- ponytail: ten seconds on screen; tune it if debug drawing clutters

local function on()
	return ct.settings.global().debug
end

--- msg (a LocalisedString) above entity.
function draw.text(entity, msg)
	if not (on() and entity.valid) then
		return
	end
	rendering.draw_text({ text = msg, surface = entity.surface, target = { entity = entity, offset = { 0, -3 } },
		color = { 1, 1, 1 }, alignment = "center", time_to_live = TTL })
end

--- A line through points ({ x, y } tables) on surface.
function draw.path(surface, points)
	if not on() then
		return
	end
	for i = 2, #points do
		rendering.draw_line({ surface = surface, from = points[i - 1], to = points[i], color = { 0, 1, 0 }, width = 2,
			time_to_live = TTL })
	end
end

--- The outline of area ({ left_top, right_bottom }) on surface.
function draw.area(surface, area, color)
	if not on() then
		return
	end
	rendering.draw_rectangle({ surface = surface, left_top = area.left_top, right_bottom = area.right_bottom,
		color = color or { 0, 0.5, 1 }, width = 2, time_to_live = TTL })
end

return draw
