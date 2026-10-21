import { test } from "node:test";
import assert from "node:assert/strict";
import { effective, kindsOff, merge, schedulerView, validate, type Full } from "../../cluster/settings.js";

const DEFAULTS: Full = {
	job_start_delay: 300, debug: false, horde: false, zone_restriction: false, robot: ["construction-robot", "normal"],
	robot_count: 50, repair_tool: ["repair-pack", "normal"], ammo: ["rocket", "normal"], ammo_count: 0,
	atomic: ["atomic-bomb", "normal"], atomic_count: 0, min_cluster: 8, minions: 1,
	kinds: { construction: true, rebuild: true, deconstruction: true, upgrade: true, repair: true, destroy: false },
};

test("validate: global keys only without a surface, surface keys only with one; CC's caps clamp (§4.6)", () => {
	assert.deepEqual(validate(undefined, { job_start_delay: -5, horde: true }),
		{ patch: { job_start_delay: 0 }, dropped: ["horde"] });
	assert.deepEqual(validate("nauvis", { debug: true, robot_count: 20000, min_cluster: 0, minions: 3 }),
		{ patch: { robot_count: 10000, min_cluster: 1, minions: 3 }, dropped: ["debug"] });
	assert.deepEqual(validate("*", { ammo_count: 9000, atomic_count: 1001, kinds: { destroy: true } }),
		{ patch: { ammo_count: 8000, atomic_count: 1000, kinds: { destroy: true } }, dropped: [] });
});

test("merge: a surface patch, the global keys under '*', kinds merged per key; the input untouched", () => {
	const before = { nauvis: { horde: true, kinds: { repair: false } } };
	const after = merge(before, "nauvis", { minions: 2, kinds: { upgrade: false } });
	assert.deepEqual(after, { nauvis: { horde: true, minions: 2, kinds: { repair: false, upgrade: false } } });
	assert.deepEqual(before, { nauvis: { horde: true, kinds: { repair: false } } });
	assert.deepEqual(merge({}, undefined, { debug: true }), { "*": { debug: true } });
});

test("merge: '*' overwrites every surface's override of its keys and drops emptied surfaces (X-12, R-68)", () => {
	const before = {
		"*": { debug: true },
		nauvis: { minions: 4, horde: true, kinds: { destroy: false, repair: false } },
		gleba: { minions: 2 },
	};
	assert.deepEqual(merge(before, "*", { minions: 3, kinds: { destroy: true } }), {
		"*": { debug: true, minions: 3, kinds: { destroy: true } },
		nauvis: { horde: true, kinds: { repair: false } },
	});
});

test("effective: defaults ⊕ '*' ⊕ the surface, kinds per key (§4.6)", () => {
	const over = { "*": { minions: 3, kinds: { destroy: true } }, nauvis: { kinds: { repair: false } } };
	const nauvis = effective(DEFAULTS, over, "nauvis");
	assert.equal(nauvis.minions, 3);
	assert.deepEqual(nauvis.kinds, { ...DEFAULTS.kinds, repair: false, destroy: true });
	assert.deepEqual(effective(DEFAULTS, over, "gleba").kinds, { ...DEFAULTS.kinds, destroy: true });
	assert.equal(DEFAULTS.kinds.destroy, false, "defaults untouched");
});

test("kindsOff: the [surface, kind] pairs an edit turned off; rebuild only stops discovery (§5.10, §6.11)", () => {
	const surfaces = ["nauvis", "gleba"];
	assert.deepEqual(kindsOff(DEFAULTS, {}, { nauvis: { kinds: { upgrade: false } } }, surfaces),
		[["nauvis", "upgrade"]]);
	assert.deepEqual(kindsOff(DEFAULTS, {}, { "*": { kinds: { deconstruction: false } } }, surfaces),
		[["nauvis", "deconstruction"], ["gleba", "deconstruction"]]);
	assert.deepEqual(kindsOff(DEFAULTS, {}, { "*": { kinds: { rebuild: false } } }, surfaces), []);
	assert.deepEqual(kindsOff(DEFAULTS, { nauvis: { kinds: { repair: false } } }, {}, surfaces), [], "turned on");
});

test("schedulerView: horde, minions and atomic; CC's values before any tile sent defaults", () => {
	assert.deepEqual(schedulerView(undefined, { nauvis: { minions: 5 } }, "nauvis"),
		{ horde: false, minions: 1, atomic: undefined });
	assert.deepEqual(schedulerView(DEFAULTS, { nauvis: { minions: 5, horde: true } }, "nauvis"),
		{ horde: true, minions: 5, atomic: ["atomic-bomb", "normal"] });
	const over = { "*": { atomic: ["x-bomb", "rare"] as [string, string] } };
	assert.deepEqual(schedulerView(DEFAULTS, over, "nauvis").atomic, ["x-bomb", "rare"]);
	const none = { ...DEFAULTS, atomic: undefined };
	assert.equal(schedulerView(none, {}, "nauvis").atomic, undefined, "a tile with no atomic item");
});
