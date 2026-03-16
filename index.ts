import * as lib from "@clusterio/lib";
import * as messages from "./messages";

lib.definePermission({
	name: "ctron_plugin.jobs.read",
	title: "Read Constructron jobs",
	description: "Read Constructron jobs persisted on the controller.",
});

declare module "@clusterio/lib" {
	export interface ControllerConfigFields { }
	export interface InstanceConfigFields { }
}

export const plugin: lib.PluginDeclaration = {
	name: "ctron_plugin",
	title: "Ctron Plugin",
	description: "Persists Constructron jobs on the controller and displays them in the Web UI.",

	controllerEntrypoint: "./dist/node/controller",
	controllerConfigFields: {},

	instanceEntrypoint: "./dist/node/instance",
	instanceConfigFields: {},

	messages: [
		messages.ConstructronJobAdd,
		messages.ConstructronJobClaim,
		messages.ConstructronJobConsume,
		messages.ConstructronJobRemove,
		messages.ConstructronJobUpdate,
		messages.ConstructronJobRoute,
		messages.ConstructronJobDeliver,
		messages.CtronPathRequest,
		messages.CtronForwardPathRequest,
		messages.CtronPathResponse,
		messages.CtronReturnPathResponse,
		messages.InstanceServiceStationStatusUpdate,
		messages.InstanceServiceStationStatusStream,
	],

	webEntrypoint: "./web",
	routes: [
		"/ctron_plugin",
	],
};
