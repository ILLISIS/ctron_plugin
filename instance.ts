import { BaseInstancePlugin } from "@clusterio/host";
import { lifecycle } from "universal_edges/runtime";
import * as messages from "./messages.js";
import { stationsFromIpc } from "./pool.js";

type ConstructronJobAddIPC = { job_key: string; job_type: string; surface_name: string; job: unknown };

/** A module log line (spec §11): op, phase and level, and the line's own fields. */
type TraceIPC = { op: string; phase: string; level: "info" | "verbose" | "warn" | "error" } & Record<string, unknown>;

type CtronSettingsChangedIPC = {
	surface_name: string | null;
	settings: Record<string, unknown>;
};

export class InstancePlugin extends BaseInstancePlugin {
	/**
	 * The save module runs only with Constructron-Continued loaded (module/control.lua's gate); without it, its RCON
	 * functions don't exist, so this plugin stays quiet (a gridworld tile with the plugin on and no CC mod pack).
	 */
	private active = false;

	async init() {
		const server = this.instance.server as any;
		const on = <T>(name: string, handler: (data: T) => Promise<void>) => {
			server.on(`ipc-ctron_plugin:${name}`, (data: T) => {
				handler(data).catch(err => this.logger.error(`Error handling ${name}:\n${err.stack}`));
			});
		};
		// Factorio -> host IPC events, sent by the module's clusterio_api.send_json(...)
		on("job_add", (data: ConstructronJobAddIPC) => this.handleJobAdd(data));
		on("job_claim", (data: { surfaces: string[]; job_key?: string }) => (
			this.claimJobFromController(data.surfaces, data.job_key ?? null)
		));
		on("cargo_offers", (data: { surfaces: string[] }) => this.fetchCargoOffers(data.surfaces));
		on("stations", (data: { stations: Record<string, number> }) => this.handleStations(data.stations));
		on("trace", async ({ op, phase, level, ...fields }: TraceIPC) => {
			lifecycle(this.logger, op, phase, fields, level);
		});
		on("settings_changed", (data: CtronSettingsChangedIPC) => this.handleSettingsChangedIPC(data));
		on("surface_created", (data: { name: string }) => this.handleSurfaceCreated(data.name));

		this.instance.handle(messages.CtronSettingsBroadcast, this.handleSettingsBroadcast.bind(this));
		this.instance.handle(messages.CtronSubscribedSurfaces, this.handleSubscribedSurfaces.bind(this));
	}

	// Called by the on_nth_tick_300 Lua handler (via IPC) to claim a job for its subscriber surfaces (spec §8).
	async claimJobFromController(surfaces: string[], jobKey: string | null = null) {
		let result: { jobKey: string; jobType: string; job: unknown } | null;
		try {
			result = await this.instance.sendTo(
				"controller", new messages.ConstructronJobClaim(this.instance.id, surfaces, jobKey),
			) as any;
		} catch (err: any) {
			this.logger.error(`ConstructronJobClaim failed: ${err?.stack ?? err}`);
			return;
		}
		if (!result) {
			return;
		}

		this.logger.info(`ConstructronJobClaim: got job key=${result.jobKey} type=${result.jobType}, sending to Lua`);
		const jobJson = JSON.stringify(result.job ?? null);
		const script = `ctron_plugin_on_job_claimed(${JSON.stringify(jobJson)})`;
		try {
			const rconResult = await this.sendRcon(`/sc ${script}`);
			this.logger.info(`ConstructronJobClaim applied for key=${result.jobKey}: ${JSON.stringify(rconResult)}`);
		} catch (err: any) {
			this.logger.error(`Failed to apply claimed job for key=${result.jobKey}: ${err?.stack ?? err}`);
		}
	}

	/** The cargo requests other tiles published on these surfaces, handed to the module to pick one (research §3). */
	async fetchCargoOffers(surfaces: string[]) {
		const { offers } = await this.instance.sendTo(
			"controller", new messages.ConstructronCargoOffers(this.instance.id, surfaces),
		) as { offers: unknown[] };
		if (offers.length) {
			await this.sendRcon(`/sc ctron_plugin_on_cargo_offers(${JSON.stringify(JSON.stringify(offers))})`);
		}
	}

	async onStart() {
		this.active = (await this.sendRcon(
			"/sc rcon.print(script.active_mods[\"Constructron-Continued\"] and \"on\" or \"off\")",
		)).trim() === "on";
		if (!this.active) {
			this.logger.info("ctron_plugin: Constructron-Continued is not loaded here; the plugin stays off");
			return;
		}

		// Register surfaces so the controller creates default entries for any it hasn't seen before.
		try {
			const raw = await this.sendRcon("/sc ctron_plugin_get_surface_names()");
			const surfaces = raw && raw.trim() ? raw.trim().split(",") : [];
			this.logger.info(`ctron_plugin: registering surfaces=${JSON.stringify(surfaces)}`);
			await this.instance.sendTo("controller", new messages.CtronSurfaceRegister(surfaces));
		} catch (err: any) {
			this.logger.warn(`Failed to register surfaces with controller: ${err?.stack ?? err}`);
		}

		// Tell the controller this instance's stations again after a restart (also when it has none)
		try {
			await this.sendRcon("/sc ctron_plugin_send_stations()");
		} catch (err: any) {
			this.logger.warn(`Failed to send the stations to the controller: ${err?.stack ?? err}`);
		}

		// Pull settings from controller and apply
		try {
			const pullResult = await this.instance.sendTo("controller", new messages.CtronSettingsPull()) as any;
			if (pullResult) {
				const payload = JSON.stringify({
					surface_settings: pullResult.surfaceSettings ?? {},
					global_settings: pullResult.globalSettings ?? {},
					mode: pullResult.mode ?? "in_game",
				});
				await this.sendRcon(`/sc ctron_plugin_apply_synced_settings(${JSON.stringify(payload)})`);

				await this.setSubscribedSurfaces(pullResult.subscribed ?? []);
			}
		} catch (err: any) {
			this.logger.warn(`Failed to pull settings from controller: ${err?.stack ?? err}`);
		}
	}

	async handleJobAdd(data: ConstructronJobAddIPC) {
		await this.instance.sendTo("controller", new messages.ConstructronJobAdd(
			this.instance.id, data.surface_name, data.job_type, data.job, data.job_key,
		));
	}

	async handleStations(stations: Record<string, number> | []) {
		await this.instance.sendTo(
			"controller",
			new messages.InstanceServiceStationStatusUpdate(this.instance.id, stationsFromIpc(stations)),
		);
	}

	async handleSettingsChangedIPC(data: CtronSettingsChangedIPC) {
		const surfaceName = data.surface_name ?? null;
		const settings = data.settings ?? {};
		await this.instance.sendTo(
			"controller", new messages.CtronSettingsUpdate(this.instance.id, surfaceName, settings),
		);
	}

	async handleSurfaceCreated(name: string) {
		await this.instance.sendTo("controller", new messages.CtronSurfaceRegister([name]));
	}

	async handleSettingsBroadcast(event: messages.CtronSettingsBroadcast) {
		if (!this.active) {
			return;
		}
		const payload = JSON.stringify({
			surface_settings: event.surfaceSettings,
			global_settings: event.globalSettings,
			mode: event.mode,
		});
		try {
			await this.sendRcon(`/sc ctron_plugin_apply_synced_settings(${JSON.stringify(payload)})`);
		} catch (err: any) {
			this.logger.error(`Failed to apply synced settings via RCON: ${err?.stack ?? err}`);
		}
	}

	async handleSubscribedSurfaces(event: messages.CtronSubscribedSurfaces) {
		if (this.active) {
			await this.setSubscribedSurfaces(event.surfaces);
		}
	}

	/** Tell the module which surface names have a subscriber, so its publisher surfaces send jobs (spec §8). */
	private async setSubscribedSurfaces(surfaces: string[]) {
		try {
			const json = JSON.stringify(JSON.stringify(surfaces));
			await this.sendRcon(`/sc ctron_plugin_set_subscribed_surfaces(${json})`);
		} catch (err: any) {
			this.logger.error(`Failed to set the subscribed surfaces via RCON: ${err?.stack ?? err}`);
		}
	}
}
