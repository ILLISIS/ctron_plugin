/* eslint-disable max-len */ // the brief's fixtures are one-line records
import { test } from "node:test";
import assert from "node:assert/strict";
import { Index } from "../../cluster/index.js";
import { CAP, Lists, PART_BYTES, build, chunk } from "../../cluster/list.js";

const NOW = 1_000_000;
const name = (inst: number) => `tile-${inst}`;
const ST = { sid: "1.s", inst: 1, x: 0, y: 0 };
const ctron = (cid: string, extra: Record<string, unknown> = {}) => ({
	cid, surface: "nauvis", name: "constructron", quality: "normal", x: 5, y: 6, state: "idle",
	free: { normal: 40, destroy: 40, cargo: 40 }, restock: { normal: [], destroy: [], cargo: [] }, ...extra,
});
const cell = (wid: string, extra: Record<string, unknown> = {}) => ({
	wid, surface: "nauvis", kind: wid.split("|")[2], since: 0, due: 0, tool: false, scanned: 1,
	area: { left_top: { x: 0, y: 0 }, right_bottom: { x: 80, y: 80 } }, center: { x: 40, y: 40 },
	bring: [["stone-brick", "normal", 100, 100]], out: 0, n: 10, ...extra,
});
const job = (ix: Index, jid: string, at: number, state: string, status: string, extra: Record<string, unknown> = {}) => {
	ix.assign({ jid, kind: "construction", surface: "nauvis", at, members: [`c${jid}`], shares: [],
		station: ST, sizedFrom: new Map() }, NOW);
	ix.delta(at, { jobs: { up: [{ jid, kind: "construction", surface: "nauvis", members: [`c${jid}`], state,
		status, tasks: [1, 4], station: ST, shares: [], ...extra }], rm: [] } } as any, NOW);
};
const sec = (rows: any[], s: string) => rows.filter(r => r.sec === s).sort((a, b) => a.ord - b.ord).map(r => r.key);

test("job sections: problem statuses need attention, returning and unloading are finishing; 50 per section (§8.2, R-134)", () => {
	const ix = new Index(0);
	job(ix, "p", 1, "to_work", "no_path");
	job(ix, "f", 1, "returning", "moving");
	for (let i = 0; i < 55; i++) {
		job(ix, `w${String(i).padStart(2, "0")}`, 1, "at_task", "working");
	}
	const { rows, stats } = build(ix, { surface: "nauvis" }, name, NOW);
	assert.deepEqual(sec(rows, "attention"), ["j:p"]);
	assert.deepEqual(sec(rows, "finishing"), ["j:f"]);
	assert.equal(sec(rows, "progress").length, CAP);
	assert.equal(stats.more.progress, 5);
	const p = rows.find((r: any) => r.key === "j:p") as any;
	assert.deepEqual([p.at, p.atName, p.worker, p.n, p.status, p.tasks, p.station.sid],
		[1, "tile-1", "cp", 1, "no_path", [1, 4], "1.s"], "R-153: worker and n, no member list");
});

test("pending: one row per (owner, kind) with count, oldest age and why; cells only for the expanded group (R-134)", () => {
	const ix = new Index(0);
	ix.delta(1, { cells: { up: [cell("1|nauvis|construction|1")], rm: [] } } as any, 10);
	ix.delta(1, { cells: { up: [cell("1|nauvis|construction|2"), cell("1|nauvis|upgrade|3")], rm: [] } } as any, 20);
	ix.delta(1, { cells: { up: [cell("1|nauvis|construction|4", { due: 60 })], rm: [] } } as any, 30);
	ix.delta(2, { cells: { up: [cell("2|nauvis|construction|5"), cell("2|nauvis|construction|6")], rm: [] } } as any, 5);
	ix.work.get("1|nauvis|construction|1")!.why = "no_ctron";
	ix.work.get("2|nauvis|construction|6")!.backoffUntilMs = NOW + 1;
	ix.work.get("2|nauvis|construction|6")!.why = "failed";
	const { rows } = build(ix, { surface: "nauvis" }, name, NOW);
	assert.deepEqual(sec(rows, "pending"), ["g:2|construction", "g:1|construction", "g:1|upgrade"], "by oldest age");
	const g = rows.find((r: any) => r.key === "g:1|construction") as any;
	assert.deepEqual([g.n, g.oldestMs, g.st, g.why, g.ownerName], [3, 10, "open", "no_ctron", "tile-1"]);
	assert.deepEqual(sec(rows, "attention"), ["w:2|nauvis|construction|6"], "a backed-off cell needs attention");
	assert.equal((rows.find((r: any) => r.key === "g:2|construction") as any).n, 1);
	assert.deepEqual(sec(rows, "cells"), []);
	const open = build(ix, { surface: "nauvis", expand: "1|construction" }, name, NOW).rows;
	assert.deepEqual(sec(open, "cells"), ["w:1|nauvis|construction|1", "w:1|nauvis|construction|2", "w:1|nauvis|construction|4"]);
	const w4 = open.find((r: any) => r.key === "w:1|nauvis|construction|4") as any;
	assert.deepEqual([w4.st, w4.dueAtMs, w4.rem, w4.committed, w4.c], ["delay", 30 + 1000, 1, 0, [40, 40]]);
});

test("pending: a cell its live job's shares cover leaves Pending; a partly covered one stays (owner, 2026-10-21)", () => {
	const ix = new Index(0);
	ix.delta(1, { cells: { up: [cell("1|nauvis|construction|1"), cell("1|nauvis|construction|2")], rm: [] } } as any, 10);
	ix.delta(1, { cells: { up: [cell("1|nauvis|destroy|3", { bring: [], n: 4 })], rm: [] } } as any, 10);
	const share = (wid: string, count: number) => ({ wid, bring: [["stone-brick", "normal", count]], out: 0 });
	ix.assign({ jid: "a", kind: "construction", surface: "nauvis", at: 1, members: ["ca"],
		shares: [share("1|nauvis|construction|1", 100), share("1|nauvis|construction|2", 40)], station: ST,
		sizedFrom: new Map() } as any, NOW);
	ix.assign({ jid: "d", kind: "destroy", surface: "nauvis", at: 1, members: ["cd"],
		shares: [{ wid: "1|nauvis|destroy|3", bring: [], out: 0 }], station: ST, sizedFrom: new Map() } as any, NOW);
	const { rows } = build(ix, { surface: "nauvis", expand: "1|construction" }, name, NOW);
	assert.deepEqual(sec(rows, "pending"), ["g:1|construction"], "the destroy cell is covered by its live share");
	assert.equal((rows.find((r: any) => r.key === "g:1|construction") as any).n, 1, "only the partly covered cell");
	assert.deepEqual(sec(rows, "cells"), ["w:1|nauvis|construction|2"]);
});

test("the tile filter keeps one tile's rows; the header stats stay cluster-wide", () => {
	const ix = new Index(0);
	ix.delta(1, { ctrons: { up: [ctron("1.1"), ctron("1.2")], rm: [] }, stations: { up: [{ sid: "1.s", surface: "nauvis", name: "A", x: 0, y: 0 }], rm: [] } } as any, 1);
	ix.delta(2, { ctrons: { up: [ctron("2.1")], rm: [] }, cells: { up: [cell("2|nauvis|repair|1")], rm: [] } } as any, 1);
	const { rows, stats } = build(ix, { surface: "nauvis", tile: 2 }, name, NOW);
	assert.deepEqual(rows.map((r: any) => r.key).sort(), ["c:2.1", "g:2|repair"]);
	assert.deepEqual([stats.total, stats.available, stats.tiles], [3, 3, [[1, "tile-1"], [2, "tile-2"]]]);
});

test("ctron rows: a position only when idle; a busy one carries its job's kind and status (P5 D-6)", () => {
	const ix = new Index(0);
	ix.delta(1, { ctrons: { up: [ctron("1.1"), ctron("cb", { state: "busy", jid: "b" })], rm: [] } } as any, 1);
	job(ix, "b", 1, "loading", "requesting");
	const { rows, stats } = build(ix, { surface: "nauvis" }, name, NOW);
	const idle = rows.find((r: any) => r.key === "c:1.1") as any;
	const busy = rows.find((r: any) => r.key === "c:cb") as any;
	assert.deepEqual([idle.x, idle.y], [5, 6]);
	assert.deepEqual([busy.x, busy.kind, busy.status], [undefined, "construction", "requesting"]);
	assert.equal(stats.available, 1);
});

test("stations carry their need, open order and no_supplier; stats.waiting sums loading jobs' missing items", () => {
	const ix = new Index(0);
	ix.delta(1, { stations: { up: [{ sid: "1.s", surface: "nauvis", name: "A", x: 0, y: 0 }], rm: [] },
		needs: { up: [{ sid: "1.s", surface: "nauvis", slots: [["iron-plate", "normal", 100, 400, 50, 100]] }], rm: [] } } as any, 1);
	job(ix, "a", 1, "loading", "awaiting_logistics", { missing: [["gear", "normal", 4]] });
	job(ix, "b", 1, "loading", "awaiting_logistics", { missing: [["gear", "normal", 6], ["pipe", "normal", 1]] });
	job(ix, "c", 1, "to_work", "moving", { missing: [["gear", "normal", 100]] });
	const { rows, stats } = build(ix, { surface: "nauvis" }, name, NOW);
	const n = rows.find((r: any) => r.key === "n:1.s") as any;
	assert.deepEqual([n.order, n.why], [[350], undefined]);
	assert.deepEqual(stats.waiting, [["gear", "normal", 10], ["pipe", "normal", 1]]);
	ix.orderBackoff.set("1.s", NOW + 5000);
	const later = build(ix, { surface: "nauvis" }, name, NOW).rows.find((r: any) => r.key === "n:1.s") as any;
	assert.equal(later.why, "no_supplier", "R-156: the order without a supplier shows on its need row");
});

test("per-watch pushes: full first in parts ≤ 3 KB, then only changes, nothing when unchanged; seq per push (R-69)", () => {
	const ix = new Index(0);
	ix.delta(1, { ctrons: { up: Array.from({ length: 50 }, (_, i) => ctron(`1.${i}`, { label: "x".repeat(40) })), rm: [] } } as any, 1);
	const lists = new Lists();
	lists.watch(1, { surface: "nauvis" }, true);
	const first = lists.push(ix, name, NOW);
	assert.ok(first.length > 1, "50 long rows don't fit one part");
	assert.ok(first.every(p => p.inst === 1 && JSON.stringify(p.payload).length <= PART_BYTES));
	assert.deepEqual(first.map(p => [p.payload.seq, p.payload.part, p.payload.parts, p.payload.full]),
		first.map((_, i) => [1, i + 1, first.length, true]));
	assert.equal(first.flatMap(p => p.payload.up).length, 50);
	assert.deepEqual(lists.push(ix, name, NOW + 1000), [], "nothing changed (stats.now alone doesn't count)");
	ix.delta(1, { ctrons: { up: [ctron("1.3", { state: "unfit", why: "no_power", label: "x".repeat(40) })], rm: ["1.9"] } } as any, 2);
	const next = lists.push(ix, name, NOW + 2000);
	assert.equal(next.length, 1);
	assert.deepEqual([next[0].payload.seq, next[0].payload.full, next[0].payload.up.map((r: any) => r.key), next[0].payload.rm],
		[2, false, ["c:1.3"], ["c:1.9"]]);
});

test("watches: two on one tile are separate; off, a re-watch and a stopped instance (R-134, R-147)", () => {
	const ix = new Index(0);
	ix.delta(1, { ctrons: { up: [ctron("1.1")], rm: [] } } as any, 1);
	ix.delta(2, { ctrons: { up: [ctron("2.1")], rm: [] } } as any, 1);
	const lists = new Lists();
	lists.watch(3, { surface: "nauvis" }, true);
	lists.watch(3, { surface: "nauvis", tile: 2 }, true);
	const both = lists.push(ix, name, NOW);
	assert.deepEqual(both.map(p => p.payload.up.length).sort(), [1, 2]);
	lists.watch(3, { surface: "nauvis", tile: 2 }, false);
	lists.watch(3, { surface: "nauvis" }, true);
	const again = lists.push(ix, name, NOW + 1000);
	assert.deepEqual(again.map(p => [p.payload.full, p.payload.up.length]), [[true, 2]], "re-watched: a full list");
	lists.dropInstance(3);
	ix.delta(1, { ctrons: { up: [ctron("1.9")], rm: [] } } as any, 2);
	assert.deepEqual(lists.push(ix, name, NOW + 2000), []);
});

test("a 3,000-row surface gives a mirror of at most 300 rows plus need rows; the rest is counted in more (R-134)", () => {
	const ix = new Index(0);
	for (let inst = 1; inst <= 20; inst++) {
		ix.delta(inst, {
			ctrons: { up: Array.from({ length: 15 }, (_, i) => ctron(`${inst}.${i}`)), rm: [] },
			stations: { up: Array.from({ length: 15 }, (_, i) => ({ sid: `${inst}.s${i}`, surface: "nauvis", name: `S${i}`, x: 0, y: 0 })), rm: [] },
			cells: { up: Array.from({ length: 60 }, (_, i) => cell(`${inst}|nauvis|${["construction", "upgrade", "repair"][i % 3]}|${i}`)), rm: [] },
		} as any, 1);
		for (let i = 0; i < 60; i++) {
			job(ix, `${inst}.j${i}`, inst, ["at_task", "returning", "loading"][i % 3], i % 10 === 0 ? "stuck" : "working");
		}
	}
	const { rows, stats } = build(ix, { surface: "nauvis" }, name, NOW);
	const shown = rows.filter((r: any) => !r.key.startsWith("n:"));
	assert.ok(shown.length <= 300, `${shown.length} rows`);
	assert.equal(shown.length + Object.values(stats.more as Record<string, number>).reduce((a, b) => a + b, 0),
		20 * (15 + 15 + 60 + 3), "every job, ctron, station and group is either shown or counted");
});

test("chunk: in order, under the budget and count; an oversized item alone", () => {
	const len = (s: string) => s.length;
	assert.deepEqual(chunk(["aaa", "bb", "c", "dddd"], len, 6), [["aaa", "bb"], ["c", "dddd"]]);
	assert.deepEqual(chunk(["a", "b", "c"], len, 100, 2), [["a", "b"], ["c"]]);
	assert.deepEqual(chunk(["x".repeat(9), "y"], len, 5), [["x".repeat(9)], ["y"]]);
	assert.deepEqual(chunk([], len, 5), []);
});

test("a part stays within 3 KB with full stats: 20 tiles, 20 waiting items, long rows (R-15)", () => {
	const ix = new Index(0);
	for (let inst = 1; inst <= 20; inst++) {
		ix.delta(inst, { ctrons: { up: Array.from({ length: 8 }, (_, i) => ctron(`${inst}.${i}`, { label: "x".repeat(60) })), rm: [] } } as any, 1);
	}
	for (let i = 0; i < 25; i++) {
		job(ix, `m${i}`, 1, "loading", "awaiting_logistics", { missing: [[`item-with-a-long-name-${i}`, "legendary", i + 1]] });
	}
	const lists = new Lists();
	lists.watch(1, { surface: "nauvis" }, true);
	const parts = lists.push(ix, name, NOW);
	assert.equal(parts[0].payload.stats.waiting.length, 20);
	assert.equal(parts[0].payload.stats.tiles.length, 20);
	assert.ok(parts.length > 1);
	assert.ok(parts.every(p => Buffer.byteLength(JSON.stringify(p.payload)) <= PART_BYTES));
});
