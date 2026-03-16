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
 * Event from instance -> controller to announce a job that should be routed to a destination instance.
 */
export class ConstructronJobRoute {
	declare ["constructor"]: typeof ConstructronJobRoute;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_plugin" as const;

	constructor(
		public sourceInstanceId: number,
		public destinationInstanceId: number,
		public jobType: string,
		public job: unknown,
		public jobKey?: string,
	) { }

	static jsonSchema = Type.Object({
		sourceInstanceId: Type.Number(),
		destinationInstanceId: Type.Number(),
		jobType: Type.String(),
		job: Type.Unknown(),
		jobKey: Type.Optional(Type.String()),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.sourceInstanceId, json.destinationInstanceId, json.jobType, json.job, json.jobKey);
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

/**
 * Event from controller -> instance delivering a routed job to a destination instance.
 */
export class ConstructronJobDeliver {
	declare ["constructor"]: typeof ConstructronJobDeliver;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_plugin" as const;

	constructor(
		public sourceInstanceId: number,
		public destinationInstanceId: number,
		public jobType: string,
		public job: unknown,
		public jobKey?: string,
	) { }

	static jsonSchema = Type.Object({
		sourceInstanceId: Type.Number(),
		destinationInstanceId: Type.Number(),
		jobType: Type.String(),
		job: Type.Unknown(),
		jobKey: Type.Optional(Type.String()),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.sourceInstanceId, json.destinationInstanceId, json.jobType, json.job, json.jobKey);
	}
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
