// Spec §6.2-§6.9: the cluster scheduler, greedy and oldest-first per surface (R-51). Pure behind SchedulerPort.
import type { Static } from "@sinclair/typebox";
import {
	list, type ItemRef, type JobAssign, type JobCancel, type JobDrop, type JobSquad, type JobStation, type StockQ,
	type StockResult, type UiCancel, type UiDrop, type WorkClear,
} from "../contracts.js";
import { itemKey, order, type SlotT } from "./cargo.js";
import {
	isCovered, isItemless, keyOf, ownerOf, remaining, totalsKey, type CellKindT, type Commit, type CtronEntry,
	type Index, type JobEntry, type JobKindT, type Repick, type ShareT, type StationEntry, type StationRefT, type Work,
} from "./index.js";
import { CROSS, type Place } from "./routes.js";
import { ASSIGN_BYTES, MERGE_RADIUS, mergeable, need, size, withCount, type Amount, type ItemT } from "./sizing.js";

export const DEBOUNCE_MS = 1000; // R-51
export const TIMER_MS = 10_000; // R-51
export const NO_SUPPLIER_MS = 10_000; // 600 ticks (R-59)
/** Route costs are asked of this many nearest idle ctrons per work (amends §6.3: Routes.cost is too dear for all). */
export const COST_K = 8;

type JobAssignT = Static<typeof JobAssign>;
type JobStationT = Static<typeof JobStation>;
type JobCancelT = Static<typeof JobCancel>;
type JobSquadT = Static<typeof JobSquad>;
type JobDropT = Static<typeof JobDrop>;
type WorkClearT = Static<typeof WorkClear>;
type UiCancelT = Static<typeof UiCancel>;
type UiDropT = Static<typeof UiDrop>;
type StockQT = Static<typeof StockQ>;
type ItemRefT = Static<typeof ItemRef>;
export type StockAnswerT = { r: Static<typeof StockResult> };

export type Outbound =
	| { type: "assign"; payload: JobAssignT }
	| { type: "station"; payload: JobStationT }
	| { type: "cancel"; payload: JobCancelT }
	| { type: "squad"; payload: JobSquadT }
	| { type: "drop"; payload: JobDropT }
	| { type: "clear"; payload: WorkClearT };

export interface SchedulerPort {
	now(): number; // ms
	cost(a: Place, b: Place): number; // Routes.cost; Infinity = unreachable
	query(inst: number, q: StockQT[]): Promise<StockAnswerT>; // {r: []} when the tile doesn't answer
	send(inst: number, msg: Outbound): void; // never throws (controller.ts catches)
	newId(): string; // UE's newId()
	settings(surface: string): { horde: boolean; minions: number; atomic: ItemRefT | undefined };
	running(): number[]; // running plugin instances (the restart hold)
	later(ms: number, fn: () => void): void; // setTimeout in controller.ts
	trace(op: string, phase: string, fields: Record<string, unknown>, level?: "info" | "verbose"): void;
}

/** Straight-line distance, plus CROSS between tiles: the cheap stand-in used to pick whom to ask Routes.cost about. */
const rough = (a: Place, b: Place) => Math.hypot(a.x - b.x, a.y - b.y) + (a.inst === b.inst ? 0 : CROSS);

export function placeOf(r: { inst: number; surface: string; x: number; y: number }): Place {
	return { inst: r.inst, surface: r.surface, x: r.x, y: r.y };
}
const ORIGIN = { x: 0, y: 0 };
const NO_AREA = { left_top: ORIGIN, right_bottom: ORIGIN };
const centerOf = (w: Work) => w.cell.center ?? ORIGIN;
/** One cell's entry in a `ct.job.assign`. */
const workEntry = (w: Work, a: Amount) => ({
	wid: w.cell.wid, key: keyOf(w.cell.wid), area: w.cell.area ?? NO_AREA, bring: a.bring, out: a.out,
});
/** The cell's centre on its owner tile. */
export function workPlace(w: Work): Place {
	const c = centerOf(w);
	return { inst: w.inst, surface: w.cell.surface, x: c.x, y: c.y };
}
export function stationRef(s: StationEntry): StationRefT {
	return { sid: s.sid, inst: s.inst, x: s.x, y: s.y };
}

/** One query record folded across tiles: stations that cover everything, and those covering some items (0-based). */
export interface Cover { all: string[]; some: Array<{ sid: string; idx: number[] }> }

/** The COST_K stations with the least straight-line detour from -> s -> to; route cost is asked of these only. */
function nearestStations(
	from: Place, to: Place | undefined, sids: string[], pool: Map<string, StationEntry>,
): StationEntry[] {
	const top: Array<{ s: StationEntry; d: number }> = [];
	for (const sid of sids) {
		const s = pool.get(sid);
		if (!s) { continue; }
		const d = rough(from, s) + (to ? rough(s, to) : 0);
		if (top.length === COST_K && d >= top[COST_K - 1].d) { continue; }
		let i = top.length === COST_K ? COST_K - 1 : top.length;
		top[i] = { s, d };
		for (; i > 0 && top[i - 1].d > top[i].d; i -= 1) { [top[i - 1], top[i]] = [top[i], top[i - 1]]; }
	}
	return top.map(t => t.s);
}

/** R-56: the lowest summed cost over `all`, else over `some`, else (tiers "all-some-nearest") the nearest to `from`. */
export function pickStation(
	from: Place, to: Place | undefined, cover: Cover | undefined, pool: Map<string, StationEntry>,
	cost: (a: Place, b: Place) => number, tiers: "all-some-nearest" | "all-nearest",
): StationEntry | undefined {
	const best = (sids: string[]) => {
		let pick: StationEntry | undefined;
		let low = Infinity;
		for (const s of nearestStations(from, to, sids, pool)) {
			const c = cost(from, s) + (to ? cost(s, to) : 0); // a StationEntry is a Place
			if (c < low || (c === low && pick && s.sid < pick.sid)) { pick = s; low = c; }
		}
		return pick;
	};
	const all = best(cover?.all ?? []);
	if (all) { return all; }
	if (tiers === "all-some-nearest") {
		const some = best((cover?.some ?? []).map(s => s.sid));
		if (some) { return some; }
	}
	let pick: StationEntry | undefined;
	let low = Infinity;
	for (const s of pool.values()) {
		const c = cost(from, s);
		if (!pick || c < low || (c === low && s.sid < pick.sid)) { pick = s; low = c; }
	}
	return pick;
}

interface Plan {
	qid: string; kind: JobKindT; members: CtronEntry[]; cells: Work[]; shares: ShareT[]; items: ItemT[];
	sized: Map<string, string>;
	minionItems?: ItemT[]; // a destroy squad: the most any minion loads, the atomic item left out (R-197)
	cargo?: { dest: StationRefT; items: ItemT[] };
}
interface Order { d: StationEntry; items: ItemT[]; since: number }
interface Ctx {
	S: string; horde: boolean; groups: Map<string, Work[]>;
	destroy: Map<number, Work[]>; // the open destroy cells per owner, oldest first (R-207)
	combined: (wid: string) => Commit | undefined; take: (s: ShareT) => void;
}
interface Trigger { st: "idle" | "scheduled" | "running"; last: number; dirty: boolean }

/** c at cost k beats pick at cost low: cheaper, then the work's own tile, then the lower cid (R-52). */
function beats(w: Work, c: CtronEntry, k: number, pick: CtronEntry, low: number): boolean {
	if (k !== low) { return k < low; }
	const own = c.inst === w.inst;
	return own !== (pick.inst === w.inst) ? own : c.cid < pick.cid;
}
/** need(a) > 0 without the slot maps (counts are positive: remaining() drops the rest). */
const nonEmpty = (a: Amount) => a.out > 0 || a.bring.some(i => i[2] > 0);

export class Scheduler {
	private readonly triggers = new Map<string, Trigger>();
	private bytes = new Map<string, number>(); // merge candidates' work-entry bytes, per pass
	private readonly orderSince = new Map<string, number>(); // destination sid -> ms its order first stood (§6.2)

	constructor(private readonly index: Index, private readonly port: SchedulerPort) {}

	trigger(surface: string): void {
		let t = this.triggers.get(surface);
		if (!t) { t = { st: "idle", last: -Infinity, dirty: false }; this.triggers.set(surface, t); }
		if (t.st === "running") { t.dirty = true; return; }
		if (t.st === "scheduled") { return; }
		t.st = "scheduled";
		this.port.later(Math.max(0, t.last + DEBOUNCE_MS - this.port.now()), () => { void this.run(surface, t); });
	}

	tick(): void {
		this.index.schedulableSurfaces().forEach(s => this.trigger(s));
	}

	private async run(surface: string, t: Trigger) {
		t.st = "running";
		t.last = this.port.now();
		try {
			await this.pass(surface);
		} catch (e) {
			this.port.trace("ctronv2.sched", "error", { surface, message: e instanceof Error ? e.message : String(e) });
		}
		t.st = "idle";
		if (t.dirty) { t.dirty = false; this.trigger(surface); }
	}

	async pass(S: string): Promise<void> {
		const { index, port } = this;
		const start = port.now();
		if (!index.holdOver(start, port.running()) || !index.schedulable(S)) { return; }
		this.bytes = new Map();
		const commits = index.commitments();
		const busy = index.busyCids();
		const taken = new Map<string, Commit>();
		const free = (c: CtronEntry) => c.surface === S && c.state === "idle" && !busy.has(c.cid)
			&& !index.isRejected(c.cid, start);
		const idle = [...index.ctrons.values()].filter(free);
		const idleAtStart = idle.length;

		const combined = (wid: string): Commit | undefined => {
			const a = commits.get(wid);
			const b = taken.get(wid);
			if (!a || !b) { return a ?? b; }
			const bring = new Map(a.bring);
			for (const [k, n] of b.bring) { bring.set(k, (bring.get(k) ?? 0) + n); }
			return { bring, out: a.out + b.out, live: a.live + b.live };
		};
		const take = (s: ShareT) => {
			let c = taken.get(s.wid);
			if (!c) { c = { bring: new Map(), out: 0, live: 0 }; taken.set(s.wid, c); }
			for (const [name, quality, count] of list<ItemT>(s.bring)) {
				const k = itemKey(name, quality);
				c.bring.set(k, (c.bring.get(k) ?? 0) + count);
			}
			c.out += s.out;
			c.live += 1;
		};

		const open = [...index.work.values()].filter(w => {
			const cell = w.cell;
			if (cell.surface !== S || cell.due !== 0 || cell.scanned === undefined || w.backoffUntilMs > start) {
				return false;
			}
			return (!isItemless(w) || (cell.n ?? 0) > 0) && !isCovered(w, combined(cell.wid));
		}).sort((a, b) => a.firstSeenMs - b.firstSeenMs || (a.cell.wid < b.cell.wid ? -1 : 1));

		const horde = port.settings(S).horde;
		const groups = new Map<string, Work[]>(); // merge candidates, open order: (owner, kind)
		for (const w of open) {
			if (isItemless(w)) { continue; }
			const k = `${w.inst}|${w.cell.kind}`;
			const g = groups.get(k);
			if (g) { g.push(w); } else { groups.set(k, [w]); }
		}
		const destroy = new Map<number, Work[]>();
		for (const w of open) {
			if (w.cell.kind !== "destroy") { continue; }
			const g = destroy.get(w.inst);
			if (g) { g.push(w); } else { destroy.set(w.inst, [w]); }
		}
		const plans: Plan[] = [];
		const ctx: Ctx = { combined, take, horde, S, groups, destroy };
		for (const w of open) {
			if (w.cell.kind === "destroy") { this.squad(w, idle, plans, ctx); continue; }
			this.planCell(w, idle, plans, ctx);
		}
		// no idle ctron left: skip the query; with nobody to carry an order it would cost a round trip every pass
		const orders = idle.length > 0 ? this.collectOrders(S, start) : [];

		let sentCount = 0;
		if (plans.length > 0 || orders.length > 0) {
			const pool = new Map([...index.stations.values()].filter(s => s.surface === S).map(s => [s.sid, s]));
			const entries: StockQT[] = plans.map(p => ({ qid: p.qid, mode: "supply", items: p.items }));
			// R-196: a squad's minions load their own restock, so they get a query of their own (even an empty one)
			for (const p of plans) {
				if (p.minionItems) { entries.push({ qid: `${p.qid}m`, mode: "supply", items: p.minionItems }); }
			}
			// the destination's own network is excluded; a network never spans tiles (R-59)
			orders.forEach((o, i) => {
				entries.push({ qid: `o${i}`, mode: "supply", items: o.items, exclude_sid: o.d.sid });
			});
			const cover = await this.ask(new Set([...pool.values()].map(s => s.inst)), entries);
			const nowBusy = index.busyCids();
			let sent = 0;
			for (const p of plans) {
				const lead = index.ctrons.get(p.members[0].cid);
				const alive = p.members.every(m => {
					const c = index.ctrons.get(m.cid);
					return c !== undefined && c.state === "idle" && !nowBusy.has(m.cid);
				}) && p.cells.every(c => {
					const cur = index.work.get(c.cell.wid);
					return cur !== undefined && cur.cell.due === 0;
				});
				if (!lead || !alive) { continue; }
				if (this.dispatch(S, p, lead, cover, pool)) { sent += 1; }
			}
			const busyNow = index.busyCids();
			orders.forEach((o, i) => {
				const hit = this.supplier(o, cover.get(`o${i}`), pool);
				if (!hit) { this.noSupplier(o.d.sid); return; }
				const avail = idle.map(c => index.ctrons.get(c.cid))
					.filter((c): c is CtronEntry => c !== undefined && c.state === "idle" && !busyNow.has(c.cid));
				const pick = this.cargoCtron(avail, hit.s, hit.covered);
				if (!pick) { return; }
				idle.splice(idle.findIndex(c => c.cid === pick.c.cid), 1);
				this.send(S, {
					qid: `o${i}`, kind: "cargo", members: [pick.c], cells: [], shares: [], items: hit.covered,
					sized: new Map(), cargo: { dest: stationRef(o.d), items: pick.share.bring },
				}, pick.c, hit.s);
				sent += 1;
			});
			sentCount = sent;
		}
		port.trace("ctronv2.sched", "pass", {
			surface: S, ms: port.now() - start, open: open.length, idle: idleAtStart, plans: sentCount,
		}, sentCount === 0 && open.length === 0 ? "verbose" : undefined);
	}

	/**
	 * §6.7, R-194..R-196: a destroy squad from the whole surface. The leader is the cheapest to the work among the
	 * nearest idle ctrons, the minions the cheapest to the leader. Without m + 1 idle ctrons the cell waits and holds
	 * back the surface's idle ctrons from younger work, so they gather over passes as CC's setup gathers minions
	 * (`destroy.lua:30-46`). Without horde mode the squad also takes the owner's chained destroy cells (R-207).
	 */
	private squad(w: Work, idle: CtronEntry[], plans: Plan[], ctx: Ctx): void {
		const port = this.port;
		if ((ctx.combined(w.cell.wid)?.live ?? 0) > 0) { return; } // merged into an earlier squad this pass
		const { minions: m, atomic } = port.settings(ctx.S);
		if (idle.length < m + 1) {
			w.why = "waiting_squad";
			this.holdBack(idle, m + 1, ctx.S);
			return;
		}
		const to = workPlace(w);
		let lead: CtronEntry | undefined;
		let low = Infinity;
		for (const c of this.nearest(idle, to, new Set())) {
			const k = port.cost(c, to);
			if (k !== Infinity && (!lead || beats(w, c, k, lead, low))) { lead = c; low = k; }
		}
		if (!lead) { w.why = "unreachable"; return; } // m + 1 idle but none reaches it: hold nothing
		const minions = this.nearest(idle.filter(c => c !== lead), lead, new Set(), m + COST_K)
			.map(c => ({ c, k: port.cost(lead, c) })).filter(x => x.k !== Infinity)
			.sort((a, b) => a.k - b.k || (a.c.cid < b.c.cid ? -1 : 1))
			.slice(0, m).map(x => x.c);
		if (minions.length < m) { w.why = "waiting_squad"; return; } // ponytail: rare islands hold nothing
		const members = [lead, ...minions];
		for (const c of members) { idle.splice(idle.indexOf(c), 1); }
		const cells = [w, ...ctx.horde ? [] : this.chain(w, members, ctx)];
		const shares = cells.map((c): ShareT => ({ wid: c.cell.wid, bring: [], out: 0 }));
		shares.forEach(ctx.take);
		cells.forEach(c => { c.why = undefined; });
		const most = new Map<string, ItemT>(); // R-197: per (name, quality) the largest minion restock, no atomic
		for (const item of minions.flatMap(c => list<ItemT>(c.restock.destroy))) {
			if (atomic && item[0] === atomic[0] && item[1] === atomic[1]) { continue; }
			const k = itemKey(item[0], item[1]);
			const have = most.get(k);
			if (!have || have[2] < item[2]) { most.set(k, item); }
		}
		plans.push({
			qid: `s${plans.length}`, kind: "destroy", members, cells, shares, items: list<ItemT>(lead.restock.destroy),
			sized: new Map(cells.map(c => [c.cell.wid, totalsKey(c.cell)])), minionItems: [...most.values()],
		});
	}

	/**
	 * R-207: the owner's open destroy cells chained within MERGE_RADIUS, centre to centre, from `w` (CC
	 * `job.lua:264-310`), as many as the leader's assign holds with every member listed. Returns the added cells.
	 * ponytail: O(n^2) over one owner's open destroy cells.
	 */
	private chain(w: Work, members: CtronEntry[], ctx: Ctx): Work[] {
		const cands = (ctx.destroy.get(w.inst) ?? [])
			.filter(o => o !== w && (ctx.combined(o.cell.wid)?.live ?? 0) === 0);
		const draft = {
			jid: "", kind: "destroy", surface: ctx.S, station: { sid: "", inst: 0, x: 0, y: 0 },
			members: members.map(c => c.cid), work: [workEntry(w, { bring: [], out: 0 })],
		};
		let left = ASSIGN_BYTES - 64 - JSON.stringify(draft).length;
		const picked = [w];
		const added: Work[] = [];
		for (let grew = true; grew;) {
			grew = false;
			for (let i = 0; i < cands.length; i++) {
				const o = cands[i];
				const c = centerOf(o);
				if (!picked.some(p => Math.hypot(centerOf(p).x - c.x, centerOf(p).y - c.y) <= MERGE_RADIUS)) {
					continue;
				}
				const bytes = JSON.stringify(workEntry(o, { bring: [], out: 0 })).length + 1;
				if (bytes > left) { continue; }
				left -= bytes;
				picked.push(o);
				added.push(o);
				cands.splice(i, 1);
				i -= 1;
				grew = true;
			}
		}
		return added;
	}

	/**
	 * R-195: the waiting squad holds every idle ctron of the surface from younger work, if the surface has m + 1
	 * ctrons that could ever join (CC locks the leader and each minion found, `destroy.lua:32-46`). Called with fewer
	 * than `want` idle, so all of them are held.
	 */
	private holdBack(idle: CtronEntry[], want: number, S: string) {
		const now = this.port.now();
		let could = 0;
		for (const c of this.index.ctrons.values()) {
			// only ctrons that could ever join: not unfit, not turned away (the `free` test, bar busy)
			if (c.surface === S && c.state !== "unfit" && !this.index.isRejected(c.cid, now)) { could += 1; }
		}
		if (could >= want) { idle.splice(0); }
	}

	/** §6.6: the top-up each need on S asks for, oldest first; the order's first-seen time lives in orderSince. */
	private collectOrders(S: string, now: number): Order[] {
		const { index } = this;
		const orders: Order[] = [];
		for (const n of index.needs.values()) {
			const d = index.stations.get(n.sid);
			if (n.surface !== S || !d || (index.orderBackoff.get(n.sid) ?? 0) > now) { continue; }
			const items = order(list<SlotT>(n.slots), index.inflightTo(n.sid, now));
			if (items.length === 0) { this.orderSince.delete(n.sid); continue; }
			const since = this.orderSince.get(n.sid) ?? now;
			this.orderSince.set(n.sid, since);
			orders.push({ d, items, since });
		}
		for (const sid of [...this.orderSince.keys()]) {
			if (!index.needs.has(sid)) { this.orderSince.delete(sid); }
		}
		return orders.sort((a, b) => a.since - b.since || (a.d.sid < b.d.sid ? -1 : 1));
	}

	private noSupplier(sid: string) {
		this.index.orderBackoff.set(sid, this.port.now() + NO_SUPPLIER_MS);
	}

	/** R-59: the covers-all station nearest the destination, else the covers-some nearest, with the items it covers. */
	private supplier(o: Order, cover: Cover | undefined, pool: Map<string, StationEntry>) {
		const nearestTo = (sids: string[]) => {
			let pick: StationEntry | undefined;
			let low = Infinity;
			for (const s of nearestStations(o.d, undefined, sids, pool)) {
				const k = this.port.cost(s, o.d);
				if (k !== Infinity && (k < low || (k === low && pick && s.sid < pick.sid))) { pick = s; low = k; }
			}
			return pick;
		};
		const all = nearestTo(cover?.all ?? []);
		if (all) { return { s: all, covered: o.items }; }
		const some = nearestTo((cover?.some ?? []).map(x => x.sid));
		if (!some) { return undefined; }
		const idx = cover!.some.find(x => x.sid === some.sid)!.idx;
		return { s: some, covered: idx.filter(i => i < o.items.length).map(i => o.items[i]) };
	}

	/** R-147: the cheapest ctron to the supplier that can carry a non-empty share of `covered`. */
	private cargoCtron(avail: CtronEntry[], sup: StationEntry, covered: ItemT[]) {
		const skip = new Set<CtronEntry>();
		for (;;) {
			const cands = this.nearest(avail, sup, skip);
			if (cands.length === 0) { return undefined; }
			let pick: { c: CtronEntry; share: { bring: ItemT[] }; k: number } | undefined;
			for (const c of cands) {
				skip.add(c);
				const k = this.port.cost(c, sup);
				const share = k === Infinity ? null : size({ bring: covered, out: 0 }, c.free.cargo);
				if (share && (!pick || k < pick.k || (k === pick.k && c.cid < pick.c.cid))) { pick = { c, share, k }; }
			}
			if (pick) { return pick; }
		}
	}

	/** After every delta, snapshot and job event: re-picks and re-sends. */
	afterReport(): void {
		for (const r of this.index.takeRepicks()) {
			void this.repick(r).catch(err => this.port.trace("ctronv2.sched", "error", {
				message: err instanceof Error ? err.message : String(err),
			}));
		}
		const sent = new Set<string>(); // squad states sent below: the queue need not repeat them
		for (const { jid, inst } of this.index.takeResends()) {
			const j = this.index.jobs.get(jid);
			if (!j) { continue; }
			if (j.cancelled) { this.port.send(inst, { type: "cancel", payload: { jid } }); }
			for (const d of j.drops) {
				const { surface } = j;
				this.port.send(inst, { type: "drop", payload: { jid, surface, name: d.name, quality: d.quality } });
			}
			if (j.squad) { this.port.send(inst, this.squadMsg(j)); sent.add(`${jid}|${inst}`); }
		}
		this.flushSquad(sent);
	}

	/** Sends the queued squad relays; the controller's tick calls it too (review finding 3). */
	flushSquad(sent = new Set<string>()): void {
		for (const { jid, inst, cancel } of this.index.takeSquad()) {
			const j = this.index.jobs.get(jid);
			if (cancel) {
				this.port.send(inst, { type: "cancel", payload: { jid } });
			} else if (j?.squad && !sent.has(`${jid}|${inst}`)) {
				this.port.send(inst, this.squadMsg(j));
			}
		}
	}

	/** The whole squad state for a tile: the leader's place, the minions gone, the release (squads.md §4.4). */
	private squadMsg(j: JobEntry): Outbound {
		const { gone, done } = j.squad ?? { gone: new Set<string>(), done: false };
		const at = this.index.ctrons.get(j.lead);
		return {
			type: "squad",
			payload: {
				jid: j.jid, ...at && { lead: { inst: at.inst, x: at.x, y: at.y } }, gone: [...gone], done,
			},
		};
	}

	/** §6.5, R-35: a new station for a ctron that ran short or has full trash; none better, it keeps waiting. */
	private async repick(r: Repick): Promise<void> {
		const { index, port } = this;
		const j = index.jobs.get(r.jid);
		if (!j || j.cancelled || r.items.length === 0) { return; }
		const lead = j.record?.station ?? j.station; // the leader's station, after any earlier re-pick
		const mine = j.stations.get(r.cid); // a minion re-picks from its own station, toward the leader's (R-196)
		const cur = mine ?? lead; // the station the run is at now
		const from: Place = { inst: cur.inst, surface: j.surface, x: cur.x, y: cur.y };
		const first = j.shares[0] && index.work.get(j.shares[0].wid);
		let to: Place | undefined; // a short item is fetched on the way to the work, or to the leader's station
		if (r.ev === "short" && mine) {
			to = { inst: lead.inst, surface: j.surface, x: lead.x, y: lead.y };
		} else if (r.ev === "short" && first) {
			to = workPlace(first);
		}
		const pool = new Map([...index.stations.values()].filter(s => s.surface === j.surface).map(s => [s.sid, s]));
		const entry: StockQT = {
			qid: "r", mode: r.ev === "short" ? "supply" : "drop", items: r.items, exclude_sid: cur.sid,
		};
		const cover = (await this.ask(new Set([...pool.values()].map(s => s.inst)), [entry])).get("r");
		if (!cover || j.cancelled) { return; }
		const found = new Set([...cover.all, ...cover.some.map(x => x.sid)]);
		found.delete(cur.sid);
		const only = new Map([...pool].filter(([sid]) => found.has(sid)));
		const s = pickStation(from, to, cover, only, port.cost, "all-some-nearest");
		const inst = index.holderOf(r.jid, r.cid);
		if (!s || inst === undefined || !index.jobs.has(r.jid)) { return; }
		port.send(inst, { type: "station", payload: { jid: r.jid, cid: r.cid, station: stationRef(s), why: r.ev } });
		if (mine) { j.stations.set(r.cid, stationRef(s)); }
		port.trace("ctronv2.job", "station", { jid: r.jid, cid: r.cid, station: s.sid, why: r.ev });
	}

	/** §6.9, R-67: a cancel from any tile's screen. */
	cancel(msg: UiCancelT): void {
		const { index, port } = this;
		if (msg.target === "work") {
			const kind = msg.kind as CellKindT;
			if (msg.id !== undefined) {
				const w = index.work.get(msg.id);
				if (!w) { return; }
				port.send(w.inst, { type: "clear", payload: { wids: [msg.id] } });
				index.forget([msg.id]);
				return;
			}
			const owners = new Set([...index.work.values()]
				.filter(w => w.cell.surface === msg.surface && w.cell.kind === kind).map(w => w.inst));
			owners.forEach(inst => port.send(inst, { type: "clear", payload: { surface: msg.surface, kind } }));
			index.dropWork(msg.surface, kind);
			return;
		}
		const jobs = msg.id !== undefined
			? [index.jobs.get(msg.id)].filter(j => j !== undefined)
			: [...index.jobs.values()].filter(j => j.kind === msg.kind && j.surface === msg.surface
				&& j.record?.state !== "returning" && j.record?.state !== "unloading");
		for (const j of jobs) {
			if (j.cancelled) { continue; }
			const wids = j.shares.map(s => s.wid);
			for (const inst of index.tilesOf(j)) {
				port.send(inst, { type: "cancel", payload: { jid: j.jid } });
			}
			index.cancel(j.jid);
			const byOwner = new Map<number, string[]>();
			for (const wid of wids) {
				const g = byOwner.get(ownerOf(wid));
				if (g) { g.push(wid); } else { byOwner.set(ownerOf(wid), [wid]); }
			}
			byOwner.forEach((ids, inst) => port.send(inst, { type: "clear", payload: { wids: ids } }));
			index.forget(wids); // leftovers aren't reassigned
			port.trace("ctronv2.job", "cancelled", { jid: j.jid, cid: j.lead });
		}
	}

	/** §6.9, R-96: drop an item from a job's ctrons, or from every loading job on the surface. */
	drop(msg: UiDropT): void {
		const { index, port } = this;
		const { surface, name, quality } = msg;
		if (msg.jid !== undefined) {
			const j = index.jobs.get(msg.jid);
			if (!j) { return; }
			for (const inst of index.tilesOf(j)) { // a squad has parts on several tiles
				port.send(inst, { type: "drop", payload: { jid: msg.jid, surface, name, quality } });
			}
			j.drops.push({ name, quality });
			return;
		}
		const tiles = new Set([...index.jobs.values()]
			.filter(j => j.surface === surface && j.record?.state === "loading").map(j => j.at));
		tiles.forEach(inst => port.send(inst, { type: "drop", payload: { surface, name, quality } }));
	}

	/**
	 * The k (COST_K) idle ctrons nearest `to` by straight line (plus CROSS for another tile), skipping `skip`.
	 * ponytail: the route cost is asked only of these, so a ctron nearer by straight line can lose to a farther one
	 * on route cost only within the top K; one outside the K is never considered. Raise COST_K if routes bend far from
	 * straight.
	 */
	private nearest(idle: CtronEntry[], to: Place, skip: Set<CtronEntry>, k = COST_K): CtronEntry[] {
		const top: Array<{ c: CtronEntry; d: number }> = [];
		for (const c of idle) {
			if (skip.size > 0 && skip.has(c)) { continue; }
			const d = rough(c, to);
			if (top.length === k && d >= top[k - 1].d) { continue; }
			let i = top.length === k ? k - 1 : top.length;
			top[i] = { c, d };
			for (; i > 0 && top[i - 1].d > top[i].d; i -= 1) { [top[i - 1], top[i]] = [top[i], top[i - 1]]; }
		}
		return top.map(t => t.c);
	}

	/** R-141: the cheapest of the nearest ctrons whose share is non-empty. `finite` = some candidate was reachable. */
	private chooseLead(w: Work, idle: CtronEntry[], rem: Amount, memo: Map<CtronEntry, number>) {
		const to = workPlace(w);
		const skip = new Set<CtronEntry>();
		let finite = false;
		for (;;) {
			const cands = this.nearest(idle, to, skip);
			if (cands.length === 0) { return { finite }; }
			let pick: CtronEntry | undefined;
			let low = Infinity;
			for (const c of cands) {
				let k = memo.get(c);
				if (k === undefined) { k = this.port.cost(c, to); memo.set(c, k); } // a CtronEntry is a Place
				if (k !== Infinity && (!pick || beats(w, c, k, pick, low))) { pick = c; low = k; }
			}
			if (!pick) { return { finite }; }
			finite = true;
			const share = size(rem, pick.free.normal);
			if (share) { return { finite, lead: pick, share }; }
			skip.add(pick);
		}
	}

	private planCell(w: Work, idle: CtronEntry[], plans: Plan[], ctx: Ctx) {
		const { combined, groups } = ctx;
		const itemless = isItemless(w);
		const memo = new Map<CtronEntry, number>(); // route costs for this cell, reused across the repeats
		let planned = 0;
		let rem = remaining(w, combined(w.cell.wid));
		if (!itemless && !nonEmpty(rem)) { return; } // merged into an earlier plan
		while ((itemless ? planned === 0 : nonEmpty(rem)) && idle.length > 0) {
			const chosen = this.chooseLead(w, idle, rem, memo);
			if (!chosen.lead || !chosen.share) {
				if (planned === 0) { w.why = chosen.finite ? "no_ctron" : "unreachable"; }
				return;
			}
			const at = idle.indexOf(chosen.lead);
			idle[at] = idle[idle.length - 1]; // order doesn't matter: ties break on inst and cid
			idle.pop();
			plans.push(this.makePlan(w, chosen.lead, chosen.share, rem, plans.length, ctx));
			planned += 1;
			w.why = undefined;
			rem = remaining(w, combined(w.cell.wid));
		}
		if (!itemless && !nonEmpty(rem)) {
			const g = groups.get(`${w.inst}|${w.cell.kind}`)!;
			g.splice(g.indexOf(w), 1);
		}
		if (planned === 0 && idle.length === 0) { w.why = "no_ctron"; }
	}

	/** The share, merged cells (R-55), the items the stock query asks for, and the shares marked taken. */
	private makePlan(w: Work, lead: CtronEntry, share: Amount, rem: Amount, n: number, ctx: Ctx): Plan {
		const shares: ShareT[] = [{ wid: w.cell.wid, bring: share.bring, out: share.out }];
		const cells = [w];
		if (!isItemless(w) && !ctx.horde && need(share) === need(rem)) {
			const group = ctx.groups.get(`${w.inst}|${w.cell.kind}`) ?? [];
			this.merge(w, lead, share, group, shares, cells, ctx.combined, ctx.S);
		}
		shares.forEach(ctx.take);
		const sum = new Map<string, ItemT>();
		for (const item of [...shares.flatMap(s => list<ItemT>(s.bring)), ...list<ItemT>(lead.restock.normal)]) {
			const k = itemKey(item[0], item[1]);
			const have = sum.get(k);
			sum.set(k, have ? withCount(have, have[2] + item[2]) : item);
		}
		return {
			qid: `p${n}`, kind: w.cell.kind as JobKindT, members: [lead], cells, shares,
			items: [...sum.values()], sized: new Map(cells.map(c => [c.cell.wid, totalsKey(c.cell)])),
		};
	}

	private merge(
		w: Work, lead: CtronEntry, share: Amount, open: Work[], shares: ShareT[], cells: Work[],
		combined: (wid: string) => Commit | undefined, S: string,
	) {
		const draft = {
			jid: "", kind: w.cell.kind, surface: S, station: { sid: "", inst: 0, x: 0, y: 0 }, members: [lead.cid],
			work: [workEntry(w, share)],
		};
		const bytesLeft = ASSIGN_BYTES - 64 - JSON.stringify(draft).length;
		const c0 = centerOf(w);
		const byWid = new Map<string, Work>();
		const cands = [];
		for (const o of open) {
			if (o === w) { continue; } // the group holds only this owner's and kind's non-itemless cells
			const dx = centerOf(o).x - c0.x;
			const dy = centerOf(o).y - c0.y;
			if (dx * dx + dy * dy > MERGE_RADIUS * MERGE_RADIUS) { continue; }
			const taken = combined(o.cell.wid);
			const untouched = taken === undefined;
			const rem = remaining(o, taken);
			if (!nonEmpty(rem)) { continue; }
			byWid.set(o.cell.wid, o);
			// an untouched cell's bytes don't change within a pass
			let bytes = untouched ? this.bytes.get(o.cell.wid) : undefined;
			if (bytes === undefined) {
				bytes = JSON.stringify(workEntry(o, rem)).length + 1;
				if (untouched) { this.bytes.set(o.cell.wid, bytes); }
			}
			cands.push({ wid: o.cell.wid, x: centerOf(o).x, y: centerOf(o).y, rem, bytes });
		}
		for (const p of mergeable(c0.x, c0.y, cands, lead.free.normal - need(share), bytesLeft)) {
			shares.push({ wid: p.wid, bring: p.rem.bring, out: p.rem.out });
			const o = byWid.get(p.wid)!;
			cells.push(o);
			o.why = undefined; // a worked cell shows no old reason
			open.splice(open.indexOf(o), 1); // whole: it can't merge again this pass
		}
	}

	/** §6.5: one query per tile with stations on the surface; the records fold into one cover per qid (R-151). */
	private async ask(tiles: Set<number>, entries: StockQT[]): Promise<Map<string, Cover>> {
		const replies = await Promise.all([...tiles].map(inst => this.port.query(inst, entries)));
		const cover = new Map<string, Cover>();
		for (const reply of replies) {
			for (const rec of list<{ qid: string; sids: unknown; cover: unknown }>(reply.r)) {
				let c = cover.get(rec.qid);
				if (!c) { c = { all: [], some: [] }; cover.set(rec.qid, c); }
				const sids = list<string>(rec.sids as string[]);
				if (rec.cover === true) {
					c.all.push(...sids);
				} else {
					const idx = list<number>(rec.cover as number[]).map(i => i - 1);
					if (idx.length > 0) { sids.forEach(sid => c.some.push({ sid, idx })); }
				}
			}
		}
		return cover;
	}

	/** R-126: the Job exists as assigned before the event leaves, so the shares never count nowhere. */
	private send(S: string, p: Plan, lead: CtronEntry, st: StationEntry) {
		const jid = this.port.newId();
		const station = stationRef(st);
		const members = p.members.map(c => c.cid);
		const payload: JobAssignT = {
			jid, kind: p.kind, surface: S, station, members,
			work: p.shares.map((s, i) => workEntry(p.cells[i], { bring: list<ItemT>(s.bring), out: s.out })),
			...(p.cargo && { cargo: p.cargo }),
		};
		const now = this.port.now();
		this.index.assign({
			jid, kind: p.kind, surface: S, at: lead.inst, members, shares: p.shares, station, cargo: p.cargo,
			sizedFrom: p.sized,
		}, now);
		this.port.send(lead.inst, { type: "assign", payload });
		this.port.trace("ctronv2.job", "assigned", {
			jid, cid: lead.cid, kind: p.kind, wids: p.shares.map(s => s.wid), station: st.sid,
		});
	}

	/** Picks the plan's stations (the leader's, and each minion's of a squad, R-196) and sends it; false when none. */
	private dispatch(S: string, p: Plan, lead: CtronEntry, cover: Map<string, Cover>, pool: Map<string, StationEntry>) {
		const { port, index } = this;
		const to = workPlace(p.cells[0]);
		const st = pickStation(placeOf(lead), to, cover.get(p.qid), pool, port.cost, "all-some-nearest");
		if (!st) { return false; }
		if (p.kind !== "destroy") {
			this.send(S, p, lead, st);
			return true;
		}
		const mst = new Map<string, StationEntry>(); // each minion's own, on its way to the leader's
		for (const m of p.members.slice(1)) {
			const at = placeOf(index.ctrons.get(m.cid)!); // alive: checked by the caller
			const pick = pickStation(at, st, cover.get(`${p.qid}m`), pool, port.cost, "all-some-nearest");
			if (!pick) { return false; }
			mst.set(m.cid, pick);
		}
		this.sendSquad(S, p, lead, st, mst);
		return true;
	}

	/**
	 * R-196: the leader's assign lists every member and the work; each (tile, station) group of minions gets an assign
	 * of its own, with no work and the leader's place. One Job, as for every kind (R-126).
	 */
	private sendSquad(S: string, p: Plan, lead: CtronEntry, st: StationEntry, mst: Map<string, StationEntry>) {
		const jid = this.port.newId();
		const station = stationRef(st);
		const members = p.members.map(c => c.cid);
		const stations = new Map([...mst].map(([cid, s]) => [cid, stationRef(s)]));
		const payload: JobAssignT = {
			jid, kind: "destroy", surface: S, station, members,
			work: p.shares.map((s, i) => workEntry(p.cells[i], { bring: list<ItemT>(s.bring), out: s.out })),
		};
		this.index.assign({
			jid, kind: "destroy", surface: S, at: lead.inst, members, shares: p.shares, station, sizedFrom: p.sized,
			stations,
		}, this.port.now());
		this.port.send(lead.inst, { type: "assign", payload });
		const groups = new Map<string, { inst: number; station: StationRefT; cids: string[] }>();
		for (const c of p.members.slice(1)) {
			const ref = stations.get(c.cid)!;
			const key = `${c.inst}|${ref.sid}`;
			const g = groups.get(key);
			if (g) { g.cids.push(c.cid); } else { groups.set(key, { inst: c.inst, station: ref, cids: [c.cid] }); }
		}
		for (const g of groups.values()) {
			this.port.send(g.inst, {
				type: "assign",
				payload: {
					jid, kind: "destroy", surface: S, station: g.station, members: g.cids, work: [],
					lead: { cid: lead.cid, inst: lead.inst, x: lead.x, y: lead.y },
				},
			});
		}
		this.port.trace("ctronv2.job", "assigned", {
			jid, cid: lead.cid, kind: p.kind, wids: p.shares.map(s => s.wid), station: st.sid, members,
		});
	}
}
