# Remote Path Request Flow

End-to-end sequence for a cross-instance path request: a game instance exhausts local pathfinding retries and delegates to the dedicated pathworld instance.

```
Game Instance (Lua)                 Controller (TS)              Pathworld Instance (TS+Lua)
─────────────────────────────────────────────────────────────────────────────────────────────
pathfinder.request_remote_path()
  │  local retries exhausted
  │
  ├─ send_json("ctron_plugin:path_request", {...})
  │    [IPC: Lua → instance.ts]
  │
  ▼
handlePathRequestIPC()
  ├─ new CtronPathRequest(...)
  └─ sendTo("controller", ...)
       [IPC: instance → controller]
                                    │
                                    ▼
                             handlePathRequest()
                               ├─ find pathworld by instance name "pathworld"
                               ├─ new CtronForwardPathRequest(...)
                               └─ sendEvent(forward, pathworldId)
                                    [IPC: controller → pathworld instance]
                                                                    │
                                                                    ▼
                                                          handleForwardPathRequest()
                                                            ├─ build JSON payload
                                                            └─ sendRcon("ctron_plugin_pathworld_on_path_request(...)")
                                                                 [RCON → Factorio]
                                                                    │
                                                                    ▼
                                                          ctron_plugin_pathworld_on_path_request()
                                                            ├─ storage.is_pathworld = true
                                                            └─ table.insert(pathworld_request_queue, data)

                                                          [next on_nth_tick[90]]
                                                            │
                                                            ▼
                                                          pathfinder.process_pathworld_queue()
                                                            ├─ surface.request_path(build_path_params(data))
                                                            └─ storage.pathworld_pending[request_id] = {requesterId, sourceInstanceId}

                                                          [on_script_path_request_finished fires]
                                                            │
                                                            ▼
                                                          pathfinder.on_path_request_finished()
                                                            ├─ lookup pathworld_pending[event.id]
                                                            ├─ send_json("ctron_plugin:path_response", {path, ...})
                                                            └─ [IPC: pathworld Lua → instance.ts]
                                                                    │
                                                                    ▼
                                                          handlePathResponseIPC()
                                                            └─ sendTo("controller", CtronPathResponse)
                                    │
                                    ▼
                             handlePathResponse()
                               ├─ lookup sourceInstanceId
                               └─ sendEvent(CtronReturnPathResponse, sourceInstanceId)
                                    [IPC: controller → game instance]
  │
  ▼
handleReturnPathResponse()
  └─ sendRcon("ctron_plugin_on_path_response(...)")
       [RCON → Factorio]
  │
  ▼
ctron_plugin_on_path_response()
  └─ pathfinder.on_remote_path_response(decoded)
       ├─ lookup pathfinder_remote_requests[id]
       ├─ convert waypoints to Factorio path format
       └─ pathfinder.on_path_request_finished({id, path, ...})
            └─ job continues normally
```

## Timeout path

`expire_remote_path_requests()` runs on the game instance every 90 ticks. If no response
arrives within `REMOTE_PATH_TIMEOUT` (1800 ticks / 30 s), the entry is expired and
`on_remote_path_response` is called with `try_again_later = true`, which clears
`job.remote_path_requested` so the job retries on the next movement tick.
