import type * as lib from "@clusterio/lib";
import * as messages from "./messages.js";

export const plugin: lib.PluginDeclaration = {
	name: "ctron_pluginv2",
	title: "Constructrons v2",
	description: "Constructrons as one cluster-wide world: " +
		"the controller assigns every job, tiles find and run the work.",
	controllerEntrypoint: "dist/node/controller.js",
	instanceEntrypoint: "dist/node/instance.js",
	webEntrypoint: "./web",
	// The save module is the tile runtime; the instance plugin talks to it over UE's bridge (/sc ue_rt.inbox).
	features: ["SavePatching", "ScriptCommands"],
	messages: [
		messages.TileSnapshotEvent,
		messages.TileDeltaEvent,
		messages.JobEventEvent,
		messages.PortalReportEvent,
		messages.UiWatchEvent,
		messages.UiCancelEvent,
		messages.UiDropEvent,
		messages.UiCargoEvent,
		messages.SettingsSetEvent,
		messages.RouteRequest,
		messages.JobDetailRequest,
		messages.JobAssignEvent,
		messages.JobStationEvent,
		messages.JobCancelEvent,
		messages.JobSquadEvent,
		messages.JobDropEvent,
		messages.StationSetEvent,
		messages.WorkClearEvent,
		messages.UiListEvent,
		messages.SettingsStateEvent,
		messages.StockQueryRequest,
		messages.JobDetailFetchRequest,
	],
};
