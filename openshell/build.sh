#!/usr/bin/env bash
# Build harness images, then persona images (persona config is BAKED into the image).
#
#   ./build.sh                        build every persona under personas/
#   ./build.sh pi-flutter-dev omp-planner   build only these personas
#   ./build.sh --harnesses            rebuild harness images only
#   ./build.sh --dry-run              print the podman commands without building
#
# Build context is project/ so persona Containerfiles can COPY both shared/ assets
# and personas/<name>/payload. Persona layers sit on a cached harness image, so an
# AGENTS.md/skills edit costs seconds, not a full build.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONLY_HARNESS=0
DRY_RUN=0
PERSONAS=()

for arg in "$@"; do
  case "$arg" in
    --harnesses) ONLY_HARNESS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) PERSONAS+=("$arg") ;;
  esac
done

# ---------- manifest reader (JSON so a Go/Rust launcher can reuse it verbatim) ----------
json_get() { # <file> <key>
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

manifest_get() { # <persona-dir> <key>
  json_get "$ROOT/personas/$1/persona.json" "$2"
}

BUILT=" "   # space-delimited list (bash 3.2 on macOS has no associative arrays)
build_harness() { # <harness>
  local h="$1" image
  if [[ "$BUILT" == *" $h "* ]]; then return 0; fi
  [[ -f "$ROOT/harnesses/$h.json" ]] || { echo "no harness manifest: harnesses/$h.json" >&2; exit 1; }
  image="$(json_get "$ROOT/harnesses/$h.json" image)"
  echo "==> harness image $image  (images/$h/Containerfile)"
  if [[ $DRY_RUN == 1 ]]; then echo "    podman build -t $image -f $ROOT/images/$h/Containerfile $ROOT"; else podman build -t "$image" -f "$ROOT/images/$h/Containerfile" "$ROOT"; fi
  BUILT+="$h "
}

if [[ $ONLY_HARNESS == 1 ]]; then
  for h in "${ROOT}"/harnesses/*.json; do build_harness "$(basename "$h" .json)"; done
  exit 0
fi

if [[ ${#PERSONAS[@]} -eq 0 ]]; then
  for mf in "$ROOT"/personas/*/persona.json; do
    [[ -f "$mf" ]] && PERSONAS+=("$(basename "$(dirname "$mf")")")
  done
fi
[[ ${#PERSONAS[@]} -gt 0 ]] || { echo "no personas found under personas/" >&2; exit 1; }

for p in "${PERSONAS[@]}"; do
  [[ -f "$ROOT/personas/$p/Containerfile" ]] || { echo "SKIP $p: no personas/$p/Containerfile" >&2; continue; }
  harness="$(manifest_get "$p" harness)"
  image="$(manifest_get "$p" image)"
  policy="$(manifest_get "$p" policy)"
  [[ -f "$ROOT/$policy" ]] || echo "WARN $p: policy file $policy not found" >&2
  build_harness "$harness"
  echo "==> persona image $image  (personas/$p/Containerfile)"
  if [[ $DRY_RUN == 1 ]]; then echo "    podman build -t $image -f $ROOT/personas/$p/Containerfile $ROOT"; else podman build -t "$image" -f "$ROOT/personas/$p/Containerfile" "$ROOT"; fi
done

echo
echo "built. launch with: ./launch.sh <persona> --dry-run"
