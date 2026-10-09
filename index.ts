import type * as lib from "@clusterio/lib";
import * as messages from "./messages.js";

declare module "@clusterio/lib" {
	export interface ControllerConfigFields {
		"ctron_plugin.settings_sync_mode": string;
	}
	export interface Permissions {
		"ctron_plugin.jobs.read": never;
		"ctron_plugin.settings.write": never;
	}
}

export const plugin: lib.PluginDeclaration = {
	name: "ctron_plugin",
	title: "Ctron Plugin",
	description: "Constructrons across instances: a job pool on the controller, and jobs that ride Universal Edges.",
	controllerEntrypoint: "dist/node/controller.js",
	instanceEntrypoint: "dist/node/instance.js",
	webEntrypoint: "./web",
	routes: ["/ctron_plugin"],
	// The save module runs Constructron-Continued's runtime; the instance plugin calls it with /sc.
	features: ["SavePatching", "ScriptCommands"],
	controllerConfigFields: {
		"ctron_plugin.settings_sync_mode": {
			title: "Settings Sync Mode",
			description: "Controls how constructron settings are synced. 'in_game': player changes push to all " +
				"instances. 'controller': settings are managed via web UI.",
			type: "string",
			initialValue: "in_game",
			enum: ["in_game", "controller"],
		},
	},
	messages: [
		messages.ConstructronJobAdd,
		messages.ConstructronJobClaim,
		messages.ConstructronJobUpdate,
		messages.InstanceServiceStationStatusUpdate,
		messages.InstanceServiceStationStatusStream,
		messages.CtronSurfaceRegister,
		messages.CtronSettingsUpdate,
		messages.CtronSettingsBroadcast,
		messages.CtronSettingsPull,
		messages.CtronSettingsSet,
		messages.CtronSettingsGet,
		messages.CtronSubscribedSurfaces,
	],
	permissions: [
		{
			name: "ctron_plugin.jobs.read",
			title: "Read Constructron jobs",
			description: "Read Constructron jobs persisted on the controller.",
		},
		{
			name: "ctron_plugin.settings.write",
			title: "Write Constructron settings",
			description: "Read constructron settings in the web UI, and edit them there in controller authority mode.",
		},
	],
};
