// A fake instance plugin context for the instance tests, as universal_edges/test/unit/bridge.test.ts's. Not a test
// file: the runner only picks up *.test.js.
import type { InstancePluginContext } from "@clusterio/host";
import { openBridge } from "universal_edges/runtime";
import { JobDetailRequest, RouteRequest } from "../../messages.js";

export type Line = { level: string; message: string; meta: Record<string, any> };
type Fn = (...args: any[]) => any;

/** Long enough for setImmediate flushes and the shared RCON chain to run. */
export const settle = () => new Promise(resolve => setTimeout(resolve, 10));

/** The batch inside one of the plugin's inbox commands (UE's batched form); [] for another. */
function parse(command: string): { id: string; type: string; payload: any }[] {
	const m = /^\/sc ue_rt\.inbox\("ctron_pluginv2", "(.*)"\)$/.exec(command);
	return m ? JSON.parse(JSON.parse(`"${m[1]}"`)) : [];
}

/**
 * One instance with UE's bridge already started (UE's plugin starts every bridge on the instance after its handshake;
 * here a bridge of its own does). opts.route answers each RouteRequest (default: "no route"); with opts.lost every
 * send to the controller throws SessionLost, as Clusterio does while the link reconnects (opts is returned, so a
 * test can set lost later).
 */
export function fakeInstance(opts: { route?: () => Promise<unknown>; lost?: boolean } = {}) {
	const ipc = new Map<string, Fn>();
	const hooks = new Map<string, Fn[]>();
	const handlers = new Map<unknown, Fn>();
	const sent: unknown[] = [];
	const commands: string[] = [];
	const lines: Line[] = [];
	const hook = (name: string) => ({
		attach: (_owner: string, fn: Fn) => {
			hooks.set(name, [...hooks.get(name) ?? [], fn]);
		},
	});
	const instance = {
		id: 7,
		server: { handle: (channel: string, fn: Fn) => ipc.set(channel, fn) },
		hooks: {
			start: hook("start"), stop: hook("stop"), exit: hook("exit"),
			controllerConnectionEvent: hook("controllerConnectionEvent"),
		},
		handle: (Class: unknown, fn: Fn) => handlers.set(Class, fn),
		sendTo: (_dst: unknown, message: unknown) => {
			sent.push(message);
			if (opts.lost) {
				throw Object.assign(new Error("No session"), { code: "SessionLost" });
			}
			if (message instanceof RouteRequest) {
				return opts.route ? opts.route() : Promise.resolve({ route: null });
			}
			if (message instanceof JobDetailRequest) {
				return Promise.resolve({ detail: null });
			}
			return undefined;
		},
		sendRcon: async (command: string) => {
			commands.push(command);
			return "";
		},
	};
	const log = (level: string, message: string, meta: Record<string, any> = {}) => {
		lines.push({ level, message, meta });
	};
	const context = (name: string) => ({
		plugin: { name },
		logger: { log, warn: (message: string, meta?: Record<string, any>) => log("warn", message, meta) },
		instance,
	}) as unknown as InstancePluginContext;
	openBridge(context("universal_edges"), {}).start();
	return {
		opts, context: context("ctron_pluginv2"), handlers, sent, lines,
		warnings: () => lines.filter(l => l.level === "warn"),
		/** Run every function attached to hook `name`. */
		fire: async (name: string, ...args: unknown[]) => {
			for (const fn of hooks.get(name) ?? []) {
				await fn(...args);
			}
		},
		/** Lua flushing these messages on the plugin's channel (one IPC line). */
		up: (msgs: { type: string; payload: unknown }[]) => ipc.get("ctron_pluginv2:out")!({
			tick: 1, msgs: msgs.map((m, i) => ({ id: `a.${i}`, ...m })),
		}),
		/** Every RCON command sent on the instance, in order. */
		commands: () => commands,
		batch: parse,
		/** Every message the plugin sent to Lua, in order: the batches inside its inbox commands. */
		down: () => commands.flatMap(parse),
	};
}
