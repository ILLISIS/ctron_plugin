import { plainJson } from "@clusterio/lib";
import { Type, Static } from "@sinclair/typebox";

// A stored Constructron job on the controller: id is its key, "<instance id>|<job index>" (spec §8).
const ConstructronJobValue = Type.Object({
	id: Type.String(),
	updatedAtMs: Type.Number(),
	isDeleted: Type.Boolean(),

	lastInstanceId: Type.Number(),
	surfaceName: Type.String(),
	jobType: Type.String(),
	job: Type.Unknown(),
});

export type ConstructronJobValue = Static<typeof ConstructronJobValue>;

/**
 * Event from instance -> controller to add a Constructron job.
 * The `job` originates from Factorio as a LuaTable and is treated as opaque JSON.
 */
export class ConstructronJobAdd {
	declare ["constructor"]: typeof ConstructronJobAdd;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;

	constructor(
		public instanceId: number,
		public surfaceName: string,
		public jobType: string,
		public job: unknown,
		public jobKey: string,
	) { }

	static jsonSchema = Type.Object({
		instanceId: Type.Number(),
		surfaceName: Type.String(),
		jobType: Type.String(),
		job: Type.Unknown(),
		jobKey: Type.String(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.instanceId, json.surfaceName, json.jobType, json.job, json.jobKey);
	}
}

/**
 * Subscribable event from controller -> control to update job list.
 */
export class ConstructronJobUpdate {
	declare ["constructor"]: typeof ConstructronJobUpdate;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "control" as const;
	static plugin = "ctron_plugin" as const;
	static permission = "ctron_plugin.jobs.read" as const;

	constructor(public updates: ConstructronJobValue[]) { }

	static jsonSchema = Type.Object({
		updates: Type.Array(ConstructronJobValue),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.updates);
	}
}

/**
 * Request from instance -> controller to atomically claim one pending job on one of `surfaces` (spec §8: the
 * claimer's subscriber surfaces with an idle constructron). Returns the claimed job or null if none are available.
 */
export class ConstructronJobClaim {
	declare ["constructor"]: typeof ConstructronJobClaim;
	static type = "request" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;

	/** `jobKey` names the entry to take (a supplier fetching a cargo offer); null takes the oldest (research §3). */
	constructor(public instanceId: number, public surfaces: string[], public jobKey: string | null) { }

	static jsonSchema = Type.Object({
		instanceId: Type.Number(),
		surfaces: Type.Array(Type.String()),
		jobKey: Type.Union([Type.String(), Type.Null()]),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.instanceId, json.surfaces, json.jobKey);
	}

	static Response = plainJson(Type.Union([
		Type.Object({
			jobKey: Type.String(),
			jobType: Type.String(),
			job: Type.Unknown(),
		}),
		Type.Null(),
	]));
}

/** Request from instance -> controller: the cargo requests other instances published on `surfaces` (research §3). */
export class ConstructronCargoOffers {
	declare ["constructor"]: typeof ConstructronCargoOffers;
	static type = "request" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;

	constructor(public instanceId: number, public surfaces: string[]) { }

	static jsonSchema = Type.Object({
		instanceId: Type.Number(),
		surfaces: Type.Array(Type.String()),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.instanceId, json.surfaces);
	}

	static Response = plainJson(Type.Object({
		offers: Type.Array(Type.Object({
			key: Type.String(),
			surfaceName: Type.String(),
			position: Type.Object({ x: Type.Number(), y: Type.Number() }),
			items: Type.Unknown(),
		})),
	}));
}

/**
 * Per-instance service station status tracked on the controller.
 * Uses the same "subscribable value" shape as other Clusterio web subscriptions.
 */
const InstanceServiceStationStatus = Type.Object({
	id: Type.String(),
	updatedAtMs: Type.Number(),
	isDeleted: Type.Boolean(),

	instanceId: Type.Number(),
	/** Service stations by surface name, the surfaces with none left out: the instance subscribes on these (§8). */
	stations: Type.Record(Type.String(), Type.Number()),
});

export type InstanceServiceStationStatus = Static<typeof InstanceServiceStationStatus>;

/**
 * Event from instance -> controller whenever a service station is built or removed: its stations by surface.
 */
export class InstanceServiceStationStatusUpdate {
	declare ["constructor"]: typeof InstanceServiceStationStatusUpdate;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;

	constructor(public instanceId: number, public stations: Record<string, number>) { }

	static jsonSchema = Type.Object({
		instanceId: Type.Number(),
		stations: Type.Record(Type.String(), Type.Number()),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.instanceId, json.stations);
	}
}

/**
 * Subscribable event from controller -> control to update service station status.
 */
export class InstanceServiceStationStatusStream {
	declare ["constructor"]: typeof InstanceServiceStationStatusStream;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "control" as const;
	static plugin = "ctron_plugin" as const;
	static permission = "ctron_plugin.jobs.read" as const;

	constructor(public updates: InstanceServiceStationStatus[]) { }

	static jsonSchema = Type.Object({
		updates: Type.Array(InstanceServiceStationStatus),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.updates);
	}
}

/**
 * Event from controller -> instance: the surface names some instance has service stations on. A publisher surface
 * sends its jobs to the controller only if its name is in the list (spec §8).
 */
export class CtronSubscribedSurfaces {
	declare ["constructor"]: typeof CtronSubscribedSurfaces;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_plugin" as const;

	constructor(public surfaces: string[]) { }

	static jsonSchema = Type.Object({
		surfaces: Type.Array(Type.String()),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.surfaces);
	}
}

/**
 * Hardcoded default values for global constructron settings.
 * Update here (and in Lua) when adding/removing settings.
 */
export const DEFAULT_GLOBAL_SETTINGS = {
	job_start_delay: 300, // ticks (5 seconds)
	debug_toggle: false,
};

/**
 * Hardcoded default values for per-surface constructron settings.
 * Update here (and in Lua) when adding/removing settings.
 */
export const DEFAULT_SURFACE_SETTINGS = {
	horde_mode: false,
	construction_job_toggle: true,
	rebuild_job_toggle: true,
	deconstruction_job_toggle: true,
	upgrade_job_toggle: true,
	repair_job_toggle: true,
	destroy_job_toggle: false,
	zone_restriction_job_toggle: false,
	desired_robot_count: 50,
	desired_robot_name: { name: "construction-robot", quality: "normal" },
	repair_tool_name: { name: "repair-pack", quality: "normal" },
	ammo_name: { name: "rocket", quality: "normal" },
	ammo_count: 0,
	atomic_ammo_name: { name: "atomic-bomb", quality: "normal" },
	atomic_ammo_count: 0,
	destroy_min_cluster_size: 8,
	minion_count: 1,
};

/**
 * Event from instance -> controller on startup to register which surfaces exist.
 * The controller creates entries for new surfaces using hardcoded defaults.
 */
export class CtronSurfaceRegister {
	declare ["constructor"]: typeof CtronSurfaceRegister;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;

	constructor(public surfaces: string[]) { }

	static jsonSchema = Type.Object({
		surfaces: Type.Array(Type.String()),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.surfaces);
	}
}

/**
 * Event from instance -> controller when a player changes constructron settings in-game.
 */
export class CtronSettingsUpdate {
	declare ["constructor"]: typeof CtronSettingsUpdate;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;

	constructor(
		public instanceId: number,
		public surfaceName: string | null,
		public settings: Record<string, unknown>,
	) { }

	static jsonSchema = Type.Object({
		instanceId: Type.Number(),
		surfaceName: Type.Union([Type.String(), Type.Null()]),
		settings: Type.Record(Type.String(), Type.Unknown()),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.instanceId, json.surfaceName, json.settings as Record<string, unknown>);
	}
}

/**
 * Event from controller -> instance broadcasting settings to all instances.
 */
export class CtronSettingsBroadcast {
	declare ["constructor"]: typeof CtronSettingsBroadcast;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_plugin" as const;

	constructor(
		public surfaceSettings: Record<string, Record<string, unknown>>,
		public globalSettings: Record<string, unknown>,
		public mode: string,
	) { }

	static jsonSchema = Type.Object({
		surfaceSettings: Type.Record(Type.String(), Type.Record(Type.String(), Type.Unknown())),
		globalSettings: Type.Record(Type.String(), Type.Unknown()),
		mode: Type.String(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(
			json.surfaceSettings as Record<string, Record<string, unknown>>,
			json.globalSettings as Record<string, unknown>,
			json.mode,
		);
	}
}

/**
 * Request from instance -> controller to pull current settings on startup.
 */
export class CtronSettingsPull {
	declare ["constructor"]: typeof CtronSettingsPull;
	static type = "request" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;

	static jsonSchema = Type.Object({});

	static fromJSON(_json: Static<typeof this.jsonSchema>) { return new this(); }

	static Response = plainJson(Type.Object({
		surfaceSettings: Type.Record(Type.String(), Type.Record(Type.String(), Type.Unknown())),
		globalSettings: Type.Record(Type.String(), Type.Unknown()),
		mode: Type.String(),
		subscribed: Type.Array(Type.String()),
	}));
}

/**
 * Request from control -> controller to set settings via web UI (controller authority mode).
 */
export class CtronSettingsSet {
	declare ["constructor"]: typeof CtronSettingsSet;
	static type = "request" as const;
	static src = "control" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;
	static permission = "ctron_plugin.settings.write" as const;

	constructor(public surfaceName: string | null, public settings: Record<string, unknown>) { }

	static jsonSchema = Type.Object({
		surfaceName: Type.Union([Type.String(), Type.Null()]),
		settings: Type.Record(Type.String(), Type.Unknown()),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.surfaceName, json.settings as Record<string, unknown>);
	}

	static Response = plainJson(Type.Object({}));
}

/**
 * Request from control -> controller to get current settings.
 */
export class CtronSettingsGet {
	declare ["constructor"]: typeof CtronSettingsGet;
	static type = "request" as const;
	static src = "control" as const;
	static dst = "controller" as const;
	static permission = "ctron_plugin.settings.write" as const;
	static plugin = "ctron_plugin" as const;

	static jsonSchema = Type.Object({});

	static fromJSON(_json: Static<typeof this.jsonSchema>) { return new this(); }

	static Response = plainJson(Type.Object({
		surfaceSettings: Type.Record(Type.String(), Type.Record(Type.String(), Type.Unknown())),
		globalSettings: Type.Record(Type.String(), Type.Unknown()),
		mode: Type.String(),
	}));
}
