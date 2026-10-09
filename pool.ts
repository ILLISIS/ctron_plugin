import type { ConstructronJobValue, InstanceServiceStationStatus } from "./messages.js";

/**
 * A claim (spec §8, D-5): the oldest unclaimed job on one of the claimer's surfaces. A job younger than minAgeMs
 * waits, as v1's did, so a claim never races the add it follows.
 */
/** Lua encodes an empty table as `[]`: no stations left on this instance. */
export function stationsFromIpc(stations: Record<string, number> | []): Record<string, number> {
	return Array.isArray(stations) ? {} : stations;
}

export function oldestOn(
	jobs: Iterable<ConstructronJobValue>, surfaces: string[], now: number, minAgeMs = 1000,
): ConstructronJobValue | undefined {
	let oldest: ConstructronJobValue | undefined;
	for (const job of jobs) {
		if (!job.isDeleted && job.jobType !== "cargo" && surfaces.includes(job.surfaceName)
			&& now - job.updatedAtMs >= minAgeMs && (!oldest || job.updatedAtMs < oldest.updatedAtMs)) {
			oldest = job;
		}
	}
	return oldest;
}

/** An instance's station status (spec §8): its service stations by surface name, surfaces with none left out. */
export function stationStatus(
	instanceId: number, stations: Record<string, number>, now: number,
): InstanceServiceStationStatus {
	const kept = Object.fromEntries(Object.entries(stations).filter(([, count]) => count > 0));
	return { id: `instance:${instanceId}`, updatedAtMs: now, isDeleted: false, instanceId, stations: kept };
}

/** The surface names some instance has service stations on, sorted: jobs are published only for these (spec §8). */
export function subscribedSurfaces(statuses: Iterable<InstanceServiceStationStatus>): string[] {
	const names = new Set<string>();
	for (const status of statuses) {
		for (const [name, count] of Object.entries(status.stations)) {
			if (!status.isDeleted && count > 0) {
				names.add(name);
			}
		}
	}
	return [...names].sort();
}

/** The cargo requests other instances published on `surfaces` (research §3): a tile never serves its own. */
export function cargoOffers(jobs: Iterable<ConstructronJobValue>, surfaces: string[], instanceId: number) {
	const offers = [];
	for (const job of jobs) {
		if (!job.isDeleted && job.jobType === "cargo" && surfaces.includes(job.surfaceName)
			&& job.lastInstanceId !== instanceId) {
			const body = job.job as any;
			offers.push({
				key: job.id,
				surfaceName: job.surfaceName,
				position: body.task_positions[0] ?? body.task_positions["1"], // Lua's one-element array is a JSON array
				items: body.required_items,
			});
		}
	}
	return offers;
}

/** A claim by key: that entry if it is still open (the first fetcher wins). */
export function claimByKey(jobs: Map<string, ConstructronJobValue>, key: string): ConstructronJobValue | undefined {
	const job = jobs.get(key);
	return job && !job.isDeleted ? job : undefined;
}
