import { test } from "node:test";
import assert from "node:assert/strict";
import {
	MARGIN, mergeable, need, size, slots, withCount, type Amount, type MergeCandidate,
} from "../../cluster/sizing.js";

test("slots: ceil(count / stack) per (name, quality); qualities apart; no stack counts 1 per item (§6.4)", () => {
	assert.equal(slots([["iron-plate", "normal", 150, 100], ["iron-plate", "rare", 1, 100]]), 3);
	assert.equal(slots([["gear", "normal", 60, 100], ["gear", "normal", 60, 100]]), 2, "one key, 120 items");
	assert.equal(slots([["rail", "normal", 3]]), 3);
	assert.equal(slots([]), 0);
});

test("size: the whole remainder when need ≤ free, as a copy (CC's whole-fit check)", () => {
	const rem: Amount = { bring: [["iron-plate", "normal", 200, 100]], out: 3 };
	const share = size(rem, 5)!;
	assert.deepEqual(share, rem);
	share.bring[0][2] = 1;
	assert.equal(rem.bring[0][2], 200, "the remainder is not mutated");
	assert.deepEqual(size({ bring: [], out: 0 }, 0), { bring: [], out: 0 }, "an itemless remainder fits whole");
});

test("size: proportional with a margin of 5 when it doesn't fit (R-53)", () => {
	assert.deepEqual(size({ bring: [["stone", "normal", 5000, 50]], out: 0 }, 30),
		{ bring: [["stone", "normal", 1250, 50]], out: 0 }, "b = 25, r = 0.25");
	assert.deepEqual(size({ bring: [], out: 100 }, 45), { bring: [], out: 40 });
	assert.deepEqual(size({ bring: [["iron-plate", "normal", 1000, 100]], out: 90 }, 55),
		{ bring: [["iron-plate", "normal", 500, 100]], out: 45 }, "need 100, b 50, r 0.5");
});

test("size: drops the smallest kinds until it fits, even below the kind count (B4)", () => {
	const rem: Amount = { bring: [["a", "normal", 10, 1], ["b", "normal", 2, 1], ["c", "normal", 30, 1]], out: 0 };
	assert.deepEqual(size(rem, 15), { bring: [["c", "normal", 8, 1]], out: 0 }, "3+1+8 = 12 > 10: drop b, then a");
	assert.deepEqual(size(rem, 6), { bring: [["c", "normal", 1, 1]], out: 0 }, "b = 1: one kind of one item");
});

test("size: a split fills each kept kind to its slots, so there is no long tail of trips (M1)", () => {
	const rem: Amount = {
		bring: Array.from({ length: 30 }, (_, i) => [`k${i}`, "normal", 40, 50] as [string, string, number, number]),
		out: 0,
	};
	let left = rem;
	let shares = 0;
	while (left.bring.length > 0 && shares < 20) {
		const share = size(left, 20)!;
		assert.ok(need(share) <= 15, "slots within the budget");
		const taken = new Map(share.bring.map(i => [i[0], i[2]]));
		const bring = left.bring.map(i => withCount(i, i[2] - (taken.get(i[0]) ?? 0)));
		left = { bring: bring.filter(i => i[2] > 0), out: 0 };
		shares += 1;
	}
	assert.equal(shares, 2, "was 11");
});

test("size: empty when the budget is ≤ 0 (R-53 step 4)", () => {
	const rem: Amount = { bring: [["a", "normal", 6, 1]], out: 0 };
	assert.equal(size(rem, 5), null);
	assert.equal(size(rem, 3), null);
	assert.equal(size({ bring: [], out: 0 }, -1), null, "a ctron whose restock overfills its trunk carries nothing");
});

test("mergeable: whole cells within 160 tiles while slots and bytes last, oldest first, skip misfits (R-55)", () => {
	const c = (wid: string, x: number, y: number, n: number, bytes = 100): MergeCandidate => (
		{ wid, x, y, rem: { bring: [], out: n }, bytes }
	);
	const picked = mergeable(0, 0, [
		c("near", 100, 100, 4), c("far", 200, 0, 1), c("big", 10, 10, 50), c("fits", 0, 160, 5), c("fat", 1, 1, 1, 900),
		c("last", 5, 5, 2),
	], 10, 1000);
	assert.deepEqual(picked.map(p => p.wid), ["near", "fits"],
		"far: 200 > 160; big: 50 > 6; fat: 900 > 800; last: 2 > 1");
	assert.equal(need(picked[0].rem), 4);
});

test("size: multiply before dividing, so float noise can't drop a kind that fits (25 at stack 1, free 12)", () => {
	assert.deepEqual(size({ bring: [["a", "normal", 25, 1]], out: 0 }, 12), { bring: [["a", "normal", 7, 1]], out: 0 });
});

test("size: any returned share fits within free - MARGIN", () => {
	for (let count = 1; count <= 60; count++) {
		for (const stack of [1, 10, 50]) {
			for (let free = 0; free <= 70; free++) {
				const bring: Amount["bring"] = [["a", "normal", count, stack], ["b", "normal", count + 3, 1]];
				const rem: Amount = { bring, out: count % 7 };
				const share = size(rem, free);
				if (need(rem) <= free) {
					assert.deepEqual(share, rem);
				} else if (share) {
					assert.ok(need(share) <= free - MARGIN, `count ${count} stack ${stack} free ${free}`);
				}
			}
		}
	}
});
