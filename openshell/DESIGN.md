# Agent fleet design: harness × persona × role

Goal: many agents, few images, fast spin-up. Split the things that actually vary into
separate axes instead of encoding all of them in one Containerfile per agent.

```
HARNESS   = which coding-agent CLI lives in the image      (pi, omp, claude, codex, opencode)
PERSONA   = harness + role instructions + config payload   (pi-flutter-dev, pi-pr-reviewer, ...)
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
├── build.sh                      build harness images, then persona images
├── launch.sh                     persona -> `openshell sandbox create ...`
├── Makefile                      make personas | make run-pi-flutter-dev | make providers
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
│   ├── pi-flutter-dev/
│   │   ├── persona.json          manifest read by build.sh / launch.sh (harness, image, policy,
│   │   │                        providers, launch cmd, mount settings)
│   │   ├── Containerfile         thin layer: FROM the harness image + COPYs instructions/payload/skills
│   │   └── payload/              HARNESS CONFIG ONLY: settings.json, mcp.json, models.json, trust.json
│   ├── pi-pr-reviewer/           same shape, policies/review.yaml, read-only mount
│   ├── pi-planner/               same shape, policies/review.yaml
│   └── omp-flutter-dev/          same role file + skills, omp harness -> config.yml + models.yml instead
│
├── policies/                     keyed by ROLE, not by persona
│   ├── dev.yaml                  workdir read-write (developer)
│   ├── review.yaml               host repo READ-ONLY + writable agent dir (reviewer/planner)
│   └── strict.yaml               no host mount at all (experiments, untrusted input)
│
├── shared/                       harness-neutral assets, COPYed into persona images
│   ├── instructions/house-rules.md        Context7 + codemode rules
│   ├── instructions/roles/<role>.md       the job: flutter-dev, pr-reviewer, planner, general-dev
│   └── skills/flutter-dev/SKILL.md        Agent Skills spec -> works for pi and omp
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

# 2. personas/pi-flutter-dev/Containerfile      -> pi-flutter-dev:local
FROM openshell-pi-harness:local
COPY shared/instructions/house-rules.md shared/instructions/roles/flutter-dev.md /tmp/assemble.md
RUN cat /tmp/assemble.md > /sandbox/agent/AGENTS.md          # role instructions assembled at build time
COPY personas/pi-flutter-dev/payload/  /sandbox/agent/       # settings.json, mcp.json, models.json, trust.json
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
Both Pi and omp implement the Agent Skills spec, so `shared/skills/flutter/SKILL.md` serves
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
./build.sh pi-flutter-dev       # one persona
./build.sh --harnesses          # harness layers only

./launch.sh pi-flutter-dev --dry-run     # print the exact openshell command, run nothing
./launch.sh pi-flutter-dev               # create sandbox and launch `pi`
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
agent() { ~/project/launch.sh "$1" --mount "${2:-$PWD}"; }   # agent pi-planner | agent pi-flutter-dev ~/repos/app
alias pi='agent pi-flutter-dev'                              # keep the old muscle memory if you want it
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

If a role needs a new capability (GitHub API, pub.dev, a package registry), add a provider
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

Not verified — I cannot run `podman`/`openshell` in this sandbox, so treat these as first-test items:
1. **No image was ever built and no sandbox ever started here.** Only command composition is tested.
2. `PI_CODING_AGENT_DIR=/sandbox/agent` for omp: docs support it for the default profile, but I could not confirm sessions/tools/extensions all follow it. Fallback: bake to `/sandbox/.omp/agent` with `HOME=/sandbox`.
3. omp install path in `images/omp/Containerfile` (install.sh vs bun) and where the `omp` binary lands on `PATH`. Check with `podman run --rm openshell-omp-harness:which omp`. The file has both variants; only one is enabled.
4. Whether the gateway overrides the sandbox workdir/user in a way that changes `include_workdir` resolution.
5. Provider profiles I marked `.draft` (see below) are guesses about hosts — review before applying.

Roles are shared assets too: `shared/instructions/roles/{flutter-dev,pr-reviewer,planner,general-dev}.md`.
A persona's `AGENTS.md` is assembled at build time as `house-rules.md + <role>.md`, so the same role
text serves any harness, and one role can exist in several harnesses (`pi-flutter-dev`,
`omp-flutter-dev`). Adding a role = add one file under `shared/instructions/roles/`.

Open gaps worth deciding next:
- **No GitHub provider profile**, yet `pi-pr-reviewer` is useless without `api.github.com`. Drafted as `providers/provider-github.yaml.draft` (the Makefile glob only matches `provider-*.yaml`, so it won't be pushed by accident).
- **No pub.dev / Flutter CDN provider** for a persona that would actually run `dart pub get`; also note no Flutter SDK is installed in these images — the Flutter personas are instruction-only, as chosen.
- If you ever want config iteration without rebuilds, OpenShell supports `--upload .:/sandbox/agent` (or an `image:` mount of a payload image). Kept out for now because you chose bake-only.
