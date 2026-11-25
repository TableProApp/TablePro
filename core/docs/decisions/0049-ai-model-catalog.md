# 0049: A provider's model list merges with one model catalog

- **Status**: Accepted; the catalog refresh under `AllowOtherAccountServers` amended by 0055
- **Date**: 2026-11-24

## Context

Each app decided five things per model from tables written by hand: which models exist, their order, their names, the default and the reasoning levels. The tables drifted apart: macOS started a new Claude provider on one model, Linux and Windows on `claude-opus-5-5`, and the macOS offline list lacked models Anthropic already served. Meanwhile the providers' own lists carry most of these facts and the decoders dropped them. The core listed ids only, so Linux and Windows offered every id OpenAI's `/v1/models` returns, embeddings and Responses-only models included, which fail on the Chat Completions protocol the core speaks to OpenAI.

## Decision

- **The provider's list decides which models exist** and every field it states. Anthropic gives the name, the release day and the lifecycle; OpenAI the release day and a shutdown date; a compatible server its ids and any `name`.
- **One catalog fills the gaps**: `core/crates/ai/ai-models.json`, generated from models.dev's v2 API by `scripts/ai-models/generate.py`. Schema 1 holds, per provider key (`anthropic`, `openai`, `openai-codex`, `google`, `xai`, `meta`), a default model and each model's name, release day, deprecation, output limit, image input, reasoning and the protocols it takes (`apis`). A file with another schema is ignored; an unknown provider key, API or effort is skipped.
- **Where it lives.** Every app bundles the committed copy: `tablepro-ai` through `include_str!`, the macOS app as a resource. The committed copy is refreshed by running `scripts/ai-models/generate.py`. A newer copy is published at `https://updates.tablepro.app/ai/models-v1.json`; an app fetches it only when a hosted provider's model list loads, at most once an hour per process, with `If-None-Match` from the stored ETag and no key, account or user agent. The core keeps it under the app's cache folder (`ai-models`), checks that it reads before replacing the copy kept, and uses the newer `generated` of the bundled and the kept copy. A failed fetch is logged at debug and never holds a list up.
- **The merge**, one pure function per language, pinned by the shared cases in `core/crates/ai/tests/model-merge-cases.json`:
  1. A listed id finds its catalog entry by the id, else by the base of a fine-tune (`ft:<base>:...`), else either without a trailing `-YYYY-MM-DD`.
  2. A model is left out when its entry's `apis` lack the protocol the client speaks, and a model with no entry is left out where unknown ids are hidden: OpenAI on its own host, Meta on its own host.
  3. Each field is the provider's, else the catalog's. A model is deprecated when either says so.
  4. The default is the one the provider flags, else the catalog's default when it is listed.
  5. Where the provider documents its order (Anthropic, Meta, ChatGPT's Codex backend) it is kept; elsewhere the newest release comes first, models without a day after those with one, ties by id. Then the default comes first and deprecated models last.
  6. When the list fails, the catalog's models for that provider that the client can reach are shown, each marked offline, beside the error.
- **Linux and Windows resolve an empty model once.** The Linux `ai-anthropic-model` key defaults to empty, and Windows has no hard-coded model. An empty model for a hosted provider takes the catalog's default the first time the provider is shown or used, and that id is saved. A saved model is never changed.

## Rationale

- The provider knows its models best and soonest; the catalog only covers what the provider does not say, so a stale catalog costs a name or an order, not a model.
- models.dev is MIT, updated several times a day, and its v2 API carries the protocols per model, which v1 lacks and the Chat Completions filter needs.
- One file read by every app ends the drift between the hand tables.
- Bundling keeps the lists working offline and on a first run; the keyless refresh reaches users between releases without asking a third party's host for every user.

## Consequences

- `updates.tablepro.app` is a new destination, reached only when a hosted provider's model list loads.
- On OpenAI's host, a new model shows only once the catalog lists it. On Anthropic's, it shows at once, with the provider's name.
- A fine-tune or a dated snapshot takes its base's entry, so it keeps its base's protocols and name.
- An untouched Linux or Windows user stays on the model saved on first use when a later catalog names another default.
- models.dev is edited by the public; the generator refuses a file that drops a listed model without deprecating it first, loses more than a few models of a provider, or names a missing or deprecated default.

## Alternatives considered

- **Keep a table per app.** It drifted within weeks, and the providers' lists already hold most of it.
- **models.dev's v1 API.** It has no per-model protocol, so it cannot tell a Responses-only model from one Chat Completions reaches, and it lists embeddings as text models.
- **Fetch models.dev from the apps.** Every user's address would reach a third party, with no check between an upstream edit and the apps.
- **Let an empty model follow the catalog's default.** A user who never picked a model would move to another between releases without being asked.
