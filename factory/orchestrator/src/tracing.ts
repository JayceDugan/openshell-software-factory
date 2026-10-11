// Langfuse tracing for every graph run. The orchestrator sandbox gets the `langfuse` provider, so
// LANGFUSE_PUBLIC_KEY/SECRET_KEY here are placeholders that OpenShell's proxy swaps for the real
// keys on the way out. LANGFUSE_BASE_URL is a placeholder too, which is useless as a URL, so the
// endpoint is set here instead (factory/langfuse, reached through host.openshell.internal).
//
// LangGraph -> CallbackHandler (one span per node/run) -> OpenTelemetry -> LangfuseSpanProcessor
// -> POST /api/public/otel/v1/traces.

import { CallbackHandler } from "@langfuse/langchain";
import { LangfuseSpanProcessor } from "@langfuse/otel";
import { NodeTracerProvider } from "@opentelemetry/sdk-trace-node";

const BASE_URL = process.env.FACTORY_LANGFUSE_URL ?? "http://host.openshell.internal:3000";

const enabled = Boolean(process.env.LANGFUSE_PUBLIC_KEY && process.env.LANGFUSE_SECRET_KEY);

if (enabled) {
  new NodeTracerProvider({
    spanProcessors: [
      new LangfuseSpanProcessor({
        baseUrl: BASE_URL,
        environment: "dev",
        // Send each span as it ends: the dev server restarts on every edit, and a batch still
        // in memory at that point would be lost.
        exportMode: "immediate",
      }),
    ],
  }).register();
} else {
  console.warn("langfuse: no LANGFUSE_PUBLIC_KEY/SECRET_KEY (missing `langfuse` provider?), tracing off");
}

/**
 * Uses the LangGraph thread id as the Langfuse session, unless the caller set one. runAgent passes
 * the same id to the agent (pi --session-id), so in Langfuse > Sessions one thread shows the
 * orchestrator trace next to the pi-agent traces it started.
 */
class FactoryHandler extends CallbackHandler {
  override handleChainStart(...args: Parameters<CallbackHandler["handleChainStart"]>) {
    const metadata = args[5];
    if (typeof metadata?.thread_id === "string" && !metadata.langfuseSessionId) {
      args[5] = { ...metadata, langfuseSessionId: metadata.thread_id };
    }
    return super.handleChainStart(...args);
  }
}

/** Callbacks to attach to every graph run; empty when tracing is off. */
export const callbacks = enabled ? [new FactoryHandler({ tags: ["factory"] })] : [];
