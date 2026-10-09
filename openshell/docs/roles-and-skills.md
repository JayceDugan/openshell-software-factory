# Roles and skills

Instructions are split across three files. None of them is tied to a harness, so pi and omp read the same text.

| | File | Loaded | Answers |
|---|---|---|---|
| **House rules** | `shared/instructions/house-rules.md` | always, at the top of every `AGENTS.md` | How does *every* agent here behave? (Context7 for docs, MCP via codemode) |
| **Role** | `shared/instructions/roles/<role>.md` | always, appended to `AGENTS.md` | What is *this* agent's job, and what does done look like? |
| **Skill** | `shared/skills/<skill>/SKILL.md` | **on demand**, when the agent decides it's relevant or a role says to load it | How do I do this specific kind of work well? |

At build time, each persona's `AGENTS.md` is `house-rules.md` followed by `<role>.md`. Every persona gets the
whole `shared/skills/` directory at `/sandbox/agent/skills/`.

**Rule of thumb:** a role says *what* and *why*, and a skill says *how*. A role can be short because it points at
skills. A skill can be long because it's only read when needed.

## Workflow: change a role

1. Edit `shared/instructions/roles/<role>.md`.
2. Find every persona that uses it. Those are the ones to rebuild:

   ```bash
   grep -l 'roles/<role>.md' personas/*/Containerfile
   ./build.sh <persona> [<persona> ...]
   ```

3. Check the result with a headless run (see [running and debugging](running-and-debugging.md)).

### Writing a good role

The existing roles follow one shape. Keep to it so that agents behave predictably:

```markdown
# Role: <name>

One paragraph: who you are, which directory you work on, what you may and may not do.

## Operating rules
1. Follow the repo, not your preferences…
2. Load the matching skills (`/skill:<name>`)…
3. Verify by execution…
…
6. Stay inside the sandbox contract (/sandbox/work, /tmp, /sandbox/agent); report policy blocks instead of routing around them.

## Definition of done
- concrete, checkable bullets
```

- State what the agent **can't** do in this sandbox, such as no SDK, read-only mount, or no GitHub access, so it
  reports honestly instead of guessing.
- Don't restate the house rules.
- Don't put harness-specific commands in a role. If pi and omp would need different text, it belongs in that
  persona's payload or Containerfile.

## Workflow: add a role

1. Write `shared/instructions/roles/<new-role>.md` in the shape above.
2. Choose the policy that fits it (see [policies](policies.md)). Does it write code? Does it touch the host repo?
3. Create a persona that uses it (see [personas](personas.md)).

## Workflow: add a skill

Skills follow the [Agent Skills](https://agentskills.io) spec, which pi and omp both implement. One skill is
written once and works in every persona.

1. Create `shared/skills/<skill-name>/SKILL.md`:

   ```markdown
   ---
   name: <skill-name>            # must match the directory name
   description: <what it covers AND when to use it. This is all the agent sees before loading it,
     so name the triggers: file types, frameworks, tasks.>
   ---

   # <Title>

   The procedure, the commands, the sandbox-specific gotchas, and the quality bar.
   ```

   Extra files, such as scripts or reference docs, can sit next to `SKILL.md` in the same directory.

2. If a role should always use the skill, reference it there: "Load `/skill:<skill-name>` before …".
3. Rebuild the personas. Every persona copies `shared/skills/`, so in practice that's all of them:

   ```bash
   ./build.sh
   ```

### Writing a good skill

Use `shared/skills/web-dev/SKILL.md` as the model:

- **Be specific to this sandbox.** "Use `localhost`, not `127.0.0.1`" and "`node_modules` from the Mac lacks Linux
  binaries, so run `npm install`" are what make a skill earn its place. Generic advice the model already knows
  doesn't.
- **Give a loop, not a lecture.** For example: install, then build and test, then serve, then look, then fix.
- **Point at other skills** instead of duplicating them. web-dev defers to `agent-browser` for command details.
- **Don't invent APIs.** Have the skill tell the agent to check Context7, and don't freeze version-specific
  details into it.

### Skills installed by a layer

Some skills ship with a tool. `shared/browser/install.sh` installs agent-browser's own skill as
`skills/agent-browser`, so only personas with that layer have it. That's the right place for a skill that's
useless without its tool.
