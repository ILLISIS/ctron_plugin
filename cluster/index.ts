// Spec §6.1, §4.5: the controller's soft mirror of every tile, rebuilt from snapshots (R-3). Pure: now is passed in.
import type { Static } from "@sinclair/typebox";
import {
	list, type Cell, type CellKind, type Ctron, type Delta, type Job, type JobEvent, type JobKind, type Need,
	type Share, type Snapshot, type Station, type StationRef,
} from "../contracts.js";
import { INFLIGHT_HOLD_MS, inflight, itemKey, type Held } from "./cargo.js";
import type { Full } from "./settings.js";
import { withCount, type Amount, type ItemT } from "./sizing.js";

export type CtronRecord = Static<typeof Ctron>;
export type StationRecord = Static<typeof Station>;
export type CellRecord = Static<typeof Cell>;
export type NeedRecord = Static<typeof Need>;
export type SnapshotT = Static<typeof Snapshot>;
export type DeltaT = Static<typeof Delta>;
export type CellKindT = Static<typeof CellKind>;
export type JobRecord = Static<typeof Job>;
export type JobEventT = Static<typeof JobEvent>;
export type JobKindT = Static<typeof JobKind>;
export type ShareT = Static<typeof Share>;
export type StationRefT = Static<typeof StationRef>;
export type CtronEntry = CtronRecord & { inst: number };
export type StationEntry = StationRecord & { inst: number };
export type NeedEntry = NeedRecord & { inst: number };
export type WorkWhy = "no_ctron" | "unreachable" | "no_supplier" | "waiting_squad" | "failed" | "no_progress";
export interface Work {
	inst: number; // the owner, from the wid
	cell: CellRecord; // the last record as sent (R-127: a re-armed cell keeps its last totals, due > 0)
	firstSeenMs: number; // when this index first saw the wid; kept across updates (oldest-first order)
	dueAtMs: number; // now + due ticks in ms at the last record (UI only; assignment reads cell.due === 0)
	backoffUntilMs: number; // 0 = none (R-62, R-130)
	why?: WorkWhy; // the last pass's reason, or the backoff's
}

export const HOLD_MS = 30_000; // R-66
export const ASSIGNED_MS = 60_000; // R-126
export const MOVING_MS = 60_000; // R-64
export const BACKOFF_MS = 300_000; // R-62, R-130
export const DESTROY_RETRY_MS = 5_000; // R-208: CC's default job_start_delay (300 ticks), before the defaults exist

const LEAVING = new Set<string>(["leave_work", "returning", "unloading"]); // run states of a leader leaving the work

export type JobState = "assigned" | "running" | "frozen";
export interface JobEntry {
	jid: string; kind: JobKindT; surface: string; state: JobState;
	at: number; // the instance holding the worker or leader run
	lead: string; // the worker's or leader's cid ("" until known after a restart)
	members: Set<string>; // every member cid ever seen (assign or records)
	parts: Map<number, string[]>; // instance -> its record's member cids (R-153)
	ended: Map<string, "done" | "lost" | "failed">;
	movingSince: Map<string, number>;
	shares: ShareT[];
	sizedFrom: Map<string, string>; // wid -> totalsKey(cell) at assign (R-130); empty after a restart
	left?: number;
	failedWid?: string; // a failed event's wid; absent = every share's wid
	failed: boolean;
	station: StationRefT;
	cargo?: { dest: StationRefT; items: ItemT[] };
	record?: JobRecord; // the latest record from `at`
	createdMs: number;
	cancelled: boolean;
	drops: Array<{ name: string; quality: string }>;
	repick?: Repick; // a re-pick waiting for the scheduler
	repickDone: boolean; // a re-pick was taken for the current short / trash_full status
	resend: boolean; // an `unknown` came back; re-send on the next record
	squad?: { gone: Set<string>; done: boolean }; // destroy: minions gone from the squad; its release (R-202, R-203)
	stations: Map<string, StationRefT>; // a squad's minion cid -> its own station (R-196)
}
/** A squad relay waiting for the scheduler: the whole squad state to `inst`, or a cancel (squads.md §4.4). */
export interface SquadRelay { inst: number; jid: string; cancel?: true }
export interface Repick { jid: string; cid: string; ev: "short" | "trash_full"; items: ItemT[] }
export interface Pending { jid: string; share: ShareT; left?: number; sized?: string }
export interface Commit { bring: Map<string, number>; out: number; live: number } // per wid
export interface Assign {
	jid: string; kind: JobKindT; surface: string; at: number; members: string[]; // lead first (R-153)
	shares: ShareT[]; station: StationRefT; cargo?: { dest: StationRefT; items: ItemT[] };
	sizedFrom: Map<string, string>; stations?: Map<string, StationRefT>;
}

/** R-130: order-independent bring + out + n, to tell whether a cell changed under a job. */
export function totalsKey(cell: CellRecord): string {
	const bring = list<ItemT>(cell.bring).map(i => [i[0], i[1], i[2]] as const)
		.sort((a, b) => a[0].localeCompare(b[0]) || a[1].localeCompare(b[1]));
	return JSON.stringify([bring, cell.out ?? 0, cell.n ?? 0]);
}

/** A cell's totals minus what jobs and pending releases hold; never negative. No totals (not scanned) = nothing. */
export function remaining(w: Work, c: Commit | undefined): Amount {
	if (w.cell.scanned === undefined) { return { bring: [], out: 0 }; }
	const bring: ItemT[] = [];
	for (const item of list<ItemT>(w.cell.bring)) {
		const count = item[2] - (c?.bring.get(itemKey(item[0], item[1])) ?? 0);
		if (count > 0) { bring.push(withCount(item, count)); }
	}
	return { bring, out: Math.max(0, (w.cell.out ?? 0) - (c?.out ?? 0)) };
}

/** Destroy work, or a cell with no item or slot to carry: it takes a ctron, not a share of items. */
export function isItemless(w: Work): boolean {
	return w.cell.kind === "destroy" || (list<ItemT>(w.cell.bring).length === 0 && (w.cell.out ?? 0) === 0);
}

// A scanned cell the live jobs' shares already cover (an itemless one: any live share). The scheduler skips it and
// the Control Center shows its job, not the cell.
export function isCovered(w: Work, c: Commit | undefined): boolean {
	if (w.cell.scanned === undefined) { return false; }
	if (isItemless(w)) { return (c?.live ?? 0) > 0; }
	const r = remaining(w, c);
	return r.out === 0 && r.bring.length === 0;
}

export function ownerOf(wid: string): number {
	return Number(wid.slice(0, wid.indexOf("|")));
}
/** CC's integer key of a wid. */
export function keyOf(wid: string): number {
	return Number(wid.slice(wid.lastIndexOf("|") + 1));
}

interface Buffer { seq: number; parts: number; got: SnapshotT[] }

export class Index {
	readonly ctrons = new Map<string, CtronEntry>(); // cid
	readonly stations = new Map<string, StationEntry>(); // sid
	readonly work = new Map<string, Work>(); // wid
	readonly needs = new Map<string, NeedEntry>(); // sid
	readonly snapshotted = new Set<number>(); // instances whose snapshot applied since they last started
	defaults?: Full; // the first tile defaults received (§6.11 step 4)
	readonly jobs = new Map<string, JobEntry>();
	readonly pending: Pending[] = [];
	/** cid -> expiresMs (now + ASSIGNED_MS): ctrons the controller turned away (R-131); a ctron up clears its entry. */
	readonly rejected = new Map<string, number>();
	/** destination sid -> delivered cargo loads still counted (R-58). */
	readonly held = new Map<string, Held[]>();
	/** destination sid -> ms: a cargo order without a supplier (R-59, R-156). */
	readonly orderBackoff = new Map<string, number>();
	private readonly buffers = new Map<number, Buffer>();
	private readonly resends: Array<{ jid: string; inst: number }> = [];
	private readonly relays = new Map<string, SquadRelay>(); // jid|inst|cancel -> relay
	private holdLatched = false;

	/** destroyRetryMs: the effective job_start_delay in ms, or undefined before the settings defaults exist (R-208). */
	constructor(private readonly startedMs: number, private readonly destroyRetryMs?: () => number | undefined) {}

	/** Buffers one snapshot part; true when it was the last and the instance's records were replaced. */
	snapshotPart(inst: number, snap: SnapshotT, now: number): boolean {
		const part = snap.part ?? 1;
		const parts = snap.parts ?? 1;
		let buf = this.buffers.get(inst);
		if (part === 1) {
			buf = { seq: snap.seq, parts, got: [] };
			this.buffers.set(inst, buf);
		} else if (!buf || buf.seq !== snap.seq || part !== buf.got.length + 1) {
			return false;
		}
		buf.got.push(snap);
		if (buf.got.length < buf.parts) { return false; }
		this.buffers.delete(inst);
		this.replace(inst, buf.got, now);
		return true;
	}

	private replace(inst: number, got: SnapshotT[], now: number) {
		const all = <T>(pick: (s: SnapshotT) => unknown) => got.flatMap(s => list<T>(pick(s) as T[]));
		const ctrons = all<CtronRecord>(s => s.ctrons);
		const stations = all<StationRecord>(s => s.stations);
		const cells = all<CellRecord>(s => s.cells);
		const needs = all<NeedRecord>(s => s.needs);
		this.sweep(this.ctrons, inst, new Set(ctrons.map(c => c.cid)));
		this.sweep(this.stations, inst, new Set(stations.map(s => s.sid)));
		this.sweep(this.needs, inst, new Set(needs.map(n => n.sid)));
		const wids = new Set(cells.map(c => c.wid));
		for (const wid of [...this.work.keys()]) {
			if (ownerOf(wid) === inst && !wids.has(wid)) { this.work.delete(wid); }
		}
		ctrons.forEach(c => this.upCtron(inst, c));
		stations.forEach(s => this.stations.set(s.sid, { ...s, inst }));
		cells.forEach(c => this.upCell(c, now));
		needs.forEach(n => this.needs.set(n.sid, { ...n, inst }));
		this.defaults ??= got[0].defaults as Full | undefined;
		this.snapshotted.add(inst);
		const records = all<JobRecord>(s => s.jobs);
		for (const job of this.jobs.values()) {
			if (job.state === "frozen" && job.at === inst) { job.state = "running"; }
		}
		records.forEach(r => this.applyJob(inst, r, now));
		const have = new Set(records.map(r => r.jid));
		for (const job of [...this.jobs.values()]) {
			if (!have.has(job.jid) && job.parts.has(inst)) { this.rmPart(job, inst, now); }
		}
		this.releasePending(now);
	}

	private sweep(map: Map<string, { inst: number }>, inst: number, keep: Set<string>) {
		for (const [id, e] of [...map]) {
			if (e.inst === inst && !keep.has(id)) { map.delete(id); }
		}
	}

	delta(inst: number, d: DeltaT, now: number): void {
		if (d.ctrons) {
			list<string>(d.ctrons.rm).forEach(id => this.rmOwned(this.ctrons, id, inst));
			list<CtronRecord>(d.ctrons.up).forEach(c => this.upCtron(inst, c));
		}
		if (d.stations) {
			list<string>(d.stations.rm).forEach(id => this.rmOwned(this.stations, id, inst));
			list<StationRecord>(d.stations.up).forEach(s => this.stations.set(s.sid, { ...s, inst }));
		}
		if (d.cells) {
			for (const wid of list<string>(d.cells.rm)) {
				if (ownerOf(wid) === inst) { this.work.delete(wid); }
			}
			list<CellRecord>(d.cells.up).forEach(c => this.upCell(c, now));
		}
		if (d.needs) {
			list<string>(d.needs.rm).forEach(id => this.rmOwned(this.needs, id, inst));
			list<NeedRecord>(d.needs.up).forEach(n => this.needs.set(n.sid, { ...n, inst }));
		}
		if (d.jobs) {
			list<JobRecord>(d.jobs.up).forEach(r => this.applyJob(inst, r, now));
			for (const jid of list<string>(d.jobs.rm)) {
				const job = this.jobs.get(jid);
				if (job) { this.rmPart(job, inst, now); }
			}
		}
		this.releasePending(now);
	}

	/** The tile left running: its records go. Not an owner removal. */
	stop(inst: number): void {
		// No releasePending: a stop is not an owner removal; a pending share waits for the owner's snapshot (R-124).
		for (const map of [this.ctrons, this.stations, this.needs]) { this.sweep(map, inst, new Set()); }
		for (const wid of [...this.work.keys()]) {
			if (ownerOf(wid) === inst) { this.work.delete(wid); }
		}
		this.snapshotted.delete(inst);
		this.buffers.delete(inst);
		for (const job of [...this.jobs.values()]) {
			if (job.at !== inst) { continue; }
			if (job.state === "assigned") {
				this.jobs.delete(job.jid);
			} else if (job.state === "running") {
				job.state = "frozen";
			}
		}
	}

	/** True once 30 s passed since the controller started or every running tile has snapshotted; latched (R-66). */
	holdOver(now: number, running: number[]): boolean {
		const allIn = running.length > 0 && running.every(i => this.snapshotted.has(i)); // R-173: [] doesn't count
		if (!this.holdLatched && (now - this.startedMs >= HOLD_MS || allIn)) {
			this.holdLatched = true;
		}
		return this.holdLatched;
	}

	schedulable(surface: string): boolean {
		return [...this.stations.values()].some(s => s.surface === surface);
	}

	schedulableSurfaces(): string[] {
		return [...new Set([...this.stations.values()].map(s => s.surface))].sort();
	}

	/** Deletes cancelled pending cells (§6.9). */
	forget(wids: string[]): void {
		wids.forEach(w => this.work.delete(w));
	}

	/** A kind turned off (§6.11 step 3): deletes that surface's Work of the kind and returns the wids. */
	dropWork(surface: string, kind: CellKindT): string[] {
		const gone = [...this.work]
			.filter(([, w]) => w.cell.surface === surface && w.cell.kind === kind).map(([k]) => k);
		this.forget(gone);
		return gone;
	}

	/** R-126: the controller creates the job when it sends the assign; it counts and busies its ctrons at once. */
	assign(a: Assign, now: number): void {
		this.jobs.set(a.jid, {
			jid: a.jid, kind: a.kind, surface: a.surface, state: "assigned", at: a.at, lead: a.members[0],
			members: new Set(a.members), parts: new Map([[a.at, [...a.members]]]), ended: new Map(),
			movingSince: new Map(), shares: a.shares, sizedFrom: a.sizedFrom, failed: false, station: a.station,
			cargo: a.cargo, createdMs: now, cancelled: false, drops: [], repickDone: false, resend: false,
			squad: a.kind === "destroy" ? { gone: new Set(), done: false } : undefined,
			stations: new Map(a.stations),
		});
	}

	/** R-126, R-131, R-139, R-143: a tile's event about a job. Unknown jids are ignored. */
	jobEvent(inst: number, ev: JobEventT, now: number): void {
		const job = this.jobs.get(ev.jid);
		if (!job) { return; }
		switch (ev.ev) {
			case "adopted":
				if (job.state === "assigned") { job.state = "running"; }
				break;
			case "rejected":
				// R-211: a squad rejected on one tile is cancelled on all of them: the rejecting tile may hold the
				// leader's adopted run too (review finding 1)
				if (job.squad) { this.tilesOf(job).forEach(t => this.relay(job.jid, t, true)); }
				this.jobs.delete(job.jid);
				for (const cid of job.members) { this.rejected.set(cid, now + ASSIGNED_MS); }
				break;
			case "left": // a minion left its squad to restock (R-202)
				if (ev.cid !== undefined && ev.cid !== job.lead && job.members.has(ev.cid)) { this.gone(job, ev.cid); }
				break;
			case "done": case "lost": case "failed":
				if (ev.cid !== undefined) { this.memberEnded(job, ev as JobEventT & { cid: string }, now); }
				break;
			case "short": case "trash_full":
				if (ev.cid === undefined) { break; }
				job.repick = { jid: job.jid, cid: ev.cid, ev: ev.ev, items: list<ItemT>(ev.missing ?? ev.items) };
				job.repickDone = false;
				break;
			case "unknown":
				job.resend = true;
				job.repickDone = false;
				break;
			default:
				break;
		}
	}

	private memberEnded(job: JobEntry, ev: JobEventT & { cid: string }, now: number) {
		job.ended.set(ev.cid, ev.ev as "done" | "lost" | "failed");
		job.movingSince.delete(ev.cid);
		this.squadEnded(job, ev.cid);
		if (ev.cid === job.lead && ev.left !== undefined) { job.left = ev.left; }
		// a minion's run carries no work (R-209): its failure does not fail the job (review finding 7)
		if (ev.ev === "failed" && (!job.squad || ev.cid === job.lead)) { job.failed = true; job.failedWid = ev.wid; }
		if (ev.ev === "done" && job.cargo && ev.cid === job.lead) {
			const held = this.held.get(job.cargo.dest.sid) ?? [];
			for (const [name, quality, count] of job.cargo.items) {
				held.push([name, quality, count, now + INFLIGHT_HOLD_MS]);
			}
			this.held.set(job.cargo.dest.sid, held);
		}
		this.maybeEnd(job, now);
	}

	/** R-123, R-139, R-143: one tile's job record. */
	private applyJob(inst: number, rec: JobRecord, now: number) {
		let job = this.jobs.get(rec.jid);
		if (!job) {
			job = {
				jid: rec.jid, kind: rec.kind, surface: rec.surface, state: "running", at: inst, lead: "",
				members: new Set(), parts: new Map(), ended: new Map(), movingSince: new Map(), shares: [],
				sizedFrom: new Map(), failed: false, station: rec.station,
				squad: rec.kind === "destroy" ? { gone: new Set(), done: false } : undefined, stations: new Map(),
				cargo: rec.cargo ? { dest: rec.cargo.dest, items: list<ItemT>(rec.cargo.items) } : undefined,
				createdMs: now, cancelled: false, drops: [], repickDone: false, resend: false,
			};
			this.jobs.set(rec.jid, job);
		}
		if (job.state !== "running") { job.state = "running"; }
		const cids = list<string>(rec.members);
		const prev = job.parts.get(inst) ?? [];
		const isNew = !job.parts.has(inst);
		job.parts.set(inst, cids);
		for (const cid of cids) { job.members.add(cid); job.movingSince.delete(cid); }
		if (isNew) {
			this.newPart(job, inst, rec, now);
		} else if (cids.some(c => !prev.includes(c))) {
			this.arrived(job, inst);
		}
		const holdsLead = job.lead !== ""
			? cids.includes(job.lead)
			: list<ShareT>(rec.shares).length > 0 || rec.kind === "cargo";
		if (holdsLead) {
			if (job.lead === "") { job.lead = cids[0] ?? ""; }
			job.at = inst;
			if (!job.cancelled) { job.shares = list<ShareT>(rec.shares); }
			job.left = rec.left ?? job.left;
			job.record = rec;
			if (LEAVING.has(rec.state)) { this.release(job); } // R-203
			if (rec.cargo) { job.cargo = { dest: rec.cargo.dest, items: list<ItemT>(rec.cargo.items) }; }
			if ((rec.status === "short" || rec.status === "trash_full") && !job.repick && !job.repickDone) {
				job.repick = { jid: job.jid, cid: job.lead, ev: rec.status, items: list<ItemT>(rec.missing) };
			} else if (rec.status !== "short" && rec.status !== "trash_full") {
				job.repickDone = false;
			}
		}
		if (job.resend) {
			job.resend = false;
			this.resends.push({ jid: job.jid, inst });
		}
		this.leftPart(job, prev.filter(c => !cids.includes(c)), now);
	}

	/** R-123: only this instance's part changes. */
	private rmPart(job: JobEntry, inst: number, now: number) {
		const prev = job.parts.get(inst);
		if (!prev) { return; }
		job.parts.delete(inst);
		this.leftPart(job, prev, now);
	}

	/** R-123: a member nobody lists any more, with no event, is moving. */
	private leftPart(job: JobEntry, cids: string[], now: number) {
		for (const cid of cids) {
			if (job.ended.has(cid) || [...job.parts.values()].some(p => p.includes(cid))) { continue; }
			job.movingSince.set(cid, job.movingSince.get(cid) ?? now);
		}
	}

	/** R-124: when every member ended, the shares go to pending release. */
	private maybeEnd(job: JobEntry, now: number) {
		for (const cid of job.members) {
			if (!job.ended.has(cid)) { return; }
		}
		this.jobs.delete(job.jid);
		if (!job.cancelled) {
			for (const share of job.shares) {
				this.pending.push({ jid: job.jid, share, left: job.left, sized: job.sizedFrom.get(share.wid) });
			}
		}
		if (job.failed) {
			const wids = job.failedWid !== undefined ? [job.failedWid] : job.shares.map(s => s.wid);
			wids.forEach(w => this.backoff(w, "failed", now));
		}
		this.releasePending(now);
	}

	/** R-208: a destroy cell retries after the effective job_start_delay, as CC re-queues it; the rest wait 5 min. */
	private backoff(wid: string, why: WorkWhy, now: number) {
		const w = this.work.get(wid);
		if (!w) { return; }
		w.backoffUntilMs = now + (w.cell.kind === "destroy" ? this.destroyRetryMs?.() ?? DESTROY_RETRY_MS : BACKOFF_MS);
		w.why = why;
	}

	/** A tile reports a part of the job for the first time: a squad's gets the whole state at once (R-199). */
	private newPart(job: JobEntry, inst: number, rec: JobRecord, now: number) {
		if (job.squad) { this.relay(job.jid, inst); }
		if (rec.lead !== undefined) { this.namedLead(job, rec.lead, now); }
	}

	/** A member arrived on a part already known: it needs the squad state too (design 4.4, review finding 2). */
	private arrived(job: JobEntry, inst: number) {
		if (job.squad) { this.relay(job.jid, inst); }
	}

	/** R-209: a part without the leader names it; unlisted by any part for 60 s it is lost (R-64). */
	private namedLead(job: JobEntry, lead: string, now: number) {
		job.lead ||= lead;
		job.members.add(lead);
		if (!job.ended.has(lead) && ![...job.parts.values()].some(p => p.includes(lead))) {
			job.movingSince.set(lead, job.movingSince.get(lead) ?? now);
		}
	}

	private relay(jid: string, inst: number, cancel?: true) {
		this.relays.set(`${jid}|${inst}|${cancel ? 1 : 0}`, { inst, jid, ...cancel && { cancel } });
	}

	/** R-202: a minion left the squad; the tile holding the leader drops it from the leader's list. */
	private gone(job: JobEntry, cid: string) {
		if (!job.squad || job.squad.gone.has(cid)) { return; }
		job.squad.gone.add(cid);
		const holder = this.holderOf(job.jid, job.lead);
		if (holder !== undefined) { this.relay(job.jid, holder); }
	}

	/** R-203: the leader is leaving the work or ended; every tile holding the job releases its minions. */
	private release(job: JobEntry) {
		if (!job.squad || job.squad.done) { return; }
		job.squad.done = true;
		// tilesOf, not parts: a minion's tile may not have reported its part yet
		for (const inst of this.tilesOf(job)) { this.relay(job.jid, inst); }
	}

	/** A member of a squad ended (done, lost or failed): the leader releases the squad, a minion leaves it. */
	private squadEnded(job: JobEntry, cid: string) {
		if (cid === job.lead) { this.release(job); } else { this.gone(job, cid); }
	}

	/** R-124, R-130: drop each pending release that no longer waits on its owner's scan. */
	private releasePending(now: number) {
		for (let i = this.pending.length - 1; i >= 0; i--) {
			const { share, left, sized } = this.pending[i];
			const w = this.work.get(share.wid);
			let release = left === undefined || (!w && this.snapshotted.has(ownerOf(share.wid)));
			if (!release && w && w.cell.scanned !== undefined && left !== undefined && w.cell.scanned >= left) {
				release = true;
				if (sized !== undefined && sized === totalsKey(w.cell)) { this.backoff(share.wid, "no_progress", now); }
			}
			if (release) { this.pending.splice(i, 1); }
		}
	}

	/** R-124: shares release at once; the ctrons stay busy until their runs end. */
	cancel(jid: string): JobEntry | undefined {
		const job = this.jobs.get(jid);
		if (!job) { return undefined; }
		job.cancelled = true;
		job.shares = [];
		return job;
	}

	/** Called every second: expires unanswered assigns, ends members listed nowhere for 60 s (R-64). */
	tick(now: number): { expired: string[]; lost: Array<[string, string]> } {
		const expired: string[] = [];
		const lost: Array<[string, string]> = [];
		for (const job of [...this.jobs.values()]) {
			if (job.state === "assigned" && now - job.createdMs >= ASSIGNED_MS) {
				this.jobs.delete(job.jid);
				expired.push(job.jid);
				continue;
			}
			if (job.state === "frozen") { continue; }
			for (const [cid, since] of [...job.movingSince]) {
				if (now - since < MOVING_MS) { continue; }
				job.movingSince.delete(cid);
				job.ended.set(cid, "lost");
				this.squadEnded(job, cid);
				lost.push([job.jid, cid]);
			}
			this.maybeEnd(job, now);
		}
		for (const [cid, until] of [...this.rejected]) {
			if (until <= now) { this.rejected.delete(cid); }
		}
		for (const [sid, loads] of [...this.held]) {
			const keep = loads.filter(h => h[3] > now);
			if (keep.length) { this.held.set(sid, keep); } else { this.held.delete(sid); }
		}
		for (const [sid, until] of [...this.orderBackoff]) {
			if (until <= now) { this.orderBackoff.delete(sid); }
		}
		return { expired, lost };
	}

	/** One walk over every live job and pending release; nothing is kept in sync. */
	commitments(): Map<string, Commit> {
		const out = new Map<string, Commit>();
		const add = (s: ShareT, seen: Set<string>) => {
			let c = out.get(s.wid);
			if (!c) { c = { bring: new Map(), out: 0, live: 0 }; out.set(s.wid, c); }
			for (const [name, quality, count] of list<ItemT>(s.bring)) {
				const k = itemKey(name, quality);
				c.bring.set(k, (c.bring.get(k) ?? 0) + count);
			}
			c.out += s.out;
			if (!seen.has(s.wid)) { seen.add(s.wid); c.live += 1; }
		};
		for (const job of this.jobs.values()) {
			if (job.cancelled) { continue; }
			const seen = new Set<string>();
			job.shares.forEach(s => add(s, seen));
		}
		this.pending.forEach(p => add(p.share, new Set()));
		return out;
	}

	/** Every member of every job (cancelled too) that has not ended. */
	busyCids(): Set<string> {
		const busy = new Set<string>();
		for (const job of this.jobs.values()) {
			for (const cid of job.members) {
				if (!job.ended.has(cid)) { busy.add(cid); }
			}
		}
		return busy;
	}

	isRejected(cid: string, now: number): boolean {
		return (this.rejected.get(cid) ?? 0) > now;
	}

	/** R-58: live cargo loads headed to sid plus held ones. */
	inflightTo(sid: string, now: number): Map<string, number> {
		const live: ItemT[][] = [];
		for (const job of this.jobs.values()) {
			if (job.cargo && !job.cancelled && job.cargo.dest.sid === sid && !job.ended.has(job.lead)) {
				live.push(job.cargo.items);
			}
		}
		return inflight(live, this.held.get(sid) ?? [], now);
	}

	takeRepicks(): Repick[] {
		const out: Repick[] = [];
		for (const job of this.jobs.values()) {
			if (job.repick) { out.push(job.repick); job.repick = undefined; job.repickDone = true; }
		}
		return out;
	}

	takeResends(): Array<{ jid: string; inst: number }> {
		return this.resends.splice(0);
	}

	/** The squad relays queued since the last call (squads.md §4.4). */
	takeSquad(): SquadRelay[] {
		const out = [...this.relays.values()];
		this.relays.clear();
		return out;
	}

	/** Every tile that holds or may hold a part of the job: reported parts, the leader's tile, the members' tiles. */
	tilesOf(job: JobEntry): Set<number> {
		const tiles = new Set([job.at, ...job.parts.keys()]);
		for (const cid of job.members) {
			const inst = this.ctrons.get(cid)?.inst;
			if (inst !== undefined) { tiles.add(inst); }
		}
		return tiles;
	}

	/** Where to send a member's message: the destination that holds the lead beats a source part not yet removed. */
	holderOf(jid: string, cid: string): number | undefined {
		const job = this.jobs.get(jid);
		if (!job) { return undefined; }
		if (job.parts.get(job.at)?.includes(cid)) { return job.at; }
		for (const [inst, cids] of job.parts) {
			if (cids.includes(cid)) { return inst; }
		}
		return job.at;
	}

	private upCtron(inst: number, c: CtronRecord) {
		const old = this.ctrons.get(c.cid);
		this.ctrons.set(c.cid, { ...c, inst });
		this.rejected.delete(c.cid);
		// the leader of a squad changed tile (the source's rm may land after this up, R-123): its parts learn its place
		const job = c.jid !== undefined ? this.jobs.get(c.jid) : undefined;
		if (job?.squad && job.lead === c.cid && old?.inst !== inst) {
			for (const part of job.parts.keys()) { if (part !== inst) { this.relay(job.jid, part); } }
		}
	}

	private rmOwned(map: Map<string, { inst: number }>, id: string, inst: number) {
		if (map.get(id)?.inst === inst) { map.delete(id); }
	}

	private upCell(cell: CellRecord, now: number) {
		const old = this.work.get(cell.wid);
		this.work.set(cell.wid, {
			inst: ownerOf(cell.wid), cell, firstSeenMs: old?.firstSeenMs ?? now,
			dueAtMs: now + Math.round(cell.due * 1000 / 60), backoffUntilMs: old?.backoffUntilMs ?? 0, why: old?.why,
		});
	}
}
