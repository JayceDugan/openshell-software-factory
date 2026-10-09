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
(docs MCP), `langfuse` (tracing), `npm`, `googlefonts`, `vllm`, `ninfer`, and `unsloth`. A GitHub profile is drafted
in `provider-github.yaml.draft` but not applied yet.

**Shared assets** (`openshell/shared/`): house rules (Context7 first, codemode), role files, Agent Skills (`web-dev`),
and the headless browser layer.

For the full architecture, the verified behavior, and known quirks, see [`openshell/DESIGN.md`](openshell/DESIGN.md).

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
│   ├── harnesses/          pi.json, omp.json: per-CLI descriptors
│   ├── images/             one Containerfile per harness
│   ├── personas/           one directory per agent: persona.json + Containerfile + payload/
│   ├── policies/           dev.yaml, review.yaml, strict.yaml
│   ├── providers/          OpenShell provider profiles + Makefile
│   └── shared/             house rules, role files, skills, browser layer
└── openshell-source/       git submodule: NVIDIA/OpenShell (reference)
```
