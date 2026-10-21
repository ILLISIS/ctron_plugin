import type { Static } from "@sinclair/typebox";
import type { NeedSlot } from "../contracts.js";
import type { ItemT } from "./sizing.js";

// Spec §6.6: cargo deliveries from needs and what is already on the way (R-58). Pure; the tile keeps no count (CR12).

export type SlotT = Static<typeof NeedSlot>;
/** A delivered cargo load still counted until releaseAtMs, when the network count shows it (§6.6). */
export type Held = [name: string, quality: string, count: number, releaseAtMs: number];

/** R-58, SP-5 (docs/ctron-pluginv2/spikes.md, lag 110 ticks): how long a delivered load stays inflight. */
export const INFLIGHT_HOLD_MS = 30_000;

export function itemKey(name: string, quality: string): string {
	return `${name}\u0000${quality}`;
}

/** Items on the way to one station: the loads of its live cargo jobs, plus held loads not yet released. */
export function inflight(live: ItemT[][], held: Held[], now: number): Map<string, number> {
	const m = new Map<string, number>();
	const add = (name: string, quality: string, count: number) => {
		const k = itemKey(name, quality);
		m.set(k, (m.get(k) ?? 0) + count);
	};
	for (const items of live) {
		for (const [name, quality, count] of items) {
			add(name, quality, count);
		}
	}
	for (const [name, quality, count, releaseAtMs] of held) {
		if (releaseAtMs > now) {
			add(name, quality, count);
		}
	}
	return m;
}

/**
 * §6.6: the top-up for one destination, or [] when no slot has count + inflight ≤ min (CC `cargo.lua:33-34`). Every
 * slot with count + inflight < max asks max − count − inflight, the trigger slot too; each item keeps its stack size.
 */
export function order(slots: SlotT[], inflightBy: Map<string, number>): ItemT[] {
	const have = (s: SlotT) => s[4] + (inflightBy.get(itemKey(s[0], s[1])) ?? 0);
	if (!slots.some(s => have(s) <= s[2])) {
		return [];
	}
	return slots.filter(s => have(s) < s[3]).map(s => [s[0], s[1], s[3] - have(s), s[5]] as ItemT);
}
