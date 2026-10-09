# ctron_plugin (v2)

Constructron-Continued across Clusterio instances: a controller job pool by surface, and jobs that ride Universal Edges
v2's vehicle crossings, hop by hop. Spec: `docs/superpowers/specs/2026-10-09-constructron-v2-design.md`.

- **`module/` forks Constructron-Continued's runtime** (`control.lua` and `script/`). **Runtime synced to CC v2.1.0.**
  It runs only where the Constructron-Continued mod is loaded; CC itself switches off under Universal Edges.
- **Re-sync** (spec §9.1, D-2), for each CC release: diff CC's tags (`<synced tag>..<new tag>`, over `control.lua` and
  `script/`), apply each change here by hand, update the tag above and `CC` in `devcluster/src/build.ts`, and run
  `./dev test game`. Keep the fork's deltas: require paths `modules/ctron_plugin/…`; events through the module's
  `events` and `on_nth_tick` tables, never `script.on_event`; the pool (`job_processor.lua`, `clusterio_handler.lua`,
  the station hook); the settings sync; worker-less jobs; and v2's lines, each marked `-- v2 (spec §n)`.
- **This repo's own Lua** sits beside the fork: `script/border_core.lua`, `border.lua`, `crossing.lua`, `trace.lua`.
- **`cc/b1-ue-barrier.patch`** is the change to CC's `data-final-fixes.lua` this needs (CC 2.1.1); the game tests apply
  it to CC v2.1.0.
