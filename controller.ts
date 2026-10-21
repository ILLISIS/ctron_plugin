// Spec §6: the controller plugin. Glue only: Clusterio handlers, hooks, timers and the settings file around the
// pure cores in cluster/.
import * as path from "node:path";
import type { Address } from "@clusterio/lib";
import type { ControllerPluginContext } from "@clusterio/controller";
import { edgeApi } from "universal_edges/edges";
import { lifecycle, loadDataFile, newId, rateLimited, saveDataFile, type Migration } from "universal_edges/runtime";
import type { Static } from "@sinclair/typebox";
import { list, type StockQ } from "./contracts.js";
import {
	JobAssignEvent, JobCancelEvent, JobDetailFetchRequest, JobDetailRequest, JobDropEvent, JobEventEvent,
	JobSquadEvent, JobStationEvent, PortalReportEvent, RouteRequest, SettingsSetEvent, SettingsStateEvent,
	StationSetEvent, StockQueryRequest, TileDeltaEvent, TileSnapshotEvent, UiCancelEvent, UiCargoEvent, UiDropEvent,
	UiListEvent, UiWatchEvent, WorkClearEvent,
} from "./messages.js";
import { DESTROY_RETRY_MS, Index, ownerOf } from "./cluster/index.js";
import { chunk, jobRow, Lists } from "./cluster/list.js";
import { Routes } from "./cluster/routes.js";
import { Scheduler, TIMER_MS, type Outbound, type StockAnswerT } from "./cluster/scheduler.js";
import { effective, kindsOff, merge, schedulerView, validate, type Over } from "./cluster/settings.js";

/** Migrations of ctron_pluginv2_settings.json (the overrides). Append; never edit one. */
const MIGRATIONS: Migration[] = [];
const TICK_MS = 1000; // R-51
const REQUEST_MS = 10_000;
const QUERY_BYTES = 2800; // each request stays under 3 KB with its envelope (R-15, R-151)
const LOGGED = new Set(["adopted", "rejected", "done", "lost", "failed", "left"]);
const QUIET = new Set(["short", "trash_full", "unknown"]);
const FREED = new Set(["rejected", "done", "lost", "failed"]);

export default async function loadControllerPlugin(context: ControllerPluginContext): Promise<void> {
	const { controller, logger, plugin } = context;
	const file = path.resolve(controller.config.get("controller.database_directory"), "ctron_pluginv2_settings.json");
	let overrides = ((await loadDataFile(file, MIGRATIONS)) ?? {}) as Over;
	// R-208: a destroy cell retries after the effective job_start_delay (a global key, ticks)
	const index: Index = new Index(Date.now(), () => {
		const d = index.defaults;
		return d ? Math.round(effective(d, overrides, "*").job_start_delay * 1000 / 60) : DESTROY_RETRY_MS;
	});
	const lists = new Lists();
	const timers = new Set<ReturnType<typeof setTimeout>>();
	let lastSurfaces = "";
	let saving: Promise<unknown> = Promise.resolve();
	const limited = rateLimited(logger);
	let unsubscribe: (() => void) | undefined;
	// edgeApi() is only called from these callbacks, never at load: UE sets it while it loads.
	const routes = new Routes({
		isActive: id => edgeApi().isActive(id),
		edge: id => {
			const e = edgeApi().get(id);
			return e && !e.deleted ? { length: e.length, a: e.a.instanceId, b: e.b.instanceId } : undefined;
		},
	});

	const enabled = (i: { config: { get(k: any): any } }) => i.config.get("ctron_pluginv2.load_plugin") !== false;
	const running = () => [...controller.instances.values()]
		.filter(i => i.status === "running" && enabled(i)).map(i => i.id);
	// R-173: Clusterio marks assigned instances "unknown" at controller start; they still owe a snapshot.
	const pending = () => [...controller.instances.values()].filter(i => enabled(i)
		&& (i.status === "running" || (i.status === "unknown" && i.config.get("instance.assigned_host") !== null)))
		.map(i => i.id);
	const name = (inst: number) => controller.instances.get(inst)?.config.get("instance.name") ?? String(inst);
	const warn = (what: string) => (err: any) => logger.warn(`ctronv2 ${what}: ${err?.message ?? err}`);

	function post(inst: number, event: any) {
		try {
			void Promise.resolve(controller.sendTo({ instanceId: inst }, event)).catch(warn("send"));
		} catch (err) {
			warn("send")(err); // SessionLost and stopped instances throw (06 §3.2)
		}
	}

	function send(inst: number, msg: Outbound) {
		switch (msg.type) {
			case "assign": post(inst, new JobAssignEvent(msg.payload)); break;
			case "station": post(inst, new JobStationEvent(msg.payload)); break;
			case "cancel": post(inst, new JobCancelEvent(msg.payload)); break;
			case "squad": post(inst, new JobSquadEvent(msg.payload)); break;
			case "drop": post(inst, new JobDropEvent(msg.payload)); break;
			case "clear": post(inst, new WorkClearEvent(msg.payload)); break;
			default: break;
		}
	}

	function within<T>(promise: Promise<T>, ms: number): Promise<T> {
		return new Promise<T>((resolve, reject) => {
			const t = setTimeout(() => reject(new Error("timeout")), ms);
			promise.then(resolve, reject).finally(() => clearTimeout(t));
		});
	}

	async function query(inst: number, q: Array<Static<typeof StockQ>>): Promise<StockAnswerT> {
		const parts = chunk(q, e => JSON.stringify(e).length, QUERY_BYTES);
		const answers = await Promise.all(parts.map(async part => {
			try {
				const a = await within(
					Promise.resolve(controller.sendTo({ instanceId: inst }, new StockQueryRequest({ q: part }))),
					REQUEST_MS,
				);
				return list(a.r);
			} catch {
				return []; // §6.5: counts as covering nothing
			}
		}));
		return { r: answers.flat() };
	}

	function settingsTo(insts: number[]) {
		for (const inst of insts) {
			post(inst, new SettingsStateEvent({ overrides, surfaces: index.schedulableSurfaces() }));
		}
	}

	const later = (ms: number, fn: () => void) => {
		const t = setTimeout(() => { timers.delete(t); fn(); }, ms);
		timers.add(t);
	};
	const scheduler = new Scheduler(index, {
		now: Date.now,
		cost: (a, b) => routes.cost(a, b),
		query,
		send,
		newId,
		settings: s => schedulerView(index.defaults, overrides, s),
		running: pending,
		later,
		trace: (op, phase, fields, level) => lifecycle(logger, op, phase, fields, level),
	});

	function afterReport(surfaces: Iterable<string>) {
		scheduler.afterReport();
		for (const s of new Set(surfaces)) { scheduler.trigger(s); }
		const now = JSON.stringify(index.schedulableSurfaces());
		if (now !== lastSurfaces) {
			lastSurfaces = now; // only this broadcast sets it: a per-tile send must not hide a change from the others
			settingsTo(running());
		}
	}

	controller.handle(TileSnapshotEvent, async (event: TileSnapshotEvent, src: Address) => {
		if (!index.snapshotPart(src.id, event.payload, Date.now())) { return; }
		settingsTo([src.id]); // §6.11: a starting instance gets the overrides right after its snapshot
		const surfaces = [
			...[...index.ctrons.values()].filter(c => c.inst === src.id).map(c => c.surface),
			...[...index.work].filter(([wid]) => ownerOf(wid) === src.id).map(([, w]) => w.cell.surface),
			...[...index.needs.values()].filter(n => n.inst === src.id).map(n => n.surface),
		];
		afterReport(surfaces);
		schedulePush();
	});

	controller.handle(TileDeltaEvent, async (event: TileDeltaEvent, src: Address) => {
		const d = event.payload;
		index.delta(src.id, d, Date.now());
		afterReport([
			...list(d.cells?.up).filter(c => c.due === 0).map(c => c.surface),
			...list(d.ctrons?.up).filter(c => c.state === "idle").map(c => c.surface),
			...list(d.needs?.up).map(n => n.surface),
		]);
		schedulePush();
	});

	controller.handle(JobEventEvent, async (event: JobEventEvent, src: Address) => {
		const { jid, cid, why, ev } = event.payload;
		const surface = index.jobs.get(jid)?.surface;
		index.jobEvent(src.id, event.payload, Date.now());
		if (LOGGED.has(ev) || QUIET.has(ev)) {
			lifecycle(logger, "ctronv2.job", ev, { jid, cid, why, inst: src.id }, QUIET.has(ev) ? "verbose" : "info");
		}
		afterReport(surface && FREED.has(ev) ? [surface] : []);
	});

	controller.handle(PortalReportEvent, async (event: PortalReportEvent, src: Address) => {
		routes.report(src.id, event.payload);
	});

	controller.handle(UiWatchEvent, async (event: UiWatchEvent, src: Address) => {
		const { surface, tile, expand, on } = event.payload;
		lists.watch(src.id, { surface, tile, expand }, on);
		schedulePush();
	});
	controller.handle(UiCancelEvent, async (event: UiCancelEvent) => {
		scheduler.cancel(event.payload);
		schedulePush();
	});
	controller.handle(UiDropEvent, async (event: UiDropEvent) => {
		scheduler.drop(event.payload);
		schedulePush();
	});

	controller.handle(UiCargoEvent, async (event: UiCargoEvent) => {
		const inst = index.stations.get(event.payload.sid)?.inst;
		if (inst !== undefined) { // the station's own tile reports the change in its next delta
			const { slots, ...rest } = event.payload;
			post(inst, new StationSetEvent({ ...rest, ...slots && { slots: list(slots) } }));
		}
	});

	controller.handle(SettingsSetEvent, async (event: SettingsSetEvent) => {
		const { patch, dropped } = validate(event.payload.surface, event.payload.patch);
		if (dropped.length) { logger.warn(`ctronv2 settings: dropped keys ${dropped.join(", ")}`); }
		if (Object.keys(patch).length === 0) { return; } // no empty override entry
		const before = overrides;
		overrides = merge(before, event.payload.surface, patch);
		if (index.defaults) { // before a snapshot there are no real defaults to compare with
			const surfaces = [...new Set([...index.work.values()].map(w => w.cell.surface))];
			for (const [s, kind] of kindsOff(index.defaults, before, overrides, surfaces)) {
				index.dropWork(s, kind); // §6.11 step 3
			}
		}
		// In order, so the file ends as the last edit.
		saving = saving.then(() => saveDataFile(file, MIGRATIONS, overrides))
			.catch(err => logger.error(`ctronv2 settings save failed: ${err.message}`));
		settingsTo(running());
		schedulePush();
	});

	controller.handle(RouteRequest, async (event: RouteRequest, src: Address) => {
		const { surface, from, to, avoid } = event.payload;
		return {
			route: routes.route(
				{ inst: src.id, surface, x: from.x, y: from.y }, { inst: to.inst, surface, x: to.x, y: to.y },
				{ avoid: list(avoid) },
			),
		};
	});

	controller.handle(JobDetailRequest, async (event: JobDetailRequest) => {
		const job = index.jobs.get(event.payload.jid);
		if (!job) { return { detail: null }; }
		try {
			const r = await within(
				Promise.resolve(controller.sendTo({ instanceId: job.at }, new JobDetailFetchRequest({ jid: job.jid }))),
				REQUEST_MS,
			);
			return r.detail ? { detail: { ...r.detail, job: jobRow(index, job, name) } } : { detail: null };
		} catch {
			return { detail: null };
		}
	});

	const { hooks } = controller;
	hooks.instanceStatusChanged.attach(plugin.name, async instance => {
		if (instance.status === "running") { return; }
		index.stop(instance.id);
		lists.dropInstance(instance.id);
		routes.dropInstance(instance.id);
		afterReport([]); // its stations may have been a surface's last
		schedulePush();
	});

	// Clusterio exits on an uncaught exception, and a restart rebuilds the same state: a timer must not throw.
	const guarded = (what: string, fn: () => void) => () => {
		try { fn(); } catch (err: any) { limited(what, `ctronv2 ${what} failed: ${err?.stack ?? err}`); }
	};
	const pushLists = () => {
		for (const { inst, payload } of lists.push(index, name, Date.now())) { post(inst, new UiListEvent(payload)); }
	};
	// R-190: a change reaches the screens about 100 ms later; pushes send only changes, so an extra one is cheap.
	let pushPending = false;
	const schedulePush = () => {
		if (pushPending) { return; }
		pushPending = true;
		later(100, guarded("push", () => { pushPending = false; pushLists(); }));
	};
	const second = setInterval(guarded("tick", () => {
		if (!unsubscribe) {
			try {
				unsubscribe = edgeApi().on(() => routes.edgesChanged());
			} catch { /* UE has not set its API yet; try again next tick */ }
		}
		const r = index.tick(Date.now());
		for (const jid of r.expired) { lifecycle(logger, "ctronv2.job", "rejected", { jid, reason: "timeout" }); }
		for (const [jid, cid] of r.lost) {
			lifecycle(logger, "ctronv2.job", "lost", { jid, cid, reason: "unreported" });
		}
		if (r.expired.length || r.lost.length) {
			scheduler.flushSquad(); // R-209 relays queued by the tick: no tile report need follow
			scheduler.tick();
		}
		pushLists();
	}), TICK_MS);
	const slow = setInterval(guarded("scheduler tick", () => scheduler.tick()), TIMER_MS); // R-51

	hooks.shutdown.attach(plugin.name, async () => {
		clearInterval(second);
		clearInterval(slow);
		timers.forEach(clearTimeout);
		timers.clear();
		unsubscribe?.();
	});
}
