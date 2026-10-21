import { test } from "node:test";
import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { plugin } from "../../index.js";

// Compiled to dist/node/test/unit/; the plugin root is four levels up.
const pluginRoot = join(import.meta.dirname, "..", "..", "..", "..");
const readJson = async (file: string) => JSON.parse(await readFile(join(pluginRoot, file), "utf8"));

test("the declaration names the plugin, and its entrypoints exist and export a default function (R-113)", async () => {
	assert.equal(plugin.name, "ctron_pluginv2");
	for (const entry of [plugin.controllerEntrypoint, plugin.instanceEntrypoint]) {
		assert.ok(entry, "entrypoint declared");
		await access(join(pluginRoot, entry));
		const loaded = await import(pathToFileURL(join(pluginRoot, entry)).href);
		assert.equal(typeof loaded.default, "function", entry);
	}
});

test("module.json carries the name and version the save patcher validates, and depends on UE", async () => {
	const moduleJson = await readJson(join("module", "module.json"));
	const pkg = await readJson("package.json");
	assert.equal(moduleJson.name, plugin.name);
	assert.equal(moduleJson.version, pkg.version);
	assert.equal(moduleJson.dependencies.universal_edges, "*");
});
