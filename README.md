# software-factory

Coding agents ([pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) and
[omp](https://github.com/can1357/oh-my-pi)) that run **only inside [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell)
sandboxes**. They don't run on the host. You start one from any directory with a single command. That directory is
bind-mounted into the sandbox, and the agent gets the role, tools, filesystem policy, and network grants that its
persona allows.

This is the per-step runtime for a larger software factory: an outer loop (LangGraph) that runs each step in a
fresh headless sandbox. That orchestrator doesn't exist yet. What this repo has today is the sandboxed agent fleet.

## What this solves

| Problem | What this repo does |
|---|---|
| Coding agents on the host can read your whole disk, all your credentials, and the whole internet | Each agent runs in an OpenShell sandbox. Landlock limits the filesystem, and network egress is deny-by-default with grants per provider. |
| One Containerfile per agent means slow rebuilds and copied config | Split into **harness** (the CLI, built once) and **persona** (role text plus config, a thin layer that rebuilds in seconds). |
| Reviewers and planners shouldn't be able to edit the repo | Role-keyed policies: `review.yaml` mounts the repo **read-only** (both the mount and the policy enforce it). `dev.yaml` mounts it read-write. `strict.yaml` mounts nothing. |
| Each launch needs a long `openshell sandbox create …` command | `launch.sh` builds the command from `persona.json`. Wrap it in a shell function to run it from anywhere. |
| Instructions and skills drift between harnesses | Role files and Agent Skills are harness-neutral, so pi and omp read identical `AGENTS.md` and `skills/`. |

## What you get

**Personas** (`openshell/personas/`):

| Persona | Harness | Policy | Mount | Purpose |
|---|---|---|---|---|
| `pi-general-dev` | pi | dev | read-write | Baseline developer with no stack-specific skills. Use it to smoke-test models and the harness. |
| `pi-web-dev` | pi | dev | read-write | React/Next.js/Vite work, plus headless Chromium (`agent-browser`) to serve the app and check it |
| `omp-web-dev` | omp | dev | read-write | The same role, skills, and browser as `pi-web-dev`, on the omp harness |
| `pi-pr-reviewer` | pi | review | read-only | Reviews the mounted repo and doesn't change code |
| `pi-planner` | pi | review | read-only | Recon of the codebase and an architecture plan, written to `/tmp` |

**Providers** (`openshell/providers/`) are network and credential grants: `bifrost` (inference), `context7`
(docs MCP), `langfuse` (tracing), `npm`, `googlefonts`, `vllm`, `ninfer`, `unsloth`, and `launcher` (the
[factory](factory/README.md) orchestrator's route to the host launcher). A GitHub profile is drafted
in `provider-github.yaml.draft` but not applied yet.

**Shared assets** (`openshell/shared/`): house rules (Context7 first, codemode), role files, Agent Skills (`web-dev`),
and the headless browser layer.

**Working in this codebase?** Guides for the common workflows are in [`openshell/docs/`](openshell/docs/README.md):
[providers](openshell/docs/providers.md), including profiles vs providers;
[personas](openshell/docs/personas.md); [roles and skills](openshell/docs/roles-and-skills.md);
[policies](openshell/docs/policies.md); [harnesses](openshell/docs/harnesses.md); [models](openshell/docs/models.md);
and [running and debugging](openshell/docs/running-and-debugging.md). For what has been verified end to end and the
harness quirks, see [`openshell/DESIGN.md`](openshell/DESIGN.md).

## How the fleet is composed

The goal is many agents from few images, with fast spin-up. A Containerfile per agent would mix several things
that change independently, so each one gets its own axis instead:

```
HARNESS   = the coding-agent CLI in the image              pi, omp  (later: claude, codex, opencode)
ROLE      = the job: what the agent is told to do           general-dev, web-dev, pr-reviewer, planner
SKILLS    = reusable know-how the agent loads on demand     web-dev, agent-browser
POLICY    = the filesystem boundary, chosen by role         dev.yaml, review.yaml, strict.yaml
PROVIDERS = network + credential grants, fleet-wide         bifrost, context7, npm, ...
PERSONA   = harness + role + skills + config payload        pi-web-dev, omp-web-dev, pi-pr-reviewer, ...
```

**A persona is the only per-agent thing.** It picks one value from each of the other axes. All of those values
are shared, so adding an agent mostly means choosing values that already exist.

```
                 ┌──────────── shared/instructions/house-rules.md ─┐
                 │  + shared/instructions/roles/web-dev.md         │──► AGENTS.md
                 └─────────────────────────────────────────────────┘
openshell-pi-harness:local ──► personas/pi-web-dev ──► image pi-web-dev:local
  (pi CLI, built once)          ├─ payload/ (pi config: settings.json, models.json, mcp.json)
                                ├─ shared/skills/      ──► /sandbox/agent/skills/
                                └─ persona.json        ──► policy dev.yaml + providers [bifrost, context7, npm, ...]
```

### Harnesses: built once

`images/<harness>/Containerfile` holds the OpenShell base sandbox, apt tools, and the agent CLI
(`npm i -g @earendil-works/pi-coding-agent`, or omp). It contains **no role text and no config**.
`harnesses/<harness>.json` records each CLI's plumbing in machine-readable form: the agent dir env var, the launch
command, the config file names, and its quirks. A harness image is the slow build, and every persona on that
harness reuses its cached copy.

### Personas: a thin layer on a harness

Each `personas/<name>/` has three parts:

- **`persona.json`** is the manifest read by `build.sh` and `launch.sh`. It sets the harness, image tag, policy,
  provider list, launch command, `mount_default`, and `mount_read_only`.
- **`Containerfile`** is `FROM` the harness image, then assembles the persona:

  ```dockerfile
  FROM openshell-pi-harness:local
  COPY shared/instructions/house-rules.md shared/instructions/roles/web-dev.md /tmp/assemble/
  RUN cat /tmp/assemble/house-rules.md /tmp/assemble/web-dev.md > /sandbox/agent/AGENTS.md
  COPY personas/pi-web-dev/payload/ /sandbox/agent/     # harness config only
  COPY shared/skills/               /sandbox/agent/skills/
  RUN pi install npm:@juicesharp/rpiv-ask-user-question # last: pi install rewrites settings.json
  ```

- **`payload/`** is **harness config only**: the model, provider, and MCP settings. It never holds instructions.

The persona layer never changes the harness, and the harness never contains role text. Editing a role or skill
rebuilds one thin layer in seconds.

Optional capabilities are extra layers in the persona's Containerfile. For example, the `*-web-dev` personas run
`shared/browser/install.sh`, which installs Playwright's Chromium and the `agent-browser` skill, and they set the
Chrome flags that OpenShell requires.

### Roles and skills: harness-neutral

- **House rules** (`shared/instructions/house-rules.md`) go into every agent: use Context7 for docs, call MCP tools
  via codemode, and so on.
- **Roles** (`shared/instructions/roles/<role>.md`) define the job and its definition of done. `AGENTS.md` is built
  at image build time as `house-rules.md` + `<role>.md`. So one role file serves any harness: `pi-web-dev` and
  `omp-web-dev` read identical instructions.
- **Skills** (`shared/skills/<skill>/SKILL.md`) follow the Agent Skills spec. pi and omp both implement it and both
  scan `<agent-dir>/skills/`, so a skill is written once and works in every persona. Roles tell the agent which
  skills to load (`/skill:web-dev`, `/skill:agent-browser`).

### Two conventions that make it composable

**1. Every harness uses one writable agent dir: `/sandbox/agent`.** Harness images set
`PI_CODING_AGENT_DIR=/sandbox/agent`. pi relocates its agent dir with that variable, and so does omp for its
default profile. Payloads, `AGENTS.md`, skills, sessions, and caches all live there. As a result, a policy never
needs to know which harness is running: it grants `/sandbox/agent` plus `/tmp`, and that's enough.

**2. Share the skills and role text, and keep the plumbing per harness.** Only config file names and formats
differ:

| | pi | omp |
|---|---|---|
| agent config dir | `$PI_CODING_AGENT_DIR` | `$PI_CODING_AGENT_DIR` (default profile only) |
| config files | `settings.json`, `models.json`, `mcp.json` | `config.yml`, **`models.yml` (YAML)**, `mcp.json` |
| project config | `.pi/` | `.omp/` |
| profiles | none | `--profile x` exists, but named profiles **ignore** `PI_CODING_AGENT_DIR`, so don't use them |

So payloads aren't shared or symlinked across harnesses. Everything else is shared.

### Policies: chosen by role, not by persona

| Role | Writes code? | Policy | Filesystem |
|---|---|---|---|
| developer | yes, in the mounted repo | `policies/dev.yaml` | `/sandbox/work` read-write, plus `/tmp` and the agent dir |
| PR reviewer | no, it only comments | `policies/review.yaml` | repo mounted read-only **and** listed read-only in the policy (defense in depth). The agent dir stays writable for sessions. |
| planner | no, it writes a plan to `/tmp` | `policies/review.yaml` | same as the reviewer |
| untrusted input | maybe | `policies/strict.yaml` | no host mount. Collect output with `openshell sandbox cp`. |

Policies are plain OpenShell YAML, enforced with Landlock. Any path that isn't listed is inaccessible.

### Providers: network is decided here, not in the persona

Egress is deny-by-default. Each `providers/provider-<id>.yaml` is an OpenShell provider profile: the allowed hosts
and ports, which binaries may use them, and any credentials, which the gateway injects so they never sit in the
image. Personas only list provider ids. When a role needs a new capability, such as the GitHub API or another
package registry, add a provider profile first; see [docs/providers.md](openshell/docs/providers.md). Planners deliberately get fewer providers than developers, because
each extra endpoint is cost and leak surface.

### Adding a persona

1. **Role:** reuse a file in `shared/instructions/roles/`, or write one new file for a new job.
2. **Payload:** `mkdir -p personas/<name>/payload` and copy a payload from another persona on the same harness.
3. **Manifest:** write `persona.json` with the harness, image tag, policy, providers, `launch_cmd`, `mount_default`,
   and `mount_read_only`.
4. **Containerfile:** copy one from another persona on the same harness and change the role file and payload path.
5. `./build.sh <name>`, then `./launch.sh <name> --dry-run`. Read the printed command before you run it.

The full walkthrough is in [docs/personas.md](openshell/docs/personas.md).

Personas are cheap and harnesses are the expensive axis: the five personas here need only two harness builds.
Adding a skill is cheaper still: drop a directory into `shared/skills/` and rebuild the personas.

> **Flutter / mobile app dev is on hold.** Flutter emulators can't run inside OpenShell sandboxes, so the Flutter
> personas, skill, role, and pub.dev provider draft were removed. They're still in git history if that changes.

## Model and inference endpoint

pi and omp both send requests to:

- **Endpoint:** `http://homelab:8080/v1/chat/completions`. The persona config sets `baseUrl: http://homelab:8080/v1`
  with the OpenAI-compatible chat API (`api: openai-completions`), and pi and omp append `/chat/completions` to
  that. The `bifrost` provider profile allows `homelab:8080`.
- **Model:** `Strata/qwen3.8-flash-next-iq3_xxs` (context window 262144). This is the exact `model` value in the
  request body. Bifrost names models as `provider/model`, so this should route to its `Strata` provider, which
  serves `qwen3.8-flash-next-iq3_xxs`. That routing hasn't been checked against Bifrost's own config.

To change the model, edit the persona payloads: `models.json` and `settings.json` (`defaultModel`) for pi, or
`models.yml` and `config.yml` for omp. Then rebuild that persona.

## Getting started

### 1. Prerequisites (one time)

- **Podman** with a running machine: `podman machine start`
- **OpenShell CLI** (tested with 0.1.1): `openshell --version`
- **node or python3** on the host, because `launch.sh` and `build.sh` use them to read `persona.json`
- Bind mounts enabled in the gateway config at `~/.config/openshell/gateway.toml`:

  ```toml
  [openshell.drivers.podman]
  allow_driver_config = true
  enable_bind_mounts = true
  ```

- Bifrost reachable at `homelab:8080` from the Podman VM

### 2. Register providers

```bash
cd ~/Projects/software-factory/openshell
make providers                                          # push every providers/provider-*.yaml profile
openshell provider create --name bifrost --type bifrost # one provider per profile you use
openshell provider create --name context7 --type context7 --credential CONTEXT7_API_KEY   # reads it from your env
openshell provider list                                 # check
```

Providers without credentials (`bifrost`, `npm`, `googlefonts`, `vllm`, `ninfer`) need only `--name` and `--type`.
For `langfuse`, pass `--credential` for each key that `provider-langfuse.yaml` lists.

### 3. Build images

```bash
./build.sh                 # harness images (cached) + all personas
./build.sh pi-web-dev      # one persona; edits to instructions/skills rebuild in seconds
./build.sh --dry-run       # print the podman commands only
```

### 4. Add the shell function (run it from anywhere)

Add this to `~/.zshrc` (it also works in `~/.bashrc`):

```sh
# software-factory: launch a sandboxed agent persona on the current directory
export SOFTWARE_FACTORY="$HOME/Projects/software-factory"

agent() {
  local launch="$SOFTWARE_FACTORY/openshell/launch.sh"
  if [ $# -eq 0 ]; then "$launch" --list; return; fi
  "$launch" "$@"
}

agent-build() { "$SOFTWARE_FACTORY/openshell/build.sh" "$@"; }

# zsh: tab-complete persona names
if [ -n "$ZSH_VERSION" ] && (( $+functions[compdef] )); then
  _agent() { compadd -- $(command ls "$SOFTWARE_FACTORY/openshell/personas"); }
  compdef _agent agent agent-build
fi
```

Every persona has `mount_default: "."`, which `launch.sh` resolves to `$PWD`. So the directory you're in becomes
`/sandbox/work` in the sandbox, and the agent starts there.

Reload your shell with `source ~/.zshrc`. Then:

```bash
agent                                   # list personas
cd ~/repos/my-next-app
agent pi-web-dev --dry-run              # print the exact openshell command; read it first
agent pi-web-dev                        # start pi on this repo, read-write
agent pi-pr-reviewer                    # same repo, read-only reviewer
agent pi-planner --mount ~/repos/other  # mount a different directory
agent pi-general-dev --no-mount         # no host files at all
agent pi-general-dev -- -p --no-session --mode json "summarise this repo" </dev/null   # headless
```

### `launch.sh` options

| Flag | Effect |
|---|---|
| `--dry-run` | Print the composed `openshell sandbox create …` command and run nothing |
| `--mount <path>` | Bind-mount this host path at `/sandbox/work` instead of `$PWD` |
| `--no-mount` | No bind mount. Use this with `--policy policies/strict.yaml`. |
| `--ro` | Force the mount read-only |
| `--policy <file>` | Override the persona's policy |
| `--provider <id>` / `--no-provider` | Add a provider on top of the persona's list, or drop them all |
| `--name <name>` | Sandbox name (default: the persona name) |
| `--keep` | Keep the sandbox after the agent exits |
| `--env K=V` | Pass an environment variable into the sandbox (repeatable) |
| `-- <args>` | Extra arguments for the agent CLI |

`make` works too: `make list`, `make run-pi-web-dev MOUNT=~/repos/app`, `make dry-pi-planner`.

## Gotchas

- **Headless pi needs stdin closed** (`</dev/null`). Otherwise it waits on stdin forever.
- pi `--mode json` can exit 0 after a retried model error. Judge success from `agent_settled` and the final `stopReason`.
- Inside the sandbox, use `http://localhost:PORT`, never `127.0.0.1`, because IPv4 loopback is swallowed.
- After `pi-web-dev` runs `npm install` in the sandbox, `node_modules` has Linux binaries. Run `npm install` again on the host afterwards.
- The reviewer needs a GitHub provider to fetch PRs directly. That provider is still a draft.

## Layout

```
software-factory/
├── openshell/              the agent fleet (see openshell/DESIGN.md)
│   ├── build.sh  launch.sh  Makefile
│   ├── docs/               workflow guides: providers, personas, roles/skills, policies, …
│   ├── harnesses/          pi.json, omp.json: per-CLI descriptors
│   ├── images/             one Containerfile per harness
│   ├── personas/           one directory per agent: persona.json + Containerfile + payload/
│   ├── policies/           dev.yaml, review.yaml, strict.yaml
│   ├── providers/          OpenShell provider profiles + Makefile
│   └── shared/             house rules, role files, skills, browser layer
└── openshell-source/       git submodule: NVIDIA/OpenShell (reference)
```
