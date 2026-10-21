import type { InstancePluginContext } from "@clusterio/host";
import { newId, on, openBridge, rateLimited } from "universal_edges/runtime";
import type { Static } from "@sinclair/typebox";
import { DOWN, UP, list } from "./contracts.js";
import {
	JobAssignEvent, JobCancelEvent, JobDetailFetchRequest, JobDetailRequest, JobDropEvent, JobEventEvent,
	JobSquadEvent, JobStationEvent, PortalReportEvent, RouteRequest, SettingsSetEvent, SettingsStateEvent,
	StationSetEvent, StockQueryRequest, TileDeltaEvent, TileSnapshotEvent, UiCancelEvent, UiCargoEvent, UiDropEvent,
	UiListEvent, UiWatchEvent, WorkClearEvent,
} from "./messages.js";

/** How long a request sent to Lua waits for its reply (R-14). */
export const REPLY_MS = 10_000;

/** Requests sent to Lua, waiting for the reply that carries their req; each rejects after timeoutMs (R-14). */
export function pendingReplies(timeoutMs = REPLY_MS) {
	type Waiter = { resolve: (value: unknown) => void; timer: ReturnType<typeof setTimeout> };
	const waiting = new Map<string, Waiter>();
	return {
		wait(req: string): Promise<unknown> {
			return new Promise((resolve, reject) => {
				const timer = setTimeout(() => {
					waiting.delete(req);
					reject(new Error(`no reply from the tile for ${req} in ${timeoutMs} ms`));
				}, timeoutMs);
				waiting.set(req, { resolve, timer });
			});
		},
		/** Whether a wait for req is open (a part for a closed one is dropped). */
		has: (req: string) => waiting.has(req),
		/** Resolve req's wait; false for a req nobody waits for (late, repeated or unknown). */
		settle(req: string, value: unknown): boolean {
			const w = waiting.get(req);
			if (!w) {
				return false;
			}
			waiting.delete(req);
			clearTimeout(w.timer);
			w.resolve(value);
			return true;
		},
	};
}

/** Controller → instance events and the bridge type each goes to Lua as (spec §9.2), payload unchanged. */
const DOWN_EVENTS: [any, string][] = [
	[JobAssignEvent, "ct.job.assign"], [JobStationEvent, "ct.job.station"], [JobCancelEvent, "ct.job.cancel"],
	[JobSquadEvent, "ct.job.squad"],
	[JobDropEvent, "ct.job.drop"], [WorkClearEvent, "ct.work.clear"], [UiListEvent, "ct.ui.list"],
	[SettingsStateEvent, "ct.settings"], [StationSetEvent, "ct.station.set"],
];

/**
 * ctron_pluginv2's instance plugin (spec §2, §9): a relay between this tile's Lua and the controller. It holds no
 * durable state (R-114): only the requests waiting for Lua's reply and the surfaces this tile's screens watch.
 */
export default async function loadInstancePlugin(context: InstancePluginContext) {
	const { instance, logger, plugin } = context;
	const warn = rateLimited(logger);
	const replies = pendingReplies();
	const stockParts = new Map<string, unknown[]>();
	// Open watches by whole-watch key, so two watches on one surface (tile, expand) are both kept (X-11).
	const watched = new Map<string, Static<typeof UP["ct.ui.watch"]>>();
	// Every send to the controller is fire-and-forget and catches its failure, SessionLost included (R-143): a lost
	// session never throws out of a handler. The async wrapper also turns a synchronous throw into a rejection.
	const send = async (message: any): Promise<any> => instance.sendTo("controller", message);
	const toController = (event: any) => {
		send(event).catch((err: Error) => warn("send", "ctronv2 send failed", { error: err.message }));
	};

	/** Start a controller request and return at once; its answer goes down as `type`, a failure only logs. */
	const relayAsk = (request: any, type: keyof typeof DOWN, build: (answer: any) => object) => {
		send(request).then(answer => bridge.send(type, build(answer)))
			.catch((err: Error) => warn(type, `ctronv2 request for ${type} failed`, { error: err.message }));
	};

	// Up messages are dispatched one at a time and each handler is awaited (UE runtime/bridge.ts receive), so a handler
	// that waits on the controller must not be awaited: it would hold every later message (R-137). Snapshot and delta
	// parts are forwarded one message each; the controller reassembles them (R-125).
	const bridge = openBridge(context, {
		"ct.snapshot": on(UP["ct.snapshot"], p => toController(new TileSnapshotEvent(p))),
		"ct.delta": on(UP["ct.delta"], p => toController(new TileDeltaEvent(p))),
		"ct.job.event": on(UP["ct.job.event"], p => toController(new JobEventEvent(p))),
		"ct.portals": on(UP["ct.portals"], p => toController(new PortalReportEvent(p))),
		"ct.ui.cancel": on(UP["ct.ui.cancel"], p => toController(new UiCancelEvent(p))),
		"ct.ui.drop": on(UP["ct.ui.drop"], p => toController(new UiDropEvent(p))),
		"ct.ui.cargo": on(UP["ct.ui.cargo"], p => toController(new UiCargoEvent(p))),
		"ct.settings.set": on(UP["ct.settings.set"], p => toController(new SettingsSetEvent(p))),
		"ct.ui.watch": on(UP["ct.ui.watch"], p => {
			const key = JSON.stringify({ surface: p.surface, tile: p.tile, expand: p.expand });
			if (p.on) {
				watched.set(key, p);
			} else {
				watched.delete(key);
			}
			toController(new UiWatchEvent(p));
		}),
		// Replies to the controller's requests; a late or unknown one is dropped.
		"ct.stock.reply": on(UP["ct.stock.reply"], p => {
			// A reply comes in parts (R-151): concatenate `r` and resolve at the last part.
			const { req, part, parts, r } = p as unknown as { req: string; part: number; parts: number; r: object };
			if (!replies.has(req)) {
				return;
			}
			const got = [...stockParts.get(req) ?? [], ...list<unknown>(r)]; // an empty part is {} (R-18)
			if (part < parts) {
				stockParts.set(req, got);
				return;
			}
			stockParts.delete(req);
			replies.settle(req, { r: got });
		}),
		"ct.detail.reply": on(UP["ct.detail.reply"], p => {
			replies.settle(p.req, { detail: p.detail ?? null });
		}),
		// Lua's own requests. On an error nothing goes down: the tile's timeout means "the controller can't be reached"
		// (§7.5), and a screen asks again.
		"ct.route.ask": on(UP["ct.route.ask"], p => relayAsk(
			new RouteRequest(p), "ct.route.reply", ({ route }) => (route ? { req: p.req, route } : { req: p.req }))),
		"ct.ui.detail.ask": on(UP["ct.ui.detail.ask"], p => relayAsk(
			new JobDetailRequest(p), "ct.ui.detail",
			({ detail }) => (detail ? { req: p.req, detail } : { req: p.req }))),
	});

	for (const [Class, type] of DOWN_EVENTS) {
		instance.handle(Class, async (event: { payload: object }) => {
			bridge.send(type, event.payload);
		});
	}
	// The controller's requests: each goes to Lua with a fresh req and resolves with Lua's reply, or rejects after
	// REPLY_MS (R-14). P4 counts a rejected stock query as covering nothing (§6.5).
	instance.handle(StockQueryRequest, async (request: StockQueryRequest) => {
		const req = newId();
		const answer = replies.wait(req);
		bridge.send("ct.stock.query", { req, q: request.payload.q });
		try {
			return await answer as any;
		} finally {
			stockParts.delete(req);
		}
	});
	instance.handle(JobDetailFetchRequest, async (request: JobDetailFetchRequest) => {
		const req = newId();
		const answer = replies.wait(req);
		bridge.send("ct.detail.fetch", { req, jid: request.payload.jid });
		return await answer as any;
	});

	// A start, or a controller that restarted, gets this tile's snapshot (§6.10). After a restart the controller has
	// no watchers, so the open watches go again (X-11); the screens learn the link state from ct.ui.link.
	instance.hooks.start.attach(plugin.name, async () => {
		bridge.send("ct.snapshot.request", {});
	});
	instance.hooks.controllerConnectionEvent.attach(plugin.name, async (event: string) => {
		if (event === "connect") {
			bridge.send("ct.snapshot.request", {});
			for (const watch of watched.values()) {
				toController(new UiWatchEvent(watch));
			}
		}
		if (event === "connect" || event === "resume") {
			bridge.send("ct.ui.link", { up: true });
		} else if (event === "drop" || event === "close") {
			bridge.send("ct.ui.link", { up: false });
		}
	});
}
