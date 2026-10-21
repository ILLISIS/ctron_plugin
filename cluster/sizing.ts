import type { Static } from "@sinclair/typebox";
import type { Item } from "../contracts.js";

// Spec §6.4: how much of a cell's remaining work one ctron carries, with no copies (R-53, R-54, R-55). Pure.

export type ItemT = Static<typeof Item>;

/** CC's margin (`job.lua:231`): a split share leaves 5 slots free. */
export const MARGIN = 5;
/** R-55: a merged cell's centre lies within this many tiles of the first cell's centre. */
export const MERGE_RADIUS = 160;
/** R-55: the encoded `ct.job.assign` stays under this many bytes (the down limit is 3 KB, R-15). */
export const ASSIGN_BYTES = 2500;

/** What a share or a remainder carries: items to bring (with stack sizes) and trash slots to take out. */
export interface Amount { bring: ItemT[]; out: number }

/** The item with another count; `stack` stays only when the input had one (a JSON null would reach Lua). */
export function withCount(item: ItemT, count: number): ItemT {
	return item.length === 4 ? [item[0], item[1], count, item[3]] : [item[0], item[1], count];
}

/** Σ ceil(count / stack) per (name, quality) (CC `utility_functions.lua:84-99`); a missing stack counts 1 per item. */
export function slots(items: ItemT[]): number {
	const totals = new Map<string, { count: number; stack: number }>();
	for (const item of items) {
		const key = `${item[0]}\u0000${item[1]}`;
		const t = totals.get(key);
		if (t) {
			t.count += item[2];
		} else {
			totals.set(key, { count: item[2], stack: item[3] ?? 1 });
		}
	}
	let n = 0;
	for (const t of totals.values()) {
		n += Math.ceil(t.count / t.stack);
	}
	return n;
}

export function need(a: Amount): number {
	return slots(a.bring) + a.out;
}

/** §6.4 (R-53): the part of `rem` a ctron with `free` empty slots carries, or null when nothing fits. */
export function size(rem: Amount, free: number): Amount | null {
	const total = need(rem);
	if (total <= free) {
		return { bring: rem.bring.map(i => withCount(i, i[2])), out: rem.out };
	}
	const budget = free - MARGIN;
	if (budget <= 0) {
		return null;
	}
	const orig = new Map<ItemT, ItemT>(); // share entry -> the remainder entry it came from
	const bring = rem.bring.map(i => {
		const s = withCount(i, Math.ceil(i[2] * budget / total));
		orig.set(s, i);
		return s;
	});
	const out = Math.floor(rem.out * budget / total);
	while (bring.length > 0 && slots(bring) + out > budget) {
		let smallest = 0;
		for (let i = 1; i < bring.length; i++) {
			if (bring[i][2] < bring[smallest][2]) {
				smallest = i;
			}
		}
		bring.splice(smallest, 1);
	}
	// fill each kept kind to the slots it already uses, so the long tail of part-full slots doesn't need more trips
	const full = bring.map(s => {
		const stack = s[3] ?? 1;
		return withCount(s, Math.min(orig.get(s)![2], Math.ceil(s[2] / stack) * stack));
	});
	return full.length === 0 && out === 0 ? null : { bring: full, out };
}

/** A cell that may join a plan whole: its remaining amount and the bytes its `work` entry adds to the assign. */
export interface MergeCandidate { wid: string; x: number; y: number; rem: Amount; bytes: number }

/**
 * §6.4 (R-55): the candidates to add whole, in order, while each fits the slots and bytes left; a misfit is skipped,
 * not a stop. The caller passes only open cells of the first cell's kind and owner, oldest first, not yet taken.
 */
export function mergeable(
	x: number, y: number, candidates: MergeCandidate[], slotsLeft: number, bytesLeft: number,
): MergeCandidate[] {
	const picked: MergeCandidate[] = [];
	for (const c of candidates) {
		const n = need(c.rem);
		if (Math.hypot(c.x - x, c.y - y) > MERGE_RADIUS || n > slotsLeft || c.bytes > bytesLeft) {
			continue;
		}
		picked.push(c);
		slotsLeft -= n;
		bytesLeft -= c.bytes;
	}
	return picked;
}
