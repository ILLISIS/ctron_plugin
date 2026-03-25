import { plainJson } from "@clusterio/lib";
import { Type, Static } from "@sinclair/typebox";

// A stored Constructron job on the controller.
const ConstructronJobValue = Type.Object({
	id: Type.String(),
	updatedAtMs: Type.Number(),
	isDeleted: Type.Boolean(),

	lastInstanceId: Type.Number(),
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

	constructor(public instanceId: number, public jobType: string, public job: unknown, public jobKey?: string) { }

	static jsonSchema = Type.Object({
		instanceId: Type.Number(),
		jobType: Type.String(),
		job: Type.Unknown(),
		jobKey: Type.Optional(Type.String()),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.instanceId, json.jobType, json.job, json.jobKey);
	}
}

/**
 * Event from instance -> controller to remove a Constructron job by controller-generated id.
 */
export class ConstructronJobRemove {
	declare ["constructor"]: typeof ConstructronJobRemove;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;

	constructor(public instanceId: number, public jobId: string) { }

	static jsonSchema = Type.Object({
		instanceId: Type.Number(),
		jobId: Type.String(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.instanceId, json.jobId);
	}
}

/**
 * Event from instance -> controller indicating a previously added job has been
 * consumed/applied on the destination instance and should be removed from the controller list.
 */
export class ConstructronJobConsume {
	declare ["constructor"]: typeof ConstructronJobConsume;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;

	constructor(public instanceId: number, public jobKey: string) { }

	static jsonSchema = Type.Object({
		instanceId: Type.Number(),
		jobKey: Type.String(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.instanceId, json.jobKey);
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
	static permission = "ctron_plugin.jobs.read";

	constructor(public updates: ConstructronJobValue[]) { }

	static jsonSchema = Type.Object({
		updates: Type.Array(ConstructronJobValue),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.updates);
	}
}

/**
 * Request from instance -> controller to atomically claim one pending job.
 * Returns the claimed job or null if none are available.
 */
export class ConstructronJobClaim {
	declare ["constructor"]: typeof ConstructronJobClaim;
	static type = "request" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;

	constructor(public instanceId: number) { }

	static jsonSchema = Type.Object({
		instanceId: Type.Number(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.instanceId);
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

/** Bounding box serialised for cross-instance path requests. */
const PathBoundingBox = Type.Object({
	x1: Type.Number(), y1: Type.Number(),
	x2: Type.Number(), y2: Type.Number(),
});

const PathWaypoint = Type.Object({
	position: Type.Object({ x: Type.Number(), y: Type.Number() }),
	needsDestroyToReach: Type.Boolean(),
});

/** Event instance -> controller: local pathfinding exhausted, route to pathworld. */
export class CtronPathRequest {
	declare ["constructor"]: typeof CtronPathRequest;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;

	constructor(
		public sourceInstanceId: number,
		public requesterId: number,
		public surface: string,
		public boundingBox: Static<typeof PathBoundingBox>,
		public start: { x: number; y: number },
		public goal: { x: number; y: number },
		public force: string,
		public radius: number,
		public pathResolutionModifier: number,
	) {}

	static jsonSchema = Type.Object({
		sourceInstanceId: Type.Number(),
		requesterId: Type.Number(),
		surface: Type.String(),
		boundingBox: PathBoundingBox,
		start: Type.Object({ x: Type.Number(), y: Type.Number() }),
		goal: Type.Object({ x: Type.Number(), y: Type.Number() }),
		force: Type.String(),
		radius: Type.Number(),
		pathResolutionModifier: Type.Number(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(
			json.sourceInstanceId, json.requesterId, json.surface,
			json.boundingBox, json.start, json.goal, json.force, json.radius,
			json.pathResolutionModifier,
		);
	}
}

/** Event controller -> pathworld instance: forwarded path request. */
export class CtronForwardPathRequest {
	declare ["constructor"]: typeof CtronForwardPathRequest;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_plugin" as const;

	constructor(
		public sourceInstanceId: number,
		public requesterId: number,
		public surface: string,
		public boundingBox: Static<typeof PathBoundingBox>,
		public start: { x: number; y: number },
		public goal: { x: number; y: number },
		public force: string,
		public radius: number,
		public pathResolutionModifier: number,
	) {}

	static jsonSchema = Type.Object({
		sourceInstanceId: Type.Number(),
		requesterId: Type.Number(),
		surface: Type.String(),
		boundingBox: PathBoundingBox,
		start: Type.Object({ x: Type.Number(), y: Type.Number() }),
		goal: Type.Object({ x: Type.Number(), y: Type.Number() }),
		force: Type.String(),
		radius: Type.Number(),
		pathResolutionModifier: Type.Number(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(
			json.sourceInstanceId, json.requesterId, json.surface,
			json.boundingBox, json.start, json.goal, json.force, json.radius,
			json.pathResolutionModifier,
		);
	}
}

/** Event pathworld instance -> controller: path result ready. */
export class CtronPathResponse {
	declare ["constructor"]: typeof CtronPathResponse;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;

	constructor(
		public requesterId: number,
		public sourceInstanceId: number,
		public path: Array<Static<typeof PathWaypoint>> | null,
		public tryAgainLater: boolean,
		public partial: boolean,
		public fullyCached: boolean,
	) {}

	static jsonSchema = Type.Object({
		requesterId: Type.Number(),
		sourceInstanceId: Type.Number(),
		path: Type.Union([Type.Array(PathWaypoint), Type.Null()]),
		tryAgainLater: Type.Boolean(),
		partial: Type.Boolean(),
		fullyCached: Type.Boolean(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(
			json.requesterId, json.sourceInstanceId, json.path,
			json.tryAgainLater, json.partial, json.fullyCached,
		);
	}
}

/** Event controller -> game instance: deliver path result back. */
export class CtronReturnPathResponse {
	declare ["constructor"]: typeof CtronReturnPathResponse;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_plugin" as const;

	constructor(
		public requesterId: number,
		public path: Array<Static<typeof PathWaypoint>> | null,
		public tryAgainLater: boolean,
		public partial: boolean,
		public fullyCached: boolean,
	) {}

	static jsonSchema = Type.Object({
		requesterId: Type.Number(),
		path: Type.Union([Type.Array(PathWaypoint), Type.Null()]),
		tryAgainLater: Type.Boolean(),
		partial: Type.Boolean(),
		fullyCached: Type.Boolean(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(
			json.requesterId, json.path,
			json.tryAgainLater, json.partial, json.fullyCached,
		);
	}
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
	serviceStationCount: Type.Number(),
	isSubscriber: Type.Boolean(),
});

export type InstanceServiceStationStatus = Static<typeof InstanceServiceStationStatus>;

/**
 * Event from instance -> controller whenever service station count changes.
 */
export class InstanceServiceStationStatusUpdate {
	declare ["constructor"]: typeof InstanceServiceStationStatusUpdate;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;

	constructor(public instanceId: number, public serviceStationCount: number) { }

	static jsonSchema = Type.Object({
		instanceId: Type.Number(),
		serviceStationCount: Type.Number(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.instanceId, json.serviceStationCount);
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
	static permission = "ctron_plugin.jobs.read";

	constructor(public updates: InstanceServiceStationStatus[]) { }

	static jsonSchema = Type.Object({
		updates: Type.Array(InstanceServiceStationStatus),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.updates);
	}
}

/**
 * Event from controller -> instance broadcasting subscriber availability.
 */
export class CtronSubscriberAvailabilityBroadcast {
	declare ["constructor"]: typeof CtronSubscriberAvailabilityBroadcast;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_plugin" as const;

	constructor(public hasSubscribers: boolean) { }

	static jsonSchema = Type.Object({
		hasSubscribers: Type.Boolean(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.hasSubscribers);
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

	constructor() { }

	static jsonSchema = Type.Object({});

	static fromJSON(_json: Static<typeof this.jsonSchema>) { return new this(); }

	static Response = plainJson(Type.Object({
		surfaceSettings: Type.Record(Type.String(), Type.Record(Type.String(), Type.Unknown())),
		globalSettings: Type.Record(Type.String(), Type.Unknown()),
		mode: Type.String(),
		hasSubscribers: Type.Boolean(),
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
	static permission = "ctron_plugin.settings.write";

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
	static permission = "ctron_plugin.settings.write";
	static plugin = "ctron_plugin" as const;

	constructor() { }

	static jsonSchema = Type.Object({});

	static fromJSON(_json: Static<typeof this.jsonSchema>) { return new this(); }

	static Response = plainJson(Type.Object({
		surfaceSettings: Type.Record(Type.String(), Type.Record(Type.String(), Type.Unknown())),
		globalSettings: Type.Record(Type.String(), Type.Unknown()),
		mode: Type.String(),
	}));
}
