import { test } from "node:test";
import assert from "node:assert/strict";
import type { Static } from "@sinclair/typebox";
import type { PortalNode } from "../../contracts.js";
import { CROSS, Routes, type EdgePort, type Place, type PortalReport } from "../../cluster/routes.js";

type N = Static<typeof PortalNode>;
const w = (id: number, edge: string, x: number, y: number, lo = 136, hi = 248, k = 1, comp = 1): N => ({
	id, kind: "w", edge, k, lo, hi, x, y, comp,
});

const rep = (surface: string, epoch: number, nodes: N[]): PortalReport => ({ surface, epoch, nodes });

function port(edges: Record<string, [number, number]>, inactive = new Set<string>()): EdgePort {
	return {
		isActive: e => !inactive.has(e),
		edge: e => (edges[e] ? { length: 512, a: edges[e][0], b: edges[e][1] } : undefined),
	};
}

const at = (inst: number, x: number, y: number): Place => ({ inst, surface: "nauvis", x, y });
const hops = (route: ReturnType<Routes["route"]>) => route?.hops.map(h => `${h.edge}@${h.from}`).join(",");

// A 2x2 gridworld of 512-tile tiles: 1 (0,0), 2 (1,0), 3 (0,1), 4 (1,1). h1 joins 1|2 and h2 3|4 on x = 512;
// v1 joins 1|3 and v2 2|4 on y = 512. One open window (k = 1, run [136, 248]) per side, its node 6 inside the line.
const EDGES: Record<string, [number, number]> = { h1: [1, 2], h2: [3, 4], v1: [1, 3], v2: [2, 4] };
const t1 = () => rep("nauvis", 1, [w(1, "h1", 506, 192), w(2, "v1", 192, 506)]);
const t2 = (h1 = true) => rep("nauvis", 1, [...(h1 ? [w(1, "h1", 518, 192)] : []), w(2, "v2", 704, 506)]);
const t3 = () => rep("nauvis", 1, [w(1, "v1", 192, 518), w(2, "h2", 506, 704)]);
const t4 = () => rep("nauvis", 1, [w(1, "h2", 518, 704), w(2, "v2", 704, 518)]);

function grid(opts: { h1OnTile2?: boolean; inactive?: Set<string> } = {}) {
	const r = new Routes(port(EDGES, opts.inactive));
	r.report(1, t1());
	r.report(2, t2(opts.h1OnTile2 ?? true));
	r.report(3, t3());
	r.report(4, t4());
	return r;
}

const A = at(1, 100, 100);
const B = at(2, 900, 100);

test("a crossing link joins two sides' windows whose runs overlap by 16 or more", () => {
	const r = new Routes(port(EDGES));
	r.report(1, t1());
	r.report(2, rep("nauvis", 1, [w(1, "h1", 518, 192, 232, 248)]));
	const expected = Math.hypot(100 - 506, 100 - 192) + CROSS + Math.hypot(518 - 900, 192 - 100);
	assert.ok(Math.abs(r.cost(A, B) - expected) < 1e-9, `${r.cost(A, B)} vs ${expected}`);
	assert.deepEqual(r.route(A, B)?.hops, [{ edge: "h1", x: 240, from: 1 }]);
	r.report(2, rep("nauvis", 2, [w(1, "h1", 518, 192, 240, 248)]));
	assert.equal(r.cost(A, B), Infinity, "an overlap of 8 doesn't link");
	assert.equal(r.route(A, B), null);
});

test("an inactive edge cuts its links; edgesChanged brings them back", () => {
	const inactive = new Set(["h1", "v1", "h2", "v2"]);
	const r = grid({ inactive });
	assert.equal(r.cost(A, B), Infinity);
	inactive.clear();
	r.edgesChanged();
	assert.ok(Number.isFinite(r.cost(A, B)));
});

test("Dijkstra detours through the other two tiles around a water-blocked border", () => {
	const route = grid({ h1OnTile2: false }).route(A, B);
	assert.equal(hops(route), "v1@1,h2@3,v2@4");
	assert.deepEqual(route?.goal, { inst: 2, x: 900, y: 100 });
	assert.ok(route?.hops.every(h => h.x === 192));
});

test("avoid lists block a whole edge or one window, and don't touch the memo", () => {
	const r = grid();
	assert.equal(hops(r.route(A, B)), "h1@1");
	assert.equal(hops(r.route(A, B, { avoid: ["h1"] })), "v1@1,h2@3,v2@4");
	assert.equal(hops(r.route(A, B, { avoid: ["h1:1"] })), "v1@1,h2@3,v2@4");
	assert.equal(hops(r.route(A, B, { avoid: ["h1:0"] })), "h1@1", "another window's key");
	assert.equal(r.route(A, B, { avoid: ["h1", "v1"] }), null, "every way out of tile 1 avoided");
	assert.equal(hops(r.route(A, B)), "h1@1");
});

test("Infinity for a tile with no open window; the memo follows the graph version", () => {
	const r = grid();
	assert.ok(Number.isFinite(r.cost(A, B)));
	r.report(2, rep("nauvis", 2, []));
	assert.equal(r.cost(A, B), Infinity, "tile 2 now reports no nodes");
});

// §14.2's "island reached through a neighbour": with labels gone (R-149) a place attaches to every node of its tile,
// so what remains to test is that a tile's components stay apart: a route can't cross a tile from one to the other.
test("a tile split by water into two components can't be crossed between them", () => {
	const r = new Routes(port(EDGES));
	r.report(1, t1());
	r.report(2, t2());
	r.report(3, rep("nauvis", 1, [w(1, "v1", 192, 518), w(2, "h2", 506, 704, 136, 248, 1, 2)]));
	r.report(4, t4());
	const D = at(4, 900, 900);
	assert.equal(hops(r.route(A, D)), "h1@1,v2@2", "through tile 2");
	assert.equal(r.route(A, D, { avoid: ["h1"] }), null, "tile 3's halves don't join");
	assert.equal(hops(grid().route(A, D, { avoid: ["h1"] })), "v1@1,h2@3", "unsplit, tile 3 carries it");
});

test("a report no newer than the stored one is ignored; a stopped instance drops out", () => {
	const r = grid();
	r.report(2, rep("nauvis", 2, []));
	r.report(2, t2());
	assert.equal(r.cost(A, B), Infinity, "epoch 1 after epoch 2");
	r.report(2, rep("nauvis", 2, [w(1, "h1", 518, 192), w(2, "v2", 704, 506)]));
	assert.equal(r.cost(A, B), Infinity, "an equal epoch");
	r.dropInstance(2);
	assert.equal(r.cost(A, B), 800 + CROSS, "no report: the estimate");
});

test("without reports, same tile, other surface", () => {
	const r = new Routes(port(EDGES));
	assert.equal(r.cost(at(1, 0, 0), at(2, 300, 400)), 500 + CROSS);
	assert.equal(r.route(at(1, 0, 0), at(2, 300, 400)), null);
	assert.equal(r.cost(at(1, 0, 0), at(1, 300, 400)), 500);
	assert.deepEqual(r.route(at(1, 0, 0), at(1, 300, 400))?.hops, []);
	assert.equal(r.cost(at(1, 0, 0), { inst: 2, surface: "vulcanus", x: 0, y: 0 }), Infinity);
});

test("links are derived: same comp costs the rounded distance, other comps are unlinked", () => {
	const r = new Routes(port(EDGES));
	const via = (comp: number) => rep("nauvis", 1, [w(1, "v1", 192, 518), { ...w(2, "h2", 506, 704), comp }]);
	r.report(1, rep("nauvis", 1, [w(1, "v1", 192, 506)]));
	r.report(3, via(1));
	r.report(4, t4());
	const from = at(1, 192, 506);
	const to = at(4, 518, 704);
	const link = Math.round(Math.hypot(506 - 192, 704 - 518)); // 365, not 364.9...
	assert.equal(r.cost(from, to), CROSS + link + CROSS);
	r.report(3, { ...via(2), epoch: 2 });
	assert.equal(r.cost(from, to), Infinity);
});

test("Lua's {} for empty arrays", () => {
	const r = new Routes(port(EDGES));
	r.report(1, t1());
	r.report(2, { surface: "nauvis", epoch: 1, nodes: {} });
	assert.equal(r.cost(A, B), Infinity);
});

test("cost is symmetric", () => {
	const r = grid({ h1OnTile2: false });
	assert.ok(Math.abs(r.cost(A, B) - r.cost(B, A)) < 1e-9);
});

test("a node first reached the long way is improved later", () => {
	// From tile 3, Dijkstra reaches tile 3's v1 node through h2 first (1207), then through tile 1 (965).
	assert.equal(hops(grid().route(at(3, 192, 600), B)), "v1@3,h1@1");
});

test("the memo is per target place, not per tile", () => {
	const r = grid();
	const B2 = at(2, 704, 700);
	r.cost(A, B);
	assert.equal(r.cost(A, B2), grid().cost(A, B2));
});

test("a 7x7 grid: every tile ranked against 49 targets in under 500 ms", () => {
	const n = 7;
	const inst = (i: number, j: number) => 1 + i + n * j;
	const edges: Record<string, [number, number]> = {};
	const nodes = new Map<number, N[]>();
	const add = (t: number, node: Omit<N, "id">) => {
		const list = nodes.get(t) ?? [];
		list.push({ ...node, id: list.length + 1 } as N);
		nodes.set(t, list);
	};
	for (let i = 0; i < n; i++) {
		for (let j = 0; j < n; j++) {
			for (let k = 0; k < 4; k++) {
				const lo = 128 * k + 24;
				const hi = 128 * k + 104;
				const mid = 128 * k + 64;
				if (i + 1 < n) {
					const e = `h${i}_${j}`;
					edges[e] = [inst(i, j), inst(i + 1, j)];
					const x = 512 * (i + 1);
					const y = 512 * j + mid;
					add(inst(i, j), { kind: "w", edge: e, k, lo, hi, x: x - 6, y, comp: 1 });
					add(inst(i + 1, j), { kind: "w", edge: e, k, lo, hi, x: x + 6, y, comp: 1 });
				}
				if (j + 1 < n) {
					const e = `v${i}_${j}`;
					edges[e] = [inst(i, j), inst(i, j + 1)];
					const x = 512 * i + mid;
					const y = 512 * (j + 1);
					add(inst(i, j), { kind: "w", edge: e, k, lo, hi, x, y: y - 6, comp: 1 });
					add(inst(i, j + 1), { kind: "w", edge: e, k, lo, hi, x, y: y + 6, comp: 1 });
				}
			}
		}
	}
	const r = new Routes(port(edges));
	for (const [t, list] of nodes) {
		r.report(t, rep("nauvis", 1, list));
	}
	const centre = (t: number) => at(t, 512 * ((t - 1) % n) + 256, 512 * Math.floor((t - 1) / n) + 256);
	const tiles = [...nodes.keys()];
	const t0 = performance.now();
	let finite = 0;
	for (const tb of tiles) {
		for (const ta of tiles) {
			if (Number.isFinite(r.cost(centre(ta), centre(tb)))) {
				finite += 1;
			}
		}
	}
	const ms = performance.now() - t0;
	assert.equal(finite, tiles.length * tiles.length);
	assert.ok(ms < 500, `${ms.toFixed(1)} ms`);
});
