# Models and the inference endpoint

Every persona talks to **Bifrost**, an OpenAI-compatible inference router on the homelab:

- base URL `http://homelab:8080/v1`, with `api: openai-completions`. The harness appends `/chat/completions`.
- model `Strata/qwen3.8-flash-next-iq3_xxs`, with a context window of 262144. Bifrost names models as
  `provider/model`.
- `apiKey: "unused"`, because the bifrost provider has no credential.

The model is set in the **persona payload**, so it's baked into the image. Network access to the endpoint comes
from the `bifrost` [provider](providers.md).

## Where the model is set

| Harness | File | What to change |
|---|---|---|
| pi | `payload/models.json` | `providers.bifrost.models[].id`, `contextWindow`, `input` |
| pi | `payload/settings.json` | `defaultProvider`, `defaultModel` (must match an id in `models.json`) |
| omp | `payload/models.yml` | `providers.bifrost.models[].id`, `name`, `contextWindow`, `input` |
| omp | `payload/config.yml` | `modelRoles.default` (and `vision`), written as `bifrost/<model id>` |

Set `input: [text, image]` only if the model really is vision-capable. Without it, omp treats the model as
text-only and silently drops images.

## Workflow: switch every persona to a new model

1. Confirm that Bifrost serves the model and that you have its exact id. A request with a wrong id fails at
   runtime, not at build.
2. Update every payload at once:

   ```bash
   OLD='Strata/qwen3.8-flash-next-iq3_xxs'; NEW='Strata/<new-model>'
   grep -rl "$OLD" personas/*/payload | xargs sed -i '' "s#$OLD#$NEW#g"
   ```

   Then fix `contextWindow` (and `name` in the omp files) by hand.
3. Rebuild with `./build.sh`, and do a headless run on one pi persona and one omp persona.

To change one persona only, edit that persona's payload and rebuild only that persona. Planners and reviewers can
reasonably use a different model from developers.

## Workflow: add a different inference backend

`vllm`, `ninfer`, and `unsloth` profiles already exist. To use one:

1. Make sure the provider exists (`openshell provider list`), and add it to the persona's `providers`. Without that,
   the endpoint is unreachable from the sandbox.
2. Add a second entry under `providers` in the payload's `models.json` or `models.yml`, with that backend's
   `baseUrl`, and point the default model at it.
3. Rebuild the persona.

Keep inference providers off personas that don't use them. An agent that can reach several inference endpoints is
a cost and leak surface. That's why `pi-planner` gets fewer providers.
