import * as lib from "@clusterio/lib";
import * as messages from "./messages";

lib.definePermission({
	name: "ctron_plugin.jobs.read",
	title: "Read Constructron jobs",
	description: "Read Constructron jobs persisted on the controller.",
});

lib.definePermission({
	name: "ctron_plugin.settings.write",
	title: "Write Constructron settings",
	description: "Edit constructron settings via the web UI (controller authority mode only).",
});

declare module "@clusterio/lib" {
	export interface ControllerConfigFields {
		"ctron_plugin.settings_sync_mode": string;
	}
	export interface InstanceConfigFields { }
}

export const plugin: lib.PluginDeclaration = {
	name: "ctron_plugin",
	title: "Ctron Plugin",
	description: "Persists Constructron jobs on the controller and displays them in the Web UI.",

	controllerEntrypoint: "./dist/node/controller",
	controllerConfigFields: {
		"ctron_plugin.settings_sync_mode": {
			title: "Settings Sync Mode",
			description: "Controls how constructron settings are synced. 'in_game': player changes push to all instances. 'controller': settings are managed via web UI.",
			type: "string",
			initialValue: "in_game",
			enum: ["in_game", "controller"],
		},
	},

	instanceEntrypoint: "./dist/node/instance",
	instanceConfigFields: {},

	messages: [
		messages.ConstructronJobAdd,
		messages.ConstructronJobClaim,
		messages.ConstructronJobConsume,
		messages.ConstructronJobRemove,
		messages.ConstructronJobUpdate,
		messages.CtronPathRequest,
		messages.CtronForwardPathRequest,
		messages.CtronPathResponse,
		messages.CtronReturnPathResponse,
		messages.InstanceServiceStationStatusUpdate,
		messages.InstanceServiceStationStatusStream,
		messages.CtronSurfaceRegister,
		messages.CtronSettingsUpdate,
		messages.CtronSettingsBroadcast,
		messages.CtronSettingsPull,
		messages.CtronSettingsSet,
		messages.CtronSettingsGet,
		messages.CtronSubscriberAvailabilityBroadcast,
	],

	webEntrypoint: "./web",
	routes: [
		"/ctron_plugin",
		"/ctron_plugin/settings",
	],
};
