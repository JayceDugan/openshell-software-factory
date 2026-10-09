# Policies: what an agent can touch on disk

`policies/*.yaml` are OpenShell sandbox policies, passed to `openshell sandbox create --policy`. They're enforced
with Landlock (`compatibility: hard_requirement`, so the sandbox fails rather than running unconfined). **Any path
that isn't listed is inaccessible.**

These files cover the **filesystem only**. Network egress comes from [providers](providers.md).

Policies are chosen **by role, not by persona**. Several personas share each one.

| Policy | Role | `/sandbox/work` (the host mount) | Writable | Notes |
|---|---|---|---|---|
| `dev.yaml` | developers | read-write (`include_workdir: true`) | `/tmp`, `/sandbox/agent` | Used by the `*-general-dev` and `*-web-dev` personas |
| `review.yaml` | reviewers, planners | **read-only**, listed explicitly | `/tmp`, `/sandbox/agent` | Used with `mount_read_only: true`, so two independent layers stop edits |
| `strict.yaml` | untrusted input, experiments | none (use `--no-mount`) | `/tmp`, `/sandbox/agent` | Collect output with `openshell sandbox download` |

All three grant `/bin`, `/usr`, `/lib`, `/etc`, `/proc`, `/var/log` and `/dev/urandom` read-only, and
`/dev/null` read-write.

## Defense in depth for read-only roles

A reviewer can't edit the repo, for two independent reasons:

1. `launch.sh` bind-mounts the repo with `read_only: true`, because of `mount_read_only` in `persona.json`.
2. `review.yaml` lists `/sandbox/work` under `read_only` and sets `include_workdir: false`. If it were `true`,
   OpenShell would add the workdir to `read_write`.

Keep both. Either one alone is a single typo away from a reviewer that can write.

## Workflow: change a policy

1. Edit `policies/<p>.yaml`. Policies are read at launch, so **nothing needs rebuilding**.
2. Dry-run a persona that uses it and check the `--policy` path:

   ```bash
   ./launch.sh pi-pr-reviewer --dry-run
   ```

3. Prove both directions with a throwaway sandbox: the new access works, and the access it should still block
   fails. Run a shell under the policy directly, and probe the paths you care about:

   ```bash
   openshell sandbox create --from pi-pr-reviewer:local --no-tty --policy "$PWD/policies/review.yaml" -- \
     sh -c 'touch /sandbox/work/x && echo "work: WRITABLE" || echo "work: denied";
            touch /sandbox/agent/x && echo "agent dir: writable"'
   ```

**Before granting a new path**, check whether the need belongs elsewhere instead:

- Does a tool want a cache in `$HOME`? Point it at `/sandbox/agent` with an env var in the harness image. That's
  how `NPM_CONFIG_CACHE=/sandbox/agent/.npm` and omp's `PI_CONFIG_DIR` work.
- Is something installed in `/opt`? Install it under `/usr` instead (see [personas](personas.md)).

## Workflow: add a policy

Add a policy only for a genuinely new trust level, not for one persona's convenience. Copy the nearest existing
policy, explain its purpose and threat model in the header comment as the existing ones do, and set `policy` in the
personas that should use it. You can also try it on a single launch with `--policy policies/<new>.yaml`.

`launch.sh` warns when you use `strict` with a mount, because `strict.yaml` assumes there's no host directory.
