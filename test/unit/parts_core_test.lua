local t = require("testlib")
local core = require("modules/ctron_pluginv2/parts_core")

-- Records are their own encoding here: strings of a chosen length.
local function encode(r)
	return r
end

t.test("every part stays within the budget, and the records keep their order", function()
	local records = {}
	for i = 1, 40 do
		records[i] = tostring(i) .. string.rep("x", i % 13)
	end
	local parts, flat = core.pack(records, encode, 50), {}
	for _, part in ipairs(parts) do
		local used = 0
		for _, r in ipairs(part) do
			used = used + #r + 1
			flat[#flat + 1] = r
		end
		t.expect_true(used <= 50, "a part of " .. used .. " bytes")
	end
	t.expect_same(flat, records)
end)

t.test("a record larger than the budget goes alone in its part", function()
	local big = string.rep("b", 80)
	local parts = core.pack({ string.rep("a", 5), big, string.rep("c", 5) }, encode, 50)
	t.expect_eq(#parts, 3)
	t.expect_eq(#parts[2], 1)
	t.expect_eq(parts[2][1], big, "the record is unsplit")
end)

t.test("a part closes only when the next record wouldn't fit; no records, no parts; the default budget", function()
	local twenty = string.rep("x", 20)
	local parts = core.pack({ twenty, twenty, twenty }, encode, 50) -- 21 + 21 = 42 fits; a third 21 doesn't
	t.expect_eq(#parts, 2)
	t.expect_eq(#parts[1], 2)
	t.expect_eq(#core.pack({}, encode, 50), 0)
	t.expect_eq(core.BUDGET, 2500)
end)
