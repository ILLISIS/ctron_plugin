import { test } from "node:test";
import assert from "node:assert/strict";
import loadInstancePlugin, { pendingReplies } from "../../instance.js";
import { RouteRequest, StockQueryRequest, TileDeltaEvent, UiWatchEvent } from "../../messages.js";
import { DOWN_SAMPLES, UP_SAMPLES } from "./samples.js";
import { fakeInstance, settle } from "./fakes.js";

test("a reply settles its wait once; a repeated or unknown reply is dropped (Review Focus 2)", async () => {
	const replies = pendingReplies(1000);
	const wait = replies.wait("x.1");
	assert.equal(replies.settle("x.1", { r: [] }), true);
	assert.deepEqual(await wait, { r: [] });
	assert.equal(replies.settle("x.1", { r: [] }), false, "repeated");
	assert.equal(replies.settle("x.9", {}), false, "unknown");
});

test("a wait without a reply rejects after its timeout; a late reply is dropped (Review Focus 2)", async () => {
	const replies = pendingReplies(20);
	await assert.rejects(replies.wait("x.2"), /no reply/);
	assert.equal(replies.settle("x.2", {}), false);
});

test("a stock query goes to Lua with a fresh req; its reply parts merge and resolve it once (R-151)", async () => {
	const f = fakeInstance();
	await loadInstancePlugin(f.context);
	const q = DOWN_SAMPLES["ct.stock.query"].q;
	const answer = f.handlers.get(StockQueryRequest)!(new StockQueryRequest({ q }));
	await settle();
	const [sent] = f.down().filter(m => m.type === "ct.stock.query");
	assert.match(sent.payload.req, /^[0-9a-f]+\.\d+$/);
	assert.deepEqual(sent.payload.q, q);
	const rec = (qid: string) => ({ qid, sids: ["1.17"], cover: true });
	await f.up([
		{ type: "ct.stock.reply", payload: { req: "other.1", part: 1, parts: 1, r: [rec("x")] } },
		{ type: "ct.stock.reply", payload: { req: sent.payload.req, part: 1, parts: 2, r: [rec("q1")] } },
	]);
	let done = false;
	void answer.then(() => { done = true; });
	await settle();
	assert.equal(done, false, "not resolved before the last part");
	await f.up([{ type: "ct.stock.reply", payload: { req: sent.payload.req, part: 2, parts: 2, r: [rec("q2")] } }]);
	assert.deepEqual(await answer, { r: [rec("q1"), rec("q2")] });
});

test("a stock reply part with no records arrives as {} and still resolves (R-18)", async () => {
	const f = fakeInstance();
	await loadInstancePlugin(f.context);
	const answer = f.handlers.get(StockQueryRequest)!(new StockQueryRequest({ q: DOWN_SAMPLES["ct.stock.query"].q }));
	await settle();
	const [sent] = f.down().filter(m => m.type === "ct.stock.query");
	await f.up([{ type: "ct.stock.reply", payload: { req: sent.payload.req, part: 1, parts: 1, r: {} } }]);
	assert.deepEqual(await answer, { r: [] });
});

test("Lua's ct.delta reaches the controller as a TileDeltaEvent, payload unchanged", async () => {
	const f = fakeInstance();
	await loadInstancePlugin(f.context);
	await f.up([{ type: "ct.delta", payload: UP_SAMPLES["ct.delta"] }]);
	assert.equal(f.sent.length, 1);
	assert.ok(f.sent[0] instanceof TileDeltaEvent);
	assert.deepEqual((f.sent[0] as TileDeltaEvent).payload, UP_SAMPLES["ct.delta"]);
});

test("a route ask goes down with Lua's req: the route, none, or nothing on error", async () => {
	const route = DOWN_SAMPLES["ct.route.reply"].route;
	// Made on demand: a rejected promise made up front would count as unhandled before its turn comes.
	const answers = [
		() => Promise.resolve({ route }), () => Promise.resolve({ route: null }),
		() => Promise.reject(new Error("down")),
	];
	const f = fakeInstance({ route: () => answers.shift()!() });
	await loadInstancePlugin(f.context);
	for (const req of ["r.1", "r.2", "r.3"]) {
		await f.up([{ type: "ct.route.ask", payload: { ...UP_SAMPLES["ct.route.ask"], req } }]);
	}
	await settle();
	assert.deepEqual(f.down().filter(m => m.type === "ct.route.reply").map(m => m.payload), [
		{ req: "r.1", route },
		{ req: "r.2" },
	]);
	assert.equal(f.warnings().length, 1, "the failed request is logged");
});

test("R-137: a ct.delta after an unanswered ct.route.ask is relayed at once", { timeout: 5000 }, async () => {
	const f = fakeInstance({ route: () => new Promise(() => { }) });
	await loadInstancePlugin(f.context);
	await f.up([
		{ type: "ct.route.ask", payload: UP_SAMPLES["ct.route.ask"] },
		{ type: "ct.delta", payload: UP_SAMPLES["ct.delta"] },
	]);
	assert.ok(f.sent[0] instanceof RouteRequest);
	assert.ok(f.sent[1] instanceof TileDeltaEvent, "the delta went on while the route request waits");
});

test("R-143: a send that throws SessionLost is caught; later messages and requests are still tried", async () => {
	const f = fakeInstance({ lost: true });
	await loadInstancePlugin(f.context);
	await f.up([
		{ type: "ct.delta", payload: UP_SAMPLES["ct.delta"] },
		{ type: "ct.route.ask", payload: UP_SAMPLES["ct.route.ask"] },
		{ type: "ct.job.event", payload: UP_SAMPLES["ct.job.event"] },
	]);
	await settle();
	assert.equal(f.sent.length, 3, "each message was tried");
	assert.deepEqual(f.down(), [], "no reply went down for the lost route request");
	assert.equal(f.warnings().length, 2, "one for the sends (rate-limited), one for the failed route request");
});

test("on connect: a snapshot request, each open watch again whole (not a closed one), link up; resume up; drop down",
	async () => {
		const f = fakeInstance();
		await loadInstancePlugin(f.context);
		await f.up([
			{ type: "ct.ui.watch", payload: { surface: "nauvis", tile: 1, expand: "1|construction", on: true } },
			{ type: "ct.ui.watch", payload: { surface: "nauvis", on: true } },
			{ type: "ct.ui.watch", payload: { surface: "gleba", on: true } },
			{ type: "ct.ui.watch", payload: { on: false, surface: "gleba" } },
		]);
		f.sent.length = 0;
		await f.fire("controllerConnectionEvent", "connect");
		await settle();
		assert.deepEqual(f.sent.map(m => (m as UiWatchEvent).payload), [
			{ surface: "nauvis", tile: 1, expand: "1|construction", on: true },
			{ surface: "nauvis", on: true },
		]);
		assert.deepEqual(f.down().map(m => [m.type, m.payload]),
			[["ct.snapshot.request", {}], ["ct.ui.link", { up: true }]]);
		await f.fire("controllerConnectionEvent", "drop");
		await f.fire("controllerConnectionEvent", "resume");
		await settle();
		assert.deepEqual(f.down().slice(2).map(m => m.payload), [{ up: false }, { up: true }]);
		// A graceful controller restart goes close, then connect, and never drop: link down, then up and the watches.
		f.sent.length = 0;
		await f.fire("controllerConnectionEvent", "close");
		await f.fire("controllerConnectionEvent", "connect");
		await settle();
		assert.deepEqual(f.down().slice(4).map(m => [m.type, m.payload]), [
			["ct.ui.link", { up: false }], ["ct.snapshot.request", {}], ["ct.ui.link", { up: true }],
		]);
		assert.equal(f.sent.length, 2, "both open watches again");
	});

test("the start hook asks Lua for a snapshot", async () => {
	const f = fakeInstance();
	await loadInstancePlugin(f.context);
	await f.fire("start");
	await settle();
	assert.deepEqual(f.down().map(m => [m.type, m.payload]), [["ct.snapshot.request", {}]]);
});

test("R-143: a failing send on connect doesn't skip ct.ui.link, and logs one warning", async () => {
	const f = fakeInstance();
	await loadInstancePlugin(f.context);
	await f.up([
		{ type: "ct.ui.watch", payload: { surface: "a", on: true } },
		{ type: "ct.ui.watch", payload: { surface: "b", on: true } },
	]);
	f.opts.lost = true;
	await f.fire("controllerConnectionEvent", "connect");
	await settle();
	assert.deepEqual(f.down().map(m => m.type), ["ct.snapshot.request", "ct.ui.link"]);
	assert.equal(f.warnings().length, 1, "the two lost watches log once (rate-limited)");
});
