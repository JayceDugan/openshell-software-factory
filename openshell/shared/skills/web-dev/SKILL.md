---
name: web-dev
description: Build, serve, and visually check React / Next.js / Vite apps inside the OpenShell sandbox with the headless browser (agent-browser + Chromium). Use when writing or debugging web UI, when a change needs to be seen in a browser, or when asked to verify a page renders and behaves.
---

# Web dev in this sandbox: build, serve, look

The loop is: **install → build/lint/test → serve on localhost → open it with `agent-browser` → fix → repeat.** A UI change is not verified until you have opened the page and read its snapshot and console.

Load `/skill:agent-browser` for the full command reference. This skill covers what is specific to this sandbox.

## 1. Install dependencies inside the sandbox

`node_modules` in `/sandbox/work` may have been installed on the user's Mac, so it lacks Linux native binaries (`@next/swc-linux-*`, `lightningcss-linux-*`, `@tailwindcss/oxide-linux-*`). Symptoms: "Failed to load SWC binary", "Cannot find module '../lightningcss.linux-arm64-gnu.node'".

Run the repo's own installer (`npm install`, or `npm ci` when the lockfile is authoritative). This swaps the macOS binaries for Linux ones, which is expected; mention in your summary that the host needs a fresh install afterwards. Only the npm registry is reachable; other package hosts are blocked by policy.

## 2. Serve in the background, wait for the port

```sh
# New session; the inner shell records its own pid, which is the process group id.
# (Not `echo $!`: setsid forks when the caller leads a process group, so $! is the wrong pid.)
setsid sh -c 'echo $$ > /tmp/dev.pid; exec npm run dev -- -p 3000' > /tmp/dev.log 2>&1 < /dev/null &
# Next: `next dev -p 3000`; Vite: `vite --port 3000`
for i in $(seq 1 60); do curl -s -o /dev/null -m 2 http://localhost:3000 && break; sleep 2; done
tail -30 /tmp/dev.log
```

Never run a dev server in the foreground: it never exits and blocks your shell. Stop it with `kill -- -$(cat /tmp/dev.pid)`, which kills the whole process group. Killing only npm's PID leaves `next dev` serving. Do not use `pkill -f "next dev"`: the pattern also matches the shell running that command and kills it (exit 143). Check `/tmp/dev.log` when the page looks wrong; compile errors land there, not in the browser.

To check the production build: `npm run build`, then start it the same way with `npm run start -- -p 3001`, writing `/tmp/start.pid` and `/tmp/start.log`.

## 3. Always use `http://localhost:PORT`, never `127.0.0.1`

IPv4 loopback TCP is swallowed inside this sandbox (`net::ERR_SOCKET_NOT_CONNECTED`, curl "Empty reply"). `localhost` resolves to `::1`, which works. If a server binds IPv4 only (`--host 127.0.0.1`, `server.host: '127.0.0.1'`), start it with `--host ::` or `--hostname localhost` instead for the session; do not commit that change.

## 4. Look at it

```sh
agent-browser open http://localhost:3000
agent-browser snapshot -i          # interactive elements with @eN refs
agent-browser click @e2            # act by ref from the latest snapshot
agent-browser console              # browser console output
agent-browser errors               # uncaught page errors
agent-browser screenshot           # saved under /tmp/screenshots/ (pass a path only if its dir exists)
agent-browser close
```

Re-snapshot after every navigation or state change: refs go stale. Check each route you touched, plus console and errors, before you call a change done. Report what you opened and what you saw.

The browser is preconfigured (`AGENT_BROWSER_EXECUTABLE_PATH`, `AGENT_BROWSER_ARGS`). Do not run `agent-browser install`: there is no Chrome for Testing build for linux-arm64, and Chromium is already in the image.

## 5. Network limits that show up in web apps

- `next/font/google` needs the `googlefonts` provider. Without it `next dev` falls back to system fonts with a warning and `next build` fails with "Failed to fetch ... from Google Fonts". Report it; don't switch the repo to `next/font/local` unless asked.
- External APIs, CDNs, and analytics the page calls will fail in the browser. Treat those console errors as environmental and say so, rather than "fixing" them in code.
- Next telemetry is disabled (`NEXT_TELEMETRY_DISABLED=1`).
