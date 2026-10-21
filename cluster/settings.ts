// Spec §4.6, §6.11: the controller's settings authority. It stores overrides only; defaults come from tiles (X-17).
import type { Static } from "@sinclair/typebox";
import type { CellKind, ItemRef, Overrides, Settings, SettingsPatch } from "../contracts.js";

export type Patch = Static<typeof SettingsPatch>;
export type Over = Static<typeof Overrides>;
export type Full = Static<typeof Settings>;
type CellKindT = Static<typeof CellKind>;

const GLOBAL_KEYS = new Set(["job_start_delay", "debug"]);
// CC's caps, ui.lua:726-842 (§4.6)
const CLAMPS: Record<string, [number, number]> = {
	job_start_delay: [0, Infinity], robot_count: [0, 10000], ammo_count: [0, 8000], atomic_count: [0, 1000],
	min_cluster: [1, 100], minions: [0, 100],
};
// Rebuild is absent on purpose: turning it off only stops discovery (§5.10).
const KIND_NAMES = ["construction", "deconstruction", "upgrade", "repair", "destroy"] as const;

/** Keep what belongs to the scope (global keys without a surface, the rest with one) and clamp CC's caps. */
export function validate(surface: string | undefined, patch: Patch): { patch: Patch; dropped: string[] } {
	const out: Record<string, unknown> = {};
	const dropped: string[] = [];
	for (const [key, value] of Object.entries(patch)) {
		if (value === undefined) { continue; }
		if (GLOBAL_KEYS.has(key) !== (surface === undefined)) { dropped.push(key); continue; }
		const clamp = CLAMPS[key];
		out[key] = clamp && typeof value === "number" ? Math.min(clamp[1], Math.max(clamp[0], value)) : value;
	}
	return { patch: out as Patch, dropped };
}

function mergePatch<T extends Patch>(a: T, b: Patch): T {
	const merged: Record<string, unknown> = { ...a, ...b };
	if (a.kinds || b.kinds) { merged.kinds = { ...a.kinds, ...b.kinds }; }
	return merged as T;
}

/** A new overrides object with the patch applied; "*" also clears every surface's override of the same keys (R-68). */
export function merge(overrides: Over, surface: string | undefined, patch: Patch): Over {
	const next = structuredClone(overrides);
	const scope = surface ?? "*";
	next[scope] = mergePatch(next[scope] ?? {}, patch);
	if (scope !== "*") { return next; }
	for (const [name, over] of Object.entries(next)) {
		if (name === "*") { continue; }
		const rest: Record<string, unknown> = { ...over };
		for (const key of Object.keys(patch)) {
			if (key !== "kinds") { delete rest[key]; }
		}
		if (patch.kinds && over.kinds) {
			const kinds: Record<string, unknown> = { ...over.kinds };
			for (const key of Object.keys(patch.kinds)) { delete kinds[key]; }
			if (Object.keys(kinds).length) { rest.kinds = kinds; } else { delete rest.kinds; }
		}
		if (Object.keys(rest).length) { next[name] = rest as Patch; } else { delete next[name]; }
	}
	return next;
}

export function effective(defaults: Full, overrides: Over, surface: string): Full {
	return mergePatch(mergePatch(defaults, overrides["*"] ?? {}), overrides[surface] ?? {});
}

/** The [surface, kind] pairs an edit turned off, so the controller drops their Work (§6.11). */
export function kindsOff(defaults: Full, before: Over, after: Over, surfaces: string[]): Array<[string, CellKindT]> {
	const off: Array<[string, CellKindT]> = [];
	for (const surface of surfaces) {
		const was = effective(defaults, before, surface).kinds;
		const now = effective(defaults, after, surface).kinds;
		for (const name of KIND_NAMES) {
			if (was[name] && !now[name]) { off.push([surface, name]); }
		}
	}
	return off;
}

/** What the scheduler reads. CC's defaults (control.lua:228) before any tile sent its own. */
export function schedulerView(
	defaults: Full | undefined, overrides: Over, surface: string,
): { horde: boolean; minions: number; atomic: Static<typeof ItemRef> | undefined } {
	if (!defaults) { return { horde: false, minions: 1, atomic: undefined }; }
	const { horde, minions, atomic } = effective(defaults, overrides, surface);
	return { horde, minions, atomic };
}
