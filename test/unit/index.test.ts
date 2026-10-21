import { test } from "node:test";
import assert from "node:assert/strict";
import {
	ASSIGNED_MS, BACKOFF_MS, DESTROY_RETRY_MS, HOLD_MS, Index, MOVING_MS, keyOf, ownerOf, remaining, totalsKey,
	type CellRecord, type CtronRecord,
} from "../../cluster/index.js";
import { INFLIGHT_HOLD_MS } from "../../cluster/cargo.js";

const DEFAULTS = {
	job_start_delay: 300, debug: false, horde: false, zone_restriction: false, robot: ["construction-robot", "normal"],
	robot_count: 50, repair_tool: ["repair-pack", "normal"], ammo: ["rocket", "normal"], ammo_count: 0,
	atomic: ["atomic-bomb", "normal"], atomic_count: 0, min_cluster: 8, minions: 1,
	kinds: { construction: true, rebuild: true, deconstruction: true, upgrade: true, repair: true, destroy: false },
} as const;
const ctron = (cid: string, extra: Partial<CtronRecord> = {}): CtronRecord => ({
	cid, surface: "nauvis", name: "constructron", quality: "normal", x: 0, y: 0, state: "idle",
	free: { normal: 40, destroy: 40, cargo: 40 }, restock: { normal: [], destroy: [], cargo: [] }, ...extra,
});
const station = (sid: string, surface = "nauvis") => ({ sid, surface, name: "service_station", x: 0, y: 0 });
const cell = (wid: string, extra: Partial<CellRecord> = {}): CellRecord => ({
	wid, surface: "nauvis", kind: "construction", since: 0, due: 0, tool: false, scanned: 100,
	area: { left_top: { x: 0, y: 0 }, right_bottom: { x: 80, y: 80 } }, center: { x: 40, y: 40 },
	bring: [["stone-brick", "normal", 100, 100]], out: 0, n: 100, ...extra,
});
const snap = (inst: number, s: Record<string, unknown>, part = 1, parts = 1) => ({
	ctrons: [], stations: [], cells: [], needs: [], jobs: [], defaults: { ...DEFAULTS, minions: inst },
	part, parts, ...s,
}) as any;
const W1 = "1|nauvis|construction|5";

test("ids: a wid's owner and CC key", () => {
	assert.equal(ownerOf("12|nauvis|construction|-40"), 12);
	assert.equal(keyOf("12|nauvis|construction|-40"), -40);
});

test("a snapshot replaces only its instance's records; the first defaults stay (§6.1)", () => {
	const ix = new Index(0);
	const first = snap(1, { ctrons: [ctron("1.1")], stations: [station("1.9")], cells: [cell(W1)] });
	assert.equal(ix.snapshotPart(1, first, 10), true);
	ix.snapshotPart(2, snap(2, { ctrons: [ctron("2.1")] }), 10);
	ix.snapshotPart(1, snap(1, { ctrons: [ctron("1.3")] }), 20);
	assert.deepEqual([...ix.ctrons.keys()].sort(), ["1.3", "2.1"]);
	assert.equal(ix.stations.size, 0);
	assert.equal(ix.work.size, 0);
	assert.equal(ix.ctrons.get("1.3")!.inst, 1);
	assert.equal(ix.defaults!.minions, 1, "tile 1's defaults came first");
});

test("snapshot parts apply as one replace at the last part; a part 1 restarts the buffer (R-125)", () => {
	const ix = new Index(0);
	assert.equal(ix.snapshotPart(1, snap(1, { ctrons: [ctron("1.1")] }, 1, 2), 10), false);
	assert.equal(ix.ctrons.size, 0, "nothing applies before the last part");
	ix.delta(1, { ctrons: { up: [ctron("1.9")], rm: [] } } as any, 11);
	assert.ok(ix.ctrons.has("1.9"), "a delta between parts applies at once");
	assert.equal(ix.snapshotPart(1, snap(1, { ctrons: [ctron("1.2")] }, 2, 2), 12), true);
	assert.deepEqual([...ix.ctrons.keys()].sort(), ["1.1", "1.2"], "the replace removes what the snapshot lacks");
	ix.snapshotPart(1, snap(1, { ctrons: [ctron("1.4")] }, 1, 2), 20);
	ix.snapshotPart(1, snap(1, { ctrons: [ctron("1.5")] }, 1, 2), 21);
	ix.snapshotPart(1, snap(1, { ctrons: [ctron("1.6")] }, 2, 2), 22);
	assert.deepEqual([...ix.ctrons.keys()].sort(), ["1.5", "1.6"]);
});

test("ownership: a crossing ctron's source rm and destination up, in either order, end on the destination", () => {
	const upThenRm = new Index(0);
	upThenRm.delta(1, { ctrons: { up: [ctron("1.1")], rm: [] } } as any, 1);
	upThenRm.delta(2, { ctrons: { up: [ctron("1.1", { x: 5 })], rm: [] } } as any, 2);
	upThenRm.delta(1, { ctrons: { up: [], rm: ["1.1"] } } as any, 3);
	assert.equal(upThenRm.ctrons.get("1.1")?.inst, 2, "the source's late rm is ignored");
	const rmThenUp = new Index(0);
	rmThenUp.delta(1, { ctrons: { up: [ctron("1.1")], rm: [] } } as any, 1);
	rmThenUp.delta(1, { ctrons: { up: [], rm: ["1.1"] } } as any, 2);
	assert.equal(rmThenUp.ctrons.has("1.1"), false);
	rmThenUp.delta(2, { ctrons: { up: [ctron("1.1")], rm: [] } } as any, 3);
	assert.equal(rmThenUp.ctrons.get("1.1")?.inst, 2);
	rmThenUp.delta(3, { ctrons: { up: [], rm: ["1.1"] }, stations: { up: [], rm: ["9.9"] } } as any, 4);
	assert.equal(rmThenUp.ctrons.get("1.1")?.inst, 2, "an rm from a non-owner, or of an unknown id, is a no-op");
});

test("cells: first seen kept, due stamped absolute, backoff kept across updates; Lua's {} lists accepted", () => {
	const ix = new Index(0);
	ix.delta(1, { cells: { up: [cell(W1, { due: 300, scanned: undefined, bring: undefined })], rm: {} } } as any, 1000);
	assert.equal(ix.work.get(W1)!.firstSeenMs, 1000);
	assert.equal(ix.work.get(W1)!.dueAtMs, 6000, "300 ticks = 5 s");
	ix.work.get(W1)!.backoffUntilMs = 99_000;
	ix.delta(1, { cells: { up: [cell(W1)], rm: [] } } as any, 7000);
	assert.equal(ix.work.get(W1)!.firstSeenMs, 1000);
	assert.equal(ix.work.get(W1)!.backoffUntilMs, 99_000);
	ix.delta(2, { cells: { up: [], rm: [W1] } } as any, 8000);
	assert.ok(ix.work.has(W1), "only the owner removes a cell");
	ix.delta(1, { cells: { up: [], rm: [W1] } } as any, 9000);
	assert.equal(ix.work.has(W1), false);
});

test("a stopped tile's ctrons, stations, cells and needs go; others stay (§6.1)", () => {
	const ix = new Index(0);
	ix.snapshotPart(1, snap(1, { ctrons: [ctron("1.1")], stations: [station("1.9")], cells: [cell(W1)] }), 1);
	ix.snapshotPart(2, snap(2, { ctrons: [ctron("2.1")], stations: [station("2.9", "gleba")] }), 1);
	ix.stop(1);
	assert.deepEqual([...ix.ctrons.keys()], ["2.1"]);
	assert.deepEqual([...ix.stations.keys()], ["2.9"]);
	assert.equal(ix.work.size, 0);
	assert.equal(ix.snapshotted.has(1), false);
	assert.deepEqual(ix.schedulableSurfaces(), ["gleba"]);
});

test("the restart hold: every running tile snapshotted, or 30 s; then latched (R-66)", () => {
	const ix = new Index(0);
	assert.equal(ix.holdOver(1000, [1, 2]), false);
	ix.snapshotPart(1, snap(1, {}), 1000);
	assert.equal(ix.holdOver(1001, [1, 2]), false);
	ix.snapshotPart(2, snap(2, {}), 1002);
	assert.equal(ix.holdOver(1003, [1, 2]), true);
	assert.equal(ix.holdOver(1004, [1, 2, 3]), true, "a tile starting later doesn't re-arm it");
	assert.equal(new Index(0).holdOver(HOLD_MS - 1, [1]), false);
	assert.equal(new Index(0).holdOver(HOLD_MS, [1]), true);
	assert.equal(new Index(0).holdOver(1000, []), false, "an empty pending list doesn't end it (R-173)");
	assert.equal(new Index(0).holdOver(HOLD_MS, []), true);
});

test("schedulable surfaces: those with a station anywhere in the cluster, sorted (§6.2)", () => {
	const ix = new Index(0);
	ix.snapshotPart(2, snap(2, { stations: [station("2.9", "nauvis"), station("2.8", "gleba")] }), 1);
	ix.snapshotPart(1, snap(1, { stations: [station("1.9", "nauvis")] }), 1);
	assert.deepEqual(ix.schedulableSurfaces(), ["gleba", "nauvis"]);
	assert.equal(ix.schedulable("vulcanus"), false);
});

test("forget and dropWork remove Work; dropWork matches surface and kind", () => {
	const ix = new Index(0);
	const W2 = "1|nauvis|upgrade|6";
	const W3 = "2|gleba|upgrade|6";
	ix.delta(1, { cells: { up: [cell(W1), cell(W2, { kind: "upgrade" })], rm: [] } } as any, 1);
	ix.delta(2, { cells: { up: [cell(W3, { kind: "upgrade", surface: "gleba" })], rm: [] } } as any, 1);
	assert.deepEqual(ix.dropWork("nauvis", "upgrade"), [W2]);
	ix.forget([W1]);
	assert.deepEqual([...ix.work.keys()], [W3]);
});

const ST = { sid: "1.9", inst: 1, x: 0, y: 0 };
const share = (wid: string, n = 40) => ({ wid, bring: [["stone-brick", "normal", n, 100]], out: 0 }) as any;
const assignJob = (ix: Index, jid: string, cid: string, wid: string, at = 1, n = 40, sized?: string) => ix.assign({
	jid, kind: "construction", surface: "nauvis", at, members: [cid], shares: [share(wid, n)],
	station: ST, sizedFrom: new Map(sized ? [[wid, sized]] : []),
}, 0);
const rec = (jid: string, members: string[], state = "to_work", extra: Record<string, unknown> = {}) => ({
	jid, kind: "construction", surface: "nauvis", members, state, status: "working",
	tasks: [0, 1], station: ST, shares: [], ...extra,
}) as any;
const jobsUp = (...records: unknown[]) => ({ jobs: { up: records, rm: [] } }) as any;
const jobsRm = (...jids: string[]) => ({ jobs: { up: [], rm: jids } }) as any;
const ev = (jid: string, e: string, extra: Record<string, unknown> = {}) => ({ jid, ev: e, tick: 0, ...extra }) as any;
const W2 = "2|nauvis|construction|7"; // a cell owned by tile 2
const open = (ix: Index, wid: string) => remaining(ix.work.get(wid)!, ix.commitments().get(wid));
const openCount = (ix: Index, wid: string) => open(ix, wid).bring[0]?.[2] ?? 0;

test("an assigned job counts at once; adopted → running; rejected → deleted, ctron skipped (R-126, R-131)", () => {
	const ix = new Index(0);
	ix.delta(1, { ctrons: { up: [ctron("1.1")], rm: [] }, cells: { up: [cell(W1)], rm: [] } } as any, 0);
	assignJob(ix, "j1", "1.1", W1);
	assert.equal(openCount(ix, W1), 60, "100 − 40 at once, before any tile record");
	assert.ok(ix.busyCids().has("1.1"));
	ix.jobEvent(1, ev("j1", "adopted"), 1);
	assert.equal(ix.jobs.get("j1")!.state, "running");
	assignJob(ix, "j2", "1.1", W1);
	ix.jobEvent(1, ev("j2", "rejected", { why: "robots_out" }), 2);
	assert.equal(ix.jobs.has("j2"), false);
	assert.ok(ix.isRejected("1.1", 3));
	ix.delta(1, { ctrons: { up: [ctron("1.1", { state: "unfit", why: "robots_out" })], rm: [] } } as any, 4);
	assert.equal(ix.isRejected("1.1", 5), false, "its next record clears it");
});

test("tick prunes expired order backoffs (M7)", () => {
	const ix = new Index(0);
	ix.orderBackoff.set("a", 10);
	ix.orderBackoff.set("b", 20);
	ix.tick(10);
	assert.deepEqual([...ix.orderBackoff.keys()], ["b"]);
});

test("an assign with no answer for 60 s is deleted; a rejected squad member comes back after 60 s", () => {
	const ix = new Index(0);
	ix.delta(1, { cells: { up: [cell(W1)], rm: [] } } as any, 0);
	assignJob(ix, "j1", "1.1", W1);
	assert.deepEqual(ix.tick(ASSIGNED_MS - 1).expired, []);
	assert.deepEqual(ix.tick(ASSIGNED_MS).expired, ["j1"]);
	assert.equal(openCount(ix, W1), 100);
	assignJob(ix, "j2", "1.1", W1);
	ix.jobEvent(1, ev("j2", "rejected"), ASSIGNED_MS);
	assert.equal(ix.isRejected("1.1", 2 * ASSIGNED_MS), false);
});

test("a crossing's parts in either order: no moving, no false lost (R-123)", () => {
	for (const order of ["up-first", "rm-first"]) {
		const ix = new Index(0);
		ix.delta(2, { cells: { up: [cell(W2)], rm: [] } } as any, 0);
		assignJob(ix, "j1", "1.1", W2);
		ix.delta(1, jobsUp(rec("j1", ["1.1"], "to_work", { shares: [share(W2)] })), 1);
		if (order === "up-first") {
			ix.delta(2, jobsUp(rec("j1", ["1.1"], "to_work", { shares: [share(W2)] })), 2);
			ix.delta(1, jobsRm("j1"), 3);
			assert.equal(ix.jobs.get("j1")!.movingSince.size, 0, order);
		} else {
			ix.delta(1, jobsRm("j1"), 2);
			assert.ok(ix.jobs.get("j1")!.movingSince.has("1.1"), "listed nowhere: moving");
			ix.delta(2, jobsUp(rec("j1", ["1.1"], "to_work", { shares: [share(W2)] })), 3);
			assert.equal(ix.jobs.get("j1")!.movingSince.size, 0, order);
		}
		assert.deepEqual(ix.tick(MOVING_MS + 10).lost, [], order);
		assert.equal(ix.jobs.get("j1")!.at, 2, order);
		assert.equal(openCount(ix, W2), 60, order);
	}
});

test("a member listed nowhere for 60 s is lost; the job ends and, with no left, releases at once (R-64)", () => {
	const ix = new Index(0);
	ix.snapshotPart(2, snap(2, { cells: [cell(W2)] }), 0);
	assignJob(ix, "j1", "1.1", W2);
	ix.delta(1, jobsUp(rec("j1", ["1.1"], "to_station", { shares: [share(W2)] })), 1);
	ix.delta(1, jobsRm("j1"), 2);
	assert.deepEqual(ix.tick(2 + MOVING_MS).lost, [["j1", "1.1"]]);
	assert.equal(ix.jobs.has("j1"), false);
	assert.equal(openCount(ix, W2), 100);
});

test("release waits for the work tile's scan at or after left, in either arrival order (R-124)", () => {
	const finish = (ix: Index) => {
		ix.jobEvent(1, ev("j1", "done", { cid: "1.1", left: 500 }), 10);
		ix.delta(1, jobsRm("j1"), 11);
	};
	const a = new Index(0); // the station tile's done first, the work tile's scan later
	a.snapshotPart(2, snap(2, { cells: [cell(W2, { scanned: 400 })] }), 0);
	assignJob(a, "j1", "1.1", W2);
	finish(a);
	assert.equal(a.jobs.has("j1"), false, "the job left the index");
	assert.equal(openCount(a, W2), 60, "its share is still held: pending release");
	a.delta(2, { cells: { up: [cell(W2, { scanned: 450 })], rm: [] } } as any, 12);
	assert.equal(openCount(a, W2), 60, "450 < 500");
	const bring30 = [["stone-brick", "normal", 30, 100]] as any;
	const scan30 = { cells: { up: [cell(W2, { scanned: 520, bring: bring30 })], rm: [] } } as any;
	a.delta(2, scan30, 13);
	assert.equal(openCount(a, W2), 30, "released; 30 left is all open");
	const b = new Index(0); // the work tile's scan first
	b.snapshotPart(2, snap(2, { cells: [cell(W2, { scanned: 400 })] }), 0);
	assignJob(b, "j1", "1.1", W2);
	b.delta(2, scan30, 5);
	finish(b);
	assert.equal(b.pending.length, 0);
	assert.equal(openCount(b, W2), 30);
});

test("release: the owner removing the cell releases; a stopped owner's dropped cell doesn't (R-124)", () => {
	const ix = new Index(0);
	ix.snapshotPart(2, snap(2, { cells: [cell(W2, { scanned: 400 })] }), 0);
	assignJob(ix, "j1", "1.1", W2);
	ix.jobEvent(1, ev("j1", "done", { cid: "1.1", left: 500 }), 10);
	ix.stop(2);
	assert.equal(ix.pending.length, 1, "tile 2 stopped: its cells were dropped, not removed");
	ix.snapshotPart(2, snap(2, { cells: [] }), 20);
	assert.equal(ix.pending.length, 0, "its snapshot lacks the cell: the owner removed it");
});

test("a job that changed nothing backs its cell off 5 min; a failed job backs off at once (R-130, R-62)", () => {
	const ix = new Index(0);
	ix.snapshotPart(2, snap(2, { cells: [cell(W2, { scanned: 400 })] }), 0);
	assignJob(ix, "j1", "1.1", W2, 1, 40, totalsKey(cell(W2)));
	ix.jobEvent(1, ev("j1", "done", { cid: "1.1", left: 500 }), 10);
	ix.delta(2, { cells: { up: [cell(W2, { scanned: 520 })], rm: [] } } as any, 1000);
	assert.equal(ix.work.get(W2)!.backoffUntilMs, 1000 + BACKOFF_MS);
	assert.equal(ix.work.get(W2)!.why, "no_progress");
	const f = new Index(0);
	f.snapshotPart(2, snap(2, { cells: [cell(W2)] }), 0);
	assignJob(f, "j1", "1.1", W2);
	f.jobEvent(1, ev("j1", "failed", { cid: "1.1", why: "no_route" }), 2000);
	assert.equal(f.work.get(W2)!.why, "failed");
	assert.equal(f.work.get(W2)!.backoffUntilMs, 2000 + BACKOFF_MS);
	assert.equal(openCount(f, W2), 100, "no left: released at once");
});

test("totalsKey ignores bring order; remaining never goes negative", () => {
	const x = cell(W1, { bring: [["a", "normal", 1, 50], ["b", "normal", 2, 50]] });
	const y = cell(W1, { bring: [["b", "normal", 2, 50], ["a", "normal", 1, 50]] });
	assert.equal(totalsKey(x), totalsKey(y));
	const w = { inst: 1, cell: cell(W1, { out: 3 }), firstSeenMs: 0, dueAtMs: 0, backoffUntilMs: 0 };
	const over = { bring: new Map([["stone-brick\u0000normal", 500]]), out: 9, live: 2 };
	assert.deepEqual(remaining(w, over), { bring: [], out: 0 });
});

test("a squad ends only when every member has ended; parts on two tiles (§6.1)", () => {
	const ix = new Index(0);
	ix.snapshotPart(2, snap(2, { cells: [cell(W2, { kind: "destroy", bring: [] })] }), 0);
	ix.assign({ jid: "s1", kind: "destroy", surface: "nauvis", at: 1, members: ["1.1", "1.2"],
		shares: [{ wid: W2, bring: [], out: 0 }], station: ST, sizedFrom: new Map() }, 0);
	ix.delta(2, jobsUp(rec("s1", ["1.1"], "fight", { shares: [{ wid: W2, bring: [], out: 0 }] })), 1);
	ix.delta(1, jobsUp(rec("s1", ["1.2"], "to_work")), 1);
	ix.jobEvent(2, ev("s1", "done", { cid: "1.1" }), 2);
	assert.ok(ix.jobs.has("s1"), "the minion is still out");
	assert.equal(ix.commitments().get(W2)!.live, 1);
	ix.jobEvent(1, ev("s1", "done", { cid: "1.2" }), 3);
	assert.equal(ix.jobs.has("s1"), false);
});

test("frozen with its tile: shares kept, members not moving; the snapshot thaws it (R-63)", () => {
	const ix = new Index(0);
	ix.snapshotPart(2, snap(2, { cells: [cell(W2)] }), 0);
	assignJob(ix, "j1", "1.1", W2);
	ix.jobEvent(1, ev("j1", "adopted"), 1);
	assignJob(ix, "j2", "1.2", W2, 1, 10);
	ix.stop(1);
	assert.equal(ix.jobs.get("j1")!.state, "frozen");
	assert.equal(ix.jobs.has("j2"), false, "an unadopted assign to a stopped tile is dropped");
	assert.deepEqual(ix.tick(10 * MOVING_MS).lost, []);
	assert.equal(openCount(ix, W2), 60);
	ix.snapshotPart(1, snap(1, { jobs: [rec("j1", ["1.1"], "to_work", { shares: [share(W2)] })] }), 20);
	assert.equal(ix.jobs.get("j1")!.state, "running");
});

test("after a controller restart, snapshot job records rebuild the commitments (§6.10)", () => {
	const ix = new Index(0);
	ix.snapshotPart(2, snap(2, { cells: [cell(W2)] }), 0);
	ix.snapshotPart(1, snap(1, { jobs: [rec("old", ["1.1"], "loading", { shares: [share(W2, 70)] })] }), 0);
	assert.equal(openCount(ix, W2), 30);
	assert.ok(ix.busyCids().has("1.1"));
});

test("cancel releases at once; the ctron stays busy until its run ends (R-124, R-39)", () => {
	const ix = new Index(0);
	ix.snapshotPart(2, snap(2, { cells: [cell(W2)] }), 0);
	assignJob(ix, "j1", "1.1", W2);
	ix.cancel("j1");
	assert.equal(openCount(ix, W2), 100);
	assert.ok(ix.busyCids().has("1.1"));
	ix.jobEvent(1, ev("j1", "done", { cid: "1.1", left: 9 }), 5);
	assert.equal(ix.pending.length, 0, "nothing pending for a cancelled job");
});

test("re-picks: a short event once; a short record when none is pending (R-143); unknown re-sends (R-139)", () => {
	const ix = new Index(0);
	assignJob(ix, "j1", "1.1", W1);
	ix.jobEvent(1, ev("j1", "short", { cid: "1.1", missing: [["gear", "normal", 5]] }), 1);
	assert.deepEqual(ix.takeRepicks(), [{ jid: "j1", cid: "1.1", ev: "short", items: [["gear", "normal", 5]] }]);
	ix.delta(1, jobsUp(rec("j1", ["1.1"], "loading", { status: "short", missing: [["gear", "normal", 5]] })), 2);
	assert.deepEqual(ix.takeRepicks(), [], "already re-picked for this status");
	ix.delta(1, jobsUp(rec("j1", ["1.1"], "loading", { status: "awaiting_logistics" })), 3);
	ix.delta(1, jobsUp(rec("j1", ["1.1"], "loading", { status: "short", missing: [["gear", "normal", 5]] })), 4);
	assert.equal(ix.takeRepicks().length, 1, "a new short status, no event (lost across a restart): re-picked");
	ix.jobEvent(1, ev("j1", "unknown"), 5);
	assert.deepEqual(ix.takeResends(), []);
	ix.delta(2, jobsUp(rec("j1", ["1.1"], "to_station")), 6);
	assert.deepEqual(ix.takeResends(), [{ jid: "j1", inst: 2 }]);
	assert.equal(ix.holderOf("j1", "1.1"), 2);
});

test("cargo inflight: the live load, then held 30 s after done; nothing held after lost (R-58)", () => {
	const ix = new Index(0);
	const D = { sid: "2.5", inst: 2, x: 0, y: 0 };
	const cargoJob = (jid: string) => ix.assign({ jid, kind: "cargo", surface: "nauvis", at: 1, members: ["1.1"],
		shares: [], station: ST, sizedFrom: new Map(),
		cargo: { dest: D, items: [["iron-plate", "normal", 300, 100]] } }, 0);
	const key = "iron-plate\u0000normal";
	cargoJob("c1");
	assert.equal(ix.inflightTo("2.5", 1).get(key), 300);
	ix.jobEvent(2, ev("c1", "done", { cid: "1.1" }), 1000);
	assert.equal(ix.inflightTo("2.5", 1000 + INFLIGHT_HOLD_MS - 1).get(key), 300);
	assert.equal(ix.inflightTo("2.5", 1000 + INFLIGHT_HOLD_MS).get(key), undefined);
	cargoJob("c2");
	ix.jobEvent(1, ev("c2", "lost", { cid: "1.1" }), 2000);
	assert.equal(ix.inflightTo("2.5", 1000 + INFLIGHT_HOLD_MS + 1).get(key), undefined, "c2 held nothing");
});

/* eslint-disable max-len */ // the squad fixtures are one-line records
// Squads (squads.md §4.4): the relay queue.
const sq = (ix: Index, jid = "s1", members = ["1.1", "2.1"], at = 1, stations?: Map<string, any>) => ix.assign({
	jid, kind: "destroy", surface: "nauvis", at, members, shares: [{ wid: W2, bring: [], out: 0 }], station: ST,
	sizedFrom: new Map(), stations,
}, 0);
const part = (jid: string, members: string[], state = "follow", extra: Record<string, unknown> = {}) => rec(
	jid, members, state, { kind: "destroy", ...extra },
);
/** A squad whose leader 1.1 is on tile 1 and minion 2.1 on tile 2, both reported, the queue drained. */
function squad() {
	const ix = new Index(0);
	sq(ix);
	ix.delta(1, { ...jobsUp(part("s1", ["1.1"], "fight", { shares: [{ wid: W2, bring: [], out: 0 }] })),
		ctrons: { up: [ctron("1.1", { jid: "s1" })], rm: [] } }, 1);
	ix.delta(2, { ...jobsUp(part("s1", ["2.1"], "follow", { lead: "1.1" })),
		ctrons: { up: [ctron("2.1", { jid: "s1" })], rm: [] } }, 1);
	ix.takeSquad();
	return ix;
}
const relays = (ix: Index) => ix.takeSquad().map(r => [r.inst, r.cancel ? "cancel" : "state"]);

test("squad relay: a tile newly reporting a part gets the state; the same part again does not", () => {
	const ix = new Index(0);
	sq(ix);
	ix.delta(1, jobsUp(part("s1", ["1.1"], "fight", { shares: [{ wid: W2, bring: [], out: 0 }] })), 1);
	assert.deepEqual(relays(ix), [], "the assigned tile's own first record is not a new part");
	ix.delta(2, jobsUp(part("s1", ["2.1"], "follow", { lead: "1.1" })), 2);
	assert.deepEqual(relays(ix), [[2, "state"]]);
	ix.delta(2, jobsUp(part("s1", ["2.1"], "follow", { lead: "1.1" })), 3);
	assert.deepEqual(relays(ix), []);
	assert.deepEqual(ix.jobs.get("s1")!.lead, "1.1");
});

test("squad relay: the leader's record on another tile (or with no earlier entry) goes to every other part", () => {
	const ix = squad();
	ix.delta(1, { ctrons: { up: [ctron("1.1", { jid: "s1", x: 5 })], rm: [] } } as any, 2);
	assert.deepEqual(relays(ix), [], "the same tile again: nothing");
	ix.delta(3, { ctrons: { up: [ctron("1.1", { jid: "s1" })], rm: [] } } as any, 3);
	assert.deepEqual(relays(ix), [[1, "state"], [2, "state"]], "tile 3 is the new place; the parts on 1 and 2 learn it");
	ix.delta(3, { ctrons: { up: [], rm: ["1.1"] } } as any, 4);
	ix.delta(2, { ctrons: { up: [ctron("1.1", { jid: "s1" })], rm: [] } } as any, 5);
	assert.deepEqual(relays(ix), [[1, "state"]], "after an rm there is no earlier entry: tile 2 is new, so only the part on 1 is told");
	ix.delta(2, { ctrons: { up: [ctron("2.1", { jid: "other" })], rm: [] } } as any, 6);
	assert.deepEqual(relays(ix), [], "a minion's or another job's record triggers nothing");
});

test("squad relay: a known part that gains a member gets the state again (design 4.4, review finding 2)", () => {
	const ix = squad();
	ix.delta(2, jobsUp(part("s1", ["2.1", "2.2"], "follow", { lead: "1.1" })), 5);
	assert.deepEqual(relays(ix), [[2, "state"]], "a second minion landed on tile 2");
	ix.delta(2, jobsUp(part("s1", ["2.1"], "follow", { lead: "1.1" })), 6);
	assert.deepEqual(relays(ix), [], "a member leaving the part relays nothing");
});

test("a minion's failed does not fail the squad job; the leader's does (review finding 7)", () => {
	const ix = squad();
	ix.jobEvent(2, ev("s1", "failed", { cid: "2.1" }), 5);
	assert.deepEqual([ix.jobs.get("s1")!.failed, ix.jobs.get("s1")!.failedWid], [false, undefined]);
	ix.jobEvent(1, ev("s1", "failed", { cid: "1.1", wid: W2 }), 6);
	assert.deepEqual([ix.jobs.get("s1")?.failed ?? "ended"], ["ended"], "all ended: backoff applied, job deleted");
	assert.equal(ix.work.get(W2), undefined);
});

test("squad relay: a minion's left, done, lost or failed joins gone and goes to the tile holding the leader, once", () => {
	for (const how of ["left", "done", "lost", "failed"]) {
		const ix = squad();
		ix.jobEvent(2, ev("s1", how, { cid: "2.1" }), 5);
		assert.deepEqual([...ix.jobs.get("s1")!.squad!.gone], ["2.1"], how);
		assert.deepEqual(relays(ix), [[1, "state"]], how);
		ix.jobEvent(2, ev("s1", how, { cid: "2.1" }), 6);
		assert.deepEqual(relays(ix), [], `${how}: already gone`);
	}
	const ix = squad();
	ix.jobEvent(1, ev("s1", "left", { cid: "1.1" }), 5);
	ix.jobEvent(1, ev("s1", "left", { cid: "9.9" }), 5);
	assert.deepEqual([relays(ix), ix.jobs.get("s1")!.squad!.gone.size], [[], 0], "the leader and a stranger are not gone");
});

test("squad relay: the leader's done, lost or failed releases the squad on every part", () => {
	for (const how of ["done", "lost", "failed"]) {
		const ix = squad();
		ix.jobEvent(1, ev("s1", how, { cid: "1.1" }), 5);
		assert.equal(ix.jobs.get("s1")!.squad!.done, true, how);
		assert.deepEqual(relays(ix), [[1, "state"], [2, "state"]], how);
	}
});

test("squad relay: the leader's record leaving the work releases the squad once (R-203)", () => {
	for (const state of ["leave_work", "returning", "unloading"]) {
		const ix = squad();
		ix.delta(1, jobsUp(part("s1", ["1.1"], state, { shares: [{ wid: W2, bring: [], out: 0 }] })), 5);
		assert.equal(ix.jobs.get("s1")!.squad!.done, true, state);
		assert.deepEqual(relays(ix), [[1, "state"], [2, "state"]], state);
		ix.delta(1, jobsUp(part("s1", ["1.1"], state, { shares: [{ wid: W2, bring: [], out: 0 }] })), 6);
		assert.deepEqual(relays(ix), [], `${state}: only once`);
	}
	const ix = squad();
	ix.delta(1, jobsUp(part("s1", ["1.1"], "fight", { shares: [{ wid: W2, bring: [], out: 0 }] })), 5);
	ix.delta(2, jobsUp(part("s1", ["2.1"], "returning", { lead: "1.1" })), 5);
	assert.deepEqual([ix.jobs.get("s1")!.squad!.done, relays(ix)], [false, []], "a minion's own returning is not a release");
});

test("squad relay: a reject cancels every tile's part, the rejecting one too; not for other kinds (R-211, review finding 1)", () => {
	const ix = new Index(0);
	ix.delta(1, { ctrons: { up: [ctron("1.1")], rm: [] } } as any, 0);
	ix.delta(2, { ctrons: { up: [ctron("2.1")], rm: [] } } as any, 0);
	ix.delta(3, { ctrons: { up: [ctron("3.1")], rm: [] } } as any, 0);
	sq(ix, "s1", ["1.1", "2.1", "3.1"]);
	ix.jobEvent(2, ev("s1", "rejected", { cid: "2.1", why: "robots_out" }), 1);
	assert.deepEqual(ix.takeSquad(), [1, 2, 3].map(inst => ({ inst, jid: "s1", cancel: true })));
	assert.equal(ix.jobs.has("s1"), false);
	assert.ok(ix.isRejected("3.1", 2), "every member is turned away, as for a one-tile reject");
	assignJob(ix, "j1", "1.1", W1);
	ix.jobEvent(1, ev("j1", "rejected"), 2);
	assert.deepEqual(ix.takeSquad(), []);
});

test("squad: a part without the leader names it; unlisted for 60 s it is lost and the squad released (R-209, R-64)", () => {
	const ix = new Index(0);
	ix.snapshotPart(2, snap(2, { jobs: [part("s1", ["2.1"], "follow", { lead: "1.1" })] }), 0);
	const job = ix.jobs.get("s1")!;
	assert.deepEqual([job.lead, [...job.members].sort(), job.squad, [...job.movingSince.keys()]],
		["1.1", ["1.1", "2.1"], { gone: new Set(), done: false }, ["1.1"]]);
	assert.deepEqual(relays(ix), [[2, "state"]], "the new part");
	assert.deepEqual(ix.tick(MOVING_MS - 1).lost, []);
	assert.deepEqual(ix.tick(MOVING_MS).lost, [["s1", "1.1"]]);
	assert.equal(job.squad!.done, true);
	assert.deepEqual(relays(ix), [[2, "state"]], "the release goes to the minion's tile");
	assert.ok(ix.jobs.has("s1"), "the minion has not ended");
	ix.delta(1, jobsUp(part("s1", ["1.1"], "fight", { shares: [{ wid: W2, bring: [], out: 0 }] })), MOVING_MS + 1);
	assert.equal(ix.jobs.get("s1")!.lead, "1.1");
	const back = new Index(0); // the leader's tile reports in time: not lost
	back.snapshotPart(2, snap(2, { jobs: [part("s1", ["2.1"], "follow", { lead: "1.1" })] }), 0);
	back.snapshotPart(1, snap(1, { jobs: [part("s1", ["1.1"], "fight", { shares: [{ wid: W2, bring: [], out: 0 }] })] }), 10);
	assert.deepEqual(back.tick(MOVING_MS + 10).lost, []);
});

test("a destroy cell backs off the effective job_start_delay, 5 s before it is known; other kinds 5 min (R-208)", () => {
	const fail = (ix: Index, kind: string) => {
		const wid = `2|nauvis|${kind}|7`;
		ix.snapshotPart(2, snap(2, { cells: [cell(wid, { kind: kind as any, bring: kind === "destroy" ? [] : undefined })] }), 0);
		ix.assign({ jid: "j1", kind: kind as any, surface: "nauvis", at: 1, members: ["1.1"], shares: [{ wid, bring: [], out: 0 }],
			station: ST, sizedFrom: new Map() }, 0);
		ix.jobEvent(1, ev("j1", "failed", { cid: "1.1", why: "no_route" }), 1000);
		return ix.work.get(wid)!.backoffUntilMs - 1000;
	};
	assert.equal(fail(new Index(0), "destroy"), DESTROY_RETRY_MS, "no hook");
	assert.equal(fail(new Index(0, () => undefined), "destroy"), DESTROY_RETRY_MS, "no defaults yet");
	assert.equal(fail(new Index(0, () => 7000), "destroy"), 7000, "the setting");
	assert.equal(fail(new Index(0, () => 7000), "construction"), BACKOFF_MS);
	const ix = new Index(0, () => 7000); // a rescan that finds no progress
	const wid = "2|nauvis|destroy|7";
	ix.snapshotPart(2, snap(2, { cells: [cell(wid, { kind: "destroy", bring: [], scanned: 400 })] }), 0);
	ix.assign({ jid: "j1", kind: "destroy", surface: "nauvis", at: 1, members: ["1.1"], shares: [{ wid, bring: [], out: 0 }],
		station: ST, sizedFrom: new Map([[wid, totalsKey(cell(wid, { kind: "destroy", bring: [] }))]]) }, 0);
	ix.jobEvent(1, ev("j1", "done", { cid: "1.1", left: 500 }), 10);
	ix.delta(2, { cells: { up: [cell(wid, { kind: "destroy", bring: [], scanned: 520 })], rm: [] } } as any, 1000);
	assert.equal(ix.work.get(wid)!.backoffUntilMs, 8000);
});
