import * as path from "path";
import * as fs from "fs/promises";

import * as lib from "@clusterio/lib";
import { BaseControllerPlugin } from "@clusterio/controller";

import * as messages from "./messages";

async function loadDatabase(
	config: lib.ControllerConfig,
	filename: string,
	logger: lib.Logger,
): Promise<Map<string, messages.ConstructronJobValue>> {
	const itemsPath = path.resolve(config.get("controller.database_directory"), filename);
	logger.verbose(`Loading ${itemsPath}`);
	try {
		const content = await fs.readFile(itemsPath, "utf-8");
		if (content.length === 0) {
			return new Map();
		}
		return new Map(JSON.parse(content));
	} catch (err: any) {
		if (err.code === "ENOENT") {
			logger.verbose("Creating new ctron_plugin jobs database");
			return new Map();
		}
		throw err;
	}
}

async function saveDatabase(
	config: lib.ControllerConfig,
	datastore: Map<any, any>,
	filename: string,
	logger: lib.Logger,
) {
	const file = path.resolve(config.get("controller.database_directory"), filename);
	logger.verbose(`writing ${file}`);
	await lib.safeOutputFile(file, JSON.stringify(Array.from(datastore)));
}

function makeJobId() {
	// Controller-generated id. No semantic meaning; must be unique.
	// Node 18 should have crypto.randomUUID.
	return `job:${globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(16).slice(2)}`}`;
}

export class ControllerPlugin extends BaseControllerPlugin {
	jobsById: Map<string, messages.ConstructronJobValue> = new Map();
	jobsByKey: Map<string, string> = new Map();
	storageDirty = false;
	static readonly dbFilename = "ctron_jobs.json";

	async init() {
		this.controller.handle(messages.ConstructronJobAdd, this.handleJobAdd.bind(this));
		this.controller.handle(messages.ConstructronJobConsume, this.handleJobConsume.bind(this));
		this.controller.handle(messages.ConstructronJobRemove, this.handleJobRemove.bind(this));
		this.controller.handle(messages.ConstructronJobRoute, this.handleJobRoute.bind(this));
		this.controller.subscriptions.handle(messages.ConstructronJobUpdate, this.handleJobsSubscription.bind(this));

		this.jobsById = await loadDatabase(this.controller.config, ControllerPlugin.dbFilename, this.logger);
		// Rebuild key index
		this.jobsByKey = new Map();
		for (const job of this.jobsById.values()) {
			// Legacy: older entries may have __ctron_plugin_key embedded in the job blob.
			const key = (job.job as any)?.__ctron_plugin_key;
			if (typeof key === "string" && !job.isDeleted) {
				this.jobsByKey.set(key, job.id);
			}
		}
	}

	async onSaveData() {
		if (this.storageDirty) {
			this.storageDirty = false;
			await saveDatabase(this.controller.config, this.jobsById, ControllerPlugin.dbFilename, this.logger);
		}
	}

	private broadcast(updates: messages.ConstructronJobValue[]) {
		if (updates.length) {
			this.controller.subscriptions.broadcast(new messages.ConstructronJobUpdate(updates));
		}
	}

	async handleJobAdd(event: messages.ConstructronJobAdd) {
		const now = Date.now();
		const id = makeJobId();

		const jobKey = event.jobKey;
		const job = (event.job && typeof event.job === "object")
			? { ...(event.job as any) }
			: event.job;

		const value: messages.ConstructronJobValue = {
			id,
			updatedAtMs: now,
			isDeleted: false,
			lastInstanceId: event.instanceId,
			jobType: event.jobType,
			job,
		};

		this.jobsById.set(id, value);
		if (jobKey) {
			this.jobsByKey.set(jobKey, id);
		}
		this.storageDirty = true;
		this.broadcast([value]);
	}

	async handleJobConsume(event: messages.ConstructronJobConsume) {
		const id = this.jobsByKey.get(event.jobKey);
		if (!id) {
			return;
		}
		const existing = this.jobsById.get(id);
		if (!existing) {
			this.jobsByKey.delete(event.jobKey);
			return;
		}

		const now = Date.now();
		// Broadcast a tombstone so UI removes it.
		const tombstone: messages.ConstructronJobValue = {
			...existing,
			updatedAtMs: now,
			isDeleted: true,
			lastInstanceId: event.instanceId,
		};

		this.jobsById.delete(id);
		this.jobsByKey.delete(event.jobKey);
		this.storageDirty = true;
		this.broadcast([tombstone]);
	}

	async handleJobRemove(event: messages.ConstructronJobRemove) {
		const existing = this.jobsById.get(event.jobId);
		if (!existing) {
			// Removing a non-existing job is a no-op.
			return;
		}

		const now = Date.now();
		const updated: messages.ConstructronJobValue = {
			...existing,
			updatedAtMs: now,
			isDeleted: true,
			lastInstanceId: event.instanceId,
		};

		// Best-effort cleanup for legacy embedded key.
		this.jobsByKey.delete((updated.job as any)?.__ctron_plugin_key);
		this.jobsById.set(event.jobId, updated);
		this.storageDirty = true;
		this.broadcast([updated]);
	}

	async handleJobRoute(event: messages.ConstructronJobRoute) {
		const instance = this.controller.instances.get(event.destinationInstanceId);
		if (!instance) {
			this.logger.warn(`Dropping routed Constructron job: destination instance ${event.destinationInstanceId} not found`);
			return;
		}

		const assignedHostId = instance.config.get("instance.assigned_host");
		if (assignedHostId === null) {
			this.logger.warn(
				`Dropping routed Constructron job: destination instance ${event.destinationInstanceId} is not assigned to a host`,
			);
			return;
		}

		const hostConnection = this.controller.wsServer.hostConnections.get(assignedHostId);
		if (!hostConnection) {
			this.logger.warn(
				`Dropping routed Constructron job: destination host ${assignedHostId} is offline (instance=${event.destinationInstanceId})`,
			);
			return;
		}

		this.logger.info(
			`Routing Constructron job from ${event.sourceInstanceId} -> ${event.destinationInstanceId} (type=${event.jobType})`,
		);

		const dst = lib.Address.fromShorthand({ instanceId: event.destinationInstanceId });
		const deliver = new messages.ConstructronJobDeliver(
			event.sourceInstanceId,
			event.destinationInstanceId,
			event.jobType,
			event.job,
			event.jobKey,
		);

		try {
			const seq = hostConnection.connector.sendEvent(deliver, dst);
			this.logger.info(`ConstructronJobDeliver forwarded to host ${assignedHostId} (seq=${seq}) dst=${dst}`);
		} catch (err: any) {
			this.logger.error(`Failed to forward ConstructronJobDeliver to host ${assignedHostId}: ${err?.stack ?? err}`);
		}
	}

	async handleJobsSubscription(request: lib.SubscriptionRequest) {
		const values = [...this.jobsById.values()].filter(v => v.updatedAtMs > request.lastRequestTimeMs);
		return values.length ? new messages.ConstructronJobUpdate(values) : null;
	}
}
