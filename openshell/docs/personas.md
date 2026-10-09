# Personas: adding or changing an agent

A persona is one agent: a harness, a role, the shared skills, a config payload, a policy, and a list of providers.
It's the only per-agent thing in the fleet. Everything it points at is shared.

```
personas/pi-web-dev/
├── persona.json     what launch.sh and build.sh read
├── Containerfile    thin layer FROM the harness image
└── payload/         harness config only → copied to /sandbox/agent/
```

## `persona.json`

```json
{
  "persona": "pi-web-dev",
  "display_name": "Pi web developer (React/Next.js, headless Chromium via agent-browser)",
  "harness": "pi",
  "image": "pi-web-dev:local",
  "policy": "policies/dev.yaml",
  "providers": ["bifrost", "context7", "langfuse", "npm", "googlefonts"],
  "launch_cmd": "pi",
  "mount_default": ".",
  "mount_read_only": false,
  "role": "developer",
  "notes": ["free-form; record anything surprising you learned"]
}
```

| Field | Read by | Meaning |
|---|---|---|
| `harness` | `build.sh` | Which `harnesses/<h>.json` and harness image to build first |
| `image` | both | Image tag the persona builds to, and that `launch.sh` starts with `--from` |
| `policy` | `launch.sh` | Filesystem policy passed as `--policy`, chosen by role (see [policies](policies.md)). `"none"` passes no policy. |
| `providers` | `launch.sh` | Provider **names** attached with `--provider` (see [providers](providers.md)) |
| `launch_cmd` | `launch.sh` | The agent command run in `/sandbox/work`. Split on spaces, so `"omp --foo"` works. |
| `mount_default` | `launch.sh` | Host path to bind-mount at `/sandbox/work`. `"."` means the caller's `$PWD`. |
| `mount_read_only` | `launch.sh` | `true` for reviewers and planners |
| `display_name`, `role`, `notes` | humans, `--list` | Documentation |

Editing `persona.json` **doesn't need a rebuild**, because `launch.sh` reads it on every launch. Editing the
`Containerfile`, the payload, a role, or a skill does.

## Workflow: add a persona

The example below adds `omp-pr-reviewer`, the existing reviewer role on the omp harness.

1. **Pick the role.** `shared/instructions/roles/pr-reviewer.md` already exists. If the job is new, write a role
   first (see [roles and skills](roles-and-skills.md)).

2. **Copy a persona on the same harness.** The payload format is per-harness, so copy from an omp persona:

   ```bash
   cp -R personas/omp-web-dev personas/omp-pr-reviewer
   ```

3. **Edit `persona.json`:** set `persona`, `display_name` and `image` (`omp-pr-reviewer:local`), then the
   `policy` (`policies/review.yaml`), `mount_read_only: true`, `role: "reviewer"`, and the smallest `providers`
   list that works.

4. **Edit the `Containerfile`.** Usually three things change:
   - the role file in the `COPY` and `cat` lines (`roles/pr-reviewer.md`)
   - the payload path (`personas/omp-pr-reviewer/payload/`)
   - any layers the new persona doesn't need. A reviewer has no use for the browser `install.sh` block or its
     `ENV` lines.

5. **Review the payload:** the model, MCP servers, and theme (see [models](models.md)). The payload is config only.
   If you find yourself writing instructions into it, they belong in the role instead.

6. **Build, then dry-run:**

   ```bash
   ./build.sh omp-pr-reviewer
   ./launch.sh omp-pr-reviewer --dry-run    # read it: policy, providers, read_only:true mount
   ```

7. **Run it once headless** to prove the agent starts, reaches its model, and is denied what it should be denied.
   See [running and debugging](running-and-debugging.md).

8. Add a row to the persona table in the top-level `README.md`.

The new persona is picked up automatically by `launch.sh --list`, `make list`, `make run-<name>`, and the `agent`
tab completion.

## Persona Containerfile anatomy

```dockerfile
FROM openshell-pi-harness:local
USER root                                          # harness ends as USER sandbox

# (optional capability layers go here, e.g. the headless browser in *-web-dev)

COPY shared/instructions/house-rules.md shared/instructions/roles/<role>.md /tmp/assemble/
RUN mkdir -p /sandbox/agent \
	&& cat /tmp/assemble/house-rules.md /tmp/assemble/<role>.md > /sandbox/agent/AGENTS.md \
	&& rm -rf /tmp/assemble

COPY personas/<name>/payload/ /sandbox/agent/      # harness config
COPY shared/skills/           /sandbox/agent/skills/

RUN pi install npm:@juicesharp/rpiv-ask-user-question   # pi only; LAST, it rewrites settings.json

RUN chown -R sandbox:sandbox /sandbox/agent
USER sandbox
WORKDIR /sandbox/work
```

The build context is `openshell/`, so every `COPY` path is relative to it.

## Adding a capability layer (tools, SDKs, browsers)

When a persona needs extra software, add it as a layer in that persona's Containerfile, **before** the assembly
steps. Follow the `*-web-dev` pattern:

- Put the install logic in a shared script (`shared/browser/install.sh`), so several personas and both harnesses
  can `RUN` it.
- Install under `/usr`. The policies grant `/usr` read-only, but `/opt` isn't in either list, so anything there
  is inaccessible at runtime.
- Write caches and state to `/sandbox/agent` or `/tmp`, because nothing else is writable.
- If the tool needs the network at runtime, add a [provider](providers.md) too. The image layer doesn't grant egress.
- Expect sandbox constraints: there are no user namespaces, `/dev/shm` isn't writable, and IPv4 loopback is
  swallowed. Chrome needed `--no-sandbox --no-zygote --disable-gpu --disable-dev-shm-usage` for these reasons.
- When the same persona exists on two harnesses, keep the layer identical in both Containerfiles.

## Removing a persona

```bash
git rm -r personas/<name>
podman rmi <name>:local
```

Remove it from the top-level `README.md` table, and search for leftover references with `grep -rn <name> .`.
