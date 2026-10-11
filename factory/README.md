# factory

The LangGraph outer loop of the software factory. Everything runs in OpenShell sandboxes except
the launcher, which is the one trusted host process.

```
host                                          OpenShell sandboxes
────                                          ───────────────────
browser ── Studio ──► localhost:2024 ──fwd──► orchestrator (langgraph dev, src/graph.ts)
                                                 │  egress: launcher provider only
launcher (Rust, 127.0.0.1:8787) ◄────────────────┘  host.openshell.internal:8787
   │  mTLS to the gateway (holds ~/.config/openshell/.../mtls)
   └──► gateway ──► persona sandbox (pi-general-dev, ...) runs one headless task, then is deleted
```

## Run it

```bash
# 1. Once: token + provider (the token lives in the gateway, never in the orchestrator sandbox)
mkdir -p ~/.config/factory && (umask 077; openssl rand -hex 32 > ~/.config/factory/launcher.token)
make -C openshell/providers update-launcher
FACTORY_LAUNCHER_TOKEN=$(cat ~/.config/factory/launcher.token) \
  openshell provider create --name launcher --type launcher --credential FACTORY_LAUNCHER_TOKEN

# 2. Once, and after changing package.json: build the orchestrator image (npm runs here)
make -C factory/orchestrator image

# 3. Terminal A: the launcher
cd factory/launcher && cargo run

# 4. Terminal B: the orchestrator; then open the Studio URL it prints
make -C factory/orchestrator dev
```

Studio is LangSmith's hosted UI talking to `localhost:2024` from your browser, so it asks for a
(free) LangSmith login. Tracing is off (`LANGSMITH_TRACING=false`); the sandbox has no LangSmith
egress either way. Without Studio, drive it over HTTP:

```bash
curl -s localhost:2024/runs/wait -H 'content-type: application/json' \
  -d '{"assistant_id":"factory","input":{"task":"What is 17 * 23? Reply with only the number."}}'
```

## Launcher API

All routes need `Authorization: Bearer <token>`.

| Route | Does |
|---|---|
| `GET /health` | Gateway health |
| `GET /personas` | Personas whose harness has `headless_args` in `openshell/harnesses/<h>.json` (pi only; omp's headless flags are unverified) |
| `POST /run {persona, task, timeout_secs?}` | Create sandbox from `persona.json` (image, policy, providers), exec the agent headless in `/sandbox/work`, delete the sandbox, return `exit_code`/`stdout`/`stderr` |

Callers pick a persona and a task, nothing else: policy, providers and mounts are never taken from
the request. Agent sandboxes get **no host mount**; work happens inside the sandbox.

## Gotchas found while building this

- The SDK's `OpenShellClient::connect` has no mTLS; the launcher builds the tonic channel itself
  and uses `from_parts`. Sandbox names are capped at 19 characters.
- Host services are `host.openshell.internal`, not `host.containers.internal` (direct connects
  to the latter get EPERM).
- npm fetches scoped packages as `@scope%2fname`; the npm provider needs `allow_encoded_slash`.
- Long `npm install`s inside a sandbox fail with EACCES: OpenShell's synthetic DNS mappings live
  at most 30s and npm reuses addresses past that. Hence deps are installed at image build time.
- `--forward` can't be combined with `--no-keep`; `run.sh` deletes the sandbox on exit itself.
  The dev server must bind `127.0.0.1` (it defaults to `::1`, which the forward doesn't reach).
- ~10s after a sandbox starts, its first settings poll reloads the network policy and kills
  connections opened before it ("policy generation is stale"). `run.sh` waits 15s before
  starting the dev server so the first launcher call doesn't die.
- File-change events don't cross the podman machine mount, so `run.sh` sets
  `CHOKIDAR_USEPOLLING=true`; host edits to `src/` then hot-reload the dev server.
- `/run` sends nothing until the agent finishes, so `launcher.ts` uses an undici `Agent` with
  timeouts off (fetch's default 300s headers timeout would cut long runs).
- If the caller disconnects mid-run, the launcher still deletes the sandbox (the job is a
  spawned task, not the request future).
