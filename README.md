# ctron_plugin (PoC)

Clusterio plugin that shows a per-instance count of **player-built** `roboport` entities on the controller Web UI.

## What it does
- Factorio mod detects `on_built_entity` for `roboport` (player-built only).
- Instance plugin forwards event to controller.
- Controller keeps an in-memory per-instance counter and broadcasts updates to Web UI subscribers.
- Web UI shows a new page: **Roboport counts**.

## Notes
- Proof-of-concept: counts reset when controller restarts.
