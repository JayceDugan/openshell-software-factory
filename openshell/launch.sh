#!/usr/bin/env bash
# Launch a persona sandbox: persona.json -> `openshell sandbox create ...`
#
#   ./launch.sh <persona> [overrides] [-- extra agent args]
#
# Overrides:
#   --dry-run            print the exact command, run nothing (read it before trusting it)
#   --mount <host-path>  bind-mount this host directory at /sandbox/work instead of persona.mount_default
#   --no-mount           omit the bind mount entirely (matches policies/strict.yaml intent)
#   --ro                 mount read-only regardless of what the persona asks for
#   --policy <file>      override the persona's policy file
#   --provider <id>      add a provider (repeatable, on top of persona.providers)
#   --no-provider        drop all providers
#   --name <name>        sandbox name (default: persona name)
#   --keep               keep the sandbox after the agent exits (default: --no-keep)
#   --env K=V            pass through an env var flag (repeatable)
#   --list               list available personas and exit
#
# Example alias for ~/.zshrc (replaces the hand-written pi() function):
#   agent() { ~/project/openshell-project/launch.sh "$1" --mount "${2:-$PWD}"; }

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

json_get() { # <file> <key> -> string; exits 1 if absent
  local mf="$1"
  [[ -f "$mf" ]] || { echo "missing $mf" >&2; return 1; }
  if command -v node >/dev/null 2>&1; then
    node -e 'const p=require(process.argv[1]);const v=p[process.argv[2]];if(v===undefined)process.exit(1);process.stdout.write(typeof v==="string"?v:JSON.stringify(v))' "$mf" "$2"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys;p=json.load(open(sys.argv[1]));v=p.get(sys.argv[2]);sys.exit(1) if v is None else sys.stdout.write(v if isinstance(v,str) else json.dumps(v))' "$mf" "$2"
  else
    echo "need node or python3 to read persona manifests" >&2; return 1
  fi
}

json_list() { # <file> <key> -> one entry per line ("" if missing/empty)
  local mf="$1" key="$2"
  [[ -f "$mf" ]] || return 0
  if command -v node >/dev/null 2>&1; then
    node -e 'const p=require(process.argv[1]);(p[process.argv[2]]||[]).forEach(v=>console.log(v))' "$mf" "$key"
  else
    python3 -c 'import json,sys;[print(v) for v in (json.load(open(sys.argv[1])).get(sys.argv[2]) or [])]' "$mf" "$key"
  fi
}

list_personas() {
  for mf in "$ROOT"/personas/*/persona.json; do
    [[ -f "$mf" ]] || continue
    local dir; dir="$(basename "$(dirname "$mf")")"
    printf '%-24s %s\n' "$dir" "$(json_get "$mf" display_name 2>/dev/null || echo '-')"
  done
}

[[ $# -gt 0 ]] || { sed -n '2,26p' "$0"; exit 1; }
case "${1:-}" in
  --list) list_personas; exit 0 ;;
  -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
esac

PERSONA="$1"; shift

MF="$ROOT/personas/$PERSONA/persona.json"
[[ -f "$MF" ]] || { echo "no persona manifest: $MF" >&2; list_personas >&2; exit 1; }

IMAGE="$(json_get "$MF" image)"
POLICY="$(json_get "$MF" policy)"
LAUNCH_CMD="$(json_get "$MF" launch_cmd)"
SANDBOX_NAME="$PERSONA"
MOUNT_SOURCE="$(json_get "$MF" mount_default 2>/dev/null || true)"
MOUNT_RO="$(json_get "$MF" mount_read_only 2>/dev/null || echo false)"

DRY_RUN=0; DO_MOUNT=1; EXTRA_PROVIDERS=(); EXTRA_ENV=(); KEEP_FLAG="--no-keep"; NO_PROVIDER=0  # keeping is openshell 0.1.1 default; there is no --keep flag; EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --mount) MOUNT_SOURCE="${2:?--mount needs a host path}"; shift 2 ;;
    --no-mount) DO_MOUNT=0; shift ;;
    --ro) MOUNT_RO=true; shift ;;
    --policy) POLICY="${2:?--policy needs a file}"; shift 2 ;;
    --provider) EXTRA_PROVIDERS+=("$2"); shift 2 ;;
    --no-provider) NO_PROVIDER=1; shift ;;
    --name) SANDBOX_NAME="$2"; shift 2 ;;
    --keep) KEEP_FLAG=""; shift ;;
    --env) EXTRA_ENV+=("$2"); shift 2 ;;
    --) shift; EXTRA_ARGS=("$@"); break ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------- compose the command ----------
CMD=(openshell sandbox create --name "$SANDBOX_NAME" --from "$IMAGE")

if [[ -n "$POLICY" && "$POLICY" != "none" ]]; then
  [[ -f "$ROOT/$POLICY" ]] || { echo "policy not found: $ROOT/$POLICY" >&2; exit 1; }
  CMD+=(--policy "$ROOT/$POLICY")
fi

if [[ $NO_PROVIDER == 0 ]]; then
  while IFS= read -r p; do [[ -n "$p" ]] && CMD+=(--provider "$p"); done < <(json_list "$MF" providers)
  for p in "${EXTRA_PROVIDERS[@]:-}"; do [[ -n "$p" ]] && CMD+=(--provider "$p"); done
fi

# --env K=V passed through as two separate argv entries (one joined string would be one flag)
for kv in "${EXTRA_ENV[@]:-}"; do [[ -n "$kv" ]] && CMD+=(--env "$kv"); done
[[ -n "$KEEP_FLAG" ]] && CMD+=("$KEEP_FLAG")

if [[ "$POLICY" == *strict* && $DO_MOUNT == 1 && -n "$MOUNT_SOURCE" ]]; then
  echo "note: policies/strict.yaml assumes NO host mount - add --no-mount to match it" >&2
fi

# ---------- bind mount (needs [openshell.drivers.podman] enable_bind_mounts = true) ----------
if [[ $DO_MOUNT == 1 && -n "$MOUNT_SOURCE" ]]; then
  # "." in persona.json means "whatever directory I ran this from", like the old alias.
  # Podman bind sources must be absolute.
  case "$MOUNT_SOURCE" in
    .) MOUNT_SOURCE="$PWD" ;;
    ~*) MOUNT_SOURCE="${HOME}${MOUNT_SOURCE:1}" ;;
    /*) : ;;
    *) MOUNT_SOURCE="$PWD/$MOUNT_SOURCE" ;;
  esac
  [[ -e "$MOUNT_SOURCE" ]] || { echo "mount source does not exist: $MOUNT_SOURCE" >&2; exit 1; }
  DRIVER_JSON="$(MOUNT_SOURCE="$MOUNT_SOURCE" MOUNT_RO="$MOUNT_RO" node -e '
    const ro = String(process.env.MOUNT_RO).toLowerCase() === "true";
    process.stdout.write(JSON.stringify({ podman: { mounts: [{ type: "bind", source: process.env.MOUNT_SOURCE, target: "/sandbox/work", read_only: ro }] } }));' 2>/dev/null \
  || MOUNT_SOURCE="$MOUNT_SOURCE" MOUNT_RO="$MOUNT_RO" python3 -c '
    import json, os, sys
    ro = os.environ.get("MOUNT_RO", "false").lower() == "true"
    sys.stdout.write(json.dumps({"podman": {"mounts": [{"type": "bind", "source": os.environ["MOUNT_SOURCE"], "target": "/sandbox/work", "read_only": ro}]}}))')"
  CMD+=(--driver-config-json "$DRIVER_JSON")
fi

CMD+=(--)
# OpenShell ignores the image WORKDIR and starts the agent in /sandbox (= $HOME); omp then
# auto-switches to a temp dir. `sandbox create` has no --workdir, so cd via a tiny shim.
CMD+=(sh -c 'cd /sandbox/work && exec "$@"' sh)
read -ra LAUNCH_ARRAY <<< "$LAUNCH_CMD"   # allows launch_cmd to be "pi" or "omp --profile review"
CMD+=("${LAUNCH_ARRAY[@]}")
[[ -n "${EXTRA_ARGS[*]:-}" ]] && CMD+=("${EXTRA_ARGS[@]}")   # bash 3.2: empty array is "unbound" under set -u

# ---------- print, then run ----------
printf '%s' "${CMD[0]}"
for a in "${CMD[@]:1}"; do printf ' %q' "$a"; done
printf '\n'
if [[ $DRY_RUN == 1 ]]; then
  echo "(dry run: nothing executed)"
  exit 0
fi

exec "${CMD[@]}"
