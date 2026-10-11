// Client for the host-side launcher (factory/launcher). The orchestrator sandbox reaches it at
// host.openshell.internal:8787 through the `launcher` provider. FACTORY_LAUNCHER_TOKEN inside the
// sandbox is only a placeholder; OpenShell's proxy swaps in the real token on the way out.

import { Agent, fetch, type RequestInit } from "undici";

const BASE_URL = process.env.FACTORY_LAUNCHER_URL ?? "http://host.openshell.internal:8787";

// /run sends nothing until the agent finishes; fetch's default 300s headers timeout would cut off
// longer runs. The launcher enforces its own per-run timeout instead.
const dispatcher = new Agent({ headersTimeout: 0, bodyTimeout: 0 });

export interface RunResult {
  sandbox: string;
  persona: string;
  exit_code: number;
  duration_ms: number;
  stdout: string;
  stderr: string;
}

async function call<T>(path: string, init: RequestInit = {}): Promise<T> {
  let res;
  try {
    res = await fetch(`${BASE_URL}${path}`, {
      ...init,
      dispatcher,
      headers: {
        authorization: `Bearer ${process.env.FACTORY_LAUNCHER_TOKEN ?? ""}`,
        "content-type": "application/json",
        ...init.headers,
      },
    });
  } catch (err) {
    // fetch only says "fetch failed"; the useful part is in `cause` (ECONNREFUSED, EACCES, ...).
    const cause = (err as { cause?: { code?: string; message?: string } }).cause;
    throw new Error(
      `launcher unreachable at ${BASE_URL}${path} (${cause?.code ?? cause?.message ?? err}). ` +
        "Is factory/launcher running on the host (cd factory/launcher && cargo run)?",
    );
  }
  const body = (await res.json()) as T & { error?: string };
  if (res.status === 401) {
    throw new Error("launcher rejected the token: check the `launcher` provider's FACTORY_LAUNCHER_TOKEN " +
      "matches ~/.config/factory/launcher.token");
  }
  if (!res.ok) throw new Error(`launcher ${path}: ${res.status} ${body.error ?? JSON.stringify(body)}`);
  return body as T;
}

export const health = () => call<{ launcher: string; gateway: string; version: string }>("/health");

export const personas = () => call<{ personas: string[] }>("/personas");

export const run = (persona: string, task: string, timeoutSecs = 900) =>
  call<RunResult>("/run", {
    method: "POST",
    body: JSON.stringify({ persona, task, timeout_secs: timeoutSecs }),
  });

/** pi `--mode json` prints one event per line; the agent's answer is the text of the last turn. */
export function finalText(stdout: string): string {
  let text = "";

  for (const line of stdout.split("\n")) {
    if (!line.startsWith("{")) continue;

    const event = JSON.parse(line);

    if (event.type === "turn_end") {
      text = (event.message?.content ?? [])
        .filter((part: { type: string }) => part.type === "text")
        .map((part: { text: string }) => part.text)
        .join("");
    }
  }
  return text;
}
