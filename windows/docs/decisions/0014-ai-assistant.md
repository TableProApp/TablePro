# 0014: The AI assistant

- **Status**: Accepted
- **Date**: 2026-11-18

## Context

The macOS and Linux apps have an AI assistant: a chat about the connection's tables, Explain, Review, Optimize and Fix on a statement, provider keys in the platform's secret store, and an AI policy per connection with a question before the first request under Ask. The core now carries the providers, the prompts, the schema read and the streamed reply across the FFI ([core 0032](../../../core/docs/decisions/0032-ai-through-the-ffi.md)).

## Decision

- Settings has an AI assistant section: Provider (Off, Anthropic, OpenAI, Ollama or compatible server), the server's address for the compatible server, the API key in a PasswordBox saved to Credential Manager through the core with Save key and Remove key, and the model in an editable ComboBox whose list is read from the provider each time it opens. Off is where it starts, so nothing is sent anywhere until a provider is chosen. The key is never shown again; the card says whether one is kept.
- The connection form's Options has AI assistant: Ask each time, Always allow or Never, each with what it sends, saved with the connection. A save that leaves it alone keeps the stored one.
- View > Show AI assistant opens a pane where the query history sits, one at a time. It shows Off with Open Settings, the connection's Never, or the conversation: each question in a card, "Sent with the structure of" the tables described, the reply streaming in as paragraphs with bold and inline code in a RichTextBlock and code blocks with Copy and Insert in editor, then its tokens, Stopped, or the error with Retry. Enter sends and Shift+Enter starts a line; Stop ends a reply and keeps what came; New conversation starts again. A reply is painted at most every 80 ms.
- The editor's menu and the Query menu have Review, Explain and Optimize with AI, on the selection or the statement at the caret, enabled while the assistant may be asked and the engine has SQL. A refused run's error bar has Fix with AI, which sends the statement with the error as the results pane words it. Each starts a new conversation.
- Under Ask each time the first request asks in a ContentDialog that names the connection and the provider and host the data goes to, with Cancel the default. The answer lasts for that provider and address until the connection disconnects: the pane is built per session. The policy and the settings are read again before each request, and a change of provider or address, or the policy moving to Never, asks again or stops a reply in flight.
- Insert in editor replaces the selection or inserts at the caret of the query tab in front as one undo step, or opens a new query tab.
- Narrator hears a reply's end and an error through a notification on the pane.
- Each `ai.*` code has its sentence with the host, status or provider it names, and the provider's own words after it.

## Rationale

- Stock WinUI controls: SettingsCard, ComboBox, PasswordBox, TextBox, RichTextBlock, ContentDialog, CommandBar and InfoBar's action button. WinUI has no Markdown control and the Toolkit's is still in Labs, so the reply is read into RichTextBlock paragraphs and code blocks by `ReplyMarkdown` in the app model.
- The pane where the history and saved queries sit keeps the editor and the grid at their width, as the Linux pane beside the tabs does.

## Consequences

- No inline suggestions while typing, no agent mode, no saved conversations, no `@` context and no AI rules per connection (roadmap A-06), and three providers (A-07).
- Tables named in SQL outside the editor's schema are not described until the completion scope moves into the core (C-08).
- A connection opened from a file without saving it has no policy of its own, so the assistant asks under Ask.
