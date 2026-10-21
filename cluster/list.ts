// Spec §6.12 (R-134): each watch's rows, built, sectioned and capped by the controller, so a tile mirrors ≤ ~300 rows.
import type { Static } from "@sinclair/typebox";
import {
	list, type CtronRow, type GroupRow, type JobRow, type NeedRow, type Row, type StationRow, type UiList, type Watch,
	type WorkRow, type WorkSt as WorkStS, type WorkWhy as WorkWhyS,
} from "../contracts.js";
import { itemKey, order, type SlotT } from "./cargo.js";
import { isCovered, remaining, type Commit, type CtronEntry, type Index, type JobEntry, type Work } from "./index.js";
import { need, type ItemT } from "./sizing.js";

export const CAP = 50; // rows per section (R-92, R-134)
export const PART_BYTES = 3000; // each encoded ct.ui.list part (R-15)
export const PROBLEM = new Set([ // job statuses with severity "problem" (§8.7); keep in step with status_core.lua
	"short", "no_logi_robots", "no_logi_storage", "no_station_power", "no_stations", "dest_invalid", "missing_robots",
	"no_landfill", "trash_full", "no_path", "stuck", "no_route", "budget",
]);
const SECTIONS = ["attention", "progress", "finishing", "pending", "cells", "ctrons", "stations"];
const WAITING_MAX = 20;

export type WatchKey = Static<typeof Watch>;
export type RowT = Static<typeof Row>;
export type JobRowT = Static<typeof JobRow>;
export type UiListT = Static<typeof UiList>;
export type StatsT = UiListT["stats"];
type Name = (inst: number) => string;
type WorkSt = Static<typeof WorkStS>;
type WorkWhyT = Static<typeof WorkWhyS>;
type WorkRowT = Static<typeof WorkRow>;
type GroupRowT = Static<typeof GroupRow>;
type CtronRowT = Static<typeof CtronRow>;
type StationRowT = Static<typeof StationRow>;
type NeedRowT = Static<typeof NeedRow>;
type Placed = { sec: string; ord: number };
type Entry = { k: string; t: number; row: Omit<RowT, "sec" | "ord"> };

export function jobRow(ix: Index, job: JobEntry, name: Name): Omit<JobRowT, "sec" | "ord"> {
	const rec = job.record;
	const st = ix.stations.get(job.station.sid);
	const missing = list<ItemT>(rec?.missing);
	return {
		key: `j:${job.jid}`, kind: job.kind, at: job.at, atName: name(job.at), worker: job.lead, n: job.members.size,
		state: rec?.state ?? job.state, status: rec?.status ?? "new", ...rec?.arg !== undefined && { arg: rec.arg },
		tasks: rec?.tasks ?? [0, 0],
		station: {
			sid: job.station.sid, name: st?.name ?? job.station.sid, inst: job.station.inst,
			x: job.station.x, y: job.station.y,
		},
		...missing.length > 0 && { missing },
	};
}

/** Consecutive groups in order, each Σ bytes + commas ≤ budget and ≤ maxCount items; an oversized item goes alone. */
export function chunk<T>(items: T[], bytes: (item: T) => number, budget: number, maxCount = Infinity): T[][] {
	const out: T[][] = [];
	let cur: T[] = [];
	let size = 0;
	for (const item of items) {
		const b = bytes(item);
		if (cur.length > 0 && (size + 1 + b > budget || cur.length >= maxCount)) {
			out.push(cur);
			cur = [];
			size = 0;
		}
		size += (cur.length > 0 ? 1 : 0) + b;
		cur.push(item);
	}
	if (cur.length > 0) { out.push(cur); }
	return out;
}

function workSt(w: Work, now: number): WorkSt {
	if (w.cell.scanned === undefined || w.cell.due > 0) { return "delay"; }
	if (w.backoffUntilMs > now) { return "backoff"; }
	return w.why === "waiting_squad" ? "waiting_squad" : "open";
}
const shownWhy = (w: Work): WorkWhyT | undefined => (w.why === "waiting_squad" ? undefined : w.why);

interface Ctx {
	ix: Index; w: WatchKey; name: Name; now: number;
	add: (sec: string, row: Entry["row"], t: number, k?: string) => void;
	mine: (inst: number) => boolean; commits: () => Map<string, Commit>;
}

function jobRows(c: Ctx, jobs: JobEntry[]) {
	for (const job of jobs.filter(j => c.mine(j.at))) {
		const row = jobRow(c.ix, job, c.name);
		const done = row.state === "returning" || row.state === "unloading";
		let sec = done ? "finishing" : "progress";
		if (PROBLEM.has(row.status)) { sec = "attention"; }
		c.add(sec, row, job.createdMs, sec === "progress" ? job.kind : "");
	}
}

function workRows(c: Ctx, work: Work[]) {
	const workRow = (wk: Work, st: WorkSt): Omit<WorkRowT, "sec" | "ord"> => {
		const rem = need(remaining(wk, c.commits().get(wk.cell.wid)));
		const ctr = wk.cell.center;
		const why = shownWhy(wk);
		return {
			key: `w:${wk.cell.wid}`, kind: wk.cell.kind, owner: wk.inst, ownerName: c.name(wk.inst),
			...ctr && { c: [ctr.x, ctr.y] as [number, number] }, st, ...why && { why }, rem,
			committed: need(remaining(wk, undefined)) - rem, firstSeenMs: wk.firstSeenMs,
			...st === "delay" && { dueAtMs: wk.dueAtMs }, tool: wk.cell.tool,
		};
	};
	const groups = new Map<string, { oldest: Work; st: WorkSt; n: number }>();
	const grouped: Array<{ g: string; w: Work; st: WorkSt }> = [];
	for (const wk of work.filter(e => c.mine(e.inst))) {
		const st = workSt(wk, c.now);
		if (st === "backoff" || wk.why === "unreachable") {
			c.add("attention", workRow(wk, st), wk.firstSeenMs);
			continue;
		}
		if (isCovered(wk, c.commits().get(wk.cell.wid))) { continue; } // its job's row shows it (owner, 2026-10-21)
		const g = `${wk.inst}|${wk.cell.kind}`;
		const cur = groups.get(g);
		if (!cur) {
			groups.set(g, { oldest: wk, st, n: 1 });
		} else {
			cur.n += 1;
			if (wk.firstSeenMs < cur.oldest.firstSeenMs) { cur.oldest = wk; cur.st = st; }
		}
		grouped.push({ g, w: wk, st });
	}
	for (const [g, { oldest, st, n }] of groups) {
		const why = shownWhy(oldest);
		const row: Omit<GroupRowT, "sec" | "ord"> = {
			key: `g:${g}`, kind: oldest.cell.kind, owner: oldest.inst, ownerName: c.name(oldest.inst), n,
			oldestMs: oldest.firstSeenMs, st, ...why && { why },
		};
		c.add("pending", row, oldest.firstSeenMs);
	}
	for (const { g, w: wk, st } of grouped) {
		if (g === c.w.expand) { c.add("cells", workRow(wk, st), wk.firstSeenMs); }
	}
}

function ctronRows(c: Ctx, ctrons: CtronEntry[]) {
	const byCid = new Map<string, JobEntry>();
	for (const job of c.ix.jobs.values()) {
		for (const cid of job.members) { byCid.set(cid, job); }
	}
	for (const e of ctrons.filter(r => c.mine(r.inst))) {
		const job = e.state === "busy" ? byCid.get(e.cid) : undefined;
		const arg = job?.record?.arg;
		const row: Omit<CtronRowT, "sec" | "ord"> = {
			key: `c:${e.cid}`, at: e.inst, atName: c.name(e.inst), name: e.name,
			...e.label !== undefined && { label: e.label }, state: e.state,
			...e.why !== undefined && { why: e.why }, ...e.jid !== undefined && { jid: e.jid },
			...e.state === "idle" && { x: e.x, y: e.y },
			...job && { kind: job.kind, status: job.record?.status ?? "new", ...arg !== undefined && { arg } },
		};
		c.add("ctrons", row, e.inst, e.cid);
	}
}

/** An n: row for each shown station with a need; its order is the open order's count per slot (R-166). */
function needRows(c: Ctx, shown: Map<string, number>): NeedRowT[] {
	const rows: NeedRowT[] = [];
	for (const [key, ord] of shown) {
		const sid = key.slice(2);
		const nd = c.ix.needs.get(sid);
		if (!nd) { continue; }
		const slots = list<SlotT>(nd.slots);
		const open = order(slots, c.ix.inflightTo(sid, c.now));
		const counts = new Map(open.map(i => [itemKey(i[0], i[1]), i[2]]));
		rows.push({
			key: `n:${sid}`, sec: "stations", ord, sid,
			slots: slots.map(s => [s[0], s[1], s[2], s[3], s[4]] as [string, string, number, number, number]),
			...open.length > 0 && { order: slots.map(s => counts.get(itemKey(s[0], s[1])) ?? 0) },
			...(c.ix.orderBackoff.get(sid) ?? 0) > c.now && { why: "no_supplier" as const },
		});
	}
	return rows;
}

/** The items the surface's loading jobs wait for, summed per (name, quality), the largest first. */
function waitingItems(jobs: JobEntry[]): StatsT["waiting"] {
	const waiting = new Map<string, [string, string, number]>();
	for (const job of jobs) {
		if (job.record?.state !== "loading") { continue; }
		for (const [n, q, count] of list<ItemT>(job.record.missing)) {
			const e = waiting.get(itemKey(n, q)) ?? [n, q, 0];
			e[2] += count;
			waiting.set(itemKey(n, q), e);
		}
	}
	return [...waiting.values()].sort((a, b) => b[2] - a[2] || a[0].localeCompare(b[0])).slice(0, WAITING_MAX);
}

export function build(ix: Index, w: WatchKey, name: Name, now: number,
	commits?: Map<string, Commit>): { rows: RowT[]; stats: StatsT } {
	const sections = new Map<string, Entry[]>(SECTIONS.map(s => [s, []]));
	let cm = commits; // a Commit walk only when a row shows a remainder
	const c: Ctx = {
		ix, w, name, now, mine: inst => w.tile === undefined || w.tile === inst,
		add: (sec, row, t, k = "") => { sections.get(sec)!.push({ k, t, row }); },
		commits: () => (cm ??= ix.commitments()),
	};
	const jobs = [...ix.jobs.values()].filter(j => j.surface === w.surface);
	const work = [...ix.work.values()].filter(e => e.cell.surface === w.surface);
	const ctrons = [...ix.ctrons.values()].filter(e => e.surface === w.surface);
	const stationList = [...ix.stations.values()].filter(e => e.surface === w.surface);
	jobRows(c, jobs);
	workRows(c, work);
	ctronRows(c, ctrons);
	for (const s of stationList.filter(e => c.mine(e.inst))) {
		const row: Omit<StationRowT, "sec" | "ord"> = {
			key: `s:${s.sid}`, at: s.inst, atName: name(s.inst), name: s.name, x: s.x, y: s.y,
		};
		c.add("stations", row, s.inst, s.name);
	}

	// Sort, cap and place; ctrons sort by (inst, cid) and stations by (inst, name), the rest by (k, t).
	const more: Record<string, number> = {};
	const rows: RowT[] = [];
	const stationOrd = new Map<string, number>();
	for (const sec of SECTIONS) {
		const entries = sections.get(sec)!;
		const bySecondary = sec === "ctrons" || sec === "stations";
		entries.sort((a, b) => (bySecondary
			? a.t - b.t || a.k.localeCompare(b.k) : a.k.localeCompare(b.k) || a.t - b.t));
		entries.slice(0, CAP).forEach((e, ord) => {
			rows.push({ ...e.row, sec, ord } as RowT);
			if (sec === "stations") { stationOrd.set(e.row.key, ord); }
		});
		if (entries.length > CAP) { more[sec] = entries.length - CAP; }
	}
	rows.push(...needRows(c, stationOrd));

	const tiles = new Set([...jobs.map(j => j.at), ...work.map(e => e.inst), ...ctrons.map(e => e.inst),
		...stationList.map(s => s.inst)]);
	const busy = ix.busyCids();
	const stats: StatsT = {
		total: ctrons.length, available: ctrons.filter(e => e.state === "idle" && !busy.has(e.cid)).length,
		surfaces: [...new Set([...ix.ctrons.values()].map(e => e.surface))].sort(),
		tiles: [...tiles].sort((a, b) => a - b).map((i): [number, string] => [i, name(i)]),
		more, waiting: waitingItems(jobs), now,
	};
	return { rows, stats };
}

interface Watcher { inst: number; w: WatchKey; sent: Map<string, string>; stats: string; seq: number; full: boolean }
const watchId = (inst: number, w: WatchKey) => `${inst}|${w.surface}|${w.tile ?? ""}|${w.expand ?? ""}`;
const bytes = (s: string) => Buffer.byteLength(s);

export class Lists {
	private readonly watchers = new Map<string, Watcher>();

	watch(inst: number, w: WatchKey, on: boolean): void {
		const id = watchId(inst, w);
		const cur = this.watchers.get(id);
		if (!on) {
			this.watchers.delete(id);
		} else if (cur) {
			cur.full = true;
		} else {
			this.watchers.set(id, { inst, w, sent: new Map(), stats: "", seq: 0, full: true });
		}
	}

	dropInstance(inst: number): void {
		for (const [id, wr] of [...this.watchers]) {
			if (wr.inst === inst) { this.watchers.delete(id); }
		}
	}

	push(ix: Index, name: Name, now: number): Array<{ inst: number; payload: UiListT }> {
		const out: Array<{ inst: number; payload: UiListT }> = [];
		if (this.watchers.size === 0) { return out; }
		const commits = ix.commitments();
		for (const wr of this.watchers.values()) {
			const { rows, stats } = build(ix, wr.w, name, now, commits);
			const enc = rows.map(r => [r, JSON.stringify(r)] as const);
			const up = wr.full ? enc : enc.filter(([r, s]) => wr.sent.get(r.key) !== s);
			const keys = new Set(rows.map(r => r.key));
			const rm = wr.full ? [] : [...wr.sent.keys()].filter(k => !keys.has(k));
			const statsKey = JSON.stringify({ ...stats, now: 0 });
			if (!wr.full && up.length === 0 && rm.length === 0 && statsKey === wr.stats) { continue; }
			wr.seq += 1;
			const head = (n: number, i: number, u: RowT[], r: string[]): UiListT => ({
				watch: wr.w, seq: wr.seq, full: wr.full, part: i, parts: n, up: u, rm: r, stats,
			});
			// The header's part numbers are counted at their widest, so a part never outgrows the budget.
			const header = bytes(JSON.stringify(head(999, 999, [], [])));
			type Item = { row: RowT; s: string } | { rm: string };
			const items: Item[] = [...up.map(([row, s]) => ({ row, s })), ...rm.map(k => ({ rm: k }))];
			const size = (it: Item) => ("rm" in it ? bytes(JSON.stringify(it.rm)) : bytes(it.s));
			const parts = chunk(items, size, PART_BYTES - header);
			if (parts.length === 0) { parts.push([]); }
			parts.forEach((p, i) => out.push({ inst: wr.inst, payload: head(parts.length, i + 1,
				p.flatMap(it => ("row" in it ? [it.row] : [])), p.flatMap(it => ("rm" in it ? [it.rm] : []))) }));
			wr.sent = new Map(enc.map(([r, s]) => [r.key, s]));
			wr.stats = statsKey;
			wr.full = false;
		}
		return out;
	}
}
