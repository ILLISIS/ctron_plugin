import { test } from "node:test";
import assert from "node:assert/strict";
import { INFLIGHT_HOLD_MS, inflight, itemKey, order } from "../../cluster/cargo.js";

const none = new Map<string, number>();

test("order: nothing until some slot has count + inflight ≤ min (CC cargo.lua:33-34)", () => {
	assert.deepEqual(order([["iron-plate", "normal", 100, 400, 101, 100]], none), []);
	assert.deepEqual(order([["iron-plate", "normal", 100, 400, 100, 100]], none), [["iron-plate", "normal", 300, 100]]);
});

test("order: every slot below max tops up to max, the trigger item too (CC asks the full max) (R-58)", () => {
	const slots: Parameters<typeof order>[0] = [
		["iron-plate", "normal", 100, 400, 50, 100], // the trigger: 350
		["copper-plate", "normal", 10, 200, 150, 100], // above min, below max: 50
		["steel-plate", "normal", 0, 100, 100, 100], // at max: nothing
	];
	assert.deepEqual(order(slots, none), [["iron-plate", "normal", 350, 100], ["copper-plate", "normal", 50, 100]]);
});

test("order: inflight counts as delivered, so no second order while a load is on the way (§6.6)", () => {
	const slots: Parameters<typeof order>[0] = [["iron-plate", "normal", 100, 400, 50, 100]];
	assert.deepEqual(order(slots, new Map([[itemKey("iron-plate", "normal"), 350]])), [], "50 + 350 > min");
	assert.deepEqual(order(slots, new Map([[itemKey("iron-plate", "normal"), 40]])),

		[["iron-plate", "normal", 310, 100]]);
	assert.deepEqual(order(slots, new Map([[itemKey("iron-plate", "rare"), 400]])),
		[["iron-plate", "normal", 350, 100]], "another quality doesn't count");
});

test("inflight: live loads plus held loads until their release time (R-58)", () => {
	const live = [[["iron-plate", "normal", 100, 100]], [["iron-plate", "normal", 50]]] as
		Parameters<typeof inflight>[0];
	const now = 1_000_000;
	const held: Parameters<typeof inflight>[1] = [
		["iron-plate", "normal", 25, now + 1], ["iron-plate", "normal", 1000, now],
		["coal", "normal", 7, now + INFLIGHT_HOLD_MS],
	];
	const m = inflight(live, held, now);
	assert.equal(m.get(itemKey("iron-plate", "normal")), 175,
		"100 + 50 live, 25 held; the one released at now is gone");
	assert.equal(m.get(itemKey("coal", "normal")), 7);
	assert.ok(INFLIGHT_HOLD_MS === 30_000 || INFLIGHT_HOLD_MS === 60_000);
});
