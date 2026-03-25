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

	// Service station status by instance id.
	serviceStationStatusByInstance: Map<number, messages.InstanceServiceStationStatus> = new Map();
	serviceStationStorageDirty = false;
	static readonly serviceStationDbFilename = "ctron_service_station_status.json";

	// Whether any instance currently has subscribers (service stations).
	hasSubscribers = false;

	// Constructron settings sync state.
	ctronSurfaceSettings: Map<string, Record<string, unknown>> = new Map();
	ctronGlobalSettings: Record<string, unknown> = { ...messages.DEFAULT_GLOBAL_SETTINGS };
	ctronSettingsDirty = false;
	static readonly ctronSettingsDbFilename = "ctron_settings.json";

	async init() {
		this.controller.handle(messages.ConstructronJobAdd, this.handleJobAdd.bind(this));
		this.controller.handle(messages.ConstructronJobClaim, this.handleJobClaim.bind(this));
		this.controller.handle(messages.ConstructronJobConsume, this.handleJobConsume.bind(this));
		this.controller.handle(messages.ConstructronJobRemove, this.handleJobRemove.bind(this));
		this.controller.handle(messages.CtronPathRequest, this.handleCtronPathRequest.bind(this));
		this.controller.handle(messages.CtronPathResponse, this.handleCtronPathResponse.bind(this));
		this.controller.subscriptions.handle(messages.ConstructronJobUpdate, this.handleJobsSubscription.bind(this));

		// Service station subscriber status
		this.controller.handle(
			messages.InstanceServiceStationStatusUpdate,
			this.handleInstanceServiceStationStatusUpdate.bind(this),
		);
		this.controller.subscriptions.handle(
			messages.InstanceServiceStationStatusStream,
			this.handleInstanceServiceStationStatusSubscription.bind(this),
		);

		// Load persisted service-station state first so restarts retain the last known status.
		const loadedStatus = await loadDatabase(
			this.controller.config,
			ControllerPlugin.serviceStationDbFilename,
			this.logger,
		) as unknown as Map<string, messages.InstanceServiceStationStatus>;
		this.serviceStationStatusByInstance = new Map();
		for (const value of loadedStatus.values()) {
			const instanceId = Number((value as any)?.instanceId);
			if (Number.isFinite(instanceId)) {
				this.serviceStationStatusByInstance.set(instanceId, value);
			}
		}

		// Seed default status for instances we don't have persisted entries for.
		const now = Date.now();
		const initial: messages.InstanceServiceStationStatus[] = [];
		for (const instance of this.controller.instances.values()) {
			const instanceId = instance.id;
			if (this.serviceStationStatusByInstance.has(instanceId)) {
				continue;
			}
			const status: messages.InstanceServiceStationStatus = {
				id: `instance:${instanceId}`,
				updatedAtMs: now,
				isDeleted: false,
				instanceId,
				serviceStationCount: 0,
				isSubscriber: false,
			};
			this.serviceStationStatusByInstance.set(instanceId, status);
			initial.push(status);
		}
		this.broadcastServiceStationStatus([...this.serviceStationStatusByInstance.values()]);
		this.hasSubscribers = this.computeHasSubscribers();
		this.broadcastSubscriberAvailability();

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

		// Settings sync handlers
		this.controller.handle(messages.CtronSurfaceRegister, this.handleSurfaceRegister.bind(this));
		this.controller.handle(messages.CtronSettingsUpdate, this.handleSettingsUpdate.bind(this));
		this.controller.handle(messages.CtronSettingsPull, this.handleSettingsPull.bind(this));
		this.controller.handle(messages.CtronSettingsSet, this.handleSettingsSet.bind(this));
		this.controller.handle(messages.CtronSettingsGet, this.handleSettingsGet.bind(this));

		// Load persisted settings
		try {
			const settingsPath = path.resolve(
				this.controller.config.get("controller.database_directory"),
				ControllerPlugin.ctronSettingsDbFilename,
			);
			const content = await fs.readFile(settingsPath, "utf-8");
			if (content.length > 0) {
				const data = JSON.parse(content);
				if (data.surfaces) {
					this.ctronSurfaceSettings = new Map(data.surfaces);
				}
				if (data.global) {
					this.ctronGlobalSettings = { ...messages.DEFAULT_GLOBAL_SETTINGS, ...data.global };
				}
			}
		} catch (err: any) {
			if (err.code !== "ENOENT") {
				this.logger.warn(`Failed to load ctron settings: ${err?.message ?? err}`);
			}
		}
	}

	async onControllerConfigFieldChanged(field: string, _curr: unknown, _prev: unknown) {
		if (field === "ctron_plugin.settings_sync_mode") {
			this.broadcastSettingsToInstances();
		}
	}

	async onSaveData() {
		if (this.storageDirty) {
			this.storageDirty = false;
			await saveDatabase(this.controller.config, this.jobsById, ControllerPlugin.dbFilename, this.logger);
		}
		if (this.serviceStationStorageDirty) {
			this.serviceStationStorageDirty = false;
			await saveDatabase(
				this.controller.config,
				this.serviceStationStatusByInstance as unknown as Map<any, any>,
				ControllerPlugin.serviceStationDbFilename,
				this.logger,
			);
		}
		if (this.ctronSettingsDirty) {
			this.ctronSettingsDirty = false;
			const data = {
				surfaces: Array.from(this.ctronSurfaceSettings),
				global: this.ctronGlobalSettings,
			};
			const file = path.resolve(
				this.controller.config.get("controller.database_directory"),
				ControllerPlugin.ctronSettingsDbFilename,
			);
			await lib.safeOutputFile(file, JSON.stringify(data));
		}
	}

	private broadcast(updates: messages.ConstructronJobValue[]) {
		if (updates.length) {
			this.controller.subscriptions.broadcast(new messages.ConstructronJobUpdate(updates));
		}
	}

	private broadcastServiceStationStatus(updates: messages.InstanceServiceStationStatus[]) {
		if (updates.length) {
			this.controller.subscriptions.broadcast(new messages.InstanceServiceStationStatusStream(updates));
		}
	}

	private computeHasSubscribers(): boolean {
		for (const status of this.serviceStationStatusByInstance.values()) {
			if (status.isSubscriber) return true;
		}
		return false;
	}

	private broadcastSubscriberAvailability() {
		const msg = new messages.CtronSubscriberAvailabilityBroadcast(this.hasSubscribers);
		for (const instance of this.controller.instances.values()) {
			const assignedHostId = instance.config.get("instance.assigned_host");
			if (!assignedHostId) continue;
			const hostConnection = this.controller.wsServer.hostConnections.get(assignedHostId);
			if (!hostConnection) continue;
			const dst = lib.Address.fromShorthand({ instanceId: instance.id });
			try {
				hostConnection.connector.sendEvent(msg, dst);
			} catch (err: any) {
				this.logger.warn(`Failed to broadcast subscriber availability to instance ${instance.id}: ${err?.message ?? err}`);
			}
		}
	}

	async handleInstanceServiceStationStatusUpdate(event: messages.InstanceServiceStationStatusUpdate) {
		const now = Date.now();
		const count = Math.max(0, Math.floor(event.serviceStationCount));
		const status: messages.InstanceServiceStationStatus = {
			id: `instance:${event.instanceId}`,
			updatedAtMs: now,
			isDeleted: false,
			instanceId: event.instanceId,
			serviceStationCount: count,
			isSubscriber: count > 0,
		};

		this.serviceStationStatusByInstance.set(event.instanceId, status);
		this.serviceStationStorageDirty = true;
		this.broadcastServiceStationStatus([status]);

		const newHasSubscribers = this.computeHasSubscribers();
		if (newHasSubscribers !== this.hasSubscribers) {
			this.hasSubscribers = newHasSubscribers;
			this.broadcastSubscriberAvailability();
		}
	}

	async handleInstanceServiceStationStatusSubscription(request: lib.SubscriptionRequest) {
		const values = [...this.serviceStationStatusByInstance.values()]
			.filter(v => v.updatedAtMs > request.lastRequestTimeMs);
		return values.length ? new messages.InstanceServiceStationStatusStream(values) : null;
	}

	async handleJobClaim(event: messages.ConstructronJobClaim) {
		// Find the oldest unclaimed (non-deleted) job.
		// Require the job to be at least 1 second old to avoid race conditions
		// where a subscriber claims a job in the same tick the publisher adds it.
		const minAgeMs = 1000;
		const now = Date.now();
		let oldest: messages.ConstructronJobValue | undefined;
		let oldestKey: string | undefined;
		for (const [key, job] of this.jobsById) {
			if (!job.isDeleted && (now - job.updatedAtMs) >= minAgeMs) {
				if (!oldest || job.updatedAtMs < oldest.updatedAtMs) {
					oldest = job;
					oldestKey = key;
				}
			}
		}
		if (!oldest || !oldestKey) return null;

		// Find jobKey for this job id (reverse lookup).
		let jobKey: string | undefined;
		for (const [k, id] of this.jobsByKey) {
			if (id === oldestKey) { jobKey = k; break; }
		}

		// Tombstone and remove.
		const tombstone: messages.ConstructronJobValue = { ...oldest, updatedAtMs: Date.now(), isDeleted: true, lastInstanceId: event.instanceId };
		this.jobsById.delete(oldestKey);
		if (jobKey) this.jobsByKey.delete(jobKey);
		this.storageDirty = true;
		this.broadcast([tombstone]);

		this.logger.info(`ConstructronJobClaim: instance ${event.instanceId} claimed job ${oldestKey} (type=${oldest.jobType})`);
		return { jobKey: jobKey ?? oldestKey, jobType: oldest.jobType, job: oldest.job };
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

	private getPathworldInstanceId(): number | undefined {
		for (const instance of this.controller.instances.values()) {
			if (instance.config.get("instance.name") === "pathworld") {
				return instance.id;
			}
		}
		return undefined;
	}

	async handleCtronPathRequest(event: messages.CtronPathRequest) {
		const pathworldId = this.getPathworldInstanceId();
		if (pathworldId == null) {
			this.logger.warn(`[ctron_plugin] path request ${event.requesterId}: no pathworld instance found, dropping`);
			return;
		}
		const instance = this.controller.instances.get(pathworldId)!;
		const assignedHostId = instance.config.get("instance.assigned_host");
		if (assignedHostId === null) {
			this.logger.warn(`[ctron_plugin] path request ${event.requesterId}: pathworld not assigned to a host, dropping`);
			return;
		}
		const hostConnection = this.controller.wsServer.hostConnections.get(assignedHostId);
		if (!hostConnection) {
			this.logger.warn(`[ctron_plugin] path request ${event.requesterId}: pathworld host offline, dropping`);
			return;
		}
		this.logger.info(`[ctron_plugin] forwarding path request ${event.requesterId} from ${event.sourceInstanceId} -> pathworld ${pathworldId}`);
		const dst = lib.Address.fromShorthand({ instanceId: pathworldId });
		const forward = new messages.CtronForwardPathRequest(
			event.sourceInstanceId, event.requesterId, event.surface,
			event.boundingBox, event.start, event.goal, event.force, event.radius,
			event.pathResolutionModifier,
		);
		try {
			hostConnection.connector.sendEvent(forward, dst);
		} catch (err: any) {
			this.logger.error(`[ctron_plugin] failed to forward path request: ${err?.stack ?? err}`);
		}
	}

	async handleCtronPathResponse(event: messages.CtronPathResponse) {
		const instance = this.controller.instances.get(event.sourceInstanceId);
		if (!instance) {
			this.logger.warn(`[ctron_plugin] path response for unknown source instance ${event.sourceInstanceId}, dropping`);
			return;
		}
		const assignedHostId = instance.config.get("instance.assigned_host");
		if (assignedHostId === null) {
			this.logger.warn(`[ctron_plugin] path response: source instance ${event.sourceInstanceId} not assigned to host, dropping`);
			return;
		}
		const hostConnection = this.controller.wsServer.hostConnections.get(assignedHostId);
		if (!hostConnection) {
			this.logger.warn(`[ctron_plugin] path response: source host offline (instance=${event.sourceInstanceId}), dropping`);
			return;
		}
		this.logger.info(`[ctron_plugin] returning path response for requester ${event.requesterId} to instance ${event.sourceInstanceId}`);
		const dst = lib.Address.fromShorthand({ instanceId: event.sourceInstanceId });
		const ret = new messages.CtronReturnPathResponse(
			event.requesterId, event.path,
			event.tryAgainLater, event.partial, event.fullyCached,
		);
		try {
			hostConnection.connector.sendEvent(ret, dst);
		} catch (err: any) {
			this.logger.error(`[ctron_plugin] failed to return path response: ${err?.stack ?? err}`);
		}
	}

	private broadcastSettingsToInstances(excludeInstanceId?: number) {
		const surfaceSettings: Record<string, Record<string, unknown>> = {};
		for (const [name, s] of this.ctronSurfaceSettings) {
			surfaceSettings[name] = s;
		}
		const mode = this.controller.config.get("ctron_plugin.settings_sync_mode");
		const msg = new messages.CtronSettingsBroadcast(surfaceSettings, this.ctronGlobalSettings, mode);
		for (const instance of this.controller.instances.values()) {
			if (instance.id === excludeInstanceId) continue;
			const assignedHostId = instance.config.get("instance.assigned_host");
			if (!assignedHostId) continue;
			const hostConnection = this.controller.wsServer.hostConnections.get(assignedHostId);
			if (!hostConnection) continue;
			const dst = lib.Address.fromShorthand({ instanceId: instance.id });
			try {
				hostConnection.connector.sendEvent(msg, dst);
			} catch (err: any) {
				this.logger.warn(`Failed to broadcast settings to instance ${instance.id}: ${err?.message ?? err}`);
			}
		}
	}

	private storeSettings(surfaceName: string | null, settings: Record<string, unknown>) {
		if (surfaceName !== null) {
			const existing = this.ctronSurfaceSettings.get(surfaceName) ?? { ...messages.DEFAULT_SURFACE_SETTINGS };
			this.ctronSurfaceSettings.set(surfaceName, { ...existing, ...settings });
		} else {
			this.ctronGlobalSettings = { ...this.ctronGlobalSettings, ...settings };
		}
	}

	async handleSurfaceRegister(event: messages.CtronSurfaceRegister) {
		this.logger.info(`ctron_plugin: handleSurfaceRegister surfaces=${JSON.stringify(event.surfaces)}`);
		let dirty = false;
		for (const name of event.surfaces) {
			if (!this.ctronSurfaceSettings.has(name)) {
				this.ctronSurfaceSettings.set(name, { ...messages.DEFAULT_SURFACE_SETTINGS });
				dirty = true;
				this.logger.info(`ctron_plugin: registered new surface "${name}"`);
			}
		}
		if (dirty) this.ctronSettingsDirty = true;
		this.logger.info(`ctron_plugin: ctronSurfaceSettings size=${this.ctronSurfaceSettings.size}`);
	}

	async handleSettingsUpdate(event: messages.CtronSettingsUpdate) {
		const mode = this.controller.config.get("ctron_plugin.settings_sync_mode");
		if (mode !== "in_game") return;
		this.storeSettings(event.surfaceName, event.settings);
		this.ctronSettingsDirty = true;
		this.broadcastSettingsToInstances(event.instanceId);
	}

	async handleSettingsPull(_event: messages.CtronSettingsPull) {
		const surfaceSettings: Record<string, Record<string, unknown>> = {};
		for (const [name, s] of this.ctronSurfaceSettings) {
			surfaceSettings[name] = s;
		}
		const mode = this.controller.config.get("ctron_plugin.settings_sync_mode");
		return { surfaceSettings, globalSettings: this.ctronGlobalSettings, mode, hasSubscribers: this.hasSubscribers };
	}

	async handleSettingsSet(event: messages.CtronSettingsSet) {
		const mode = this.controller.config.get("ctron_plugin.settings_sync_mode");
		if (mode !== "controller") {
			throw new Error("Settings sync mode is not 'controller'");
		}
		if (event.surfaceName === null) {
			for (const name of this.ctronSurfaceSettings.keys()) {
				this.storeSettings(name, event.settings);
			}
		} else {
			this.storeSettings(event.surfaceName, event.settings);
		}
		this.ctronSettingsDirty = true;
		this.broadcastSettingsToInstances();
		return {};
	}

	async handleSettingsGet(_event: messages.CtronSettingsGet) {
		const surfaceSettings: Record<string, Record<string, unknown>> = {};
		for (const [name, s] of this.ctronSurfaceSettings) {
			surfaceSettings[name] = s;
		}
		const mode = this.controller.config.get("ctron_plugin.settings_sync_mode");
		return { surfaceSettings, globalSettings: this.ctronGlobalSettings, mode };
	}

	async handleJobsSubscription(request: lib.SubscriptionRequest) {
		const values = [...this.jobsById.values()].filter(v => v.updatedAtMs > request.lastRequestTimeMs);
		return values.length ? new messages.ConstructronJobUpdate(values) : null;
	}
}
