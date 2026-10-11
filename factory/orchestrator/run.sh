#!/usr/bin/env bash
# Run the LangGraph orchestrator inside an OpenShell sandbox. Nothing here touches host npm.
#
#   ./run.sh               `langgraph dev` with Studio's API on localhost:2024
#   ./run.sh -- <cmd...>   one-off command in the sandbox, e.g. ./run.sh -- npx tsc --noEmit
#
# Dependencies are baked into the image (`make image`); only src/ and the config files are
# bind-mounted, so edits on the host hot-reload in the dev server. The only egress is the
# launcher (host.openshell.internal:8787), which must already be running on the host:
#   cd factory/launcher && cargo run
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$HERE/../../openshell"
NAME="orch-$$"
bind() { printf '{"type":"bind","source":"%s/%s","target":"/sandbox/work/%s","read_only":%s}' "$HERE" "$1" "$1" "$2"; }
MOUNT="{\"podman\":{\"mounts\":[$(bind src true),$(bind langgraph.json true),$(bind tsconfig.json true)]}}"

# The graph is useless without the launcher, so check it before starting anything. Without a
# token it answers 401; no answer at all (000) means it isn't running.
if [[ "$(curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:8787/health)" != "401" ]]; then
  echo "factory launcher is not running on 127.0.0.1:8787. Start it first:" >&2
  echo "  cd $(cd "$HERE/../launcher" && pwd) && cargo run" >&2
  exit 1
fi

CMD=(openshell sandbox create --name "$NAME" --from factory-orchestrator:local
  --policy "$FLEET/policies/dev.yaml" --provider launcher --env LANGSMITH_TRACING=false --env CHOKIDAR_USEPOLLING=true
  --driver-config-json "$MOUNT")

if [[ "${1:-}" == "--" ]]; then
  shift
  CMD+=(--no-keep --no-tty -- sh -c 'cd /sandbox/work && exec "$@" </dev/null' sh "$@")
else
  # ~10s after start the sandbox's first settings poll reloads its network policy
  # (provider_env_changed) and kills connections opened before it, so the first launcher call
  # would fail with "policy generation is stale". Start the server after that has happened.
  CMD+=(--forward 2024 -- sh -c 'echo "waiting 15s for the sandbox policy to settle..."; sleep 15
cd /sandbox/work && exec npx langgraphjs dev --host 127.0.0.1 --port 2024 --no-browser')
fi

# --forward can't be combined with --no-keep, so delete the sandbox ourselves on any exit
# (Ctrl-C, closing the terminal, or the dev server dying).
trap 'openshell sandbox delete "$NAME" >/dev/null 2>&1' EXIT
trap 'exit 130' INT TERM
trap 'exit 129' HUP
"${CMD[@]}"
