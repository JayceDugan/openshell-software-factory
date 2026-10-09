# Running and debugging

## Interactive

```bash
cd ~/repos/app
agent pi-web-dev --dry-run     # always look first
agent pi-web-dev
```

`agent` is the shell function from the top-level README. Without it, use `./launch.sh <persona>` or
`make run-<persona> MOUNT=~/repos/app`.

## Headless (scripted, CI, and the future outer loop)

pi:

```bash
agent pi-general-dev -- -p --no-session --mode json "Summarise this repo's architecture" </dev/null
```

- `</dev/null` is **required**. Without it, pi waits for stdin to reach EOF and never finishes.
- `--mode json` streams events. Judge success from the final `agent_settled` and `stopReason`, **not** the exit
  code, because pi can exit 0 after recovering from (or giving up on) a model error.
- Add `--name <unique>` when you run several sandboxes at once. The sandbox name defaults to the persona name.

omp runs the same way through `launch.sh`. `launch.sh` already does the `cd /sandbox/work` that omp needs.

## Inspecting sandboxes

```bash
openshell sandbox list
openshell sandbox get <name>
openshell logs <name> -n 200                 # sandbox and supervisor logs, including policy denials
openshell sandbox exec -n <name> -- sh       # shell into a running sandbox (launch with --keep to keep it alive)
openshell sandbox provider list <name>       # providers actually attached
openshell sandbox download <name> /tmp/plan.md ./plan.md   # collect output (strict/no-mount runs)
openshell sandbox delete <name>
```

`launch.sh` passes `--no-keep` by default, so the sandbox is removed when the agent exits. Pass `--keep` to leave
it running for inspection.

## Why was that denied?

| Symptom | Likely cause | Fix |
|---|---|---|
| `Connection error` / timeout to some host | No provider grants that host | [Add a provider](providers.md), or attach an existing one with `--provider` |
| Host is granted but still denied | The **binary** isn't in the profile's `binaries` (common with omp, or with `npm` → `node`) | Add the real, resolved executable path to the profile, then run `make -C providers update-<id>` |
| `credential_endpoint_mismatch` (HTTP 403) | A credential placeholder was sent to a host outside its provider's endpoints | Add the endpoint to that provider's profile, or stop sending the credential there |
| `Permission denied` on a file | The path isn't in the policy | Redirect writes to `/sandbox/agent` or `/tmp`, or see [policies](policies.md) |
| Reviewer can write the repo | `mount_read_only` is false, or `review.yaml` has changed | Restore both layers (see [policies](policies.md)) |
| `127.0.0.1:3000` refused, but the server is running | IPv4 loopback is swallowed in OpenShell | Use `http://localhost:3000` (`::1`) |
| Chrome crashes on launch | User namespaces or `/dev/shm` unavailable | Keep `AGENT_BROWSER_ARGS` from the `*-web-dev` Containerfile |
| `Failed to load SWC binary` / missing `*-linux-*.node` | `node_modules` was installed on macOS | Run `npm install` in the sandbox, then `npm install` again on the host afterwards |
| `next build` fails fetching fonts | No `googlefonts` provider | Attach `googlefonts` |
| Agent starts in a temp dir, not the repo | The image `WORKDIR` was ignored | Launch through `launch.sh`, which adds the `cd /sandbox/work` shim |
| `mount source does not exist` | `--mount` path is wrong | Use an absolute path, or `cd` there and omit `--mount` |
| Bind mount ignored or rejected | Gateway opt-in missing | `enable_bind_mounts = true` and `allow_driver_config = true` under `[openshell.drivers.podman]` in `~/.config/openshell/gateway.toml` |
| `provider create` rejects the type | Profile was never imported | `make -C providers update-<id>` |
| `profile update` refused: stale `resource_version` | A raw `openshell profile update` was run with the file's old version | Use `make -C providers update-<id>`, which submits the gateway's current version |

## Before you commit a change

- `bash -n launch.sh build.sh`
- `./build.sh --dry-run`, then `./launch.sh <each persona you touched> --dry-run`
- One real headless run per persona you touched
- Update `README.md` or these docs if you changed a workflow, and record anything newly verified in `DESIGN.md`
