# ctron_plugin (v2)

Constructron-Continued across Clusterio instances: a controller job pool by surface, and jobs that ride Universal Edges
v2's vehicle crossings, hop by hop. Its design documents, which code comments cite by section (§), live in the
clusterio-v2 integration repo, which isn't public.

- **`module/` forks Constructron-Continued's runtime** (`control.lua` and `script/`). **Runtime synced to CC v2.1.0.**
  It runs only where the Constructron-Continued mod is loaded; CC itself switches off under Universal Edges.
- **Re-sync** (spec §9.1, D-2), for each CC release: diff CC's tags (`<synced tag>..<new tag>`, over `control.lua` and
  `script/`), apply each change here by hand, update the tag above and `CC` in the integration repo's
  `devcluster/src/build.ts`, and run its `./dev test game`. Keep the fork's deltas: require paths
  `modules/ctron_plugin/…`; events through the module's `events` and `on_nth_tick` tables, never `script.on_event`; the
  pool (`job_processor.lua`, `clusterio_handler.lua`, the station hook); the settings sync; worker-less jobs; and v2's
  lines, each marked `-- v2 (spec §n)`.
- **This repo's own Lua** sits beside the fork: `script/border_core.lua`, `border.lua`, `crossing.lua`, `trace.lua`.
- **`cc/b1-ue-barrier.patch`** is the change to CC's `data-final-fixes.lua` this needs (CC 2.1.1); the game tests apply
  it to CC v2.1.0.

## Requirements

- Clusterio built from source, master at commit `4c0c89c` or later. 2.0.0-alpha.27, the latest release, lacks APIs this uses, and before `4c0c89c` the plugins' web pages don't load.
- Node 22 or later, and pnpm at the version in Clusterio's `packageManager`.
- Universal Edges v2, cloned next to it (`external_plugins/universal_edges`).
- `zip` (the mod build), and `lua5.2` and `luacheck` (tests and lint).
- The Constructron-Continued mod 2.1.1 (2.1.0 with `cc/b1-ue-barrier.patch`).

## Install

In a Clusterio checkout:

```sh
git clone -b v2 https://github.com/clusterio/universal_edges.git external_plugins/universal_edges
git clone https://github.com/ILLISIS/ctron_plugin.git external_plugins/ctron_plugin
pnpm install
pnpm build
pnpm run -r --if-present prepare
```

`prepare` compiles the plugin and bundles its web page. Add the plugin to the controller's plugin list with `npx clusteriocontroller plugin add <path to external_plugins/ctron_plugin>` and to each host's with `npx clusteriohost plugin add <that path>`.

## Test and lint

Run these from inside the Clusterio checkout, where ESLint is installed:

```sh
pnpm --filter ctron_plugin run test   # TypeScript and Lua unit tests; run prepare first
pnpm --filter ctron_plugin run lint   # ESLint with Clusterio's rules, and luacheck
```

Game tests (headless Factorio, the `*_game_test.lua` files) and multi-instance end-to-end tests run from the clusterio-v2 integration repo, which isn't public. The design documents that code comments cite by section (§) live there too.
