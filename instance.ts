import { BaseInstancePlugin } from "@clusterio/host";
import * as messages from "./messages";

function toBase64Utf8(text: string): string {
	// Prefer btoa if available (browser-like environments); otherwise fallback.
	const g: any = globalThis as any;
	if (typeof g.btoa === "function") {
		// btoa expects binary string; encodeURIComponent/unescape handles utf8.
		return g.btoa(unescape(encodeURIComponent(text)));
	}
	// Minimal base64 for utf8 text without relying on Node Buffer types.
	const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
	let output = "";
	let i = 0;
	const bytes = new TextEncoder().encode(text);
	while (i < bytes.length) {
		const b1 = bytes[i++]!;
		const b2 = i < bytes.length ? bytes[i++]! : NaN;
		const b3 = i < bytes.length ? bytes[i++]! : NaN;

		const e1 = b1 >> 2;
		const e2 = ((b1 & 3) << 4) | (Number.isNaN(b2) ? 0 : (b2 >> 4));
		const e3 = Number.isNaN(b2) ? 64 : (((b2 & 15) << 2) | (Number.isNaN(b3) ? 0 : (b3 >> 6)));
		const e4 = Number.isNaN(b3) ? 64 : (b3 & 63);

		output += chars[e1] + chars[e2] + chars[e3] + chars[e4];
	}
	return output;
}

type ConstructronJobAddIPC = {
	instance_id?: number;
	job_type?: string;
	job?: unknown;
	job_key?: string;
};

type ConstructronJobRemoveIPC = {
	instance_id?: number;
	job_id?: string;
};

type ConstructronJobConsumeIPC = {
	instance_id?: number;
	job_key?: string;
};

type ServiceStationCountIPC = {
	instance_id?: number;
	service_station_count?: number;
};

type CtronPathRequestIPC = {
	requesterId?: number;
	surface?: string;
	boundingBox?: { x1: number; y1: number; x2: number; y2: number };
	start?: { x: number; y: number };
	goal?: { x: number; y: number };
	force?: string;
	radius?: number;
	pathResolutionModifier?: number;
};

type CtronSettingsChangedIPC = {
	surface_name: string | null;
	settings: Record<string, unknown>;
};

type CtronPathResponseIPC = {
	requesterId?: number;
	sourceInstanceId?: number;
	path?: Array<{ position: { x: number; y: number }; needsDestroyToReach: boolean }> | null;
	tryAgainLater?: boolean;
	partial?: boolean;
	fullyCached?: boolean;
};

export class InstancePlugin extends BaseInstancePlugin {
	async init() {
		// Factorio -> host IPC event emitted by clusterio_lib when our module calls clusterio_api.send_json(...)
		(this.instance.server as any).on("ipc-ctron_plugin:job_add", (data: ConstructronJobAddIPC) => {
			this.handleJobAdd(data).catch(err => this.logger.error(
				`Error handling job_add:\n${err.stack}`
			));
		});
		(this.instance.server as any).on("ipc-ctron_plugin:job_remove", (data: ConstructronJobRemoveIPC) => {
			this.handleJobRemove(data).catch(err => this.logger.error(
				`Error handling job_remove:\n${err.stack}`
			));
		});
		(this.instance.server as any).on("ipc-ctron_plugin:job_consume", (data: ConstructronJobConsumeIPC) => {
			this.handleJobConsume(data).catch(err => this.logger.error(
				`Error handling job_consume:\n${err.stack}`
			));
		});
		(this.instance.server as any).on("ipc-ctron_plugin:job_claim", () => {
			this.claimJobFromController().catch(err => this.logger.error(
				`Error handling job_claim:\n${err.stack}`
			));
		});

		(this.instance.server as any).on("ipc-ctron_plugin:service_station_count", (data: ServiceStationCountIPC) => {
			this.handleServiceStationCount(data).catch(err => this.logger.error(
				`Error handling service_station_count:\n${err.stack}`
			));
		});

		// Path request: game Lua -> controller -> pathworld
		(this.instance.server as any).on("ipc-ctron_plugin:path_request", (data: CtronPathRequestIPC) => {
			this.handlePathRequest(data).catch(err => this.logger.error(
				`Error handling path_request:\n${err.stack}`
			));
		});

		// Path response IPC: pathworld Lua -> controller -> game
		(this.instance.server as any).on("ipc-ctron_plugin:path_response", (data: CtronPathResponseIPC) => {
			this.handlePathResponseIPC(data).catch(err => this.logger.error(
				`Error handling path_response ipc:\n${err.stack}`
			));
		});

		// Controller delivers forwarded request -> pathworld Lua via RCON
		this.instance.handle(messages.CtronForwardPathRequest, this.handleForwardPathRequest.bind(this));

		// Controller delivers result -> game Lua via RCON
		this.instance.handle(messages.CtronReturnPathResponse, this.handleReturnPathResponse.bind(this));

		// Settings sync: game Lua -> controller
		(this.instance.server as any).on("ipc-ctron_plugin:settings_changed", (data: CtronSettingsChangedIPC) => {
			this.handleSettingsChangedIPC(data).catch(err => this.logger.error(
				`Error handling settings_changed:\n${err.stack}`
			));
		});

		// Controller -> instance: broadcast settings
		this.instance.handle(messages.CtronSettingsBroadcast, this.handleSettingsBroadcast.bind(this));

		// Controller -> instance: broadcast subscriber availability
		this.instance.handle(messages.CtronSubscriberAvailabilityBroadcast, this.handleSubscriberAvailabilityBroadcast.bind(this));

		// New surface created in-game -> register with controller
		(this.instance.server as any).on("ipc-ctron_plugin:surface_created", (data: { name: string }) => {
			this.handleSurfaceCreated(data.name).catch(err => this.logger.error(
				`Error handling surface_created:\n${err.stack}`
			));
		});
	}

	// Called by on_nth_tick_300 Lua handler (via IPC) when running as a subscriber to claim a job from the controller.
	async claimJobFromController() {
		const instanceId = this.getInstanceId();
		this.logger.info(`Claiming job from controller (instanceId=${instanceId})`);
		let result: { jobKey: string; jobType: string; job: unknown } | null;
		try {
			result = await this.instance.sendTo("controller", new messages.ConstructronJobClaim(instanceId)) as any;
		} catch (err: any) {
			this.logger.error(`ConstructronJobClaim failed: ${err?.stack ?? err}`);
			return;
		}
		if (!result) {
			this.logger.info("ConstructronJobClaim: no jobs available on controller");
			return;
		}

		this.logger.info(`ConstructronJobClaim: got job key=${result.jobKey} type=${result.jobType}, sending to Lua`);
		const jobJson = JSON.stringify(result.job ?? null);
		const script = `ctron_plugin_on_job_claimed(${JSON.stringify(jobJson)})`;
		try {
			const rconResult = await this.sendRcon(`/sc ${script}`);
			this.logger.info(`ConstructronJobClaim applied for key=${result.jobKey}: ${JSON.stringify(rconResult)}`);
		} catch (err: any) {
			this.logger.error(`Failed to apply claimed job for key=${result.jobKey}: ${err?.stack ?? err}`);
		}
	}

	async onStart() {
		// Keep the instance id bridge in save storage (useful for Lua-side context).
		const instanceId = this.instance.config.get("instance.id");
		this.logger.info(`Setting global instance_id for ctron_plugin (instance.id=${instanceId})`);
		const script = [
			"storage.clusterio = storage.clusterio or {}",
			"storage.clusterio.globals = storage.clusterio.globals or {}",
			`storage.clusterio.globals.ctron_plugin_instance_id = ${instanceId}`,
			"rcon.print('ctron_plugin: wrote storage.clusterio.globals.ctron_plugin_instance_id=' .. tostring(storage.clusterio.globals.ctron_plugin_instance_id))",
		].join("; ");
		const result = await this.sendRcon(`/sc ${script}`);
		this.logger.info(`ctron_plugin init storage rcon result: ${JSON.stringify(result)}`);

		// Register surfaces so the controller creates default entries for any it hasn't seen before.
		try {
			const raw = await this.sendRcon("/sc ctron_plugin_get_surface_names()");
			this.logger.info(`ctron_plugin: surface names RCON raw=${JSON.stringify(raw)}`);
			const surfaces = raw && raw.trim() ? raw.trim().split(",") : [];
			this.logger.info(`ctron_plugin: registering surfaces=${JSON.stringify(surfaces)}`);
			await this.instance.sendTo("controller", new messages.CtronSurfaceRegister(surfaces));
		} catch (err: any) {
			this.logger.warn(`Failed to register surfaces with controller: ${err?.stack ?? err}`);
		}

		// Pull settings from controller and apply
		try {
			const pullResult = await this.instance.sendTo("controller", new messages.CtronSettingsPull()) as any;
			if (pullResult) {
				const payload = JSON.stringify({
					surface_settings: pullResult.surfaceSettings ?? {},
					global_settings: pullResult.globalSettings ?? {},
					mode: pullResult.mode ?? "in_game",
				});
				const rconResult = await this.sendRcon(`/sc ctron_plugin_apply_synced_settings(${JSON.stringify(payload)})`);
				this.logger.info(`ctron_plugin settings pull applied: ${JSON.stringify(rconResult)}`);

				// Apply subscriber availability from the pull response
				const subValue = pullResult.hasSubscribers ? "true" : "false";
				try {
					await this.sendRcon(`/sc ctron_plugin_set_subscriber_availability(${subValue})`);
				} catch (err: any) {
					this.logger.warn(`Failed to set subscriber availability on startup: ${err?.stack ?? err}`);
				}
			}
		} catch (err: any) {
			this.logger.warn(`Failed to pull settings from controller: ${err?.stack ?? err}`);
		}
	}

	private getInstanceId(fallback?: number) {
		return fallback ?? this.instance.config.get("instance.id");
	}

	async handleJobAdd(data: ConstructronJobAddIPC) {
		const instanceId = this.getInstanceId(data.instance_id);
		const jobType = data.job_type ?? "";
		const job = data.job;
		const jobKey = data.job_key;
		this.logger.info(`Forwarding ConstructronJobAdd(instanceId=${instanceId}, jobType=${jobType})`);
		await this.instance.sendTo("controller", new messages.ConstructronJobAdd(instanceId, jobType, job, jobKey));
	}

	async handleJobRemove(data: ConstructronJobRemoveIPC) {
		const instanceId = this.getInstanceId(data.instance_id);
		const jobId = data.job_id;
		if (!jobId) {
			this.logger.warn("Ignoring job_remove without job_id");
			return;
		}
		this.logger.info(`Forwarding ConstructronJobRemove(instanceId=${instanceId}, jobId=${jobId})`);
		await this.instance.sendTo("controller", new messages.ConstructronJobRemove(instanceId, jobId));
	}

	async handleJobConsume(data: ConstructronJobConsumeIPC) {
		const instanceId = this.getInstanceId(data.instance_id);
		const jobKey = data.job_key;
		if (!jobKey) {
			this.logger.warn("Ignoring job_consume without job_key");
			return;
		}
		this.logger.info(`Forwarding ConstructronJobConsume(instanceId=${instanceId}, jobKey=${jobKey})`);
		await this.instance.sendTo("controller", new messages.ConstructronJobConsume(instanceId, jobKey));
	}

	async handleServiceStationCount(data: ServiceStationCountIPC) {
		const instanceId = this.getInstanceId(data.instance_id);
		const count = Number.isFinite(data.service_station_count as any) ? Number(data.service_station_count) : 0;
		this.logger.info(`Forwarding InstanceServiceStationStatusUpdate(instanceId=${instanceId}, count=${count})`);
		await this.instance.sendTo(
			"controller",
			new messages.InstanceServiceStationStatusUpdate(instanceId, count),
		);
	}

	async handlePathRequest(data: CtronPathRequestIPC) {
		const instanceId = this.getInstanceId();
		const requesterId = data.requesterId ?? 0;
		this.logger.info(`[ctron_plugin] forwarding path request ${requesterId} to controller`);
		await this.instance.sendTo("controller", new messages.CtronPathRequest(
			instanceId,
			requesterId,
			data.surface ?? "nauvis",
			data.boundingBox ?? { x1: -5, y1: -5, x2: 5, y2: 5 },
			data.start ?? { x: 0, y: 0 },
			data.goal ?? { x: 0, y: 0 },
			data.force ?? "player",
			data.radius ?? 1,
			data.pathResolutionModifier ?? 0,
		));
	}

	async handlePathResponseIPC(data: CtronPathResponseIPC) {
		const requesterId = data.requesterId ?? 0;
		const sourceInstanceId = data.sourceInstanceId ?? this.getInstanceId();
		this.logger.info(`[ctron_plugin] pathworld sending path response for requester ${requesterId} to instance ${sourceInstanceId}`);
		await this.instance.sendTo("controller", new messages.CtronPathResponse(
			requesterId,
			sourceInstanceId,
			data.path ?? null,
			data.tryAgainLater ?? false,
			data.partial ?? false,
			data.fullyCached ?? false,
		));
	}

	async handleForwardPathRequest(event: messages.CtronForwardPathRequest) {
		const payload = JSON.stringify({
			requesterId:         event.requesterId,
			sourceInstanceId:    event.sourceInstanceId,
			surface:             event.surface,
			boundingBox:         event.boundingBox,
			start:               event.start,
			goal:                event.goal,
			force:               event.force,
			radius:              event.radius,
			pathResolutionModifier: event.pathResolutionModifier,
		});
		const script = `ctron_plugin_pathworld_on_path_request(${JSON.stringify(payload)})`;
		try {
			await this.sendRcon(`/sc ${script}`);
		} catch (err: any) {
			this.logger.error(`[ctron_plugin] RCON failed for path request ${event.requesterId}: ${err?.stack ?? err}`);
		}
	}

	async handleReturnPathResponse(event: messages.CtronReturnPathResponse) {
		const payload = JSON.stringify({
			id:              event.requesterId,
			path:            event.path,
			try_again_later: event.tryAgainLater,
			partial:         event.partial,
			fully_cached:    event.fullyCached,
		});
		const script = `ctron_plugin_on_path_response(${JSON.stringify(payload)})`;
		try {
			await this.sendRcon(`/sc ${script}`);
		} catch (err: any) {
			this.logger.error(`[ctron_plugin] RCON failed for path response ${event.requesterId}: ${err?.stack ?? err}`);
		}
	}

	async handleSettingsChangedIPC(data: CtronSettingsChangedIPC) {
		const instanceId = this.getInstanceId();
		const surfaceName = data.surface_name ?? null;
		const settings = data.settings ?? {};
		await this.instance.sendTo("controller", new messages.CtronSettingsUpdate(instanceId, surfaceName, settings));
	}

	async handleSurfaceCreated(name: string) {
		await this.instance.sendTo("controller", new messages.CtronSurfaceRegister([name]));
	}

	async handleSettingsBroadcast(event: messages.CtronSettingsBroadcast) {
		const payload = JSON.stringify({
			surface_settings: event.surfaceSettings,
			global_settings: event.globalSettings,
			mode: event.mode,
		});
		try {
			await this.sendRcon(`/sc ctron_plugin_apply_synced_settings(${JSON.stringify(payload)})`);
		} catch (err: any) {
			this.logger.error(`Failed to apply synced settings via RCON: ${err?.stack ?? err}`);
		}
	}

	async handleSubscriberAvailabilityBroadcast(event: messages.CtronSubscriberAvailabilityBroadcast) {
		const value = event.hasSubscribers ? "true" : "false";
		try {
			await this.sendRcon(`/sc ctron_plugin_set_subscriber_availability(${value})`);
		} catch (err: any) {
			this.logger.error(`Failed to set subscriber availability via RCON: ${err?.stack ?? err}`);
		}
	}

}
