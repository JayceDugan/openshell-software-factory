# Harnesses: the agent CLIs

A harness is the coding-agent program inside the image: pi or omp today, and possibly claude, codex or opencode
later. Harnesses are the **expensive axis**. Each one is a full image build, and every persona on it is a thin
layer on top.

```
images/<harness>/Containerfile   → openshell-<harness>-harness:local
harnesses/<harness>.json         → machine-readable descriptor of the CLI's plumbing
```

## What a harness image contains, and what it doesn't

It contains:

- the OpenShell community base sandbox (`ghcr.io/nvidia/openshell-community/sandboxes/base`)
- common tools: git, ripgrep, fd, curl, jq, vim
- the agent CLI, installed globally
- environment variables that point **all** of the CLI's writable state at `/sandbox/agent` or `/tmp`

It doesn't contain role text, skills, model config, or MCP config. Those come from the persona layer.

## The two contracts a new harness must satisfy

### 1. All writable state goes in `/sandbox/agent`

Policies grant only `/sandbox/agent`, `/tmp`, and the workdir. A CLI that writes to `~/.something` fails under
`review.yaml` and `strict.yaml`. Find every place the CLI writes and redirect it:

| Harness | Redirects |
|---|---|
| pi | `PI_CODING_AGENT_DIR=/sandbox/agent`, `NPM_CONFIG_CACHE=/sandbox/agent/.npm` |
| omp | `PI_CODING_AGENT_DIR=/sandbox/agent` (default profile only), `PI_CONFIG_DIR=agent/.omp` (logs and run state, joined onto `HOME=/sandbox`), `PI_NATIVES_DIR=/usr/local/lib/omp/natives` (native addon extracted at **build** time, because `/usr` is read-only at runtime) |

### 2. It reads `AGENTS.md` and `skills/` from the agent dir

That's what lets roles and skills stay harness-neutral. If a CLI reads instructions from another file name, such as
`CLAUDE.md`, the persona Containerfile must write the assembled text to that name. Don't fork the role files.

## Workflow: add a harness

1. **Research the CLI's config surface**, using Context7 or its docs: the config dir and its env override, the
   config file names and formats, the model/provider config, MCP config, skills support, any profile system, and
   how to run it headless.

2. **Write `images/<h>/Containerfile`.** Copy `images/pi/Containerfile` and change the install step and the env
   redirects. End with `USER sandbox`.

3. **Write `harnesses/<h>.json`**, with these fields: `harness`, `display_name`, `image`, `containerfile`,
   `agent_dir`, `project_config_dir`, `config_env`, `launch_cmd`, `payload_files`, `notes`. Use `notes` for the
   quirks you discover. `harnesses/omp.json` shows how much is worth writing down.

4. **Check the network identity.** OpenShell matches the process by its real executable path. If the CLI is a
   single compiled binary, as omp is (Bun), every provider it uses must list that binary in `binaries`, or its
   egress is denied. A node-based CLI is covered by `/usr/bin/node`. See [providers](providers.md).

5. **Make a first persona** for it (see [personas](personas.md)). Use an existing role, and write a payload in the
   new CLI's format: model pointing at bifrost (see [models](models.md)), plus Context7 MCP.

6. **Verify headless, under both `dev.yaml` and `review.yaml`.** The second one catches writes outside
   `/sandbox/agent`. Check that the agent:
   - starts in `/sandbox/work`
   - reaches bifrost and Context7
   - can load a skill
   - exits cleanly

7. Record the verified behavior in `DESIGN.md`.

## Known harness quirks

- **pi** reads non-TTY stdin to EOF, so headless runs need `</dev/null` or they hang forever. `pi install` rewrites
  `settings.json`, so run it **after** copying the payload. `--mode json` can exit 0 after a retried error.
- **omp** treats `$HOME` (`/sandbox`) as "don't work here" and switches to a temp dir. `launch.sh` always runs
  `cd /sandbox/work` first for this reason. Its `mcp.json` timeout is in **milliseconds** (pi uses seconds), its
  header env refs must be `${VAR}`, and named `--profile`s ignore `PI_CODING_AGENT_DIR`, so never use them. On
  startup it probes model-catalog hosts. Those probes are denied, and that's harmless.
- **OpenShell** ignores the image `WORKDIR`, which is why `launch.sh` adds the `sh -c 'cd /sandbox/work && exec "$@"'`
  shim.
