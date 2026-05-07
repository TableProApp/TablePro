# AI Chat Panel Redesign

**Status**: PR A merged, B-H pending
**Created**: 2026-05-07
**Driver**: Native macOS / Apple HIG correctness for the AI chat surface
**Scope**: TablePro/Views/AIChat, TablePro/ViewModels/AIChatViewModel, TablePro/Core/AI/Chat (~5,800 LOC)

## Why

The current AI chat panel grew organically across 12+ PRs in the umbrella (#1057-#1072). Architecture is solid (transport, tools, parser tests all in place). UI/UX is not. Concrete pain:

- `ChatComposerTextView` is a 293-LOC `NSViewRepresentable` fighting `NSTextView` + deprecated `NSLayoutManager` (TextKit 1) when SwiftUI's `TextEditor(axis: .vertical)` handles it natively on macOS 13+.
- `AIChatCodeBlockView` ships a 340-LOC hand-rolled regex SQL/JS highlighter with `force_try` suppression. The app already runs `CodeEditSourceEditor` (tree-sitter) for the main editor.
- 80+ LOC of business logic (`mentionCandidates`, `isVisibleInMessageList`) lives inside `AIChatPanelView`.
- Action row chains 5 borderless `Menu`s where `.toolbar { }` is HIG-canonical.
- `currentQuery` / `queryResults` flow into the viewmodel via manual `updateContext()` calls before send. Stale during streaming.
- `AIChatMessageView` has 4 non-localized strings (`"You"`, `"Generation failed."`, `"Retry"`, `"Regenerate"`).

Plus open issues from the umbrella that need a UX home:
- Tool-call permission gating for destructive SQL (the existing `confirm_destructive_operation` is a wire contract; the UX is a generic safe-mode dialog).
- Per-connection rules (PII columns, naming conventions) have nowhere to live.
- Multibuffer review for queued INSERT/UPDATE/DELETE doesn't exist.
- No inline assistant in the SQL editor for rewrite-in-place.

## Research

Four parallel research streams (2026-05-07):

| Stream | What | Output |
|---|---|---|
| VS Code Copilot Chat | Marketplace + docs + repo audit | Edit-in-editor wins, three-symbol composer, tiered approval |
| Zed + Cursor | Both editors' agent panels in depth | Three modes wins over six, multibuffer review, checkpoints, threads sidebar |
| Apple HIG | First-party AI surfaces + HIG sections | Inspector panel skeleton, no bubbles, segmented mode picker, `arrow.up.circle.fill` send |
| Internal audit | TablePro's existing chat code | 5,817 LOC mapped, kept/redesigned/deleted lists |

### Convergent signals (lock in)

1. **Plain stacked transcript with `.secondary` role label, no bubbles.** Apple's first-party AI never bubbles. Bubbles are Messages-only.
2. **Inline collapsible tool-call cards** (`DisclosureGroup`).
3. **Tiered approval for destructive operations** (per-card "Run / Always for this connection / Cancel").
4. **Hover-revealed code-block action row** (Copy / Insert / Run).
5. **Empty state with starter prompt chips** (Apple HIG calls this out by name in the Generative AI section).
6. **Theme tokens shared between editor and chat** (audit confirmed currently broken).
7. **Typing-anchored `@` picker** as primary path; button as discovery fallback.
8. **Cmd-Return send, Shift-Return newline, Esc cancel.**

### Divergent picks

| Question | Pick | Source / why |
|---|---|---|
| Number of modes | **3 (Ask / Edit / Agent)** | Zed agrees. Apple `Picker(.segmented)` caps at 5-7. Cursor's six modes draw user complaints. |
| Mode picker placement | **Toolbar `Picker(.segmented)`** | HIG-canonical. Toolbar items also appear in Customize Toolbar / menu bar. |
| Conversation history | **Title-bar `Menu` dropdown** | VS Code pattern. Sidebar (Zed) is overkill for a single-window app. |
| Composer symbols | **`/` for verbs, `@` for nouns** | Cursor's split. Cleaner than Zed's @-only. |
| Tool-call default state | **Collapsed pill with permission dropdown** | Zed pattern. Per-call gating, not global toggles. |
| Send glyph | **`arrow.up.circle.fill`** | Apple uses this in Messages. Paper-plane is web cargo-cult. |

## Design

### Layout

```
NSWindow (TablePro main window)
└─ NSSplitViewController
   ├─ Sidebar         (connection / database tree)
   ├─ Detail          (query editor + results)
   └─ Inspector       NSSplitViewItem(behavior: .inspector)
      └─ NSVisualEffectView(.sidebar, .behindWindow)
         ├─ .toolbar:
         │     Picker(.segmented)   Ask | Edit | Agent
         │     Menu(NSPopUpButton)  Model picker
         │     Button               square.and.pencil  (new conversation, Shift-Cmd-N)
         │     Menu                 clock              (history dropdown)
         ├─ ScrollView (reverse-scroll, sticky-bottom)
         │     ForEach(messages):
         │       Text role label (.secondary, .caption)
         │       Markdown text     (no bubble, no avatar)
         │       DisclosureGroup   tool-call cards (collapsed by default)
         │       CodeEditSourceEditor (read-only, theme-synced)
         ├─ ContentUnavailableView (empty state + starter chips)
         ├─ Divider
         └─ Composer:
               WrapLayout of attachment chips
               TextEditor(axis: .vertical)
               HStack: + (attach) | spacer | stop / send (arrow.up.circle.fill)
```

### Modes

| Mode | Tool exposure | Confirmation |
|---|---|---|
| **Ask** | Read-only tools only (`list_*`, `describe_*`, `get_table_ddl`, `search_query_history`) | None |
| **Edit** | Above + `execute_query` (writes via SafeModeGuard) | Per-call card-level approval for `INSERT/UPDATE/DELETE` |
| **Agent** | Above + `confirm_destructive_operation` (DDL with phrase) | Per-call card + transaction savepoint per turn |

Mode selector lives in the toolbar via `Picker(.segmented)`. Switching mode rebuilds `ChatToolRegistry.allSpecs` to expose only the tools allowed in that mode (provider sees fewer tools in Ask vs Agent).

### Composer

Drop the `NSViewRepresentable` wrapper entirely. SwiftUI native:

```swift
TextEditor(text: $viewModel.inputText)
    .textEditorStyle(.roundedBorder)        // macOS 14+
    .lineLimit(1...5)
    .scrollDisabled(false)
    .onSubmit { viewModel.send() }          // Cmd-Return wired separately
    .onChange(of: viewModel.inputText) { detectMention() }
```

Mention popover: SwiftUI `.popover(isPresented:attachmentAnchor:)` on a `GeometryReader` overlay. The pure `MentionDetector` logic stays unchanged.

Send button:

```swift
Button {
    viewModel.send()
} label: {
    Image(systemName: "arrow.up.circle.fill")
}
.buttonStyle(.borderedProminent)
.controlSize(.large)
.keyboardShortcut(.return, modifiers: .command)
.disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
```

### Tool-call cards

```swift
DisclosureGroup {
    // Input JSON, output content, error if any
} label: {
    HStack {
        Image(systemName: statusSymbol)
            .foregroundStyle(statusColor)
        Text("Calling \(toolName)")
            .foregroundStyle(.primary)
        Spacer()
        if needsApproval {
            Menu {
                Button("Run once") { ... }
                Button("Always for this connection") { ... }
                Button("Cancel", role: .cancel) { ... }
            } label: {
                Image(systemName: "lock.shield")
            }
            .menuStyle(.borderlessButton)
        }
    }
}
.padding(.vertical, 4)
```

### Code blocks

Replace `AIChatCodeBlockView`'s regex highlighter with a read-only `CodeEditSourceEditor` per block, theme-synced via the existing `SQLEditorTheme`. Hover-revealed action row: Copy, Insert at Cursor, Run as new tab (for SQL only).

### Empty state

```swift
ContentUnavailableView {
    Label("Ask AI about your database", systemImage: "sparkles")
} description: {
    Text("Get help writing queries, exploring schema, or fixing errors.")
} actions: {
    HStack {
        Button("Show me the schema") { ... }
        Button("Find slow queries") { ... }
        Button("Generate a migration") { ... }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
}
```

Starter chips adapt to connection type (different prompts for SQL vs MongoDB vs Redis).

### Keyboard

| Shortcut | Action |
|---|---|
| `Cmd-/` | Toggle inspector |
| `Cmd-Return` | Send |
| `Shift-Return` | Newline in composer |
| `Esc` | Cancel stream / dismiss popover |
| `Shift-Cmd-N` | New conversation (Cmd-N reserved for new query tab) |
| `Cmd-K` | Clear current conversation (Terminal convention) |
| `@` in composer | Open mention picker |
| `/` at line start | Open slash command picker |

## Implementation plan

Each row is one PR, independently reviewable.

| # | PR | Scope | LOC | Depends on | Status |
|---|---|---|---|---|---|
| A | Layout shell | Inspector tab picker (Details / AI Chat) at inspector header, slim empty state, single-row composer footer (mention, slash, mode, model, history, new conversation, send). `AIChatMode` enum saved to settings. **No provider behavior change.** | ~250 | (none) | DONE |
| B | Composer rewrite | Drop NSViewRepresentable, use TextEditor(axis: .vertical), SwiftUI mention popover anchored at caret. Keep MentionDetector. | -250 net | A | TODO |
| C | Code block via CodeEditSourceEditor | Replace regex highlighter, theme-sync, retain Copy/Insert/Run row. | -200 net | A | TODO |
| D | Modes + per-mode tool gating | Ask / Edit / Agent. Registry rebuilds allSpecs by mode. | ~250 | A | TODO |
| E | Tool-call permission dropdown | Per-card "Run / Always for this connection / Cancel" replacing the global safe-mode dialog when appropriate. | ~200 | D | TODO |
| F | Inline assistant in SQL editor | Ctrl-Enter on selection opens floating prompt strip. Rewrite-in-place. | ~300 | A | TODO |
| G | Per-connection rules | `.tableprorules` schema, settings UI, system prompt include. | ~250 | A | TODO |
| H | Multibuffer review + checkpoints | Reuse DataChangeManager for review surface; SAVEPOINT per agent turn. | ~400 | D, E | TODO |

**Recommended order**: A → B → C → D → E → F/G/H in parallel.

## Things to keep verbatim

The following are working and well-tested. Do not modify in this refactor.

- `MentionDetector` (pure logic, NSString character-at)
- `ChatTool` protocol + `ChatToolRegistry` + `ChatToolContext` + `ChatToolBootstrap`
- `resolveTurnForWire(_:)` async with `ensureColumnsLoaded` dedup via `inFlightColumnFetches`
- `viewModel.tables` computed from `SchemaService.shared`
- `nonisolated` static helpers (`assembleToolUseBlocks`, `executeToolUses`, `runToolUse`, `buildSystemPrompt`)
- `AnthropicProvider.parseChunk` / `OpenAICompatibleProvider.parseChunk` / `GeminiProvider.parseChunk` extracted for testability
- `ChatTransportOptions.tools` plumbing through providers
- Per-provider `parseChunk` test suites (~30 tests)
- `MCPConnectionBridge` shared instance via `ChatToolBootstrap.bridge`

## Things to delete

- `Color.clear` placeholder in `AIChatPanelView` header (line ~147). Dead weight from a removed feature.
- `AIChatViewModel.savedQueries` pre-population. The lazy `ensureSavedQueryLoaded(id:)` covers the wire path.
- `AIProviderFactory.copilotDeleteLastTurn()` unconditional call in `regenerate()`. Move behind optional `ChatTransport.prepareRegenerate()` hook.

## Things to redesign from scratch

1. `ChatComposerTextView` (293 LOC) → SwiftUI `TextEditor(axis: .vertical)`. Keeps mention detection logic, drops AppKit wrapping.
2. `AIChatCodeBlockView` (340 LOC) → read-only `CodeEditSourceEditor` per block, theme-synced.
3. Action row + model picker (~210 LOC) → toolbar items via `.toolbar { }` + `AIChatModelMenuModel` value type for picker logic.

## Anti-patterns to refuse

| Pattern | Source | Why refuse |
|---|---|---|
| Bubble chat with avatars | Cursor, web tools | Apple uses bubbles only in Messages. Outside that surface, bubbles signal Electron. |
| Voice mic button in toolbar | VS Code | macOS users dictate via Fn-Fn. Custom mic glyph is web cargo cult. |
| Three full chat surfaces (panel + inline + floating) | VS Code | Panel + inline is enough. Floating chat fights Spotlight muscle memory. |
| Permission level "Autopilot" toggle in header | VS Code | Dangerous in a DB client. Settings preference + per-card sheet. |
| Six-mode picker | Cursor | Choice paralysis. Three modes is the cap. |
| Separate "Agents Window" | Cursor | Native macOS users expect one window per connection. |
| Hand-rolled toolbar in `HStack` | Current TablePro | Skips Customize Toolbar, overflow collapse, unified titlebar. |
| Hand-rolled segmented controls | Web | `Picker.pickerStyle(.segmented)` exists. |
| Paper-plane send glyph | Web | Apple uses `arrow.up.circle.fill` in Messages. |
| Token counter in header | Zed | Irrelevant for non-billed local agents. |
| Pinned chats as a primitive | Cursor | Pin queries instead. That's the right primitive in a DB client. |
| Sheets for repeated input | (HIG explicitly forbids) | "Use a panel instead of a sheet if people need to repeatedly provide input and observe results." |
| Warnings inside popovers | (HIG explicitly forbids) | Popovers can be dismissed by accident. |

## Open questions

1. **Starter prompts per connection type**: do we ship 3 universal prompts or per-driver variants (SQL vs MongoDB vs Redis)? Audit suggests per-driver; complexity is small.
2. **"Always for this connection" persistence**: where does the per-tool permission preference live? Connection settings vs `AppSettingsManager.shared.ai`?
3. **Inline assistant scope**: only on SELECT statements, or any selection? Recommend selection-aware: SELECT triggers explain/optimize, INSERT/UPDATE/DELETE prompts before rewriting.
4. **Model picker scope**: per-conversation or global? Currently global. VS Code is per-session (each conversation can have its own model). Consider per-conversation for #1048 Apple Intelligence (which gets default treatment).
5. **Edit mode and the `currentQuery` snapshot**: should Edit mode auto-attach the editor query as `@currentQuery`, or rely on user to type `@`? Recommend auto-attach with visible chip the user can remove.
6. **Conversation history scope**: per-connection or global? Currently global. Per-connection is the Zed pattern and matches TablePro's window-per-connection model.

## References

- [Apple HIG: Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Apple HIG: Panels](https://developer.apple.com/design/human-interface-guidelines/panels)
- [Apple HIG: Generative AI](https://developer.apple.com/design/human-interface-guidelines/generative-ai)
- [Apple HIG: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Apple HIG: Pop-up Buttons](https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons)
- [Apple HIG: Segmented Controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls)
- [VS Code Chat overview](https://code.visualstudio.com/docs/copilot/chat/copilot-chat)
- [VS Code v1.108 release notes](https://code.visualstudio.com/updates/v1_108)
- [Zed Agent Panel docs](https://zed.dev/docs/ai/agent-panel)
- [Zed Inline Assistant docs](https://zed.dev/docs/ai/inline-assistant)
- [Cursor Agent overview](https://cursor.com/docs/agent/overview)
- [Cursor Modes docs](https://cursor.com/docs/agent/modes)
- [Cursor 2.0 changelog](https://cursor.com/changelog/2-0)

## Changelog

- **2026-05-07**: Initial draft after parallel research streams (VS Code, Zed/Cursor, Apple HIG, internal audit).
