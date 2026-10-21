local t = require("testlib")
local core = require("modules/ctron_pluginv2/status_core")

--- Every "section.key" in a locale .cfg file, as a set.
local function keys(path)
	local out, section = {}, nil
	for line in assert(io.open(path)):lines() do
		local s = string.match(line, "^%[([%w_%-]+)%]")
		if s then
			section = s
		else
			local k = string.match(line, "^([%w_%-]+)=")
			if k and section then
				out[section .. "." .. k] = true
			end
		end
	end
	return out
end

-- CC's English locale, from the checkout buildCcZipFor archives (devcluster/src/build.ts); v2.1.0's locale is the
-- working copy's. The runner's cwd is the plugin directory.
local CC = (os.getenv("V2_CC_REPO") or (os.getenv("HOME") .. "/F21/mods/Constructron-Continued")) .. "/locale/en/locale.cfg"
local known = keys(CC)
for k in pairs(keys("module/locale/en/ctronv2.cfg")) do
	known[k] = true
end

t.test("every status code of spec §8.7 has a severity with an icon and a key in CC's or the module's locale", function()
	local n = 0
	for code in pairs(core.CODES) do
		local info = core.info(code)
		t.expect_true(info ~= nil, code)
		t.expect_true(core.ICONS[info.sev] ~= nil, code .. ": severity " .. tostring(info.sev))
		t.expect_true(known[info.key], code .. ": key " .. info.key .. " is in no locale file")
		n = n + 1
	end
	t.expect_eq(n, 42, "codes")
end)

t.test("working names the kind's CC key and cargo keeps job_type_working; an unknown code has no info", function()
	t.expect_eq(core.info("working", "deconstruction").key, "ctron_status.job_type_deconstruction")
	t.expect_eq(core.info("working", "cargo").key, "ctron_status.job_type_working")
	t.expect_eq(core.info("working").key, "ctron_status.job_type_working")
	for _, kind in ipairs({ "construction", "deconstruction", "upgrade", "repair", "destroy" }) do
		t.expect_true(known[core.info("working", kind).key], kind)
	end
	t.expect_eq(core.info("nope"), nil)
end)
