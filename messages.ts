import { plainJson } from "@clusterio/lib";
import { Type, type Static } from "@sinclair/typebox";
import {
	Delta, Detail, DetailFull, JobAssign, JobCancel, JobDrop, JobEvent, JobSquad, JobStation, Portals, Route,
	RouteAsk, SettingsSet,
	SettingsState, Snapshot, StationSet, StockQ, StockResult, UiCancel, UiCargo, UiDetailAsk, UiDrop, UiList, UiWatch,
	WorkClear,
} from "./contracts.js";

// ctron_pluginv2's Clusterio messages (spec §9.3): each carries one contract payload as `payload`. No permission:
// none is control traffic (R-9). The controller sends to {instanceId} in a loop over running instances (06 §3.2).

const StockQueryBody = Type.Object({ q: Type.Array(StockQ) });
const DetailFetchBody = Type.Object({ jid: Type.String() });
const DetailFullAnswer = Type.Object({ detail: Type.Union([DetailFull, Type.Null()]) });
const DetailAnswer = Type.Object({ detail: Type.Union([Detail, Type.Null()]) });

/** Instance → controller: a tile's whole state, in answer to ct.snapshot.request (§6.1). */
export class TileSnapshotEvent {
	declare ["constructor"]: typeof TileSnapshotEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof Snapshot>) { }

	static jsonSchema = Type.Object({ payload: Snapshot });

	static fromJSON(json: Static<typeof TileSnapshotEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Instance → controller: a tile's changed records, at most every 60 ticks (R-19). */
export class TileDeltaEvent {
	declare ["constructor"]: typeof TileDeltaEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof Delta>) { }

	static jsonSchema = Type.Object({ payload: Delta });

	static fromJSON(json: Static<typeof TileDeltaEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Instance → controller: a run's event: adopted, done, short, ... (§9.2). */
export class JobEventEvent {
	declare ["constructor"]: typeof JobEventEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof JobEvent>) { }

	static jsonSchema = Type.Object({ payload: JobEvent });

	static fromJSON(json: Static<typeof JobEventEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Instance → controller: a tile's portal graph on one surface (§7.4). */
export class PortalReportEvent {
	declare ["constructor"]: typeof PortalReportEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof Portals>) { }

	static jsonSchema = Type.Object({ payload: Portals });

	static fromJSON(json: Static<typeof PortalReportEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Instance → controller: a watch's first viewer opened, or its last closed (§6.12). */
export class UiWatchEvent {
	declare ["constructor"]: typeof UiWatchEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof UiWatch>) { }

	static jsonSchema = Type.Object({ payload: UiWatch });

	static fromJSON(json: Static<typeof UiWatchEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Instance → controller: a cancel from a screen (§6.9). */
export class UiCancelEvent {
	declare ["constructor"]: typeof UiCancelEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof UiCancel>) { }

	static jsonSchema = Type.Object({ payload: UiCancel });

	static fromJSON(json: Static<typeof UiCancelEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Instance → controller: drop one requested item from loading jobs (§6.9). */
export class UiDropEvent {
	declare ["constructor"]: typeof UiDropEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof UiDrop>) { }

	static jsonSchema = Type.Object({ payload: UiDrop });

	static fromJSON(json: Static<typeof UiDropEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Instance → controller: edit a station's requests and/or name, wherever its tile is (§8.4). */
export class UiCargoEvent {
	declare ["constructor"]: typeof UiCargoEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof UiCargo>) { }

	static jsonSchema = Type.Object({ payload: UiCargo });

	static fromJSON(json: Static<typeof UiCargoEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Instance → controller: an in-game settings edit (§6.11). */
export class SettingsSetEvent {
	declare ["constructor"]: typeof SettingsSetEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof SettingsSet>) { }

	static jsonSchema = Type.Object({ payload: SettingsSet });

	static fromJSON(json: Static<typeof SettingsSetEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Instance → controller: a route for a leg to another instance; null when there is none (§7.5). */
export class RouteRequest {
	declare ["constructor"]: typeof RouteRequest;
	static type = "request" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof RouteAsk>) { }

	static jsonSchema = Type.Object({ payload: RouteAsk });

	static fromJSON(json: Static<typeof RouteRequest.jsonSchema>) {
		return new this(json.payload);
	}

	static Response = plainJson(Type.Object({ route: Type.Union([Route, Type.Null()]) }));
}

/** Instance → controller: a remote job's detail for Job Details (§6.12). */
export class JobDetailRequest {
	declare ["constructor"]: typeof JobDetailRequest;
	static type = "request" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof UiDetailAsk>) { }

	static jsonSchema = Type.Object({ payload: UiDetailAsk });

	static fromJSON(json: Static<typeof JobDetailRequest.jsonSchema>) {
		return new this(json.payload);
	}

	static Response = plainJson(DetailFullAnswer);
}

/** Controller → instance: a job for the ctron's instance (§6.9). */
export class JobAssignEvent {
	declare ["constructor"]: typeof JobAssignEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof JobAssign>) { }

	static jsonSchema = Type.Object({ payload: JobAssign });

	static fromJSON(json: Static<typeof JobAssignEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Controller → instance: a better station for one member (§6.5). */
export class JobStationEvent {
	declare ["constructor"]: typeof JobStationEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof JobStation>) { }

	static jsonSchema = Type.Object({ payload: JobStation });

	static fromJSON(json: Static<typeof JobStationEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Controller → instance: cancel a job on every tile holding part of it (§6.9). */
export class JobCancelEvent {
	declare ["constructor"]: typeof JobCancelEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof JobCancel>) { }

	static jsonSchema = Type.Object({ payload: JobCancel });

	static fromJSON(json: Static<typeof JobCancelEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Controller → instance: the squad's leader place, gone minions and release (squads.md §4.4). */
export class JobSquadEvent {
	declare ["constructor"]: typeof JobSquadEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof JobSquad>) { }

	static jsonSchema = Type.Object({ payload: JobSquad });

	static fromJSON(json: Static<typeof JobSquadEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Controller → instance: drop one requested item (§6.9). */
export class JobDropEvent {
	declare ["constructor"]: typeof JobDropEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof JobDrop>) { }

	static jsonSchema = Type.Object({ payload: JobDrop });

	static fromJSON(json: Static<typeof JobDropEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Controller → instance: apply a station edit on the station's tile (§8.4). */
export class StationSetEvent {
	declare ["constructor"]: typeof StationSetEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof StationSet>) { }

	static jsonSchema = Type.Object({ payload: StationSet });

	static fromJSON(json: Static<typeof StationSetEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Controller → instance: forget cells (§6.9, §6.11). */
export class WorkClearEvent {
	declare ["constructor"]: typeof WorkClearEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof WorkClear>) { }

	static jsonSchema = Type.Object({ payload: WorkClear });

	static fromJSON(json: Static<typeof WorkClearEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Controller → instance: one part of a watch's UI rows (§6.12). */
export class UiListEvent {
	declare ["constructor"]: typeof UiListEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof UiList>) { }

	static jsonSchema = Type.Object({ payload: UiList });

	static fromJSON(json: Static<typeof UiListEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Controller → instance: the controller's overrides and the schedulable surfaces (§6.11). */
export class SettingsStateEvent {
	declare ["constructor"]: typeof SettingsStateEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof SettingsState>) { }

	static jsonSchema = Type.Object({ payload: SettingsState });

	static fromJSON(json: Static<typeof SettingsStateEvent.jsonSchema>) {
		return new this(json.payload);
	}
}

/** Controller → instance: this tile's stations grouped by covering network, answered in parts (R-151) (§6.5). */
export class StockQueryRequest {
	declare ["constructor"]: typeof StockQueryRequest;
	static type = "request" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof StockQueryBody>) { }

	static jsonSchema = Type.Object({ payload: StockQueryBody });

	static fromJSON(json: Static<typeof StockQueryRequest.jsonSchema>) {
		return new this(json.payload);
	}

	static Response = plainJson(Type.Object({ r: StockResult }));
}

/** Controller → instance: a job's detail from the tile holding it (§6.12). */
export class JobDetailFetchRequest {
	declare ["constructor"]: typeof JobDetailFetchRequest;
	static type = "request" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "ctron_pluginv2" as const;

	constructor(public payload: Static<typeof DetailFetchBody>) { }

	static jsonSchema = Type.Object({ payload: DetailFetchBody });

	static fromJSON(json: Static<typeof JobDetailFetchRequest.jsonSchema>) {
		return new this(json.payload);
	}

	static Response = plainJson(DetailAnswer);
}
