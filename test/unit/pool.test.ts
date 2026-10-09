import { test } from "node:test";
import assert from "node:assert/strict";
import type { ConstructronJobValue, InstanceServiceStationStatus } from "../../messages.js";
import { oldestOn, stationsFromIpc, stationStatus, subscribedSurfaces } from "../../pool.js";

const job = (id: string, surfaceName: string, updatedAtMs: number, isDeleted = false): ConstructronJobValue => (
	{ id, updatedAtMs, isDeleted, lastInstanceId: 1, surfaceName, jobType: "construction", job: {} }
);
type Status = InstanceServiceStationStatus;
const status = (instanceId: number, stations: Record<string, number>, isDeleted = false): Status => (
	{ id: `instance:${instanceId}`, updatedAtMs: 0, isDeleted, instanceId, stations }
);

test("a claim takes the oldest job on the claimer's surfaces; none when there's none (spec §8, D-5)", () => {
	const now = 100_000;
	const jobs = [
		job("1|1", "gleba", 10), job("1|2", "nauvis", 20), job("1|3", "nauvis", 5, true), job("1|4", "nauvis", 30),
		job("1|5", "nauvis", now - 500),
	];
	assert.equal(oldestOn(jobs, ["nauvis"], now)?.id, "1|2", "gleba's older job and the claimed 1|3 don't count");
	assert.equal(oldestOn(jobs, ["gleba", "nauvis"], now)?.id, "1|1");
	assert.equal(oldestOn(jobs, ["vulcanus"], now), undefined, "nothing on the claimer's surfaces");
	assert.equal(oldestOn([job("1|5", "nauvis", now - 500)], ["nauvis"], now), undefined, "younger than 1 s waits");
});

test("the subscribed surfaces: those some instance has stations on, sorted (spec §8)", () => {
	assert.deepEqual(subscribedSurfaces([
		status(1, { nauvis: 2, gleba: 0 }), status(2, { gleba: 1 }), status(3, { fulgora: 4 }, true), status(4, {}),
	]), ["gleba", "nauvis"], "gleba from instance 2 only; a deleted instance's stations don't count");
	assert.deepEqual(subscribedSurfaces([]), []);
});

test("an instance's station status: its stations by surface name, a surface with none dropped (spec §8)", () => {
	const s = stationStatus(7, { nauvis: 2, gleba: 0 }, 5);
	assert.deepEqual(s, { id: "instance:7", updatedAtMs: 5, isDeleted: false, instanceId: 7, stations: { nauvis: 2 } });
	assert.deepEqual(subscribedSurfaces([s, stationStatus(8, { gleba: 0 }, 6)]), ["nauvis"]);
});

test("stationsFromIpc: Lua's empty table arrives as [] and means no stations", () => {
	assert.deepEqual(stationsFromIpc([]), {});
	assert.deepEqual(stationsFromIpc({ nauvis: 2 }), { nauvis: 2 });
});
