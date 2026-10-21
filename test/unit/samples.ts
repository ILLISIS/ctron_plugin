// One valid payload per bridge type (spec §9.2), and the largest records of each kind (spec §14.2's maxima), for the
// contract and relay tests. Not a test file: the runner only picks up *.test.js.
import type { Static, TSchema } from "@sinclair/typebox";
import type { DOWN, Settings, UP } from "../../contracts.js";

type Payloads<T extends Record<string, TSchema>> = { [K in keyof T]: Static<T[K]> };

export const SETTINGS: Static<typeof Settings> = {
	job_start_delay: 300, debug: false,
	kinds: { construction: true, rebuild: true, deconstruction: true, upgrade: true, repair: true, destroy: false },
	horde: false, zone_restriction: false, robot: ["construction-robot", "normal"], robot_count: 50,
	repair_tool: ["repair-pack", "normal"], ammo: ["rocket", "normal"], ammo_count: 0,
	atomic: ["atomic-bomb", "normal"], atomic_count: 0, min_cluster: 8, minions: 1,
};

// CC's key for the 80×80 cell holding (0, 0): (0 + 12500) * 25000 + (0 + 12500) (CC entity_processor.lua:18).
const WID = "1|nauvis|construction|312512500";
const station = { sid: "1.17", inst: 1, x: 10.5, y: -4 };
const area = { left_top: { x: 0, y: 0 }, right_bottom: { x: 40, y: 20 } };

export const UP_SAMPLES: Payloads<typeof UP> = {
	"ct.snapshot": {
		seq: 1, part: 1, parts: 1,
		ctrons: [{
			cid: "1.42", surface: "nauvis", name: "constructron", quality: "normal", x: 3, y: 4, state: "idle",
			free: { normal: 60, destroy: 58, cargo: 62 },
			restock: { normal: [["construction-robot", "normal", 50, 50]], destroy: {}, cargo: {} },
		}],
		stations: [{ sid: "1.17", surface: "nauvis", name: "Mall", x: 10.5, y: -4 }],
		cells: [
			{ wid: WID, surface: "nauvis", kind: "construction", since: 600, due: 240, tool: false },
			{
				wid: "1|nauvis|deconstruction|312512500", surface: "nauvis", kind: "deconstruction", since: 600, due: 0,
				tool: false, scanned: 900, area, center: { x: 20, y: 10 }, bring: {}, out: 7, n: 30,
			},
		],
		needs: [{ sid: "1.17", surface: "nauvis", slots: [["iron-plate", "normal", 100, 500, 80, 100]] }],
		jobs: [{
			jid: "b007.3", kind: "construction", surface: "nauvis", members: ["1.42"], state: "loading",
			status: "requesting", tasks: [0, 4], station,
			shares: [{ wid: WID, bring: [["wooden-chest", "normal", 12, 50]], out: 0 }],
			missing: [["wooden-chest", "normal", 2]],
		}, {
			jid: "b007.4", kind: "cargo", surface: "nauvis", members: ["1.43"], state: "to_dest", status: "delivering",
			tasks: [0, 0], station, shares: {},
			cargo: { dest: { sid: "1.18", inst: 1, x: 20, y: 8 }, items: [["iron-plate", "normal", 200]] },
		}],
		defaults: SETTINGS,
	},
	"ct.delta": { cells: { up: {}, rm: [WID] }, jobs: { up: {}, rm: ["b007.3"] } },
	"ct.job.event": { jid: "b007.3", ev: "done", tick: 1200, cid: "1.42", left: 1180 },
	"ct.stock.reply": {
		req: "c7e5.1", part: 1, parts: 1,
		r: [{ qid: "q1", sids: ["1.17", "1.18"], cover: true }, { qid: "q1", sids: ["2.4"], cover: [1, 3] }],
	},
	"ct.route.ask": {
		req: "c7e5.2", jid: "b007.3", surface: "nauvis", from: { x: 3, y: 4 }, to: { inst: 2, x: 600, y: 4 }, avoid: {},
	},
	"ct.portals": {
		surface: "nauvis", epoch: 2,
		nodes: [
			{ id: 0, kind: "w", edge: "e1", k: 0, lo: 24, hi: 96, x: 60, y: 6, comp: 1 },
			{ id: 1, kind: "s", x: 10.5, y: -4, comp: 1, sid: "1.17" },
		],
	},
	"ct.detail.reply": {
		req: "c7e5.3",
		detail: {
			members: [{
				cid: "1.42", x: 3, y: 4, trunk: [["iron-plate", "normal", 100]], ammo: {}, trash: {},
				requests: [["iron-gear-wheel", "normal", 40, 12]],
			}],
			tasks: [[10, 20]], station,
		},
	},
	"ct.ui.watch": { surface: "nauvis", tile: 1, expand: "1|construction", on: true },
	"ct.ui.cancel": { target: "work", kind: "construction", surface: "nauvis" },
	"ct.ui.drop": { surface: "nauvis", name: "iron-gear-wheel", quality: "normal" },
	"ct.ui.cargo": { sid: "1.17", slots: {}, name: "Mall" }, // Lua sends an empty list as {}
	"ct.ui.detail.ask": { req: "c7e5.4", jid: "b007.3" },
	"ct.settings.set": { surface: "*", patch: { robot_count: 60, kinds: { destroy: true } } },
};

const JOB_ROW = {
	key: "j:b007.3", kind: "construction", at: 1, atName: "tile-0-0", worker: "1.42", n: 1, state: "loading",
	status: "requesting", tasks: [0, 4] as [number, number], station: { sid: "1.17", name: "Mall",
		inst: 1, x: 10.5, y: -4 },
} as const;

export const DOWN_SAMPLES: Payloads<typeof DOWN> = {
	"ct.snapshot.request": {},
	"ct.job.assign": {
		jid: "b007.3", kind: "construction", surface: "nauvis", station, members: ["1.42"],
		work: [{ wid: WID, key: 312512500, area, bring: [["wooden-chest", "normal", 12, 50]], out: 0 }],
	},
	"ct.job.station": { jid: "b007.3", cid: "1.42", station: { sid: "2.9", inst: 2, x: 500, y: 0 }, why: "short" },
	"ct.job.cancel": { jid: "b007.3" },
	"ct.job.squad": { jid: "b007.3", lead: { inst: 2, x: 12.5, y: -3 }, gone: ["1.42"], done: false },
	"ct.job.drop": { surface: "nauvis", name: "iron-gear-wheel", quality: "normal" },
	"ct.station.set": { sid: "1.17", slots: [["iron-plate", "normal", 10, 100]], name: "Mall" },
	"ct.work.clear": { wids: [WID] },
	"ct.stock.query": {
		req: "c7e5.5", q: [{ qid: "q1", mode: "supply", items: [["wooden-chest", "normal", 12]], exclude_sid: "1.17" }],
	},
	"ct.route.reply": {
		req: "c7e5.2", route: { v: 1, goal: { inst: 2, x: 600, y: 4 }, hops: [{ edge: "e1", x: 32,
			from: 1 }], graph: 7 },
	},
	"ct.detail.fetch": { req: "c7e5.6", jid: "b007.3" },
	"ct.ui.list": {
		watch: { surface: "nauvis", tile: 1, expand: "1|construction" }, seq: 1, full: true, part: 1, parts: 1, rm: [],
		up: [
			{
				key: "g:1|construction", sec: "pending", ord: 0, kind: "construction", owner: 1, ownerName: "tile-0-0",
				n: 4, oldestMs: 1000, st: "backoff", why: "no_progress",
			},
			{
				key: `w:${WID}`, sec: "pending", ord: 1, kind: "construction", owner: 1, ownerName: "tile-0-0",
				c: [20, 10], st: "open", why: "no_ctron", rem: 1, committed: 0, firstSeenMs: 1000, tool: false,
			},
			{ ...JOB_ROW, sec: "progress", ord: 0 },
			{
				key: "c:1.42", sec: "ctrons", ord: 0, at: 1, atName: "tile-0-0", name: "constructron", state: "busy",
				jid: "b007.3", kind: "construction", status: "requesting",
			},
			{ key: "s:1.17", sec: "stations", ord: 0, at: 1, atName: "tile-0-0", name: "Mall", x: 10.5, y: -4 },
			{
				key: "n:1.17", sec: "stations", ord: 1, sid: "1.17", slots: [["iron-plate", "normal", 100, 500, 80]],
				order: [420], why: "no_supplier",
			},
		],
		stats: {
			total: 1, available: 0, surfaces: ["nauvis"], tiles: [[1, "tile-0-0"]], now: 1760000000000,
			more: { progress: 0 }, waiting: [["wooden-chest", "normal", 2]],
		},
	},
	"ct.ui.detail": {
		req: "c7e5.4", detail: { ...UP_SAMPLES["ct.detail.reply"].detail!, job: JOB_ROW },
	},
	"ct.ui.link": { up: false },
	"ct.settings": { overrides: { "*": { job_start_delay: 600 }, "nauvis": { minions: 2 } }, surfaces: ["nauvis"] },
};

// The largest records (spec §14.2, R-155): 19-character ids, 40-character item names, legendary quality, counts of
// 99999, 30-character surfaces and 60-character free text.
const NAME = "explosive-uranium-cannon-shell-mk2-xxxxx"; // 40 characters
const SURFACE = "s".repeat(30);
const ID = "1234567890.12345678";
const TEXT = "t".repeat(60);
const XY = { x: -123456.5, y: 654321.25 };
/** A distinct 40-character item name per index. */
const nm = (i: number) => NAME.slice(0, 40 - String(i).length) + i;
/** n distinct item kinds as [name, quality, count, stack]. */
type Big = [string, string, number, number];
type Slot5 = [string, string, number, number, number];
type Slot = [string, string, number, number, number, number];
const bigs = (n: number) => Array.from({ length: n }, (_, i): Big => [nm(i), "legendary", 99999, 99999]);
const slot = (i: number): Slot => [nm(i), "legendary", 99999, 99999, 99999, 99999];
const stationRef = { sid: ID, inst: 1234567890, ...XY };
export const MAX_WID = `1234567890|${SURFACE}|deconstruction|312512500`;
const job = {
	jid: ID, kind: "construction" as const, surface: SURFACE, members: [ID], state: "unloading" as const,
	status: "awaiting_logistics", arg: TEXT, tasks: [99999, 99999] as [number, number], station: stationRef,
	shares: [] as { wid: string, bring: [string, string, number, number][], out: number }[],
	left: 123456789, missing: bigs(10),
};
export const MAX = {
	ctron: {
		cid: ID, surface: SURFACE, name: NAME, quality: "legendary", label: TEXT, ...XY, state: "unfit" as const,
		why: TEXT, jid: ID, free: { normal: 99999, destroy: 99999, cargo: 99999 },
		restock: { normal: bigs(4), destroy: bigs(4), cargo: bigs(4) },
	},
	station: { sid: ID, surface: SURFACE, name: TEXT, ...XY },
	cell: {
		wid: MAX_WID, surface: SURFACE, kind: "deconstruction" as const, since: 123456789, due: 99999,
		tool: false, scanned: 123456789,
		area: { left_top: { x: -123440, y: 654320 }, right_bottom: { x: -123360, y: 654400 } },
		center: { x: -123400, y: 654360 }, bring: bigs(30), out: 99999, n: 99999,
	},
	need: { sid: ID, surface: SURFACE, slots: Array.from({ length: 30 }, (_, i) => slot(i)) },
	/** A construction job with one share of 30 kinds. */
	job: { ...job, shares: [{ wid: MAX_WID, bring: bigs(30), out: 99999 }] },
	/** A cargo job: 30 cargo items. */
	cargoJob: {
		...job, kind: "cargo" as const, shares: [], tasks: [0, 0] as [number, number],
		cargo: { dest: stationRef, items: bigs(30).map(([n, q, c]) => [n, q, c] as [string, string, number]) },
	},
	/** A destroy job at CC's minion cap: 101 runs. */
	destroyJob: {
		...job, kind: "destroy" as const, members: Array.from({ length: 101 }, () => ID),
		shares: [{ wid: MAX_WID, bring: bigs(1), out: 99999 }],
	},
	/** One stock-reply record: 100 stations of one network, 30 items covered. */
	stockRec: {
		qid: `q-${"9".repeat(17)}`, sids: Array.from({ length: 100 }, () => ID),
		cover: Array.from({ length: 30 }, (_, i) => i + 1),
	},
};

/** The other up messages at their largest (the three with no cap in §14.2 get a generous one). */
export const MAX_UP = {
	"ct.job.event": {
		jid: ID, ev: "short" as const, tick: 4294967295, cid: ID, left: 4294967295, why: TEXT, missing: bigs(10),
		items: bigs(10), wid: MAX_WID,
	},
	"ct.route.ask": {
		req: "ffffffff.4294967295", jid: ID, surface: SURFACE, from: XY, to: { inst: 1234567890, ...XY },
		avoid: Array.from({ length: 20 }, () => SURFACE),
	},
	"ct.ui.watch": { surface: SURFACE, tile: 1234567890, expand: "1234567890|deconstruction", on: true },
	"ct.ui.cancel": { target: "work" as const, kind: "deconstruction" as const, surface: SURFACE, id: MAX_WID },
	"ct.ui.drop": { jid: ID, surface: SURFACE, name: NAME, quality: "legendary" },
	"ct.ui.cargo": { sid: ID, slots: Array.from({ length: 30 }, (_, i) => slot(i).slice(0, 4) as Big), name: TEXT },
	"ct.ui.detail.ask": { req: "ffffffff.4294967295", jid: ID },
	"ct.settings.set": {
		surface: SURFACE, patch: {
			job_start_delay: 99999, debug: true, horde: true, zone_restriction: true,
			robot_count: 10000, ammo_count: 8000,
			atomic_count: 1000, min_cluster: 100, minions: 100,
			kinds: { construction: true, rebuild: true, deconstruction: true, upgrade: true,
				repair: true, destroy: true },
			robot: [NAME, "legendary"], repair_tool: [NAME, "legendary"], ammo: [NAME, "legendary"],
			atomic: [NAME, "legendary"],
		},
	},
};

/** Down messages at their largest (3 KB each, R-15). */
export const MAX_DOWN = {
	assign101: {
		jid: ID, kind: "destroy" as const, surface: SURFACE, station: stationRef, members: MAX.destroyJob.members,
		work: [] as { wid: string, key: number, area: typeof MAX.cell.area, bring: [string, string,
			number, number][], out: number }[],
	},
	/** A minion assign of 100 members. */
	assignMinions100: {
		jid: ID, kind: "destroy" as const, surface: SURFACE, station: stationRef,
		members: Array.from({ length: 100 }, () => ID), work: [] as never[],
		lead: { cid: ID, inst: 1234567890, ...XY },
	},
	/** A squad update naming 100 gone minions. */
	squad100: {
		jid: ID, lead: { inst: 1234567890, ...XY }, gone: Array.from({ length: 100 }, () => ID), done: true,
	},
	assign30: {
		jid: ID, kind: "deconstruction" as const, surface: SURFACE, station: stationRef, members: [ID],
		work: [{ wid: MAX_WID, key: 312512500, area: MAX.cell.area, bring: bigs(30), out: 99999 }],
	},
	/** One ct.list part's row kinds at their widest, to be packed by hand to the part budget. */
	rows: [
		{
			key: `w:${MAX_WID}`, sec: "pending", ord: 99999, kind: "deconstruction" as const, owner: 1234567890,
			ownerName: TEXT, c: [-123456.5, 654321.25] as [number, number], st: "waiting_squad" as const,
			why: "no_progress" as const, rem: 99999, committed: 99999, firstSeenMs: 1760000000000,
			dueAtMs: 1760000000000,
			tool: false,
		},
		{
			key: `j:${ID}`, sec: "progress", ord: 99999, kind: "deconstruction" as const, at: 1234567890, atName: TEXT,
			worker: ID, n: 101, state: "unloading", status: "awaiting_logistics", arg: TEXT, tasks: [99999, 99999] as
				[number, number], station: { sid: ID, name: TEXT, inst: 1234567890, ...XY }, missing: bigs(10),
		},
		{
			key: `c:${ID}`, sec: "ctrons", ord: 99999, at: 1234567890, atName: TEXT, name: NAME, label: TEXT,
			state: "unfit" as const, why: TEXT, jid: ID, kind: "deconstruction" as const, status: "awaiting_logistics",
			arg: TEXT, ...XY,
		},
		{ key: `s:${ID}`, sec: "stations", ord: 99999, at: 1234567890, atName: TEXT, name: TEXT, ...XY },
		{
			key: `n:${ID}`, sec: "stations", ord: 99999, sid: ID,
			slots: Array.from({ length: 30 }, (_, i) => slot(i).slice(0, 5) as Slot5),
			order: Array.from({ length: 30 }, () => 99999), why: "no_supplier" as const,
		},
	],
};
