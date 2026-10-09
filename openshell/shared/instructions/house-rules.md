# House rules (harness-neutral, concatenated into every persona's AGENTS.md)

## 1. Documentation: always use Context7

Use the **Context7 MCP server** for all code documentation concerns and requirements. Never answer library, framework, SDK, API, CLI, config, or tooling questions from memory or training data — fetch current docs first, then write code.

Tools (call them from `codemode`, since MCP tools are deferred):

- `tools.mcp__context7__resolve_library_id({ libraryName, query })` → a Context7 library ID (`/org/project`, or `/org/project/version`)
- `tools.mcp__context7__query_docs({ libraryId, query })` → current docs + code examples for one concept

Workflow:

1. Identify the dependency and its installed version from the repo (`package.json`, lockfiles, `pyproject.toml`, `go.mod`, `Cargo.toml`, imports, error text).
2. Resolve the ID with the official name and punctuation (`Next.js` not `nextjs`, `Customer.io` not `customerio`) and a `query` describing the actual task.
3. Prefer exact name match, High source reputation, more code snippets, higher benchmark score, and the version matching what is installed (`/vercel/next.js/v16.2.9`).
4. Query docs with **one concept per call**: good — `Express.js JWT auth middleware setup`, `React useEffect cleanup examples`; bad — `auth`, `hooks`, or a multi-topic dump.
5. Implement from what the docs say, cite the library ID used, and flag any conflict between docs and the installed version.

Skip resolution only when the user already gives an `/org/project` (or `/org/project/version`) ID.

Use Context7 for: API signatures and behavior, setup/config/migrations/upgrades, diagnosing dependency errors and deprecations, verifying an API still exists in the pinned version, choosing between libraries, framework conventions for tests/build/CI/deploys, and anything the user asks to "look up" or "confirm".

Limits and hygiene:

- At most **3** `resolve_library_id` calls and **3** `query_docs` calls per question; if still unresolved, use the best candidate and say what could not be confirmed.
- Never put secrets in a query: no API keys, tokens, passwords, connection strings, or proprietary code.
- If Context7 returns nothing useful, say so, then fall back to vendored/installed source or repo docs, labeled as unverified. Never present memory as current documentation.
- Ask before guessing when the library or version is ambiguous; state assumptions when proceeding with a best match.

Context7 covers third-party docs only — project intent and internal conventions still come from the repo, its tests, and the user.

## 2. Aggressively use codemode

Prefer **`codemode`** as the default way to drive tools. Write JavaScript that calls tools; only the script's output reaches context. Use it instead of long chains of single tool calls.

Reach for `codemode` whenever a step involves more than one call, any fan-out, or anything worth filtering:

- **Parallelize**: independent lookups in one script with `Promise.allSettled()` — e.g. resolve several library IDs and query their docs at once; read config files plus list directories plus grep at once.
- **Fan out over many items**: loop/map over files, endpoints, issues, or test cases in a single script rather than iterating call-by-call across turns.
- **Filter and aggregate large output**: run `bash`/`read` inside a script and return only the summary — counts, matches, diffs, file lists, pass/fail tables. Never pull raw logs, full files, or huge JSON into context when a script can reduce it first.
- **Chain dependent work**: read → transform → decide → write in one script; branch on `exit_code`, `truncated`, `isError`.
- **Loops with early exit**: search-and-refine, retry-on-failure, paginated fetches, batch edits across many files.
- **Discovery**: find unlisted/MCP tools with `searchTools(query, { limit?, namespace? })`, `describeTool(name)`, `describeNamespace(name)`, `ALL_TOOLS` — do not assume a tool is unavailable because it is not listed.
- **State across turns**: `store(key, value)` / `load(key)` for small JSON such as IDs, cursors, summaries, checklists (256 Ki chars per value, 1 Mi total; never store image data).
- **Non-LLM models**: use `models.getAvailableOfType("classifier" | "image")`, `models.classify(...)` for triage/scoring/classification of JSON state, and `models.generateImages(...)` + `image(block)` for images. Read the codemode docs before using `models`.

Script rules:

- Input is raw JavaScript (no JSON, no code fence), run as an async function body in QuickJS: top-level `await` and `return` work. No Node APIs, no filesystem, no network, no timers — reach the outside only through `tools.*`, `models.*`.
- Optional first line: `// @options: {"max_output_tokens": 10000, "timeout_ms": 60000}`. Set `timeout_ms` for long work (image generation can take minutes); keep `max_output_tokens` small so output stays digestible.
- Output with `return`, `text(...)`, `console.log(...)`, `image(...)`; stop early with `exit()`.
- Use `Promise.allSettled()` where partial failure is expected, and report which calls failed instead of letting one rejection kill the batch.
- No timers means no waiting on promises that can never settle; always await the calls whose results you need — unawaited promises are discarded when the script ends.
- Script VM has 256 MB memory: filter/aggregate instead of accumulating large data, and write large data to a file with a tool rather than returning it.
- A failed script keeps its partial output plus `Script error:`; nested tool calls are real and already applied (validation, hooks, permission checks apply as for direct calls) — make scripts idempotent or ordered accordingly.
- Scripts cannot start other `codemode` scripts.

Direct tool calls remain fine for single obvious steps (one read, one edit). Do not use `codemode` for a single trivial call, and do not use it to hide destructive actions: state intent before edits, deletions, or anything touching production systems.

## 3. Sandbox contract

- You are already executing inside a secure OpenShell sandbox. Do not attempt to instantiate new sandboxes or call container runtimes to test code. Execute all test commands and code directly via local bash subprocesses.
- Your working directory is `/sandbox/work` (the host repository, mounted per policy — possibly read-only). Your own writable config/session space is `/sandbox/agent`; scratch space is `/tmp`.
- If a write is blocked by policy, do not work around it: report what was blocked and where the output should go instead.
