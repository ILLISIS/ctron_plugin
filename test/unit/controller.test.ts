import { test } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import load from "../../controller.js";
import * as m from "../../messages.js";

// §14.2 (R-145): every instance -> controller class is handled; a change to the schedulable set reaches running tiles.
test("controller wiring: every handler present; the schedulable set reaches running tiles", async () => {
	const handlers = new Map<string, any>();
	const hooks: Record<string, any[]> = {};
	const sent: Array<[number, any]> = [];
	const hook = (n: string) => ({ attach: (_o: string, fn: any) => { (hooks[n] ??= []).push(fn); } });
	const inst = (id: number, status: string) => ({
		id, status, config: { get: (k: string) => (k === "instance.name" ? `t${id}` : undefined) },
	});
	const dir = await fs.mkdtemp(path.join(os.tmpdir(), "ctronv2-"));
	const controller: any = {
		config: { get: (k: string) => (k === "controller.database_directory" ? dir : undefined) },
		instances: new Map([[1, inst(1, "running")], [2, inst(2, "running")]]),
		handle: (C: any, fn: any) => handlers.set(C.name, fn),
		sendTo: (dst: any, msg: any) => {
			sent.push([dst.instanceId, msg]);
			return msg.constructor.type === "request" ? Promise.resolve({ r: [], detail: null }) : undefined;
		},
		hooks: { instanceStatusChanged: hook("status"), shutdown: hook("shutdown"), save: hook("save") },
	};
	const logger: any = { log() { }, info() { }, warn() { }, error() { }, verbose() { } };
	await load({ controller, logger, plugin: { name: "ctron_pluginv2" } } as any);
	try {
		const want = Object.values(m).filter((C: any) => C.src === "instance" && C.dst === "controller")
			.map((C: any) => C.name);
		assert.equal(want.length, 11);
		assert.deepEqual(want.filter(n => !handlers.has(n)), []);
		const states = () => sent.filter(([, msg]) => msg.constructor.name === "SettingsStateEvent")
			.map(([to, msg]) => [to, msg.payload.surfaces]);
		await handlers.get("TileSnapshotEvent")(new m.TileSnapshotEvent({
			seq: 1, part: 1, parts: 1, ctrons: [], cells: [], needs: [], jobs: [],
			stations: [{ sid: "1.1", surface: "nauvis", name: "s", x: 0, y: 0 }],
		}), { id: 1 });
		assert.deepEqual(states(), [[1, ["nauvis"]], [1, ["nauvis"]], [2, ["nauvis"]]]);
		// a station edit goes to the station's tile as a plain array; an unknown station gets nothing
		const edits = () => sent.filter(([, msg]) => msg.constructor.name === "StationSetEvent");
		await handlers.get("UiCargoEvent")(new m.UiCargoEvent({ sid: "1.1", slots: {}, name: "x" }), { id: 2 });
		await handlers.get("UiCargoEvent")(new m.UiCargoEvent({ sid: "9.9", name: "y" }), { id: 2 });
		assert.deepEqual(edits().map(([to, msg]) => [to, msg.payload]), [[1, { sid: "1.1", slots: [], name: "x" }]]);
		controller.instances.get(1).status = "stopped";
		for (const fn of hooks.status) { await fn(controller.instances.get(1), "running"); }
		assert.deepEqual(states().at(-1), [2, []], "tile 1 stopped: its station was the last on nauvis");
	} finally {
		for (const fn of hooks.shutdown ?? []) { await fn(); }
		await fs.rm(dir, { recursive: true, force: true });
	}
});
