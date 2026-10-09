# Agent fleet design: harness × persona × role

Goal: many agents, few images, fast spin-up. Split the things that actually vary into
separate axes instead of encoding all of them in one Containerfile per agent.

```
HARNESS   = which coding-agent CLI lives in the image      (pi, omp, claude, codex, opencode)
PERSONA   = harness + role instructions + config payload   (pi-web-dev, pi-pr-reviewer, ...)
ROLE      = the job: developer / reviewer / planner / ...  (changes AGENTS.md, skills, policy)
POLICY    = the security boundary, keyed by ROLE           (dev.yaml, review.yaml, strict.yaml)
PROVIDERS = network + credential grants, fleet-wide        (providers/provider-*.yaml)
```

Only `PERSONA` is per-agent. Harness images are built once and cached; persona layers are
thin (`COPY payload/` on top of a cached harness), so editing instructions/skills costs a
few seconds instead of a full image build.

## Layout

```
project/
├── DESIGN.md                     this file
├── docs/                         workflow guides (providers, personas, roles/skills, policies, harnesses, models, debugging)
├── build.sh                      build harness images, then persona images
├── launch.sh                     persona -> `openshell sandbox create ...`
├── Makefile                      make personas | make run-pi-web-dev | make providers
├── .containerignore              keeps providers/ + docs out of the image build context
│
├── harnesses/                    one descriptor per coding-agent CLI (machine-readable)
│   ├── pi.json                   agent dir env, launch command, config file names
│   └── omp.json
│
├── images/                       one Containerfile per HARNESS only
│   ├── pi/Containerfile          -> openshell-pi-harness:local
│   └── omp/Containerfile         -> openshell-omp-harness:local
│
├── personas/                     one directory per AGENT (harness + role + payload)
│   ├── pi-general-dev/
│   │   ├── persona.json          manifest read by build.sh / launch.sh (harness, image, policy,
│   │   │                        providers, launch cmd, mount settings)
│   │   ├── Containerfile         thin layer: FROM the harness image + COPYs instructions/payload/skills
│   │   └── payload/              HARNESS CONFIG ONLY: settings.json, mcp.json, models.json, trust.json
│   ├── pi-pr-reviewer/           same shape, policies/review.yaml, read-only mount
│   ├── pi-planner/               same shape, policies/review.yaml
│   ├── pi-web-dev/               web-dev role + headless browser (agent-browser + Chromium)
│   └── omp-web-dev/              same as pi-web-dev on the omp harness
│
├── policies/                     keyed by ROLE, not by persona
│   ├── dev.yaml                  workdir read-write (developer)
│   ├── review.yaml               host repo READ-ONLY + writable agent dir (reviewer/planner)
│   └── strict.yaml               no host mount at all (experiments, untrusted input)
│
├── shared/                       harness-neutral assets, COPYed into persona images
│   ├── instructions/house-rules.md        Context7 + codemode rules
│   ├── instructions/roles/<role>.md       the job: web-dev, pr-reviewer, planner, general-dev
│   ├── skills/<skill>/SKILL.md            Agent Skills spec -> works for pi and omp (web-dev)
│   └── browser/install.sh                 headless browser layer, RUN by the *-web-dev personas
│
└── providers/                    unchanged (Makefile pattern already correct)
```

Nothing else lives here. The earlier `agents/pi` + `agents/pi-flutter` directories (one self-contained
image per agent, config baked to `/sandbox/.pi`) were deleted; this layout replaces them.

## How one persona image is assembled

Two layers, always:

```dockerfile
# 1. images/pi/Containerfile            -> openshell-pi-harness:local
#    base sandbox + apt tools + `npm i -g @earendil-works/pi-coding-agent`
#    ENV PI_CODING_AGENT_DIR=/sandbox/agent     <- no persona config here at all

# 2. personas/pi-general-dev/Containerfile      -> pi-general-dev:local
FROM openshell-pi-harness:local
COPY shared/instructions/house-rules.md shared/instructions/roles/general-dev.md /tmp/assemble/
RUN cat /tmp/assemble/house-rules.md /tmp/assemble/general-dev.md > /sandbox/agent/AGENTS.md         # role instructions assembled at build time
COPY personas/pi-general-dev/payload/  /sandbox/agent/       # settings.json, mcp.json, models.json, trust.json
COPY shared/skills/                    /sandbox/agent/skills/
RUN pi install npm:@juicesharp/rpiv-ask-user-question        # after payload: pi install rewrites settings.json
```

So the harness layer is *identical* for every pi persona and is built once; each persona is a thin
layer of instructions + config on top of it. Layer 2 never changes the base image, and layer 1 never
contains role text.

## Two conventions that make the fleet composable

**1. One writable agent-config path for every harness: `/sandbox/agent`.**
Harness images set `PI_CODING_AGENT_DIR=/sandbox/agent` and persona payloads are baked to
`/sandbox/agent`. Pi relocates its agent dir with that env var; omp honors it for the
*default* profile (`docs/settings.md`: "PI_CODING_AGENT_DIR relocates the default profile's
agent directory, including config.yml and its agent data"). So a policy never needs to know
which harness is running — it only ever grants `/sandbox/agent` (writable: sessions, npm
packages, caches) plus `/tmp`.

This is why every policy grants `/sandbox/agent` without knowing which harness runs, and why
`/sandbox/.pi` (Pi's default) is not used anywhere in this fleet.

**2. Skills and role text are harness-neutral; only config file *names* differ.**
Both Pi and omp implement the Agent Skills spec, so `shared/skills/web-dev/SKILL.md` serves
both. What must be duplicated per harness is the plumbing:

| | pi | omp |
|---|---|---|
| user config dir | `$PI_CODING_AGENT_DIR` (`settings.json`, `mcp.json`, `models.json`) | `$PI_CODING_AGENT_DIR` / `~/.omp/agent` (`config.yml`, **`models.yml` (YAML)**, `mcp.json`, `tools/`, `extensions/`) |
| project config | `.pi/` | `.omp/` |
| models file | JSON | YAML — payload is per-harness, do not symlink |
| profiles | none | built in: `--profile work` -> `~/.omp/profiles/work/agent`, and named profiles **ignore** `PI_CODING_AGENT_DIR` |

Consequence: don't try to share one payload directory across harnesses. Share the *skills*
and the *role instructions*, generate the plumbing per harness.

## Build / run flow

```bash
./build.sh                      # all harness images (cached) + all persona images
./build.sh pi-web-dev           # one persona
./build.sh --harnesses          # harness layers only

./launch.sh pi-web-dev --dry-run         # print the exact openshell command, run nothing
./launch.sh pi-web-dev                   # create sandbox and launch `pi`
./launch.sh pi-pr-reviewer --mount ~/repos/app   # override the host repo bind-mount source
```

`launch.sh` composes from `persona.json`: image, policy file, provider list, bind mount,
env passthrough, and the trailing agent command. It replaces the hand-written zsh alias:

```zsh
pi() { openshell sandbox create --from pi-agent:local --provider bifrost ... \
  --driver-config-json "{\"podman\":{\"mounts\":[{\"type\":\"bind\",\"source\":\"$(pwd)\",...}]}}" -- pi }
```

becomes:

```zsh
agent() { ~/Projects/software-factory/openshell/launch.sh "$@"; }   # agent pi-planner | agent pi-web-dev --mount ~/repos/app
alias pi='agent pi-general-dev'                             # keep the old muscle memory if you want it
```

One alias, every persona. `--dry-run` is the escape hatch: run it first and read the command.

Bind mounts require gateway opt-in (docs: `[openshell.drivers.podman] enable_bind_mounts = true`),
which your current alias already relies on.

## Role -> policy mapping

| Role | Writes code? | Policy | Why |
|---|---|---|---|
| developer | yes, in the mounted repo | `policies/dev.yaml` | workdir read-write + `/tmp` + agent dir |
| PR reviewer | no — comments only | `policies/review.yaml` | host repo mounted `read_only: true` **and** policy read-only (defense in depth); agent dir still writable for sessions |
| planner / scout | no — produces a plan doc in `/tmp` or the agent dir | `policies/review.yaml` | same as reviewer |
| untrusted input (issue bodies, third-party repos) | maybe | `policies/strict.yaml` | no host mount; output collected with `openshell sandbox cp`/upload |

Policy files are consumed by OpenShell directly, so they stay plain YAML. Persona manifests
are read by my scripts, so they are JSON (`persona.json`) — parseable with only stdlib
tools, which matters if you rewrite the launcher in Go later.

## Adding a persona (the whole procedure)

1. **Pick or write the role** — a file under `shared/instructions/roles/<role>.md`. Reuse an existing
   one if the job is the same; a new job means one new file, nothing else.
2. `mkdir -p personas/<name>/payload` and copy another persona's payload as the starting point (it is
   harness config only — no instructions in it).
3. Write `persona.json`: harness, image tag, policy file, provider list, launch command,
   `mount_default`, `mount_read_only`.
4. Copy a persona `Containerfile` and change three things: the `FROM` harness image, the role file name,
   and the payload path.
5. `./build.sh <name>` then `./launch.sh <name> --dry-run`; read the printed command before running it.

Persona count is cheap; harness count is the expensive axis. Four personas here need only two builds.

If a role needs a new capability (GitHub API, a package registry), add a provider
profile first — network access is decided by `providers/`, not by the persona.

## What I verified vs. what you must test

Verified against current docs (Context7: `/nvidia/openshell`, `/can1357/oh-my-pi`,
`/websites/omp_sh`) plus Pi's shipped docs (`docs/configuration.md`, `settings.md`,
`skills.md`, `packages.md`, `mcp.md`).

Also verified *in this sandbox* (no podman/openshell available here, so no builds/launches):
- `bash -n` on `build.sh` and `launch.sh`; every persona/harness/payload JSON parses.
- `./build.sh --dry-run` prints correct build order for all 4 personas (2 harness layers, then persona layers).
- `./launch.sh <persona> --dry-run` composes correct commands for all 4 personas, including `read_only: true` mounts for the reviewer/planner personas, and honors `--no-mount`, `--provider`, `--env K=V`, `--policy`, `--name`, and trailing `-- <agent args>`.
- `make -n personas | run-<persona> | dry-<persona> | pi-planner` resolves (pattern rules needed explicit `.PHONY` per name).
- Every `COPY`/`ADD` source in every Containerfile exists relative to the build context.

Confirmed:
- `--from` accepts a catalog name, local directory, pre-built sandbox name, or registry image; `podman build -t x ./dir` + `--from localhost/x` is the documented podman path.
- `sandbox create` supports repeatable `--provider`, `--policy <file>`, `--env K=V`, `--upload src:dst`, `--label k=v`, `--driver-config-json`, and a trailing `-- <agent process>`.
- Podman driver mount types: `bind` (needs `enable_bind_mounts = true`), `volume`, `tmpfs`, `image`.
- Policy schema: paths absent from both lists are inaccessible; `include_workdir: true` adds the *driver-resolved* workdir to `read_write`.
- omp config dir is `~/.omp/agent` / `.omp/`, `models.yml` is YAML, profiles isolate settings/auth/sessions, and named profiles ignore `PI_CODING_AGENT_DIR`.
- OpenShell upstream itself uses manifest-driven agents (`scripts/agents/README.md`: `agent.yaml` with `sandbox`, `harness`, `runtime`, `profile_paths`, skills, subagents; harness adapters live outside agent dirs; payload baked read-only under `/etc/openshell/agent-payload`). This layout is a smaller version of that pattern.

Verified end-to-end on the host (2026-10-09, openshell 0.1.1, podman applehv):
- `openshell-pi-harness:local` + `pi-planner:local` build; sandbox create→run→delete takes ~2s.
- Headless run: `sandbox create --no-tty --no-keep --provider bifrost --provider context7 -- sh -c 'exec pi -p --no-session --mode json "<task>" </dev/null'`.
  **stdin must be closed** (`</dev/null`): pi reads non-TTY stdin to EOF and hangs forever otherwise.
- bifrost (`homelab:8080/v1/chat/completions`) and Context7 MCP egress allowed via `_provider_*` rules; Landlock denies `ls /sandbox` under review.yaml as intended.
- pi `--mode json` exits 0 even after a model `Connection error` (it auto-retried and succeeded); judge success from `agent_settled` + final `stopReason`, not the exit code.
- `--upload` cannot be combined with a trailing command in 0.1.1; `--keep` does not exist (keep is the default).
- OpenShell ignores the image `WORKDIR`: the agent process starts in `/sandbox` (= `$HOME`). omp treats `$HOME` as
  "don't work here" and auto-switches to a temp dir, so headless runs should `cd /sandbox/work` (or pass `--cwd`).
- omp v18.8.6 verified headless under both dev.yaml and review.yaml, with bifrost + Context7 MCP. Harness quirks
  (config root, natives dir, mcp.json units/syntax, provider binaries) are recorded in `harnesses/omp.json` notes.

Not verified (originally written without podman access) — I cannot run `podman`/`openshell` in this sandbox, so treat these as first-test items:
1. **No image was ever built and no sandbox ever started here.** Only command composition is tested.
4. Whether the gateway overrides the sandbox workdir/user in a way that changes `include_workdir` resolution.
5. Provider profiles I marked `.draft` (see below) are guesses about hosts — review before applying.

Roles are shared assets too: `shared/instructions/roles/{web-dev,pr-reviewer,planner,general-dev}.md`.
A persona's `AGENTS.md` is assembled at build time as `house-rules.md + <role>.md`, so the same role
text serves any harness, and one role can exist in several harnesses (`pi-web-dev`,
`omp-web-dev`). Adding a role = add one file under `shared/instructions/roles/`.

Headless browser (`pi-web-dev`, `omp-web-dev`), verified 2026-10-09 in OpenShell under dev.yaml on arm64:
- `agent-browser install` can't be used: Chrome for Testing has no linux-arm64 build and Ubuntu 24.04's
  chromium is a snap stub. `shared/browser/install.sh` installs Playwright's Chromium under `/usr`
  (`/opt` is in neither Landlock list) and agent-browser's own skill as `skills/agent-browser`.
- Chrome needs `--no-sandbox --no-zygote --disable-gpu --disable-dev-shm-usage` (no user namespaces,
  no writable /dev/shm), set via `AGENT_BROWSER_ARGS` in the persona Containerfile.
- IPv4 loopback TCP is swallowed inside the sandbox; `localhost` (= `::1`) works. Agents must browse
  `http://localhost:PORT`, never `127.0.0.1`.
- `next/font/google` needs `providers/provider-googlefonts.yaml` for `next build` (dev falls back).
- Both agents passed a headless run against a copy of a Next 16 app: serve, open, snapshot, console, stop.

Open gaps worth deciding next:
- **No GitHub provider profile**, yet `pi-pr-reviewer` is useless without `api.github.com`. Drafted as `providers/provider-github.yaml.draft` (the Makefile glob only matches `provider-*.yaml`, so it won't be pushed by accident).
- **Flutter / mobile app dev is on hold.** Flutter emulators can't run inside OpenShell sandboxes, so the Flutter personas, skill, role and pub.dev provider draft were removed (2026-10-10). Recover them from git history if that changes.
- If you ever want config iteration without rebuilds, OpenShell supports `--upload .:/sandbox/agent` (or an `image:` mount of a payload image). Kept out for now because you chose bake-only.
