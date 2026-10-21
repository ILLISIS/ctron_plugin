import { test } from "node:test";
import assert from "node:assert/strict";
import * as lib from "@clusterio/lib";
import { Type } from "@sinclair/typebox";
import {
	DETAIL_BYTES, DOWN, Delta, Item, List, PART_BUDGET, Snapshot, UP, UP_LIMIT, list,
} from "../../contracts.js";
import { plugin } from "../../index.js";
import * as messages from "../../messages.js";
import { DOWN_SAMPLES, MAX, MAX_DOWN, MAX_UP, MAX_WID, SETTINGS, UP_SAMPLES } from "./samples.js";
import loadInstancePlugin from "../../instance.js";
import { fakeInstance, settle } from "./fakes.js";

const valid = (schema: unknown, value: unknown) => lib.compile(schema as any)(value);

test("the catalogue lists every bridge type of spec §9.2, and each type's sample is valid", () => {
	assert.deepEqual(Object.keys(UP).sort(), [
		"ct.delta", "ct.detail.reply", "ct.job.event", "ct.portals", "ct.route.ask", "ct.settings.set", "ct.snapshot",
		"ct.stock.reply", "ct.ui.cancel", "ct.ui.cargo", "ct.ui.detail.ask", "ct.ui.drop", "ct.ui.watch",
	]);
	assert.deepEqual(Object.keys(DOWN).sort(), [
		"ct.detail.fetch", "ct.job.assign", "ct.job.cancel", "ct.job.drop", "ct.job.squad", "ct.job.station",
		"ct.route.reply",
		"ct.settings", "ct.snapshot.request", "ct.station.set", "ct.stock.query", "ct.ui.detail", "ct.ui.link",
		"ct.ui.list", "ct.work.clear",
	]);
	const samples: Record<string, unknown> = { ...UP_SAMPLES, ...DOWN_SAMPLES };
	for (const [type, schema] of Object.entries({ ...UP, ...DOWN })) {
		assert.ok(valid(schema, samples[type]), `${type}'s sample is valid`);
	}
});

test("List() takes an array, or Lua's {} for an empty one, and nothing else; list() reads {} as []", () => {
	const ints = List(Type.Integer()); // eslint-disable-line new-cap
	assert.ok(valid(ints, []));
	assert.ok(valid(ints, [1, 2]));
	assert.ok(valid(ints, {}));
	assert.ok(!valid(ints, { a: 1 }));
	assert.ok(!valid(ints, "1"));
	assert.ok(!valid(ints, ["x"]));
	assert.deepEqual(list({}), []);
	assert.deepEqual(list([3]), [3]);
});

test("a fresh tile's snapshot and delta, every list an empty Lua table, are valid (R-18)", () => {
	assert.ok(valid(Snapshot, { seq: 1, part: 2, parts: 2, ctrons: {}, stations: {}, cells: {}, needs: {}, jobs: {} }));
	assert.ok(valid(Delta, { cells: { up: {}, rm: {} } }));
	assert.ok(valid(Delta, {}));
	assert.ok(valid(Snapshot, {
		seq: 1, part: 1, parts: 1, ctrons: {}, stations: {}, cells: {}, needs: {}, jobs: {}, defaults: SETTINGS,
	}));
});

test("an item is [name, quality, count] or [name, quality, count, stack], counts whole", () => {
	assert.ok(valid(Item, ["iron-plate", "normal", 5]));
	assert.ok(valid(Item, ["iron-plate", "rare", 5, 100]));
	assert.ok(!valid(Item, ["iron-plate", "normal"]));
	assert.ok(!valid(Item, ["iron-plate", "normal", 5, 100, 1]));
	assert.ok(!valid(Item, ["iron-plate", "normal", 2.5]));
});

/** Each class with a payload for it: the bridge sample, or for the two controller requests the sample without req. */
const CLASS_PAYLOADS: [any, unknown][] = [
	[messages.TileSnapshotEvent, UP_SAMPLES["ct.snapshot"]],
	[messages.TileDeltaEvent, UP_SAMPLES["ct.delta"]],
	[messages.JobEventEvent, UP_SAMPLES["ct.job.event"]],
	[messages.PortalReportEvent, UP_SAMPLES["ct.portals"]],
	[messages.UiWatchEvent, UP_SAMPLES["ct.ui.watch"]],
	[messages.UiCancelEvent, UP_SAMPLES["ct.ui.cancel"]],
	[messages.UiDropEvent, UP_SAMPLES["ct.ui.drop"]],
	[messages.UiCargoEvent, UP_SAMPLES["ct.ui.cargo"]],
	[messages.SettingsSetEvent, UP_SAMPLES["ct.settings.set"]],
	[messages.RouteRequest, UP_SAMPLES["ct.route.ask"]],
	[messages.JobDetailRequest, UP_SAMPLES["ct.ui.detail.ask"]],
	[messages.JobAssignEvent, DOWN_SAMPLES["ct.job.assign"]],
	[messages.JobStationEvent, DOWN_SAMPLES["ct.job.station"]],
	[messages.JobCancelEvent, DOWN_SAMPLES["ct.job.cancel"]],
	[messages.JobSquadEvent, DOWN_SAMPLES["ct.job.squad"]],
	[messages.JobDropEvent, DOWN_SAMPLES["ct.job.drop"]],
	[messages.StationSetEvent, DOWN_SAMPLES["ct.station.set"]],
	[messages.WorkClearEvent, DOWN_SAMPLES["ct.work.clear"]],
	[messages.UiListEvent, DOWN_SAMPLES["ct.ui.list"]],
	[messages.SettingsStateEvent, DOWN_SAMPLES["ct.settings"]],
	[messages.StockQueryRequest, { q: DOWN_SAMPLES["ct.stock.query"].q }],
	[messages.JobDetailFetchRequest, { jid: DOWN_SAMPLES["ct.detail.fetch"].jid }],
];

test("22 classes, each declared in index.ts and round-tripping its payload through JSON", () => {
	const classes = Object.values(messages);
	assert.equal(classes.length, 22);
	assert.deepEqual(new Set(CLASS_PAYLOADS.map(([C]) => C)), new Set(classes), "every class has a payload row");
	for (const [C, payload] of CLASS_PAYLOADS) {
		assert.ok(plugin.messages?.includes(C), `${C.name} is declared`);
		assert.equal(C.plugin, "ctron_pluginv2", C.name);
		const json = JSON.parse(JSON.stringify(new C(payload)));
		assert.ok(valid(C.jsonSchema, json), `${C.name}'s JSON is valid`);
		assert.deepEqual(C.fromJSON(json), new C(payload), C.name);
	}
});

test("each request's Response takes its answer, and null where there is none", () => {
	const route = DOWN_SAMPLES["ct.route.reply"].route;
	const detail = UP_SAMPLES["ct.detail.reply"].detail;
	assert.ok(valid(messages.RouteRequest.Response.jsonSchema, { route }));
	assert.ok(valid(messages.RouteRequest.Response.jsonSchema, { route: null }));
	assert.ok(valid(messages.JobDetailRequest.Response.jsonSchema, { detail: DOWN_SAMPLES["ct.ui.detail"].detail }));
	assert.ok(!valid(messages.JobDetailRequest.Response.jsonSchema, { detail }), "the controller adds the job row");
	assert.ok(valid(messages.JobDetailFetchRequest.Response.jsonSchema, { detail }));
	assert.ok(valid(messages.JobDetailRequest.Response.jsonSchema, { detail: null }));
	assert.ok(valid(messages.JobDetailFetchRequest.Response.jsonSchema, { detail: null }));
	assert.ok(valid(messages.StockQueryRequest.Response.jsonSchema, { r: UP_SAMPLES["ct.stock.reply"].r }));
	assert.ok(valid(messages.StockQueryRequest.Response.jsonSchema, { r: {} }), "Lua's empty r");
});

/** A bridge message as UE's flush encodes it: { id, type, payload }, with the longest id the bridge mints. */
const encoded = (type: string, payload: unknown) => JSON.stringify({ id: "ffffffff.4294967295", type, payload }).length;

/** Fill a part as parts_core.pack fills one: each value's JSON plus one separator byte, up to PART_BUDGET. */
function fill(part: any, pool: [string, string, unknown][]) {
	let used = 0;
	for (const [kind, op, value] of pool) {
		const bytes = JSON.stringify(value).length + 1;
		if (used + bytes <= PART_BUDGET) {
			part[kind][op].push(value);
			used += bytes;
		}
	}
	return used;
}

const ENVELOPE_ID = "ffffffff.4294967295";
const measure = (name: string, bytes: number, limit: number, strict: boolean) => {
	process.stdout.write(`size ${name}: ${bytes} bytes (limit ${limit})\n`);
	assert.ok(strict ? bytes < limit : bytes <= limit, `${name}: ${bytes} bytes, over ${limit}`);
};

test("R-125/R-155: at the maxima of spec §14.2, every up message but ct.portals encodes under UP_LIMIT", () => {
	const kinds = ["ctrons", "stations", "cells", "needs", "jobs"];
	const records: [string, string, unknown][] = [
		["jobs", "up", MAX.job], ["jobs", "up", MAX.cargoJob], ["jobs", "up", MAX.destroyJob],
		["cells", "up", MAX.cell],
		["needs", "up", MAX.need], ["ctrons", "up", MAX.ctron], ["stations", "up", MAX.station],
	];
	const rms: [string, string, unknown][] = Array.from(
		{ length: 200 }, (_, i) => [kinds[i % 5], "rm", `${MAX_WID}${i}`]);
	const delta: any = Object.fromEntries(kinds.map(k => [k, { up: [], rm: [] }]));
	assert.ok(fill(delta, [...records, ...rms]) > PART_BUDGET - 100, "the delta part is full");
	assert.ok(valid(Delta, delta));
	measure("ct.delta part", encoded("ct.delta", delta), UP_LIMIT, false);

	const snap: any = {
		seq: 99999, part: 1, parts: 999, defaults: { ...SETTINGS, robot: [MAX.ctron.name, "legendary"] },
	};
	for (const k of kinds) {
		snap[k] = { up: [] };
	}
	fill(snap, Array.from({ length: 20 }, (_, i) => records[i % records.length]));
	for (const k of kinds) {
		snap[k] = snap[k].up;
	}
	assert.ok(valid(Snapshot, snap));
	measure("ct.snapshot part 1", encoded("ct.snapshot", snap), UP_LIMIT, false);

	// A stock reply part: maximal records packed to PART_BUDGET.
	const stock: any = { req: ENVELOPE_ID, part: 99, parts: 99, r: [] };
	fill({ x: stock }, Array.from({ length: 10 }, () => ["x", "r", MAX.stockRec] as [string, string, unknown]));
	assert.ok(valid(UP["ct.stock.reply"], stock));
	measure("ct.stock.reply part", encoded("ct.stock.reply", stock), UP_LIMIT, false);
	measure("ct.stock.reply, one record alone", encoded("ct.stock.reply",
		{ req: ENVELOPE_ID, part: 1, parts: 1, r: [MAX.stockRec] }), UP_LIMIT, false);

	const member = {
		cid: MAX.ctron.cid, x: -123456.5, y: 654321.25, trunk: [] as unknown[], ammo: {}, trash: {}, requests: {},
	};
	const detail = { members: [member], tasks: {}, station: MAX.job.station };
	for (let i = 0; JSON.stringify(detail).length + 60 < DETAIL_BYTES; i++) {
		member.trunk.push([`${MAX.ctron.name}${i}`, "legendary", 99999]);
	}
	assert.ok(JSON.stringify(detail).length <= DETAIL_BYTES);
	const reply = { req: ENVELOPE_ID, detail };
	assert.ok(valid(UP["ct.detail.reply"], reply));
	measure("ct.detail.reply", encoded("ct.detail.reply", reply), UP_LIMIT, false);

	for (const [type, payload] of Object.entries(MAX_UP)) {
		assert.ok(valid((UP as any)[type], payload), `${type}'s maximum is valid`);
		measure(type, encoded(type, payload), UP_LIMIT, false);
	}
	for (const [type, payload] of Object.entries(UP_SAMPLES)) {
		assert.ok(type === "ct.portals" || encoded(type, payload) < UP_LIMIT, type);
	}
});

/** Lua packs a record larger than the part budget alone (R-164): it must still fit a message with its wrapper. */
test("R-164: each maximal record alone in a ct.delta, or a stock record in a reply, fits UP_LIMIT", () => {
	const records: [string, string, unknown][] = [
		["construction job", "jobs", MAX.job], ["cargo job", "jobs", MAX.cargoJob],
		["destroy job", "jobs", MAX.destroyJob], ["cell", "cells", MAX.cell], ["need", "needs", MAX.need],
		["ctron", "ctrons", MAX.ctron], ["station", "stations", MAX.station], ["stock record", "", MAX.stockRec],
	];
	for (const [name, kind, record] of records) {
		const alone = kind ? encoded("ct.delta", { [kind]: { up: [record], rm: {} } })
			: encoded("ct.stock.reply", { req: ENVELOPE_ID, part: 99, parts: 99, r: [record] });
		measure(`${name} alone (record ${JSON.stringify(record).length})`, alone, UP_LIMIT, false);
	}
});

test("R-15/R-155: at the maxima, down messages encode within 3 KB, envelope included", () => {
	const assign101 = MAX_DOWN.assign101;
	const assign30 = MAX_DOWN.assign30;
	assert.equal(assign101.members.length, 101);
	const cases = [["ct.job.assign, 101 members", assign101], ["ct.job.assign, 30-kind share", assign30]];
	for (const [name, payload] of cases) {
		assert.ok(valid(DOWN["ct.job.assign"], payload), name as string);
		measure(name as string, encoded("ct.job.assign", payload), 3072, false);
	}
	assert.ok(valid(DOWN["ct.job.assign"], MAX_DOWN.assignMinions100));
	measure("ct.job.assign, 100 minions", encoded("ct.job.assign", MAX_DOWN.assignMinions100), 3072, false);
	assert.ok(valid(DOWN["ct.job.squad"], MAX_DOWN.squad100));
	measure("ct.job.squad, 100 gone", encoded("ct.job.squad", MAX_DOWN.squad100), 3072, false);
	// One ct.ui.list part, packed by hand: widest rows in turn until the next would pass 3 KB.
	const part: any = {
		watch: { surface: "s".repeat(30), tile: 1234567890, expand: "1234567890|deconstruction" }, seq: 99999,
		full: true, part: 99, parts: 99, up: [], rm: [],
		stats: {
			total: 99999, available: 99999, surfaces: [], tiles: [], now: 1760000000000, more: { progress: 99999 },
			waiting: [],
		},
	};
	for (let i = 0; i < 200; i++) {
		part.up.push(MAX_DOWN.rows[i % MAX_DOWN.rows.length]);
		if (encoded("ct.ui.list", part) > 3072) {
			part.up.pop();
			break;
		}
	}
	assert.ok(part.up.length > 0, "at least one widest row fits a part");
	assert.ok(valid(DOWN["ct.ui.list"], part));
	measure("ct.ui.list part", encoded("ct.ui.list", part), 3072, false);
	for (const row of MAX_DOWN.rows) {
		assert.ok(valid(DOWN["ct.ui.list"], { ...part, up: [row] }), `${row.key.slice(0,
			1)} row at its widest is valid`);
		process.stdout.write(`size ct.ui.list row ${row.key.slice(0, 2)}: ${JSON.stringify(row).length} bytes\n`);
	}
	const nRow = MAX_DOWN.rows.find(r => r.key.startsWith("n:"))!;
	assert.ok(valid(DOWN["ct.ui.list"], { ...part, up: [nRow] }));
	measure("ct.ui.list part with the widest n: row", encoded("ct.ui.list", { ...part, up: [nRow] }), 3072, false);
	for (const [type, payload] of Object.entries(DOWN_SAMPLES)) {
		assert.ok(encoded(type, payload) <= 3072, `${type}: ${encoded(type, payload)} bytes`);
	}
});

test("every catalogue row has a relay: each up type reaches the controller or a reply, and each down type is sent",
	async () => {
		const f = fakeInstance();
		await loadInstancePlugin(f.context);
		await f.up(Object.entries(UP_SAMPLES).map(([type, payload]) => ({ type, payload })));
		await settle();
		assert.deepEqual(f.warnings(), [], "every up type is known and its sample valid");
		const reached = new Set(f.sent.map(m => (m as object).constructor));
		for (const C of CLASS_PAYLOADS.map(([K]) => K).filter(K => K.src === "instance")) {
			assert.ok(reached.has(C), `${C.name} reached the controller`);
		}
		// The down paths: each controller → instance class, the start hook and a controller connect.
		const answers = CLASS_PAYLOADS.filter(([C]) => f.handlers.has(C))
			.map(([C, payload]) => f.handlers.get(C)!(new C(payload)));
		await f.fire("start");
		await f.fire("controllerConnectionEvent", "connect");
		await settle();
		for (const m of f.down().filter(d => d.type === "ct.stock.query" || d.type === "ct.detail.fetch")) {
			const reply = m.type === "ct.stock.query"
				? { req: m.payload.req, part: 1, parts: 1, r: [] } : { req: m.payload.req };
			await f.up([{ type: m.type === "ct.stock.query" ? "ct.stock.reply" : "ct.detail.reply", payload: reply }]);
		}
		await Promise.all(answers);
		assert.deepEqual(new Set(f.down().map(m => m.type)), new Set(Object.keys(DOWN)));
	});
