# Providers: network and credentials

Sandboxes start with **no network egress**: every outbound connection is denied unless something grants it.
In this fleet, providers are the only thing that grants egress. The policy files in `policies/` cover the
filesystem only.

## What a provider is

A provider bundles everything an agent needs to use one external service:

- **Endpoints:** which `host:port` the sandbox may reach, and whether access is read-only or read-write.
- **Binaries:** which executables inside the sandbox may make those connections. Any other process is denied,
  even if it targets the same host.
- **Credentials (optional):** the API key or token, which the gateway stores and injects.

When a sandbox starts with `--provider bifrost`, OpenShell adds `_provider_bifrost` network rules to that
sandbox's effective policy. It also hands the agent placeholder environment variables for any credentials.

### Credentials never enter the sandbox

The agent never sees a real secret. Its environment holds an opaque placeholder, for example
`CONTEXT_7_MCP_API_KEY=<placeholder>`. When the agent sends a request containing that placeholder, OpenShell's
proxy swaps in the real value at the last moment, and only if both of these hold:

1. Network policy allows that binary to reach that destination.
2. The destination is one of the endpoints declared in **that provider's** profile.

A Context7 key therefore can't be sent to any other host, even one the sandbox is allowed to reach. Images and
payloads stay free of secrets: `mcp.json` refers to `$CONTEXT_7_MCP_API_KEY` and nothing more.

## Profile vs provider: why there are two steps

OpenShell separates the definition from the instance:

| | **Provider profile** | **Provider** (instance) |
|---|---|---|
| What it is | A *type*: the endpoints, the binaries, and which credentials exist | A configured *instance* of a type, holding the actual credential values |
| Lives in | `providers/provider-<id>.yaml` in this repo, imported into the gateway | the gateway only (`openshell provider list`) |
| Contains secrets? | No, it only names them (`env_vars: [GITHUB_TOKEN]`) | Yes, the stored credential values |
| Created with | `make -C providers update-<id>`, which imports it the first time | `openshell provider create --name <name> --type <id>` |
| Changed with | `make -C providers update-<id>` (or `make providers` for all) | `openshell provider update <name> …` |
| Referenced by | the `--type` of a provider | `--provider <name>` on `sandbox create`, which is what `persona.json` lists |

So the order is always **profile first, then provider**:

1. **Import the profile.** This teaches the gateway that a "github" type exists and what it may reach. The
   gateway's catalog is import-only: it starts empty and only knows the profiles you import.
2. **Create a provider from it.** This stores your actual token under a name. `openshell provider create` refuses
   a `--type` that has no imported profile.
3. **Attach the provider by name** when you create a sandbox. `launch.sh` does this from `persona.json`
   `providers`.

The split is what lets the network rules live in git and be reviewed while the secrets stay out of it. One profile
can also back several providers, for example `github-work` and `github-personal`, both of type `github` with
different tokens.

In this repo, each provider has the same name as its profile (`bifrost` is of type `bifrost`), so `persona.json`
looks as if it lists profile ids. Strictly, it lists **provider names**.

## Workflow: add a new provider

The example below adds read-only access to the PyPI registry for a hypothetical Python persona.

### 1. Write the profile

Create `providers/provider-pypi.yaml`. Start from the closest existing profile: `provider-npm.yaml` for an
anonymous registry, or `provider-context7.yaml` for one that needs an API key.

```yaml
id: pypi                      # lowercase kebab-case; must match the filename suffix
resource_version: 1           # informational; the Makefile uses the gateway's current version
display_name: PyPI
description: Python package index (anonymous, read-only installs)
category: data                # inference | agent | source_control | messaging | data | knowledge | other
inference_capable: false
endpoints:
  - host: pypi.org
    port: 443
    protocol: rest
    access: read-only         # read-only = GET/HEAD; read-write allows POST etc.
    enforcement: enforce
  - host: files.pythonhosted.org
    port: 443
    protocol: rest
    access: read-only
    enforcement: enforce
binaries: [/usr/bin/python3, /usr/local/bin/python3]
```

For a service with a credential, add a `credentials` section and a `discovery` section, as in
`provider-context7.yaml`:

```yaml
credentials:
  - name: api_key
    description: Example API key
    env_vars: [EXAMPLE_API_KEY]   # the placeholder env var the agent sees
    required: true
    auth_style: bearer            # basic | bearer | header | query | path
    header_name: authorization
discovery:
  credentials: [api_key]          # lets `provider create --from-existing` read it from your env
```

**Getting `binaries` right is the usual trap.** OpenShell identifies the calling process by its **real executable
path, with symlinks resolved**. That means:

- `npm`, `npx`, and `next` are node scripts, so the binary to list is `/usr/bin/node`.
- omp is a single Bun binary. A provider that omp itself uses, such as inference or MCP, must list
  `/usr/local/bin/omp`, or omp's egress is denied.
- If you're unsure of the path, run `openshell sandbox create --from pi-general-dev:local -- sh -c 'readlink -f "$(command -v python3)"'`
  in a sandbox.
- Keep the list tight. A planner has no reason to let `git` reach a package registry.

Add a comment at the top that explains why the profile exists and gives a one-line smoke test. The existing
profiles all do this.

### 2. Lint it

```bash
openshell profile lint -f providers/provider-pypi.yaml
```

Lint validates the profile against the gateway without storing it. If the profile is already imported, lint
reports `already exists`. That's expected for an update.

### 3. Import the profile into the gateway

```bash
make -C providers update-pypi            # or: make providers  (every provider-*.yaml)
openshell profile list                   # pypi now shows up
openshell profile describe pypi
```

OpenShell's `profile import` is create-only, and `profile update` fails for an unknown id. The Makefile target
checks with `openshell profile describe` and runs whichever one applies, so the same command works for new and
existing profiles.

### 4. Create the provider instance

Without credentials:

```bash
openshell provider create --name pypi --type pypi
```

With credentials, you have three options:

```bash
openshell provider create --name example --type example --credential EXAMPLE_API_KEY            # read from your shell env
openshell provider create --name example --type example --credential EXAMPLE_API_KEY=sk-...     # literal (lands in shell history)
openshell provider create --name example --type example --from-existing                         # profile-driven discovery
```

Check the result with `openshell provider list`.

Shortcut: if `sandbox create --provider X` names a provider that doesn't exist yet, but X matches an imported
profile id, the CLI offers to create the provider through discovery. Creating it explicitly is still clearer.

### 5. Smoke-test it on its own

```bash
openshell sandbox create --from pi-general-dev:local --no-tty --provider pypi -- \
  python3 -c 'import urllib.request;print(urllib.request.urlopen("https://pypi.org/simple/").status)'
```

Then run it **without** `--provider pypi` to confirm the request is denied. A grant you've never seen denied
hasn't been tested.

### 6. Give it to the personas that need it

Add the name to `providers` in each relevant `personas/<name>/persona.json`. Only add it where it's needed: every
provider widens what that agent can reach. Nothing needs rebuilding, because providers are attached at launch.

```bash
./launch.sh pi-general-dev --dry-run    # check that --provider pypi is in the command
```

For a one-off, skip the manifest edit and pass it on the command line: `agent pi-general-dev --provider pypi`.

## Workflow: update an existing provider

To change the endpoints or binaries:

```bash
$EDITOR providers/provider-npm.yaml
make -C providers update-npm             # or: make providers  (all of them)
```

`profile update` checks `resource_version` so that a stale file can't overwrite a newer definition, and every update
bumps the gateway's version. The Makefile handles this by submitting a temporary copy of the file that carries the
gateway's current `resource_version`. The `resource_version` in the repo files is therefore informational, and you
never need to bump it by hand. Git is the source of truth, so a change made directly on the gateway is overwritten
by the next `make providers`.

If you call `openshell profile update` yourself, use the version from
`openshell profile export <id> -o yaml | grep resource_version`.

Updated profile rules reach running sandboxes on their next config sync.

To rotate a credential, which changes the provider and not the profile:

```bash
openshell provider update context7 --credential CONTEXT_7_MCP_API_KEY
```

## Workflow: remove a provider

```bash
# 1. remove it from every persona.json that lists it
openshell provider delete pypi
openshell profile delete pypi      # refused while a sandbox-attached provider still uses it
git rm providers/provider-pypi.yaml
```

## Drafts

Files named `provider-*.yaml.draft` (such as `provider-github.yaml.draft`) are deliberately **not** matched by
`providers/Makefile`, which only globs `provider-*.yaml`. Use the `.draft` suffix for a profile whose hosts or
binaries you haven't confirmed yet. Rename the file to activate it, then follow the steps above from step 2.

## Current providers

| Provider | Grants | Credentials | Used by |
|---|---|---|---|
| `bifrost` | `homelab:8080`: the inference router | none | all personas |
| `context7` | `mcp.context7.com`: docs MCP | `CONTEXT_7_MCP_API_KEY` | all personas |
| `langfuse` | Langfuse tracing | public key, secret key, base URL, host URL | dev and reviewer personas |
| `npm` | `registry.npmjs.org`, read-only, `node` only | none | all personas |
| `googlefonts` | `fonts.googleapis.com`, `fonts.gstatic.com`, read-only | none | `*-web-dev` (`next build` with `next/font/google`) |
| `vllm`, `ninfer`, `unsloth` | other inference backends | see the profile | not attached by default |
