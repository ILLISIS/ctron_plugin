// The cluster route service (spec §7.5, §7.6), pure: the portal graph built from tile reports, Dijkstra with its own
// binary heap, cost() for the scheduler and route() for travel. controller.ts (P4) feeds it reports and edge events.
import type { Static } from "@sinclair/typebox";
import { list, type PortalNode, type Portals, type Route as RouteSchema } from "../contracts.js";

export type PortalReport = Static<typeof Portals>;
export type Route = Static<typeof RouteSchema>;
type ReportNode = Static<typeof PortalNode>;

/** Tile-equivalents for one UE crossing (R-86); P6 re-tunes it from E2E crossing timings. */
export const CROSS = 64;
/** Two sides' open runs must overlap by this much to make a crossing link (spec §7.5). */
const MIN_OVERLAP = 16;

export type Place = { inst: number; surface: string; x: number; y: number };
export type EdgePort = {
	isActive(edge: string): boolean;
	edge(edge: string): { length: number; a: number; b: number } | undefined;
};

type Link = { to: number; cost: number; edge?: string; key?: string; x?: number };
type GraphNode = { inst: number; x: number; y: number; links: Link[] };
type Search = { dist: Float64Array; next: Int32Array; via: (Link | undefined)[] };
type Window = { edge: string; k: number; node: number; inst: number; lo: number; hi: number };

const euclid = (ax: number, ay: number, bx: number, by: number) => Math.hypot(ax - bx, ay - by);
const tileKey = (inst: number, surface: string) => `${inst}|${surface}`;

/** A binary min-heap of (distance, node); UE's isn't exported (R-86). */
class Heap {
	private d: number[] = [];
	private n: number[] = [];

	get size() {
		return this.d.length;
	}

	push(dist: number, node: number) {
		const { d, n } = this;
		let i = d.length;
		d.push(dist);
		n.push(node);
		while (i > 0) {
			const p = (i - 1) >> 1;
			if (d[p] <= dist) {
				break;
			}
			d[i] = d[p];
			n[i] = n[p];
			i = p;
		}
		d[i] = dist;
		n[i] = node;
	}

	pop(): [number, number] {
		const { d, n } = this;
		const top: [number, number] = [d[0], n[0]];
		const ld = d.pop() as number;
		const ln = n.pop() as number;
		if (d.length > 0) {
			let i = 0;
			for (;;) {
				let c = 2 * i + 1;
				if (c >= d.length) {
					break;
				}
				if (c + 1 < d.length && d[c + 1] < d[c]) {
					c += 1;
				}
				if (d[c] >= ld) {
					break;
				}
				d[i] = d[c];
				n[i] = n[c];
				i = c;
			}
			d[i] = ld;
			n[i] = ln;
		}
		return top;
	}
}

export class Routes {
	private readonly port: EdgePort;
	private reports = new Map<string, { inst: number; report: PortalReport }>();
	private version = 0;
	private built = -1;
	private nodes: GraphNode[] = [];
	private byTile = new Map<string, number[]>();
	// ponytail: one search per distinct target place per version, cleared at 2,000 entries; every report or edge
	// event clears it too.
	private memo = new Map<string, Search>();

	constructor(port: EdgePort) {
		this.port = port;
	}

	/** A full replace for (inst, report.surface); a report no newer than the stored one is ignored (R-125). */
	report(inst: number, report: PortalReport): void {
		const key = tileKey(inst, report.surface);
		const old = this.reports.get(key);
		if (old && old.report.epoch >= report.epoch) {
			return;
		}
		this.reports.set(key, { inst, report });
		this.version += 1;
	}

	dropInstance(inst: number): void {
		for (const [key, r] of this.reports) {
			if (r.inst === inst) {
				this.reports.delete(key);
			}
		}
		this.version += 1;
	}

	edgesChanged(): void {
		this.version += 1;
	}

	cost(a: Place, b: Place): number {
		if (a.surface !== b.surface) {
			return Infinity;
		}
		if (a.inst === b.inst) {
			return euclid(a.x, a.y, b.x, b.y);
		}
		this.build();
		const from = this.byTile.get(tileKey(a.inst, a.surface));
		const to = this.byTile.get(tileKey(b.inst, b.surface));
		if (!from || !to) {
			return euclid(a.x, a.y, b.x, b.y) + CROSS; // the estimate (spec §7.6)
		}
		return this.start(a, from, this.search(b, to)).cost;
	}

	route(a: Place, b: Place, opts: { avoid?: string[] } = {}): Route | null {
		const goal = { inst: b.inst, x: b.x, y: b.y };
		if (a.surface !== b.surface) {
			return null;
		}
		if (a.inst === b.inst) {
			return { v: 1, goal, hops: [], graph: this.version };
		}
		this.build();
		const from = this.byTile.get(tileKey(a.inst, a.surface));
		const to = this.byTile.get(tileKey(b.inst, b.surface));
		if (!from || !to) {
			return null;
		}
		const s = this.search(b, to, opts.avoid?.length ? new Set(opts.avoid) : undefined);
		const best = this.start(a, from, s);
		if (best.cost === Infinity) {
			return null;
		}
		let node = best.node;
		const hops: Route["hops"] = [];
		while (s.next[node] !== -1) {
			const link = s.via[node] as Link;
			if (link.edge !== undefined) {
				hops.push({ edge: link.edge, x: link.x as number, from: this.nodes[node].inst });
			}
			node = s.next[node];
		}
		return { v: 1, goal, hops, graph: this.version };
	}

	private build(): void {
		if (this.built === this.version) {
			return;
		}
		this.built = this.version;
		this.memo.clear();
		this.nodes = [];
		this.byTile.clear();
		const windows = new Map<string, Window[]>();
		for (const { inst, report } of this.reports.values()) {
			const mine: number[] = [];
			for (const n of list<ReportNode>(report.nodes)) {
				const i = this.nodes.length;
				this.nodes.push({ inst, x: n.x, y: n.y, links: [] });
				mine.push(i);
				if (n.kind === "w" && n.edge !== undefined && n.k !== undefined && n.lo !== undefined
					&& n.hi !== undefined) {
					const key = JSON.stringify([report.surface, n.edge, n.k]);
					const entries = windows.get(key) ?? [];
					entries.push({ edge: n.edge, k: n.k, node: i, inst, lo: n.lo, hi: n.hi });
					windows.set(key, entries);
				}
			}
			this.byTile.set(tileKey(inst, report.surface), mine);
			// R-150: straight-line links between every pair of nodes in one component.
			const nodes = list<ReportNode>(report.nodes);
			for (let a = 0; a < mine.length; a++) {
				for (let b = a + 1; b < mine.length; b++) {
					if (nodes[a].comp === nodes[b].comp) {
						const cost = Math.round(Math.hypot(nodes[a].x - nodes[b].x, nodes[a].y - nodes[b].y));
						this.nodes[mine[a]].links.push({ to: mine[b], cost });
						this.nodes[mine[b]].links.push({ to: mine[a], cost });
					}
				}
			}
		}
		for (const entries of windows.values()) {
			const { edge, k } = entries[0];
			const e = this.port.edge(edge);
			if (!e || !this.port.isActive(edge)) {
				continue;
			}
			const sa = entries.find(w => w.inst === e.a);
			const sb = entries.find(w => w.inst === e.b);
			if (!sa || !sb || sa === sb) {
				continue;
			}
			const lo = Math.max(sa.lo, sb.lo);
			const hi = Math.min(sa.hi, sb.hi);
			if (hi - lo < MIN_OVERLAP) {
				continue;
			}
			const link = { cost: CROSS, edge, key: `${edge}:${k}`, x: (lo + hi) / 2 };
			this.nodes[sa.node].links.push({ to: sb.node, ...link });
			this.nodes[sb.node].links.push({ to: sa.node, ...link });
		}
	}

	/** Distances to place b from every node: Dijkstra seeded at b's tile nodes (R-149: b attaches to all of them). */
	private search(b: Place, to: number[], avoid?: Set<string>): Search {
		const key = `${b.inst}|${b.surface}|${b.x}|${b.y}`;
		const hit = avoid ? undefined : this.memo.get(key);
		if (hit) {
			return hit;
		}
		const count = this.nodes.length;
		const dist = new Float64Array(count).fill(Infinity);
		const next = new Int32Array(count).fill(-1);
		const via: (Link | undefined)[] = new Array<Link | undefined>(count);
		const heap = new Heap();
		for (const i of to) {
			dist[i] = euclid(b.x, b.y, this.nodes[i].x, this.nodes[i].y);
			heap.push(dist[i], i);
		}
		while (heap.size > 0) {
			const [d, u] = heap.pop();
			if (d > dist[u]) {
				continue;
			}
			for (const l of this.nodes[u].links) {
				if (avoid && l.edge !== undefined && (avoid.has(l.edge) || avoid.has(l.key as string))) {
					continue;
				}
				const nd = d + l.cost;
				if (nd < dist[l.to]) {
					dist[l.to] = nd;
					next[l.to] = u;
					via[l.to] = l;
					heap.push(nd, l.to);
				}
			}
		}
		const s = { dist, next, via };
		if (!avoid) {
			if (this.memo.size >= 2000) { this.memo.clear(); }
			this.memo.set(key, s);
		}
		return s;
	}

	/** a's best node to leave from, and the whole cost through it. */
	private start(a: Place, from: number[], s: Search) {
		let node = -1;
		let cost = Infinity;
		for (const i of from) {
			const c = euclid(a.x, a.y, this.nodes[i].x, this.nodes[i].y) + s.dist[i];
			if (c < cost) {
				cost = c;
				node = i;
			}
		}
		return { node, cost };
	}
}
