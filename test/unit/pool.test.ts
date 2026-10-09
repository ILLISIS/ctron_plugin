import { test } from "node:test";
import assert from "node:assert/strict";
import type { ConstructronJobValue, InstanceServiceStationStatus } from "../../messages.js";
import { cargoOffers, claimByKey, oldestOn, stationsFromIpc, stationStatus, subscribedSurfaces } from "../../pool.js";

const job = (id: string, surfaceName: string, updatedAtMs: number, isDeleted = false): ConstructronJobValue => (
	{ id, updatedAtMs, isDeleted, lastInstanceId: 1, surfaceName, jobType: "construction", job: {} }
);
const cargo = (id: string, surfaceName: string, instanceId: number, isDeleted = false): ConstructronJobValue => ({
	id, updatedAtMs: 0, isDeleted, lastInstanceId: instanceId, surfaceName, jobType: "cargo",
	job: { task_positions: [{ x: 1, y: 2 }], required_items: { "iron-plate": { normal: 20 } } },
});
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

test("a blind claim never takes a cargo request", () => {
	const now = 100_000;
	assert.equal(oldestOn([cargo("2|1", "nauvis", 1), job("1|2", "nauvis", 5)], ["nauvis"], now)?.id, "1|2");
	assert.equal(oldestOn([cargo("2|1", "nauvis", 1)], ["nauvis"], now), undefined);
});

test("offers: open cargo requests on the asker's surfaces, not its own", () => {
	const jobs = [
		cargo("1|1", "nauvis", 1), cargo("1|2", "gleba", 1), cargo("2|1", "nauvis", 2), cargo("1|3", "nauvis", 1, true),
	];
	assert.deepEqual(cargoOffers(jobs, ["nauvis"], 2), [{
		key: "1|1", surfaceName: "nauvis", position: { x: 1, y: 2 }, items: { "iron-plate": { normal: 20 } },
	}]);
});

test("a split remainder published by B for requester A is offered to B, not to A", () => {
	const rest = { ...cargo("2|5", "nauvis", 2),
		job: { requester: 1, task_positions: [{ x: 1, y: 2 }], required_items: {} } };
	assert.equal(cargoOffers([rest], ["nauvis"], 2).length, 1);
	assert.equal(cargoOffers([rest], ["nauvis"], 1).length, 0);
});

test("a claim by key finds that entry while it is open", () => {
	const jobs = new Map([cargo("1|1", "nauvis", 1), cargo("1|3", "nauvis", 1, true)].map(j => [j.id, j]));
	assert.equal(claimByKey(jobs, "1|1")?.id, "1|1");
	assert.equal(claimByKey(jobs, "9|9"), undefined);
	assert.equal(claimByKey(jobs, "1|3"), undefined);
});
