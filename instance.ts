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

type ConstructronJobRouteIPC = {
	source_instance_id?: number;
	destination_instance_id?: number;
	job_type?: string;
	job?: unknown;
	job_key?: string;
};

type ServiceStationCountIPC = {
	instance_id?: number;
	service_station_count?: number;
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
		(this.instance.server as any).on("ipc-ctron_plugin:job_route", (data: ConstructronJobRouteIPC) => {
			this.handleJobRoute(data).catch(err => this.logger.error(
				`Error handling job_route:\n${err.stack}`
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

		// Controller -> host -> instance message delivery
		this.instance.handle(messages.ConstructronJobDeliver, this.handleJobDeliver.bind(this));
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

	async handleJobRoute(data: ConstructronJobRouteIPC) {
		const sourceInstanceId = this.getInstanceId(data.source_instance_id);
		const destinationInstanceId = data.destination_instance_id;
		const jobType = data.job_type ?? "";
		const job = data.job;
		const jobKey = data.job_key;

		if (destinationInstanceId == null) {
			this.logger.warn("Ignoring job_route without destination_instance_id");
			return;
		}

		this.logger.info(
			`Forwarding ConstructronJobRoute(source=${sourceInstanceId}, dest=${destinationInstanceId}, type=${jobType})`,
		);
		await this.instance.sendTo(
			"controller",
			new messages.ConstructronJobRoute(sourceInstanceId, destinationInstanceId, jobType, job, jobKey),
		);
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

	async handleJobDeliver(event: messages.ConstructronJobDeliver) {
		// Cache delivered job in save storage; Factorio Lua will apply it when the matching constructron spawns.
		this.logger.info(
			`Received ConstructronJobDeliver(jobKey=${event.jobKey}, source=${event.sourceInstanceId}, dest=${event.destinationInstanceId}, type=${event.jobType})`,
		);
		if (!event.jobKey) {
			this.logger.warn("Ignoring job_deliver without jobKey");
			return;
		}

		const escapedKey = JSON.stringify(event.jobKey);
		const jobType = JSON.stringify(event.jobType ?? null);
		const jobJson = JSON.stringify(event.job ?? null);

		const script = [
			// Store job as JSON string. Do NOT attempt to parse in /sc.
			`storage.ctron_plugin.queued_jobs[${escapedKey}] = { ok = true, job_type = ${jobType}, job_json = ${JSON.stringify(jobJson)} }`,
			"rcon.print('ctron_plugin: queued job stored for ' .. " + escapedKey + ")",
		].join("; ");

		try {
			this.logger.info(`Storing queued job via rcon for key=${event.jobKey}`);
			const result = await this.sendRcon(`/sc ${script}`);
			this.logger.info(`RCON store result for jobKey=${event.jobKey}: ${JSON.stringify(result)}`);
		} catch (err: any) {
			this.logger.error(`Failed to store queued job for jobKey=${event.jobKey}: ${err?.stack ?? err}`);
		}
	}
}
