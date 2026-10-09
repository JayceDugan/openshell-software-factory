# Docs: working in the agent fleet

These guides cover the common jobs in this codebase: adding a capability, adding an agent, and changing what an
agent may touch. The top-level [`README.md`](../../README.md) covers what the fleet is and how to get started.
[`DESIGN.md`](../DESIGN.md) is the design record: what was verified and the harness quirks.

## Guides

| Guide | Read it when you want to… |
|---|---|
| [Providers](providers.md) | let agents reach a new host or API, or give them a credential. It also explains **profiles vs providers**. |
| [Personas](personas.md) | add a new agent, or change an existing agent's role, policy, providers, or mount |
| [Roles and skills](roles-and-skills.md) | change what an agent is told to do, or teach every agent a new skill |
| [Policies](policies.md) | change which files an agent can read or write |
| [Harnesses](harnesses.md) | add a new coding-agent CLI (claude, codex, opencode, …) next to pi and omp |
| [Models](models.md) | switch the model or the inference endpoint |
| [Running and debugging](running-and-debugging.md) | launch headless runs, inspect a sandbox, or work out why something was denied |

## The mental model in one page

An agent here is a **persona**: one value picked from each of several independent axes.

```
                     what it is told          what it knows          the CLI
                   ┌──────────────────┐   ┌───────────────────┐   ┌──────────────┐
                   │ house-rules.md + │   │ shared/skills/*   │   │ harness image│
                   │ roles/<role>.md  │   │  (Agent Skills)   │   │  pi | omp    │
                   └────────┬─────────┘   └─────────┬─────────┘   └──────┬───────┘
                            └──────────── persona image ─────────────────┘
                                       (personas/<name>/Containerfile
                                        + payload/ harness config)
                                                 │
            openshell sandbox create ◄───────────┤  launch.sh reads persona.json
                                                 │
                   ┌─────────────────────────────┴────────────────────────────┐
                   │ what it may touch on disk     what it may reach on network│
                   │ policies/<role>.yaml          providers (bifrost, npm, …) │
                   │ (Landlock, enforced)          (egress allowlist + creds)   │
                   └───────────────────────────────────────────────────────────┘
```

| Term | Where it lives | Built or applied | Shared by |
|---|---|---|---|
| **Harness** | `images/<h>/Containerfile`, `harnesses/<h>.json` | built once with podman | every persona on that CLI |
| **Persona** | `personas/<name>/` (`persona.json`, `Containerfile`, `payload/`) | thin podman layer, rebuilds in seconds | — (one per agent) |
| **Role** | `shared/instructions/roles/<role>.md` | concatenated into `AGENTS.md` at build time | any persona, any harness |
| **House rules** | `shared/instructions/house-rules.md` | prepended to every `AGENTS.md` | everyone |
| **Skill** | `shared/skills/<skill>/SKILL.md` | copied to `/sandbox/agent/skills/` | every persona, both harnesses |
| **Payload** | `personas/<name>/payload/` | copied to `/sandbox/agent/` | — (harness-specific config) |
| **Policy** | `policies/<p>.yaml` | passed to `openshell sandbox create --policy` | every persona with that role |
| **Provider profile** | `providers/provider-<id>.yaml` | imported into the OpenShell gateway | the whole gateway |
| **Provider** | the gateway's database (`openshell provider list`) | created once from a profile | every sandbox that attaches it |

### Where to change things

- **What the agent does** → the role file. Change it and rebuild the personas.
- **What it knows how to do** → a skill. Change it and rebuild the personas.
- **Which files it can touch** → the policy. Nothing needs rebuilding: the next launch uses it.
- **Which hosts it can reach** → the provider profile on the gateway. Nothing needs rebuilding.
- **Which model it uses** → the persona payload. Rebuild that persona.
- **Which CLI it runs** → the harness. Rebuild the harness and every persona on it.

## Conventions worth keeping

- **`/sandbox/agent`** is the single writable agent dir for every harness. Policies grant only this, `/tmp`, and
  the workdir.
- **`/sandbox/work`** is where the host directory is mounted, and the agent always starts there.
- Payloads hold **config only**. Instructions belong in roles, and know-how belongs in skills.
- **Network access is granted by providers, never by policy files or personas.**
- Run `--dry-run` before trusting a launch, and read the printed command.
- Never run agents on the host. Everything goes through `launch.sh` and OpenShell.
