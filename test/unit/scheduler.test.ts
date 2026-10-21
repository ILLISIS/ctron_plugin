/* eslint-disable max-len, no-plusplus */ // the brief's fixtures are one-line records
import { test } from "node:test";
import assert from "node:assert/strict";
import { Index, MOVING_MS, totalsKey } from "../../cluster/index.js";
import { COST_K, DEBOUNCE_MS, Scheduler, type Outbound, type SchedulerPort } from "../../cluster/scheduler.js";
import type { Place } from "../../cluster/routes.js";

type Q = Parameters<SchedulerPort["query"]>[1];
type R = Awaited<ReturnType<SchedulerPort["query"]>>;
const settle = () => new Promise(resolve => setImmediate(resolve));
const T0 = 100_000; // past the 30 s hold

function harness(opts: {
	cost?: (a: Place, b: Place) => number; reply?: (inst: number, q: Q) => R | Promise<R>;
	horde?: boolean; minions?: number; atomic?: [string, string]; running?: number[]; startedMs?: number;
} = {}) {
	const ix = new Index(opts.startedMs ?? 0);
	const clock = { now: T0 };
	const sent: Array<[number, Outbound]> = [];
	const queries: Array<[number, Q]> = [];
	const timers: Array<{ at: number; fn: () => void }> = [];
	const lines: Array<[string, string, Record<string, any>]> = [];
	const levels: Array<string | undefined> = [];
	let ids = 0;
	const stationsOf = (inst: number) => [...ix.stations.values()].filter(s => s.inst === inst).map(s => s.sid);
	const port: SchedulerPort = {
		now: () => clock.now,
		cost: opts.cost ?? ((a, b) => Math.hypot(a.x - b.x, a.y - b.y) + (a.inst === b.inst ? 0 : 64)),
		query: async (inst, q) => {
			queries.push([inst, q]);
			if (opts.reply) { return opts.reply(inst, q); }
			const mine = stationsOf(inst);
			return { r: q.map(e => ({ qid: e.qid, sids: mine, cover: true })) };
		},
		send: (inst, msg) => { sent.push([inst, msg]); },
		newId: () => `j${++ids}`,
		settings: () => ({ horde: opts.horde ?? false, minions: opts.minions ?? 1, atomic: opts.atomic }),
		running: () => opts.running ?? [],
		later: (ms, fn) => { timers.push({ at: clock.now + ms, fn }); },
		trace: (op, phase, fields, level) => { lines.push([op, phase, fields]); levels.push(level); },
	};
	const assigns = () => sent.filter(([, m]) => m.type === "assign").map(([inst, m]) => ({ inst, ...(m.payload as any) }));
	return { ix, s: new Scheduler(ix, port), clock, sent, queries, timers, lines, levels, assigns };
}
const ctron = (cid: string, x = 0, y = 0, extra: Record<string, unknown> = {}) => ({
	cid, surface: "nauvis", name: "constructron", quality: "normal", x, y, state: "idle",
	free: { normal: 40, destroy: 40, cargo: 40 },
	restock: { normal: [["construction-robot", "normal", 50, 50]], destroy: [], cargo: [] }, ...extra,
});
const station = (sid: string, x = 0, y = 0) => ({ sid, surface: "nauvis", name: "service_station", x, y });
const cell = (wid: string, cx: number, cy: number, extra: Record<string, unknown> = {}) => ({
	wid, surface: "nauvis", kind: wid.split("|")[2], since: 0, due: 0, tool: false, scanned: 1,
	area: { left_top: { x: cx - 40, y: cy - 40 }, right_bottom: { x: cx + 40, y: cy + 40 } }, center: { x: cx, y: cy },
	bring: [["stone-brick", "normal", 100, 100]], out: 0, n: 100, ...extra,
});
/** A delta from one tile (records arrive in this order, so cells listed first are older). */
const tile = (ix: Index, inst: number, r: { ctrons?: any[]; stations?: any[]; cells?: any[] }, now = 0) => {
	ix.snapshotPart(inst, { ctrons: r.ctrons ?? [], stations: r.stations ?? [], cells: [], needs: [], jobs: [], part: 1, parts: 1 } as any, now);
	for (const c of r.cells ?? []) {
		ix.delta(inst, { cells: { up: [c], rm: [] } } as any, now++);
	}
};

test("oldest first; the cheapest ctron; ties to the work's own tile (R-51, R-52)", async () => {
	const h = harness();
	tile(h.ix, 2, { ctrons: [ctron("2.1", 40, 40)] });
	tile(h.ix, 1, { ctrons: [ctron("1.1", 900, 900)], stations: [station("1.9")],
		cells: [cell("1|nauvis|construction|1", 40, 40), cell("1|nauvis|construction|2", 900, 900)] });
	await h.s.pass("nauvis");
	assert.deepEqual(h.assigns().map(a => [a.work[0].wid, a.members[0]]),
		[["1|nauvis|construction|1", "2.1"], ["1|nauvis|construction|2", "1.1"]],
		"the older cell goes first and takes 2.1 (cost 64 < 1216); the newer gets 1.1");
	const tie = harness({ cost: () => 10 });
	tile(tie.ix, 2, { ctrons: [ctron("2.1")] });
	tile(tie.ix, 1, { ctrons: [ctron("1.1")], stations: [station("1.9")], cells: [cell("1|nauvis|construction|1", 40, 40)] });
	await tie.s.pass("nauvis");
	assert.equal(tie.assigns()[0].members[0], "1.1", "equal cost: the work's own tile");
});

test("every cost Infinity → unreachable; no idle ctron → no_ctron (§6.3)", async () => {
	const h = harness({ cost: (a, b) => (a.inst === b.inst ? 0 : Infinity) });
	tile(h.ix, 2, { ctrons: [ctron("2.1")] });
	tile(h.ix, 1, { stations: [station("1.9")], cells: [cell("1|nauvis|construction|1", 40, 40)] });
	await h.s.pass("nauvis");
	assert.equal(h.assigns().length, 0);
	assert.equal(h.ix.work.get("1|nauvis|construction|1")!.why, "unreachable");
	h.ix.stop(2);
	await h.s.pass("nauvis");
	assert.equal(h.ix.work.get("1|nauvis|construction|1")!.why, "no_ctron");
});

test("the cheapest ctron whose share is non-empty wins; a rejected ctron is skipped (R-141, R-131)", async () => {
	const h = harness();
	tile(h.ix, 1, {
		ctrons: [ctron("1.1", 0, 0, { free: { normal: 3, destroy: 3, cargo: 3 } }), ctron("1.2", 500, 500), ctron("1.3", 600, 600)],
		stations: [station("1.9")], cells: [cell("1|nauvis|construction|1", 40, 40, { bring: [["rail", "normal", 1000, 100]] })],
	});
	h.ix.rejected.set("1.2", T0 + 60_000);
	await h.s.pass("nauvis");
	assert.deepEqual(h.assigns().map(a => a.members[0]), ["1.3"], "1.1 can't carry a share; 1.2 rejected");
});

test("a split leaves the rest open and the next idle ctron takes another share in the same pass (R-54)", async () => {
	const h = harness();
	tile(h.ix, 1, {
		ctrons: [ctron("1.1", 0, 0, { free: { normal: 30, destroy: 30, cargo: 30 } }), ctron("1.2", 10, 0, { free: { normal: 30, destroy: 30, cargo: 30 } })],
		stations: [station("1.9")], cells: [cell("1|nauvis|deconstruction|1", 40, 40, { bring: [["stone", "normal", 5000, 50]] })],
	});
	await h.s.pass("nauvis");
	const a = h.assigns();
	assert.equal(a.length, 2, "two jobs on one cell, no copies");
	assert.deepEqual(a.map(x => x.work[0].bring[0][2]), [1250, 1250], "25 slots each: free 30 − margin 5");
	assert.equal(h.ix.commitments().get("1|nauvis|deconstruction|1")!.live, 2);
});

test("merging takes whole cells of one kind and owner within 160 tiles; never across tiles, never in horde (R-55)", async () => {
	for (const horde of [false, true]) {
		const h = harness({ horde });
		tile(h.ix, 2, { cells: [cell("2|nauvis|construction|9", 60, 40)] });
		tile(h.ix, 1, {
			ctrons: [ctron("1.1")], stations: [station("1.9")], cells: [
				cell("1|nauvis|construction|1", 40, 40), cell("1|nauvis|construction|2", 120, 40),
				cell("1|nauvis|upgrade|3", 40, 120), cell("1|nauvis|construction|4", 440, 40),
			],
		});
		await h.s.pass("nauvis");
		assert.equal(h.assigns()[0].work.length, horde ? 1 : 2, `horde ${horde}: merged cell count`);
		const wids = h.assigns().filter(a => a.inst === 1).flatMap(a => a.work.map((w: any) => w.wid));
		assert.deepEqual(wids.slice(0, horde ? 1 : 2),
			horde ? ["1|nauvis|construction|1"] : ["1|nauvis|construction|1", "1|nauvis|construction|2"], `horde ${horde}`);
		assert.ok(!wids.includes("2|nauvis|construction|9"), "another owner's cell never merges");
		assert.ok(!h.assigns()[0].work.some((w: any) => w.wid === "1|nauvis|upgrade|3"), "another kind never merges");
	}
});

test("never assigned: due > 0, no scan yet, backed off; no kind filter at all (R-22, R-62, R-129)", async () => {
	const h = harness();
	tile(h.ix, 1, {
		ctrons: [ctron("1.1"), ctron("1.2"), ctron("1.3"), ctron("1.4")], stations: [station("1.9")], cells: [
			cell("1|nauvis|construction|1", 40, 40, { due: 120 }),
			cell("1|nauvis|construction|2", 400, 40, { scanned: undefined, bring: undefined, out: undefined, n: undefined }),
			cell("1|nauvis|construction|3", 800, 40),
			cell("1|nauvis|upgrade|4", 1200, 40, { tool: true }),
		],
	});
	h.ix.work.get("1|nauvis|construction|3")!.backoffUntilMs = T0 + 1;
	await h.s.pass("nauvis");
	assert.deepEqual(h.assigns().map(a => a.work[0].wid), ["1|nauvis|upgrade|4"],
		"the port has no kinds: whatever a tile reports with due 0 runs (tool cells, rebuilds)");
});

test("station pick: covers all by the lowest summed cost, else some, else nearest the ctron (R-56)", async () => {
	const setup = (reply?: (inst: number, q: Q) => R) => {
		const h = harness({ reply });
		tile(h.ix, 2, { stations: [station("2.3", 0, 0)] });
		tile(h.ix, 1, { ctrons: [ctron("1.1", 0, 0)], stations: [station("1.1s", -300, 0), station("1.2s", 500, 0)],
			cells: [cell("1|nauvis|construction|1", 1000, 0)] });
		return h;
	};
	const all = setup();
	await all.s.pass("nauvis");
	assert.equal(all.assigns()[0].station.sid, "1.2s", "500 + 500 beats 300 + 1300 and 64 + 1064");
	const items = all.queries[0][1][0].items.map((i: any) => i[0]).sort();
	assert.deepEqual(items, ["construction-robot", "stone-brick"], "the share's bring plus the normal restock");
	const some = setup(inst => (inst === 1 ? { r: [{ qid: "p0", sids: ["1.1s"], cover: [1] }] } : { r: [] }));
	await some.s.pass("nauvis");
	assert.equal(some.assigns()[0].station.sid, "1.1s");
	const none = setup(() => ({ r: [] }));
	await none.s.pass("nauvis");
	assert.equal(none.assigns()[0].station.sid, "2.3", "nearest the ctron by cost: 64 on tile 2");
	assert.deepEqual(none.queries.map(([inst]) => inst).sort(), [1, 2], "one query per tile with stations on the surface");
});

test("a plan whose ctron changed while the stock query was out is dropped (Review Focus 3)", async () => {
	let release!: (r: R) => void;
	const h = harness({ reply: () => new Promise<R>(resolve => { release = resolve; }) });
	tile(h.ix, 1, { ctrons: [ctron("1.1")], stations: [station("1.9")], cells: [cell("1|nauvis|construction|1", 40, 40)] });
	const pass = h.s.pass("nauvis");
	await settle();
	h.ix.delta(1, { ctrons: { up: [ctron("1.1", 0, 0, { state: "unfit", why: "no_power" })], rm: [] } } as any, T0);
	release({ r: [] });
	await pass;
	assert.equal(h.assigns().length, 0);
	assert.equal(h.ix.jobs.size, 0);
});

test("the Job exists as assigned before its event is sent; it holds the shares (R-126)", async () => {
	const h = harness();
	tile(h.ix, 1, { ctrons: [ctron("1.1")], stations: [station("1.9")], cells: [cell("1|nauvis|construction|1", 40, 40)] });
	await h.s.pass("nauvis");
	const [a] = h.assigns();
	assert.equal(h.ix.jobs.get(a.jid)!.state, "assigned");
	assert.deepEqual(a.work[0], { wid: "1|nauvis|construction|1", key: 1, area: cell("1|nauvis|construction|1", 40, 40).area,
		bring: [["stone-brick", "normal", 100, 100]], out: 0 });
	assert.deepEqual([a.members, a.station], [["1.1"], { sid: "1.9", inst: 1, x: 0, y: 0 }], "R-153: a cid list, one station");
	await h.s.pass("nauvis");
	assert.equal(h.assigns().length, 1, "the next pass sees the cell committed and the ctron busy");
	assert.ok(h.lines.some(([op, phase, f]) => op === "ctronv2.job" && phase === "assigned" && f.jid === a.jid && f.cid === "1.1"));
});

test("the restart hold and station-less surfaces stop passes (R-66, §6.2)", async () => {
	const h = harness({ running: [1, 2], startedMs: T0 });
	tile(h.ix, 1, { ctrons: [ctron("1.1")], stations: [station("1.9")], cells: [cell("1|nauvis|construction|1", 40, 40)] });
	await h.s.pass("nauvis");
	assert.equal(h.assigns().length, 0, "tile 2 hasn't snapshotted and 30 s haven't passed");
	tile(h.ix, 2, {});
	await h.s.pass("nauvis");
	assert.equal(h.assigns().length, 1);
	await h.s.pass("gleba");
	assert.equal(h.queries.filter(([, q]) => q.length > 0).length, 1, "no stations on gleba: no pass work at all");
});

test("≤ 1 pass per second per surface, one in flight; a stock reply triggers nothing (R-51, R-142)", async () => {
	let release!: (r: R) => void;
	const h = harness({ reply: () => new Promise<R>(resolve => { release = resolve; }) });
	tile(h.ix, 1, { ctrons: [ctron("1.1")], stations: [station("1.9")], cells: [cell("1|nauvis|construction|1", 40, 40)] });
	h.s.trigger("nauvis");
	h.s.trigger("nauvis");
	assert.equal(h.timers.length, 1, "one scheduled pass");
	h.timers.shift()!.fn();
	await settle();
	h.s.trigger("nauvis");
	assert.equal(h.timers.length, 0, "a pass is in flight: the trigger only marks it dirty");
	release({ r: [] });
	await settle();
	await settle();
	assert.equal(h.timers.length, 1, "dirty: one more pass, not before a second after the last start");
	assert.equal(h.timers[0].at, T0 + DEBOUNCE_MS);
	assert.equal(h.lines.filter(([op, phase]) => op === "ctronv2.sched" && phase === "pass").length, 1);
});

const synthetic = (cost: (a: Place, b: Place) => number) => {
	const h = harness({ cost });
	for (let inst = 1; inst <= 20; inst++) {
		const ctrons = Array.from({ length: 50 }, (_, i) => ctron(`${inst}.${i}`, (i * 37) % 1600, (i * 53) % 1200));
		const cells = Array.from({ length: 300 }, (_, i) => cell(`${inst}|nauvis|construction|${i}`, 40 + 80 * (i % 20),
			40 + 80 * Math.floor(i / 20), { bring: [["stone-brick", "normal", 20, 100]] }));
		tile(h.ix, inst, { ctrons, stations: [station(`${inst}.s1`, 0, 0), station(`${inst}.s2`, 800, 600)], cells });
	}
	return h;
};
/** Best of 3 timed passes (each on a fresh world) after a warm-up: the machine is shared. */
async function bestOf3(cost: (a: Place, b: Place) => number) {
	await synthetic(cost).s.pass("nauvis"); // warm-up: JIT
	let best = Infinity;
	let last = synthetic(cost);
	for (let i = 0; i < 3; i++) {
		last = synthetic(cost);
		const t0 = performance.now();
		await last.s.pass("nauvis");
		best = Math.min(best, performance.now() - t0);
	}
	return { best, h: last };
}

test("a synthetic 20 tiles × 50 ctrons × 300 cells pass stays under 50 ms (§14.2, §14.5)", async () => {
	// a cheap fake cost: the test measures the scheduler, not the route service
	const { best, h } = await bestOf3((a, b) => Math.abs(a.x - b.x) + Math.abs(a.y - b.y) + (a.inst === b.inst ? 0 : 64));
	assert.ok(h.assigns().length > 0);
	assert.ok(h.assigns().every(a => JSON.stringify(a).length <= 3000), "every assign ≤ 3 KB (R-15)");
	process.stderr.write(`synthetic pass: ${best.toFixed(1)} ms\n`);
	assert.ok(best < 50, `pass took ${best.toFixed(1)} ms`);
});

test("the same pass with a cost that burns 0.01 ms per call stays under 400 ms (R-149 scale)", async () => {
	const spin = (ms: number) => { const end = performance.now() + ms; while (performance.now() < end) { /* busy */ } };
	const { best } = await bestOf3((a, b) => { spin(0.01); return Math.abs(a.x - b.x) + Math.abs(a.y - b.y) + (a.inst === b.inst ? 0 : 64); });
	process.stderr.write(`slow-cost pass: ${best.toFixed(1)} ms\n`);
	assert.ok(best < 400, `pass took ${best.toFixed(1)} ms`); // about 25k cost calls: 8 per plan, 16 for the station
});

test("only the K nearest idle ctrons are costed per work, and the cheapest of them wins (§6.3 scale ruling)", async () => {
	let asked = 0;
	// ctron k sits k*10 tiles from the work; the route cost is the distance; the station is far off the y = 0 line
	const h = harness({ cost: (a, b) => { asked += a.y === 0 && b.y === 0 ? 1 : 0; return Math.abs(a.x - b.x) + Math.abs(a.y - b.y); } });
	const ctrons = Array.from({ length: 50 }, (_, k) => ctron(`1.${k}`, k * 10, 0));
	tile(h.ix, 1, { ctrons, stations: [station("1.9", 0, 5000)], cells: [cell("1|nauvis|construction|1", 0, 0)] });
	await h.s.pass("nauvis");
	assert.equal(asked, COST_K, "50 candidates, 8 cost calls");
	assert.equal(h.assigns()[0].members[0], "1.0", "the cheapest of the 8 nearest");
	const bent = harness({ cost: (a, b) => (a.x === 100 ? 1000 : Math.abs(a.x - b.x) + 1) });
	tile(bent.ix, 1, { ctrons: [ctron("1.0", 100, 0), ctron("1.1", 110, 0)], stations: [station("1.9")], cells: [cell("1|nauvis|construction|1", 100, 0)] });
	await bent.s.pass("nauvis");
	assert.equal(bent.assigns()[0].members[0], "1.1", "route cost decides within the K");
});

test("a cell merged into another plan loses its old why", async () => {
	const h = harness();
	tile(h.ix, 1, { stations: [station("1.9")], cells: [cell("1|nauvis|construction|1", 40, 40), cell("1|nauvis|construction|2", 120, 40)] });
	await h.s.pass("nauvis");
	assert.equal(h.ix.work.get("1|nauvis|construction|2")!.why, "no_ctron");
	h.ix.delta(1, { ctrons: { up: [ctron("1.1")], rm: [] } } as any, T0);
	await h.s.pass("nauvis");
	assert.equal(h.assigns()[0].work.length, 2);
	assert.equal(h.ix.work.get("1|nauvis|construction|2")!.why, undefined);
});

test("the Job records each cell's totalsKey at assign as sizedFrom (R-130)", async () => {
	const h = harness();
	tile(h.ix, 1, { ctrons: [ctron("1.1")], stations: [station("1.9")], cells: [cell("1|nauvis|construction|1", 40, 40)] });
	await h.s.pass("nauvis");
	const wid = "1|nauvis|construction|1";
	assert.equal(h.ix.jobs.get(h.assigns()[0].jid)!.sizedFrom.get(wid), totalsKey(h.ix.work.get(wid)!.cell));
});

const need = (sid: string, slots: unknown[]) => ({ sid, surface: "nauvis", slots });
const destroyCell = (wid: string, cx: number, n = 5) => cell(wid, cx, 0, { bring: [], out: 0, n });
const types = (h: ReturnType<typeof harness>) => h.sent.map(([inst, m]) => [inst, m.type]);
/** The assigns that carry work or a squad's whole member list: not a minion group's. */
const leaders = (h: ReturnType<typeof harness>) => h.assigns().filter(a => a.lead === undefined);

const ATOMIC = ["atomic-bomb", "normal"] as [string, string];
/** The stations a tile reports for a query: the minions' query covers tile 1's two stations only. */
const minionSids = (qid: string, inst: number) => {
	if (!qid.endsWith("m")) { return [`${inst}.s`]; }
	return inst === 1 ? ["1.s", "1.t"] : [];
};
const kit = (rockets: number, atomic = 0) => ({
	normal: [], cargo: [], destroy: [["rocket", "normal", rockets, 100], ...atomic ? [["atomic-bomb", "normal", atomic, 10]] : []],
});

test("a squad comes from the whole surface; each member loads at its own station, the minions' by their own restock (R-194..R-197)", async () => {
	const h = harness({ minions: 2, atomic: ATOMIC, reply: (inst, q) => ({ r: q.map(e => ({ qid: e.qid,
		sids: minionSids(e.qid, inst), cover: true })) }) });
	tile(h.ix, 2, { ctrons: [ctron("2.1", 100, 0, { restock: kit(50, 1) })], stations: [station("2.s", 100, 0)],
		cells: [destroyCell("2|nauvis|destroy|1", 100)] });
	tile(h.ix, 1, { ctrons: [ctron("1.1", 50, 0, { restock: kit(100, 1) }), ctron("1.2", 500, 0, { restock: kit(50) })],
		stations: [station("1.s", 0, 0), station("1.t", 500, 0)] });
	await h.s.pass("nauvis");
	const [lead, ...mins] = h.assigns();
	assert.deepEqual([lead.inst, lead.kind, lead.members, lead.station.sid, lead.lead], [2, "destroy", ["2.1", "1.1", "1.2"], "2.s", undefined],
		"the leader is the cheapest to the work (cost 0 on its own tile); the minions the cheapest to the leader; the leader's assign lists all");
	assert.deepEqual(lead.work.map((w: any) => [w.wid, w.bring, w.out]), [["2|nauvis|destroy|1", [], 0]], "the whole cell");
	assert.deepEqual(mins.map(a => [a.inst, a.members, a.station.sid, a.work, a.lead]), [
		[1, ["1.1"], "1.s", [], { cid: "2.1", inst: 2, x: 100, y: 0 }],
		[1, ["1.2"], "1.t", [], { cid: "2.1", inst: 2, x: 100, y: 0 }],
	], "one minion assign per (tile, station) group, no work, the leader's place");
	assert.ok(mins.every(a => a.jid === lead.jid && a.kind === "destroy"));
	const job = h.ix.jobs.get(lead.jid)!;
	assert.deepEqual([job.lead, job.at, [...job.members]], ["2.1", 2, ["2.1", "1.1", "1.2"]]);
	assert.deepEqual([...job.stations], [["1.1", { sid: "1.s", inst: 1, x: 0, y: 0 }], ["1.2", { sid: "1.t", inst: 1, x: 500, y: 0 }]]);
	assert.deepEqual(job.squad, { gone: new Set(), done: false });
	const [qs] = h.queries.map(([, q]) => q).filter(q => q.some(e => e.qid === "s0"));
	assert.deepEqual(qs.find(e => e.qid === "s0")!.items, [["rocket", "normal", 50, 100], ["atomic-bomb", "normal", 1, 10]], "the leader's destroy restock");
	assert.deepEqual(qs.find(e => e.qid === "s0m")!.items, [["rocket", "normal", 100, 100]], "the most of any minion, no atomic");
});

test("destroy waits for a full squad, opens only while n > 0 and no live job is on it (R-128, §6.7)", async () => {
	const h = harness({ minions: 2 });
	tile(h.ix, 1, { ctrons: [ctron("1.1"), ctron("1.2")], stations: [station("1.s")],
		cells: [destroyCell("1|nauvis|destroy|1", 100), destroyCell("1|nauvis|destroy|2", 900, 0)] });
	await h.s.pass("nauvis");
	assert.equal(h.assigns().length, 0);
	assert.equal(h.ix.work.get("1|nauvis|destroy|1")!.why, "waiting_squad");
	const one = harness({ minions: 1 });
	tile(one.ix, 1, { ctrons: [ctron("1.1"), ctron("1.2"), ctron("1.3"), ctron("1.4")], stations: [station("1.s")],
		cells: [destroyCell("1|nauvis|destroy|1", 100), destroyCell("1|nauvis|destroy|2", 900, 0)] });
	await one.s.pass("nauvis");
	assert.deepEqual(leaders(one).map(a => a.work[0].wid), ["1|nauvis|destroy|1"], "n = 0 is not open");
	await one.s.pass("nauvis");
	assert.equal(leaders(one).length, 1, "a live squad on the cell: no second one");
});

test("cargo: a supplier on another network nearest the destination, the ctron nearest the supplier, inflight at once (R-58, R-59)", async () => {
	const h = harness({ reply: (inst, q) => (inst === 2
		? { r: q.filter(e => e.qid.startsWith("o")).map(e => ({ qid: e.qid, sids: ["2.a", "2.b"], cover: true })) }
		: { r: [] }) });
	tile(h.ix, 2, { ctrons: [ctron("2.1", 120, 0), ctron("2.2", 100, 0, { free: { normal: 40, destroy: 40, cargo: 2 } })],
		stations: [station("2.a", 1000, 0), station("2.b", 100, 0)] });
	tile(h.ix, 1, { ctrons: [ctron("1.1", 0, 0)], stations: [station("1.d", 0, 0)] });
	h.ix.delta(1, { needs: { up: [need("1.d", [["iron-plate", "normal", 100, 400, 50, 100]])], rm: [] } } as any, 0);
	await h.s.pass("nauvis");
	const o = h.queries[0][1].find(e => e.qid.startsWith("o"))!;
	assert.equal(o.exclude_sid, "1.d", "the destination's own network is excluded");
	const [a] = h.assigns();
	assert.deepEqual([a.kind, a.members, a.station.sid, a.work], ["cargo", ["2.1"], "2.b", []],
		"2.b is nearest the destination; 2.2 stands on it but its free.cargo can't carry a share; 2.1 is next");
	assert.deepEqual(a.cargo, { dest: { sid: "1.d", inst: 1, x: 0, y: 0 }, items: [["iron-plate", "normal", 350, 100]] });
	await h.s.pass("nauvis");
	assert.equal(h.assigns().length, 1, "50 + 350 inflight > min: no second order");
});

test("cargo: a supplier covering some carries only those items; none backs the order off 600 ticks (R-59)", async () => {
	const slots = [["iron-plate", "normal", 100, 400, 0, 100], ["copper-plate", "normal", 100, 400, 0, 100]];
	const some = harness({ reply: (inst, q) => (inst === 2
		? { r: q.map(e => ({ qid: e.qid, sids: ["2.a"], cover: [2] })) } // the 2nd item, 1-based
		: { r: [] }) });
	tile(some.ix, 2, { ctrons: [ctron("2.1")], stations: [station("2.a")] });
	tile(some.ix, 1, { stations: [station("1.d")] });
	some.ix.delta(1, { needs: { up: [need("1.d", slots)], rm: [] } } as any, 0);
	await some.s.pass("nauvis");
	assert.deepEqual(some.assigns()[0].cargo.items, [["copper-plate", "normal", 400, 100]]);
	const none = harness({ reply: () => ({ r: [] }) });
	tile(none.ix, 2, { ctrons: [ctron("2.1")], stations: [station("2.a")] });
	tile(none.ix, 1, { stations: [station("1.d")] });
	none.ix.delta(1, { needs: { up: [need("1.d", slots)], rm: [] } } as any, 0);
	const orderQueries = () => none.queries.filter(([, q]) => q.some(e => e.qid.startsWith("o"))).length;
	await none.s.pass("nauvis");
	none.clock.now += 5_000;
	await none.s.pass("nauvis");
	assert.equal(orderQueries(), 2, "two tiles asked once; the backed-off order isn't asked again 5 s later");
	none.clock.now += 5_000;
	await none.s.pass("nauvis");
	assert.equal(orderQueries(), 4);
	assert.equal(none.assigns().length, 0);
});

test("short re-picks with the current station excluded and goes to the tile holding the run; nothing better, nothing sent (R-35)", async () => {
	const run = async (cover: boolean) => {
		const h = harness({ reply: (inst, q) => (cover && inst === 1
			? { r: q.map(e => ({ qid: e.qid, sids: ["1.b"], cover: true })) } : { r: [] }) });
		tile(h.ix, 1, { stations: [station("1.a", 0, 0), station("1.b", 50, 0)] });
		h.ix.assign({ jid: "j1", kind: "construction", surface: "nauvis", at: 1, members: ["1.1"], shares: [],
			station: { sid: "1.a", inst: 1, x: 0, y: 0 }, sizedFrom: new Map() }, T0);
		h.ix.jobEvent(1, { jid: "j1", ev: "short", tick: 1, cid: "1.1", missing: [["gear", "normal", 5]] } as any, T0);
		h.s.afterReport();
		await settle();
		await settle();
		return h;
	};
	const yes = await run(true);
	assert.deepEqual(yes.queries[0][1], [{ qid: "r", mode: "supply", items: [["gear", "normal", 5]], exclude_sid: "1.a" }]);
	assert.deepEqual(yes.sent, [[1, { type: "station", payload: { jid: "j1", cid: "1.1", station: { sid: "1.b", inst: 1, x: 50, y: 0 }, why: "short" } }]]);
	const no = await run(false);
	assert.deepEqual(no.sent, []);
});

test("trash_full asks in drop mode and picks the nearest accepting station (§6.5)", async () => {
	const h = harness({ reply: (inst, q) => ({ r: q.map(e => ({ qid: e.qid, sids: [inst === 1 ? "1.far" : "2.near"], cover: true })) }) });
	tile(h.ix, 1, { stations: [station("1.a", 0, 0), station("1.far", 900, 0)] });
	tile(h.ix, 2, { stations: [station("2.near", 10, 0)] });
	h.ix.assign({ jid: "j1", kind: "deconstruction", surface: "nauvis", at: 1, members: ["1.1"], shares: [],
		station: { sid: "1.a", inst: 1, x: 0, y: 0 }, sizedFrom: new Map() }, T0);
	h.ix.jobEvent(1, { jid: "j1", ev: "trash_full", tick: 1, cid: "1.1", items: [["wood", "normal", 400]] } as any, T0);
	h.s.afterReport();
	await settle();
	await settle();
	assert.equal(h.queries[0][1][0].mode, "drop");
	assert.equal((h.sent[0][1].payload as any).station.sid, "2.near", "74 beats 900");
});

test("cancel: the job's tiles get the cancel, its cells are cleared and never reassigned; unknown re-sends to the new tile (R-67, R-139)", async () => {
	const h = harness();
	const W = "1|nauvis|construction|1";
	tile(h.ix, 1, { ctrons: [ctron("1.1"), ctron("1.2")], stations: [station("1.s")], cells: [cell(W, 40, 40)] });
	await h.s.pass("nauvis");
	const jid = h.assigns()[0].jid;
	h.sent.length = 0;
	h.s.cancel({ target: "job", kind: "construction", surface: "nauvis", id: jid } as any);
	assert.deepEqual(types(h), [[1, "cancel"], [1, "clear"]]);
	assert.deepEqual((h.sent[1][1].payload as any).wids, [W]);
	assert.equal(h.ix.work.has(W), false);
	await h.s.pass("nauvis");
	assert.equal(h.assigns().length, 0, "the free ctron 1.2 doesn't get the cancelled cell");
	h.ix.jobEvent(1, { jid, ev: "unknown", tick: 2 } as any, T0);
	h.ix.delta(2, { jobs: { up: [{ jid, kind: "construction", surface: "nauvis", members: ["1.1"],
		state: "to_work", status: "moving", tasks: [0, 3], station: { sid: "1.s", inst: 1, x: 0, y: 0 }, shares: [] }], rm: [] } } as any, T0);
	h.s.afterReport();
	assert.deepEqual(types(h).slice(-1), [[2, "cancel"]]);
});

test("ctrl-cancel: every pending cell of a kind on a surface, one clear per owner; every job of a kind not yet returning (R-67)", () => {
	const h = harness();
	tile(h.ix, 1, { cells: [cell("1|nauvis|construction|1", 40, 40), cell("1|nauvis|upgrade|2", 40, 40)] });
	tile(h.ix, 2, { cells: [cell("2|nauvis|construction|3", 40, 40)] });
	tile(h.ix, 3, { cells: [cell("3|gleba|construction|4", 40, 40, { surface: "gleba" })] });
	h.s.cancel({ target: "work", kind: "construction", surface: "nauvis" } as any);
	assert.deepEqual(h.sent.map(([inst, m]) => [inst, m.payload]).sort(),
		[[1, { surface: "nauvis", kind: "construction" }], [2, { surface: "nauvis", kind: "construction" }]]);
	assert.deepEqual([...h.ix.work.keys()].sort(), ["1|nauvis|upgrade|2", "3|gleba|construction|4"]);
	h.sent.length = 0;
	const job = (jid: string, state: string) => {
		h.ix.assign({ jid, kind: "upgrade", surface: "nauvis", at: 1, members: [`c${jid}`], shares: [],
			station: { sid: "1.s", inst: 1, x: 0, y: 0 }, sizedFrom: new Map() }, T0);
		h.ix.delta(1, { jobs: { up: [{ jid, kind: "upgrade", surface: "nauvis", members: [`c${jid}`], state,
			status: "working", tasks: [0, 1], station: { sid: "1.s", inst: 1, x: 0, y: 0 }, shares: [] }], rm: [] } } as any, T0);
	};
	job("a", "at_task");
	job("b", "returning");
	h.s.cancel({ target: "job", kind: "upgrade", surface: "nauvis" } as any);
	assert.deepEqual(h.sent.filter(([, m]) => m.type === "cancel").map(([, m]) => (m.payload as any).jid), ["a"]);
});

test("drop: to job.at with a jid (kept for a re-send); without, to each tile with a loading job on the surface (§6.9)", () => {
	const h = harness();
	const job = (jid: string, at: number, state: string, surface = "nauvis") => {
		h.ix.assign({ jid, kind: "construction", surface, at, members: [`c${jid}`], shares: [],
			station: { sid: "1.s", inst: 1, x: 0, y: 0 }, sizedFrom: new Map() }, T0);
		h.ix.delta(at, { jobs: { up: [{ jid, kind: "construction", surface, members: [`c${jid}`], state,
			status: "requesting", tasks: [0, 1], station: { sid: "1.s", inst: 1, x: 0, y: 0 }, shares: [] }], rm: [] } } as any, T0);
	};
	job("a", 1, "loading");
	job("b", 2, "to_work");
	job("c", 3, "loading", "gleba");
	job("d", 1, "loading");
	h.s.drop({ surface: "nauvis", name: "gear", quality: "normal" } as any);
	assert.deepEqual(h.sent, [[1, { type: "drop", payload: { surface: "nauvis", name: "gear", quality: "normal" } }]]);
	h.s.drop({ jid: "b", surface: "nauvis", name: "pipe", quality: "normal" } as any);
	assert.deepEqual(h.sent[1], [2, { type: "drop", payload: { jid: "b", surface: "nauvis", name: "pipe", quality: "normal" } }]);
	assert.deepEqual(h.ix.jobs.get("b")!.drops, [{ name: "pipe", quality: "normal" }]);
});

test("a second re-pick ranks from the station the run is at now and excludes it (§6.5)", async () => {
	const h = harness({ reply: (inst, q) => ({ r: q.map(e => ({ qid: e.qid, sids: ["1.a", "1.c"], cover: true })) }) });
	tile(h.ix, 1, { stations: [station("1.a", 0, 0), station("1.b", 500, 0), station("1.c", 600, 0)] });
	h.ix.assign({ jid: "j1", kind: "construction", surface: "nauvis", at: 1, members: ["1.1"], shares: [],
		station: { sid: "1.a", inst: 1, x: 0, y: 0 }, sizedFrom: new Map() }, T0);
	h.ix.delta(1, { jobs: { up: [{ jid: "j1", kind: "construction", surface: "nauvis", members: ["1.1"], state: "to_work",
		status: "moving", tasks: [0, 1], station: { sid: "1.b", inst: 1, x: 500, y: 0 }, shares: [] }], rm: [] } } as any, T0);
	h.ix.jobEvent(1, { jid: "j1", ev: "short", tick: 1, cid: "1.1", missing: [["gear", "normal", 5]] } as any, T0);
	h.s.afterReport();
	await settle();
	await settle();
	assert.equal(h.queries[0][1][0].exclude_sid, "1.b");
	assert.equal((h.sent[0][1].payload as any).station.sid, "1.c", "from 1.b: 1.c costs 100, 1.a 500");
});

test("a waiting squad holds the surface's idle ctrons from younger cells; an impossible squad holds nothing (R-195, CC destroy.lua:30-46)", async () => {
	const h = harness({ minions: 3 });
	tile(h.ix, 2, { ctrons: [ctron("2.1")] });
	tile(h.ix, 1, { ctrons: [ctron("1.1"), ctron("1.2"), ctron("1.3"), ctron("1.4")], stations: [station("1.s")],
		cells: [destroyCell("1|nauvis|destroy|1", 100), cell("1|nauvis|construction|2", 40, 40)] });
	h.ix.assign({ jid: "b", kind: "construction", surface: "nauvis", at: 1, members: ["1.3", "1.4"], shares: [],
		station: { sid: "1.s", inst: 1, x: 0, y: 0 }, sizedFrom: new Map() }, T0);
	await h.s.pass("nauvis");
	assert.equal(h.assigns().length, 0, "1.1, 1.2 and 2.1 wait for the busy 1.3 and 1.4, whatever their tile");
	assert.equal(h.ix.work.get("1|nauvis|destroy|1")!.why, "waiting_squad");
	assert.equal(h.ix.work.get("1|nauvis|construction|2")!.why, "no_ctron");
	const no = harness({ minions: 2 });
	tile(no.ix, 1, { ctrons: [ctron("1.1"), ctron("1.2")], stations: [station("1.s")],
		cells: [destroyCell("1|nauvis|destroy|1", 100), cell("1|nauvis|construction|2", 40, 40)] });
	await no.s.pass("nauvis");
	assert.equal(no.ix.work.get("1|nauvis|destroy|1")!.why, "waiting_squad");
	assert.deepEqual(no.assigns().map(a => a.work[0].wid), ["1|nauvis|construction|2"], "a squad of 3 can't form from 2 ctrons");
});

test("a squad nobody can reach is unreachable; too few reachable minions wait; both hold nothing; unfit ctrons don't count (R-194, R-195)", async () => {
	const h = harness({ minions: 1, cost: (a, b) => (a.inst === b.inst ? 0 : Infinity) });
	tile(h.ix, 2, { ctrons: [ctron("2.1"), ctron("2.2")], stations: [station("2.s")],
		cells: [] });
	tile(h.ix, 1, { stations: [station("1.s")], cells: [destroyCell("1|nauvis|destroy|1", 100)] });
	tile(h.ix, 3, { ctrons: [ctron("3.1")], stations: [station("3.s")], cells: [cell("3|nauvis|construction|2", 40, 40)] });
	await h.s.pass("nauvis");
	assert.equal(h.ix.work.get("1|nauvis|destroy|1")!.why, "unreachable");
	assert.deepEqual(h.assigns().map(a => a.work[0].wid), ["3|nauvis|construction|2"], "3.1 is not held");
	const island = harness({ minions: 1, cost: (a, b) => (a.inst === b.inst ? Math.hypot(a.x - b.x, a.y - b.y) : Infinity) });
	tile(island.ix, 2, { ctrons: [ctron("2.1", 100, 0)], stations: [station("2.s", 100, 0)] });
	tile(island.ix, 1, { ctrons: [ctron("1.1", 0, 0)], stations: [station("1.s")], cells: [destroyCell("1|nauvis|destroy|1", 100),
		cell("1|nauvis|construction|2", 40, 40)] });
	await island.s.pass("nauvis");
	assert.equal(island.ix.work.get("1|nauvis|destroy|1")!.why, "waiting_squad", "the leader is 1.1; 2.1 can't be reached from it");
	assert.deepEqual(island.assigns().map(a => a.work[0].wid), ["1|nauvis|construction|2"], "nothing was held");
	const u = harness({ minions: 1 });
	tile(u.ix, 1, { ctrons: [ctron("1.1"), ctron("1.2", 0, 0, { state: "unfit" })], stations: [station("1.s")],
		cells: [destroyCell("1|nauvis|destroy|1", 100), cell("1|nauvis|construction|2", 40, 40)] });
	await u.s.pass("nauvis");
	assert.equal(u.ix.work.get("1|nauvis|destroy|1")!.why, "waiting_squad");
	assert.deepEqual(u.assigns().map(a => a.work[0].wid), ["1|nauvis|construction|2"], "the squad can never form: 1.1 isn't held");
});

test("a cancel landing during a re-pick's stock query sends no station (M2)", async () => {
	let release!: () => void;
	const gate = new Promise<void>(resolve => { release = resolve; });
	const h = harness({ reply: async (_inst, q) => { await gate; return { r: q.map(e => ({ qid: e.qid, sids: ["1.b"], cover: true })) }; } });
	tile(h.ix, 1, { stations: [station("1.a", 0, 0), station("1.b", 50, 0)] });
	h.ix.assign({ jid: "j1", kind: "construction", surface: "nauvis", at: 1, members: ["1.1"], shares: [],
		station: { sid: "1.a", inst: 1, x: 0, y: 0 }, sizedFrom: new Map() }, T0);
	h.ix.jobEvent(1, { jid: "j1", ev: "short", tick: 1, cid: "1.1", missing: [["gear", "normal", 5]] } as any, T0);
	h.s.afterReport();
	await settle();
	h.ix.cancel("j1");
	release();
	await settle();
	await settle();
	assert.deepEqual(h.sent.filter(([, m]) => m.type === "station"), []);
});

test("an idle pass logs at verbose (M3)", async () => {
	const h = harness();
	tile(h.ix, 1, { ctrons: [ctron("1.1")], stations: [station("1.s")] });
	await h.s.pass("nauvis");
	assert.deepEqual(h.levels, ["verbose"]);
});

const chainTile = (h: ReturnType<typeof harness>, xs: number[], more: { ctrons?: any[]; cells?: any[] } = {}) => tile(h.ix, 1, {
	ctrons: [ctron("1.1"), ctron("1.2"), ctron("1.3"), ctron("1.4"), ctron("1.5"), ctron("1.6"), ...more.ctrons ?? []], stations: [station("1.s")],
	cells: [...xs.map((x, i) => destroyCell(`1|nauvis|destroy|${i + 1}`, x)), ...more.cells ?? []],
});
const wids = (a: { work: Array<{ wid: string }> }) => a.work.map(w => w.wid.slice(-1));

test("a squad takes the owner's destroy cells chained within 160 tiles; a merged cell isn't planned again (R-207)", async () => {
	const h = harness({ minions: 1 });
	tile(h.ix, 2, { cells: [destroyCell("2|nauvis|destroy|9", 120)] });
	chainTile(h, [100, 250, 400, 1000]);
	await h.s.pass("nauvis");
	assert.deepEqual(leaders(h).map(wids), [["1", "2", "3"], ["9"], ["4"]],
		"250 is within 160 of 100, 400 of 250 but not of 100; 1000 is alone; the other owner's cell squads on its own");
	assert.equal(h.ix.commitments().get("1|nauvis|destroy|2")!.live, 1, "one squad on the merged cell");
	assert.equal(h.ix.work.get("1|nauvis|destroy|2")!.why, undefined);
	const horde = harness({ minions: 1, horde: true });
	chainTile(horde, [100, 250, 400, 1000]);
	await horde.s.pass("nauvis");
	assert.deepEqual(leaders(horde).map(wids), [["1"], ["2"], ["3"]], "horde mode: one cell per squad");
});

test("the chain stops at the assign byte cap, members counted (R-207)", async () => {
	const h = harness({ minions: 1 });
	chainTile(h, Array.from({ length: 30 }, (_, i) => 100 + 100 * i));
	await h.s.pass("nauvis");
	const [a] = leaders(h);
	assert.ok(a.work.length > 3 && a.work.length < 30, `${a.work.length} cells`);
	assert.ok(JSON.stringify(a).length <= 2500, `${JSON.stringify(a).length} bytes`);
	assert.deepEqual(wids(a).slice(0, 3), ["1", "2", "3"], "oldest first");
});

test("afterReport sends the queued squad state and the reject cancels; a resend carries the squad too (squads.md §4.4)", () => {
	const h = harness();
	tile(h.ix, 1, { ctrons: [ctron("1.1", 30, 40)] });
	h.ix.assign({ jid: "s1", kind: "destroy", surface: "nauvis", at: 1, members: ["1.1", "2.1"], shares: [],
		station: { sid: "1.s", inst: 1, x: 0, y: 0 }, sizedFrom: new Map() }, T0);
	const part = (members: string[], state: string, extra = {}) => ({ jid: "s1", kind: "destroy", surface: "nauvis", members, state,
		status: "working", tasks: [0, 1], station: { sid: "1.s", inst: 1, x: 0, y: 0 }, shares: [], ...extra });
	h.ix.delta(2, { jobs: { up: [part(["2.1"], "follow", { lead: "1.1" })], rm: [] } } as any, T0);
	h.s.afterReport();
	assert.deepEqual(h.sent, [[2, { type: "squad", payload: { jid: "s1", lead: { inst: 1, x: 30, y: 40 }, gone: [], done: false } }]]);
	h.sent.length = 0;
	h.ix.jobEvent(2, { jid: "s1", ev: "left", tick: 1, cid: "2.1" } as any, T0);
	h.ix.delta(1, { jobs: { up: [part(["1.1"], "returning", { shares: [{ wid: "1|nauvis|destroy|1", bring: [], out: 0 }] })], rm: [] } } as any, T0);
	h.s.afterReport();
	assert.deepEqual(h.sent.map(([inst, m]) => [inst, m.type, (m.payload as any).gone, (m.payload as any).done]),
		[[1, "squad", ["2.1"], true], [2, "squad", ["2.1"], true]], "the leader's tile first for the gone minion, then the release to both parts");
	h.sent.length = 0;
	h.ix.jobEvent(3, { jid: "s1", ev: "rejected", tick: 1, why: "robots_out" } as any, T0);
	h.s.afterReport();
	assert.deepEqual(h.sent.map(([inst, m]) => [inst, m.type]), [[1, "cancel"], [2, "cancel"]],
		"a reject on tile 3 cancels the squad on the others (R-211); the job is gone, so no squad state follows");
	const r = harness();
	tile(r.ix, 1, { ctrons: [ctron("1.1")] });
	tile(r.ix, 2, { ctrons: [ctron("2.1")] });
	r.ix.assign({ jid: "s2", kind: "destroy", surface: "nauvis", at: 1, members: ["1.1", "2.1"], shares: [],
		station: { sid: "1.s", inst: 1, x: 0, y: 0 }, sizedFrom: new Map() }, T0);
	r.ix.jobEvent(2, { jid: "s2", ev: "rejected", tick: 1, why: "robots_out" } as any, T0);
	r.s.afterReport();
	assert.deepEqual(r.sent.map(([inst, m]) => [inst, m.type]), [[1, "cancel"], [2, "cancel"]], "every member's tile is cancelled, the rejecting one too (R-211)");
	const u = harness();
	tile(u.ix, 1, { ctrons: [ctron("1.1")] });
	u.ix.assign({ jid: "s3", kind: "destroy", surface: "nauvis", at: 1, members: ["1.1"], shares: [],
		station: { sid: "1.s", inst: 1, x: 0, y: 0 }, sizedFrom: new Map() }, T0);
	u.ix.jobEvent(1, { jid: "s3", ev: "unknown", tick: 1 } as any, T0);
	u.ix.delta(2, { jobs: { up: [{ ...part(["1.1"], "to_station"), jid: "s3" }], rm: [] } } as any, T0);
	u.sent.length = 0;
	u.s.afterReport();
	assert.deepEqual(u.sent.map(([inst, m]) => [inst, m.type]), [[2, "squad"]], "the resend path (and the new part) send the state once each");
});

test("flushSquad sends a lost leader's done to the minion tiles with no tile report (R-209, review finding 3)", () => {
	const h = harness();
	tile(h.ix, 2, { ctrons: [ctron("2.1")] });
	// no assign: the controller restarted, so the minion's part is all it knows of the leader (R-209)
	h.ix.delta(2, { jobs: { up: [{ jid: "s1", kind: "destroy", surface: "nauvis", members: ["2.1"], state: "follow", lead: "1.1",
		status: "working", tasks: [0, 1], station: { sid: "1.s", inst: 1, x: 0, y: 0 }, shares: [] }], rm: [] } } as any, T0);
	h.s.flushSquad();
	h.sent.length = 0;
	assert.deepEqual(h.ix.tick(T0 + MOVING_MS).lost, [["s1", "1.1"]]);
	h.s.flushSquad();
	assert.deepEqual(h.sent.map(([inst, m]) => [inst, m.type, (m.payload as any).done]), [[2, "squad", true]]);
});

test("cancel and a job drop reach every tile of a squad, even one that hasn't reported a part (R-67, R-96)", () => {
	const h = harness();
	tile(h.ix, 1, { ctrons: [ctron("1.1")] });
	tile(h.ix, 2, { ctrons: [ctron("2.1")] });
	h.ix.assign({ jid: "s1", kind: "destroy", surface: "nauvis", at: 1, members: ["1.1", "2.1"], shares: [],
		station: { sid: "1.s", inst: 1, x: 0, y: 0 }, sizedFrom: new Map() }, T0);
	h.s.drop({ jid: "s1", surface: "nauvis", name: "gear", quality: "normal" } as any);
	assert.deepEqual(h.sent.map(([inst, m]) => [inst, m.type]), [[1, "drop"], [2, "drop"]]);
	h.sent.length = 0;
	h.s.cancel({ target: "job", kind: "destroy", surface: "nauvis", id: "s1" } as any);
	assert.deepEqual(h.sent.filter(([, m]) => m.type === "cancel").map(([inst]) => inst), [1, 2]);
});

test("a minion's short re-picks from its own station toward the leader's, goes to the tile holding it, and is remembered (R-196, R-35)", async () => {
	const h = harness({ reply: (inst, q) => ({ r: q.map(e => ({ qid: e.qid, sids: inst === 1 ? ["1.b"] : ["2.b"], cover: true })) }) });
	tile(h.ix, 1, { stations: [station("1.a", 0, 0), station("1.b", 10, 0)] });
	tile(h.ix, 2, { stations: [station("2.a", 500, 0), station("2.b", 550, 0)] });
	h.ix.assign({ jid: "s1", kind: "destroy", surface: "nauvis", at: 1, members: ["1.1", "2.1"], shares: [],
		station: { sid: "1.a", inst: 1, x: 0, y: 0 }, sizedFrom: new Map(),
		stations: new Map([["2.1", { sid: "2.a", inst: 2, x: 500, y: 0 }]]) }, T0);
	const part = (members: string[], extra = {}) => ({ jid: "s1", kind: "destroy", surface: "nauvis", members, state: "loading",
		status: "working", tasks: [0, 1], station: { sid: "1.a", inst: 1, x: 0, y: 0 }, shares: [], ...extra });
	h.ix.delta(2, { jobs: { up: [part(["2.1"], { lead: "1.1" })], rm: [] } } as any, T0);
	h.ix.delta(1, { jobs: { up: [part(["1.1"], { shares: [{ wid: "1|nauvis|destroy|1", bring: [], out: 0 }] })], rm: [] } } as any, T0);
	h.sent.length = 0;
	h.ix.jobEvent(2, { jid: "s1", ev: "short", tick: 1, cid: "2.1", missing: [["rocket", "normal", 5]] } as any, T0);
	h.s.afterReport();
	await settle();
	await settle();
	assert.equal(h.queries.at(-1)![1][0].exclude_sid, "2.a", "the minion's own station is excluded");
	const sent = h.sent.filter(([, m]) => m.type === "station");
	assert.deepEqual(sent, [[2, { type: "station", payload: { jid: "s1", cid: "2.1", station: { sid: "1.b", inst: 1, x: 10, y: 0 }, why: "short" } }]],
		"1.b: 490 + 64 + 10 beats 2.b: 50 + 614");
	assert.deepEqual(h.ix.jobs.get("s1")!.stations.get("2.1"), { sid: "1.b", inst: 1, x: 10, y: 0 });
	h.ix.jobEvent(2, { jid: "s1", ev: "short", tick: 2, cid: "2.1", missing: [["rocket", "normal", 5]] } as any, T0);
	h.s.afterReport();
	await settle();
	await settle();
	assert.equal(h.queries.at(-1)![1][0].exclude_sid, "1.b", "the second re-pick starts from the station it was sent to");
});
