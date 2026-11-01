# ctron_pluginv2

Constructrons across a Clusterio cluster as one world. Each instance finds work (ghosts, deconstruction and upgrade
marks, damage, nests, cargo needs) and runs it; the controller holds one list of all work, constructrons and service
stations, and gives each job to the best constructron anywhere. Constructrons cross instances on Universal Edges'
vehicle crossings along routes from a cluster portal graph.

Players can call a constructron from the panel beside their character screen. The nearest free one loads what their
logistic requests are missing at a service station, follows them (to other instances too), hands it over with its
robots, takes their trash, and goes back to the station. A call waits for a constructron to finish its job; it ends
when everything is handed over, when the player cancels or dies, or after 5 minutes off the cluster.

It replaces `ctron_plugin` (this repo's `master` branch): a new runtime written from scratch. The Constructron-Continued
mod supplies the prototypes, graphics and locale, and switches its own runtime off under Universal Edges. The design
documents, which code comments cite (§ sections and R-numbers), live in the clusterio-v2 integration repo, which isn't
public.

## Requirements

- Clusterio 2.1, built from source: until 2.1 is tagged, a checkout of `master`. The plugin builds inside Clusterio's
  pnpm workspace. It doesn't load on 2.0.x.
- Node 22 or later, and pnpm at the version in Clusterio's `packageManager`.
- Universal Edges v2 (Lua API version 1), cloned next to it (`external_plugins/universal_edges`) and loaded on every
  instance that loads this plugin.
- Factorio 2.1.7 or later.
- The Constructron-Continued mod 2.1.1 in the instances' mod pack (or 2.1.0 with `cc/b1-ue-barrier.patch`). Without it
  the save module loads and does nothing.
- `lua5.2` and `luacheck` (tests and lint).
- Never on the same instance as the old `ctron_plugin`: remove that from the plugin lists, or set
  `ctron_plugin.load_plugin false` on every instance that runs this one.

## Install

In a Clusterio checkout:

```sh
git clone https://github.com/clusterio/universal_edges.git external_plugins/universal_edges
git clone -b v2 https://github.com/ILLISIS/ctron_plugin.git external_plugins/ctron_pluginv2
pnpm install
pnpm build
pnpm run -r --if-present prepare
```

`prepare` compiles the plugin and bundles its web page. Add the plugin to the controller's plugin list with
`npx clusteriocontroller plugin add ./external_plugins/ctron_pluginv2` and to each host's with
`npx clusteriohost plugin add ./external_plugins/ctron_pluginv2`, from the checkout (a path needs the `./`).

Constructrons and service stations join when they are built. Ones already on a map when the plugin is first loaded
there are not picked up: place them again.

## Test and lint

Run these from inside the Clusterio checkout, where Oxlint is installed:

```sh
pnpm --filter ctron_pluginv2 run test   # TypeScript and Lua unit tests; run prepare first
pnpm --filter ctron_pluginv2 run lint   # Oxlint with Clusterio's rules, and luacheck
```

Game tests (headless Factorio, the `*_game_test.lua` files), multi-instance end-to-end tests and the performance bench
run from the clusterio-v2 integration repo.

## Licence

See `LICENSE`.
