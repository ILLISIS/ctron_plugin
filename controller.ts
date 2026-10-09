import * as path from "path";
import * as fs from "fs/promises";

import * as lib from "@clusterio/lib";
import { BaseControllerPlugin, type InstanceRecord } from "@clusterio/controller";

import * as messages from "./messages.js";
import { cargoOffers, claimByKey, oldestOn, stationStatus, subscribedSurfaces } from "./pool.js";

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

export class ControllerPlugin extends BaseControllerPlugin {
	/** The pool (spec §8): unclaimed jobs by key. */
	jobs: Map<string, messages.ConstructronJobValue> = new Map();
	storageDirty = false;
	static readonly dbFilename = "ctron_jobs.json";

	// Service stations by instance id, per surface.
	serviceStationStatusByInstance: Map<number, messages.InstanceServiceStationStatus> = new Map();
	serviceStationStorageDirty = false;
	static readonly serviceStationDbFilename = "ctron_stations.json";

	/** The surface names some instance has stations on: publishers send jobs only for these (spec §8). */
	subscribed: string[] = [];

	// Constructron settings sync state.
	ctronSurfaceSettings: Map<string, Record<string, unknown>> = new Map();
	ctronGlobalSettings: Record<string, unknown> = { ...messages.DEFAULT_GLOBAL_SETTINGS };
	ctronSettingsDirty = false;
	static readonly ctronSettingsDbFilename = "ctron_settings.json";

	async init() {
		this.controller.handle(messages.ConstructronJobAdd, this.handleJobAdd.bind(this));
		this.controller.handle(messages.ConstructronJobClaim, this.handleJobClaim.bind(this));
		this.controller.handle(messages.ConstructronCargoOffers, this.handleCargoOffers.bind(this));
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
		for (const instance of this.controller.instances.values()) {
			if (!this.serviceStationStatusByInstance.has(instance.id)) {
				this.serviceStationStatusByInstance.set(instance.id, stationStatus(instance.id, {}, now));
			}
		}
		this.broadcastServiceStationStatus([...this.serviceStationStatusByInstance.values()]);
		this.subscribed = subscribedSurfaces(this.serviceStationStatusByInstance.values());

		this.jobs = await loadDatabase(this.controller.config, ControllerPlugin.dbFilename, this.logger);

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

	async onInstanceStatusChanged(instance: InstanceRecord, _prev?: lib.InstanceStatus) {
		const instanceId = instance.id;
		if (instance.status === "deleted") {
			const existing = this.serviceStationStatusByInstance.get(instanceId);
			if (existing) {
				const tombstone = { ...stationStatus(instanceId, {}, Date.now()), isDeleted: true };
				this.serviceStationStatusByInstance.delete(instanceId);
				this.serviceStationStorageDirty = true;
				this.broadcastServiceStationStatus([tombstone]);
				this.updateSubscribed();
			}
		} else if (!this.serviceStationStatusByInstance.has(instanceId)) {
			const status = stationStatus(instanceId, {}, Date.now());
			this.serviceStationStatusByInstance.set(instanceId, status);
			this.serviceStationStorageDirty = true;
			this.broadcastServiceStationStatus([status]);
		}
	}

	async onSaveData() {
		if (this.storageDirty) {
			this.storageDirty = false;
			await saveDatabase(this.controller.config, this.jobs, ControllerPlugin.dbFilename, this.logger);
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

	/** Recompute the subscribed surfaces, and tell every instance when they changed (spec §8). */
	private updateSubscribed() {
		const now = subscribedSurfaces(this.serviceStationStatusByInstance.values());
		if (now.join("\n") !== this.subscribed.join("\n")) {
			this.subscribed = now;
			this.controller.sendTo("allInstances", new messages.CtronSubscribedSurfaces(now));
		}
	}

	async handleInstanceServiceStationStatusUpdate(event: messages.InstanceServiceStationStatusUpdate) {
		const status = stationStatus(event.instanceId, event.stations, Date.now());
		this.serviceStationStatusByInstance.set(event.instanceId, status);
		this.serviceStationStorageDirty = true;
		this.broadcastServiceStationStatus([status]);
		this.updateSubscribed();
	}

	async handleInstanceServiceStationStatusSubscription(request: lib.SubscriptionRequest) {
		const values = [...this.serviceStationStatusByInstance.values()]
			.filter(v => v.updatedAtMs > request.lastRequestTimeMs);
		return values.length ? new messages.InstanceServiceStationStatusStream(values) : null;
	}

	async handleJobClaim(event: messages.ConstructronJobClaim) {
		const job = event.jobKey !== null
			? claimByKey(this.jobs, event.jobKey)
			: oldestOn(this.jobs.values(), event.surfaces, Date.now());
		if (!job) {
			return null;
		}
		this.jobs.delete(job.id);
		this.storageDirty = true;
		this.broadcast([{ ...job, updatedAtMs: Date.now(), isDeleted: true, lastInstanceId: event.instanceId }]);
		this.logger.info(`ConstructronJobClaim: instance ${event.instanceId} claimed ${job.id} on ${job.surfaceName}`);
		return { jobKey: job.id, jobType: job.jobType, job: job.job };
	}

	async handleCargoOffers(event: messages.ConstructronCargoOffers) {
		return { offers: cargoOffers(this.jobs.values(), event.surfaces) };
	}

	async handleJobAdd(event: messages.ConstructronJobAdd) {
		const value: messages.ConstructronJobValue = {
			id: event.jobKey,
			updatedAtMs: Date.now(),
			isDeleted: false,
			lastInstanceId: event.instanceId,
			surfaceName: event.surfaceName,
			jobType: event.jobType,
			job: event.job,
		};
		this.jobs.set(value.id, value);
		this.storageDirty = true;
		this.broadcast([value]);
	}

	/**
	 * The settings to every running instance with the plugin loaded ("allInstances": the hosts skip the others, which
	 * would reject an event they have no handler for). The instance a change came from gets its own values back.
	 */
	private broadcastSettingsToInstances() {
		const surfaceSettings: Record<string, Record<string, unknown>> = {};
		for (const [name, s] of this.ctronSurfaceSettings) {
			surfaceSettings[name] = s;
		}
		const mode = this.controller.config.get("ctron_plugin.settings_sync_mode");
		this.controller.sendTo(
			"allInstances", new messages.CtronSettingsBroadcast(surfaceSettings, this.ctronGlobalSettings, mode),
		);
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
		if (dirty) {
			this.ctronSettingsDirty = true;
		}
		this.logger.info(`ctron_plugin: ctronSurfaceSettings size=${this.ctronSurfaceSettings.size}`);
	}

	async handleSettingsUpdate(event: messages.CtronSettingsUpdate) {
		const mode = this.controller.config.get("ctron_plugin.settings_sync_mode");
		if (mode !== "in_game") {
			return;
		}
		this.storeSettings(event.surfaceName, event.settings);
		this.ctronSettingsDirty = true;
		this.broadcastSettingsToInstances();
	}

	async handleSettingsPull(_event: messages.CtronSettingsPull) {
		const surfaceSettings: Record<string, Record<string, unknown>> = {};
		for (const [name, s] of this.ctronSurfaceSettings) {
			surfaceSettings[name] = s;
		}
		const mode = this.controller.config.get("ctron_plugin.settings_sync_mode");
		return { surfaceSettings, globalSettings: this.ctronGlobalSettings, mode, subscribed: this.subscribed };
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
		const values = [...this.jobs.values()].filter(v => v.updatedAtMs > request.lastRequestTimeMs);
		return values.length ? new messages.ConstructronJobUpdate(values) : null;
	}
}
