# 0032: The AI assistant crosses the FFI

- **Status**: Accepted
- **Date**: 2026-11-18

## Context

`tablepro-ai` speaks Anthropic's Messages API and the Chat Completions protocol OpenAI and Ollama share, writes the prompts and streams a reply. The Linux app calls it directly and keeps the rest in `linux/crates/app`: the key in the keyring, the schema read for a prompt, the per-connection AI policy and the question under Ask Each Time. The Windows app reaches the core only through `crates/ffi`, which exposed none of it, and `ConnectionRecord` dropped the saved connection's `ai_policy`.

## Decision

- `Core::ai_assistant()` gives an `AiAssistant` over the core's secret store and one `AiClient`, built off the caller's thread on first use and shared by every assistant.
- `has_key(provider)` says whether a key is kept and `set_key(provider, key)` keeps it trimmed, or removes it when blank. The key is read again from the store for each request and never crosses back to the app. A provider that needs no key reads none when the store cannot be read.
- `AiSettingsArg` names the provider, the model and, for the compatible server only, its address. A hosted provider always goes to its own address, so no app setting can send its key elsewhere. `ai_host_of` names the host a request goes to and `ai_address_is_valid` checks an address as a request takes it.
- `start_conversation(session, engine, asked, editor, database)` reads the session's catalog, never a row: the tables and views of the schema the editor is in, or of the editor's database where the server's databases are its schemas, and the columns of the ones whose names stand in the question, the statement or the editor's text as words, up to `MAX_DESCRIBED_TABLES` in catalog order. A database elsewhere carries only its name. It returns `chat_system_prompt` and the names described.
- `reply(session, settings, chat, listener)` returns an `AiReply` at once. Its events are drained as a run's are: text, joined while the app is busy, then one of `Finished` with the stop reason and token counts, `Failed` with an `ErrorInfo`, or `Stopped` after a cancel or the session's shutdown. Dropping it stops the reply, and a closed session's reply sends nothing.
- `start_conversation` and `reply` read the saved connection's policy before anything is sent and refuse Never with `ai.blocked`. Asking under Ask, and remembering the answer, is the app's, as on Linux.
- An `AiError` keeps its `ai.*` code; `ErrorInfo.ai` carries its host, status, provider and transport detail, and the provider's own words go in `server`. `tablepro-ai` takes the key it sent out of every text a server or the transport wrote before an error leaves it, so a server that echoes the key cannot show it.
- `ConnectionRecord.ai_policy` reads back the saved policy; on a save, None keeps the stored one, so a record built without it never resets Never.
- `ai_action_message` and `ai_providers` are functions of their own.

## Rationale

- One client, one key store and one prompt writer: the Windows app words and lays out, as `windows/AGENTS.md` asks.
- The policy check in the core keeps a connection under Never out of every prompt even if an app's own check is skipped or stale.
- Names found as words cover a question in words and a statement alike, without the SQL parser the Linux app's completion code holds.

## Consequences

- A table named in SQL only with its schema, outside the schema the editor is in, is not described. Describing it waits on the completion scope moving into the core (roadmap C-08).
- Inline suggestions stay Linux's: `completion_message` and `clean_completion` are not exposed yet.
- A file opened without saving has no saved policy, so it is asked about under Ask.
