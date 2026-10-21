-- Packing records into message parts (spec §9.1, R-125), pure: every up message but ct.portals must encode under
-- 3,900 bytes, because a longer one goes through Clusterio's file path and later lines overtake it.
local core = {}

--- Record bytes per part: contracts.ts's PART_BUDGET. The rest of 3,900 is the envelope's, and part 1's defaults.
core.BUDGET = 2500

--- records split into parts, in order: each part's sum of (#encode(r) + 1) stays within budget (default BUDGET), except
--- that a record larger than the budget goes alone in its part. encode(r) returns r's encoding (helpers.table_to_json
--- in the game; the caller counts rm ids the same way). Returns { { r, ... }, ... }; no records, no parts.
function core.pack(records, encode, budget)
	budget = budget or core.BUDGET
	local parts, part, used = {}, nil, 0
	for _, r in ipairs(records) do
		local size = #encode(r) + 1
		if part == nil or used + size > budget then
			part, used = {}, 0
			parts[#parts + 1] = part
		end
		part[#part + 1] = r
		used = used + size
	end
	return parts
end

return core
