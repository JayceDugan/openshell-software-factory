// The smallest useful factory graph:
//
//   START -> ping -> (task given?) -> runAgent -> END
//                         \-> END
//
// LangGraph in three ideas:
//   State: one typed object that flows through the graph. Nodes return partial updates, and
//          LangGraph merges them in (last write wins unless a channel defines a reducer).
//   Nodes: plain async functions, (state) => partial state.
//   Edges: fixed ("always go to X") or conditional (a function that picks the next node).

import { Annotation, END, START, StateGraph } from "@langchain/langgraph";
import * as launcher from "./launcher.js";

const State = Annotation.Root({
  // Input: what the agent should do. Leave it empty to only check connectivity.
  task: Annotation<string>,
  // Which persona runs the task. Only personas with a verified headless mode are accepted.
  persona: Annotation<string>({ reducer: (_old, next) => next, default: () => "pi-general-dev" }),
  // Outputs.
  launcher: Annotation<string>,
  reply: Annotation<string>,
  exitCode: Annotation<number>,
  sandbox: Annotation<string>,
});

type FactoryState = typeof State.State;

async function ping(): Promise<Partial<FactoryState>> {
  const h = await launcher.health();
  return { launcher: `launcher ${h.launcher}, gateway ${h.gateway} ${h.version}` };
}

async function runAgent(state: FactoryState): Promise<Partial<FactoryState>> {
  const result = await launcher.run(state.persona, state.task);

  return {
    reply: launcher.finalText(result.stdout),
    exitCode: result.exit_code,
    sandbox: result.sandbox,
  };
}

function afterPing(state: FactoryState): "runAgent" | typeof END {
  return state.task?.trim() ? "runAgent" : END;
}

export const graph = new StateGraph(State)
  .addNode("ping", ping)
  .addNode("runAgent", runAgent)
  .addEdge(START, "ping")
  .addConditionalEdges("ping", afterPing, ["runAgent", END])
  .addEdge("runAgent", END)
  .compile();

graph.name = "factory";
