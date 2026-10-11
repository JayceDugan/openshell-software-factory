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

## Langfuse (tracing)

Self-hosted Langfuse runs on podman from the upstream compose file in the `langfuse-source`
submodule (pinned to a release tag, unmodified). `factory/langfuse/` only layers local changes on
top: telemetry off, GHCR images (Docker Hub rate-limits anonymous pulls), and Postgres on host
port 5433 (5432 is often taken). Upstream default passwords are kept: it's local dev only.

```bash
make -C factory/langfuse up          # http://localhost:3000
make -C factory/langfuse logs | ps | down
make -C factory/langfuse upgrade TAG=v4.57.0
```

First time: sign up at http://localhost:3000, create an org and project, create API keys, and
store them in 1Password. Then point the `langfuse` provider at the local instance (sandboxes
reach it as `host.openshell.internal:3000`):

```bash
LANGFUSE_PUBLIC_KEY=$(op read "op://<vault>/<item>/public key") \
LANGFUSE_SECRET_KEY=$(op read "op://<vault>/<item>/secret key") \
LANGFUSE_BASE_URL=http://host.openshell.internal:3000 \
LANGFUSE_HOST_URL=http://host.openshell.internal:3000 \
  openshell provider update langfuse --credential LANGFUSE_PUBLIC_KEY --credential LANGFUSE_SECRET_KEY \
    --credential LANGFUSE_BASE_URL --credential LANGFUSE_HOST_URL
```

The orchestrator sandbox gets the `langfuse` provider, and `src/tracing.ts` traces every graph
run (one span per node) through `@langfuse/langchain`'s `CallbackHandler` and OpenTelemetry. The
provider's `LANGFUSE_BASE_URL` is a placeholder inside the sandbox, so the endpoint comes from
`FACTORY_LANGFUSE_URL` (default `http://host.openshell.internal:3000`). Langfuse v4 runs in
events-only mode, so `/api/public/traces` is gone; use the UI (Tracing) to look at runs.

The agents trace themselves with the [pi-langfuse](https://pi.dev/packages/pi-langfuse) extension
(a `pi-agent` trace per prompt: turns, LLM generations, tool calls), baked into every persona
image: `pi install npm:pi-langfuse` for pi, and npm + `omp plugin link` for omp (`omp install`
needs bun). It reads the provider's `LANGFUSE_BASE_URL` placeholder as its host, so both agent
wrappers (`openshell/launch.sh` and the launcher's exec) replace a placeholder with
`http://host.openshell.internal:3000`. Its default privacy preset is `full-debug` (prompts, tool
I/O, system prompts); set `LANGFUSE_PRIVACY_PRESET` to capture less.

The two are linked by Langfuse session: the orchestrator uses the LangGraph thread id as its
trace's session and passes it to the launcher as `session_id`, which becomes
`pi --session-id <id>` (the harness's `session_id_args`). Langfuse > Sessions then shows a
thread's `factory` traces next to the `pi-agent` traces they started. (pi-langfuse always starts
a new root trace, so the agent can't nest under `runAgent` itself.)

## Launcher API

All routes need `Authorization: Bearer <token>`.

| Route | Does |
|---|---|
| `GET /health` | Gateway health |
| `GET /personas` | Personas whose harness has `headless_args` in `openshell/harnesses/<h>.json` (pi only; omp's headless flags are unverified) |
| `POST /run {persona, task, timeout_secs?, session_id?}` | Create sandbox from `persona.json` (image, policy, providers), exec the agent headless in `/sandbox/work`, delete the sandbox, return `exit_code`/`stdout`/`stderr` |

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
