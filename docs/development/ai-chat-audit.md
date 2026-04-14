# AI Chat Feature — Production Readiness Audit

Comprehensive analysis of the AI chat feature across security, data integrity, concurrency, performance, and enterprise readiness. Conducted on 2026-04-14 against PR #738 (`fix/ai-chat-hang-735`).

## Table of Contents

- [Security](#security)
- [Data Integrity & Loss Prevention](#data-integrity--loss-prevention)
- [Concurrency & Stability](#concurrency--stability)
- [Performance & Scalability](#performance--scalability)
- [Enterprise Production Readiness](#enterprise-production-readiness)
- [Priority Actions](#priority-actions)

---

## Security

| ID | Severity | Issue | Location | Status |
|----|----------|-------|----------|--------|
| S1 | CRITICAL | Ollama stream logged with `privacy: .public` — leaks schema/query data to system log | `OpenAICompatibleProvider.swift:70` | Open |
| S2 | CRITICAL | Query result rows sent to AI without clear disclosure in consent prompt | `AISchemaContext.swift`, consent dialog | Open |
| S3 | HIGH | AI API keys sync to iCloud Keychain when password sync enabled | `KeychainHelper.swift`, `AIKeyStorage.swift` | Open |
| S4 | HIGH | Raw provider error bodies surfaced to UI — leaks endpoint/infra details | `AIProvider.swift:59-70` | Open |
| S5 | HIGH | API keys cached in heap for app lifetime, never evicted on disconnect | `AIProviderFactory.swift:20-56` | Open |
| S6 | MEDIUM | No HTTPS enforcement for custom provider endpoints (HTTP allowed) | `AIProviderFactory.swift` | Open |
| S7 | MEDIUM | Connection names persist in chat history with no retention policy | `AIConversation.swift` | Open |
| S8 | LOW | Session consent not invalidated when data-sharing settings change | `AIChatViewModel.swift` | Open |

### S1 — Ollama stream logged with `privacy: .public`

The `privacy: .public` annotation opts data out of OSLog's automatic redaction. On any machine where a log stream is captured (Console.app, `log stream`, MDM log collection), the first 200 characters of every Ollama response line — which may contain AI-generated SQL with table names, column names, and data values — are emitted in plaintext.

**Remediation:** Remove this log statement or change to `privacy: .private`.

### S2 — Query result rows sent without disclosure

`buildQueryResultsSummary()` sends the first 10 rows of active query results to the AI provider. The `askEachTime` consent dialog says "Your database schema and query data will be sent" but does not specify live row data. The setting defaults to off but users who enable it have no visibility into what rows are included.

**Remediation:** Enumerate data categories in consent prompt. Add row/column redaction or exclusion options.

### S3 — AI API keys sync to iCloud Keychain

`AIKeyStorage` uses `KeychainHelper` which has iCloud sync mode. When enabled, AI provider API keys (Anthropic, OpenAI, Gemini) sync to all Macs signed into the same Apple ID.

**Remediation:** Force `kSecAttrSynchronizable: false` for AI key items regardless of global sync preference.

### S4 — Raw error bodies surfaced to UI

`mapHTTPError(statusCode:body:)` passes raw server response into `AIProviderError.serverError`. Provider error bodies can contain internal endpoint paths, rate limit quota details, or upstream infrastructure details.

**Remediation:** Truncate error bodies to 200 chars and strip URL-like substrings before displaying.

### S5 — API keys cached indefinitely in memory

Provider cache holds `(apiKey: String?, provider: AIProvider)` for the entire app lifetime. `clearSessionData()` does not invalidate it.

**Remediation:** Call `AIProviderFactory.invalidateCache()` from `clearSessionData()`.

### S6 — No HTTPS enforcement for custom endpoints

Custom provider endpoints accept `http://` URLs. Schema data and conversation history can be transmitted over plaintext HTTP.

**Remediation:** Validate `https://` prefix for all non-Ollama provider endpoints.

### S7 — Connection names persist without retention

`AIConversation.connectionName` persists in `~/Library/Application Support/TablePro/ai_chats/*.json` indefinitely. Connection names often encode hostname/environment info.

**Remediation:** Add configurable max conversation age with auto-delete.

### S8 — Session consent not invalidated on settings change

If a user approves AI access with `includeQueryResults: false`, then enables it in settings, the cached approval is reused without re-prompting.

**Remediation:** Invalidate `sessionApprovedConnections` when `includeSchema`/`includeQueryResults` settings change.

---

## Data Integrity & Loss Prevention

| ID | Severity | Issue | Location | Status |
|----|----------|-------|----------|--------|
| D1 | CRITICAL | No persistence on app termination — streaming conversation lost on force-quit | `AIChatViewModel.swift`, `AppDelegate` | Open |
| D2 | CRITICAL | Rapid cancel+resend can send stale message history to AI provider | `AIChatViewModel.swift:380` | Open |
| D3 | HIGH | `editMessage` destroys all subsequent messages with no undo | `AIChatViewModel.swift:77-84` | Open |
| D4 | HIGH | Async save task pre-empted by force-quit → disk rollback on next launch | `AIChatViewModel.swift:285-310` | Open |
| D5 | HIGH | `clearConversation` `deleteAll()` can race with immediate new `save()` | `AIChatViewModel.swift:156-163` | Open |
| D6 | MEDIUM | `deleteConversation` can lose to a queued `save` — deleted conversation reappears | `AIChatViewModel.swift:275-282` | Open |

### D1 — No persistence on app termination

`persistCurrentConversation()` is only called after stream completion, cancel, or conversation switch. `applicationWillTerminate` does not persist in-flight AI conversations. Force-quit during streaming loses all unsaved messages.

**Remediation:** In `applicationWillTerminate`, resolve all live `AIChatViewModel` instances and call `persistCurrentConversation()` synchronously.

### D2 — Stale message history on rapid cancel+resend

The `chatMessages` snapshot is captured before `Task.detached`. If `startStreaming` is called rapidly (cancel previous + start new), the cancel path and new stream's `MainActor.run` blocks can interleave, potentially sending a snapshot that includes a partially-written assistant message from the cancelled stream.

**Remediation:** Ensure `chatMessages` is captured only after all prior `MainActor.run` blocks from the cancelled task have drained.

### D3 — `editMessage` is destructive with no undo

`messages.removeSubrange(idx...)` followed by immediate `persistCurrentConversation()` permanently destroys all subsequent messages including assistant responses. No undo stack, no confirmation dialog.

**Remediation:** Add confirmation dialog for destructive edits, or implement undo support.

### D4 — Async save pre-empted by force-quit

`persistCurrentConversation()` updates `conversations[index]` synchronously but queues `Task { await chatStorage.save(conversation) }` asynchronously. Force-quit between the two operations causes disk to rollback on next launch.

**Remediation:** Use synchronous save in critical paths, or batch with a write-ahead log.

### D5 — `deleteAll` races with new `save`

`clearConversation()` fires `Task { await chatStorage.deleteAll() }` then allows immediate new conversation creation. If `save()` for the new conversation arrives on the actor queue before `deleteAll()` finishes, the new file is deleted.

**Remediation:** `await` the `deleteAll()` before allowing new conversations, or use a generation counter to skip stale deletes.

### D6 — Deleted conversation reappears

If a `save` task is queued for a conversation ID before `delete` is called, the actor processes them in FIFO order. If `delete` runs before the pending `save`, the save recreates the file.

**Remediation:** Track deleted IDs in a set and skip saves for deleted conversations.

---

## Concurrency & Stability

| ID | Severity | Issue | Location | Status |
|----|----------|-------|----------|--------|
| C1 | CRITICAL | Non-Sendable `DatabaseDriver` captured in `Task.detached` — data race | `AIChatViewModel.swift:484-539` | Open |
| C2 | CRITICAL | `nonisolated(unsafe) streamingTask` written from detached task AND `deinit` | `AIChatViewModel.swift:95,409,429` | Open |
| C3 | HIGH | `AIProvider` protocol not `Sendable` — latent strict-concurrency error | `AIProviderFactory.swift`, `AIChatViewModel.swift` | Open |
| C4 | HIGH | `schemaFetchTask` not cancelled in `deinit`, not `nonisolated(unsafe)` | `AIChatViewModel.swift:96,109` | Open |
| C5 | MEDIUM | Partial response persisted after cancellation via racing `MainActor.run` | `AIChatViewModel.swift:405-412` | Open |

### C1 — Non-Sendable `DatabaseDriver` across isolation boundary

`DatabaseDriver` is `AnyObject` without `Sendable`. It is captured in `Task.detached` for schema fetching. The underlying plugin driver uses a serial GCD queue (safe in practice), but Swift 6 strict concurrency would reject this. `ConnectionHealthMonitor` already uses closure-based injection to avoid this exact problem.

**Remediation:** Either mark `DatabaseDriver: Sendable` (after auditing all implementations) or use closure-based injection like `ConnectionHealthMonitor`.

### C2 — `nonisolated(unsafe)` race on `streamingTask`

`streamingTask` is written from `@MainActor` and from `MainActor.run` inside `Task.detached`. `deinit` reads it without isolation. If `AIChatViewModel` is released from a non-main context, this is a write-write race.

**Remediation:** Remove `streamingTask = nil` writes from inside the detached task's `MainActor.run` blocks, or ensure `deinit` always runs on the main actor.

### C3 — `AIProvider` not `Sendable`

Concrete implementations are effectively Sendable (all `let` properties + thread-safe URLSession) but the protocol lacks the annotation.

**Remediation:** Add `Sendable` to `AIProvider` protocol, mark implementations `@unchecked Sendable`.

### C4 — `schemaFetchTask` not cancelled in `deinit`

Detached task continues running after view model deallocation, wasting resources. Also not marked `nonisolated(unsafe)` for `deinit` access.

**Remediation:** Mark `nonisolated(unsafe)`, cancel in `deinit`.

### C5 — Partial response persisted after cancel

After `cancelStream()` completes, a racing `MainActor.run` from the detached task can still call `persistCurrentConversation()` with partial content.

**Remediation:** Check `Task.isCancelled` inside the `MainActor.run` completion block, not just before it.

---

## Performance & Scalability

| ID | Severity | Issue | Location | Status |
|----|----------|-------|----------|--------|
| P1 | CRITICAL | O(n) `firstIndex` + COW string copy in streaming hot loop (per token) | `AIChatViewModel.swift:391-402` | Open |
| P2 | CRITICAL | Per-token `MainActor.run` hop + full Markdown re-parse (80/sec at fast models) | `AIChatViewModel.swift:390-403` | Open |
| P3 | HIGH | `loadAll()` reads all conversation files serially on startup, no cap or pagination | `AIChatStorage.swift:75-100` | Open |
| P4 | HIGH | `persistCurrentConversation` encodes full JSON on MainActor at stream end | `AIChatViewModel.swift:285-311` | Open |
| P5 | MEDIUM | No per-message content size cap (unbounded memory despite 200 message limit) | `AIChatViewModel.swift:89` | Open |
| P6 | MEDIUM | JSON encoder uses `.prettyPrinted \| .sortedKeys` — 2-3x size inflation | `AIChatStorage.swift:19-25` | Open |

### P1 + P2 — Per-token overhead in streaming loop

Every token triggers: (1) `firstIndex(where:)` O(n) scan over messages array, (2) `content += token` COW copy on `@Observable` property, (3) `MainActor.run` actor hop, (4) SwiftUI observation notification, (5) `Markdown()` full re-parse. At 80 tokens/sec (Claude Haiku, GPT-4o), this is ~16,000 UUID comparisons/sec plus 80 full markdown parses.

**Remediation:** Batch tokens in a non-isolated buffer, flush to `@MainActor` on a 50-100ms timer. Cache the message index before the loop. Use a separate `streamingContent: String` property instead of mutating the messages array per-token.

### P3 — Unbounded conversation loading on startup

`loadAll()` reads every `.json` file in `ai_chats/` directory serially. With 100+ conversations of 200 messages each, this is 10+ MB of JSON decoded at startup.

**Remediation:** Pass `[.contentModificationDateKey]` to `contentsOfDirectory`, sort by date, load only most recent N files. Add startup pruning.

### P4 — JSON encoding on MainActor

`persistCurrentConversation()` builds `AIConversation`, then fires `Task { await chatStorage.save(conversation) }`. The `AIConversation` struct creation with full message array copy happens on `@MainActor` synchronously.

**Remediation:** Move encode+write entirely into the actor.

### P5 — No message content size cap

200 messages × 50KB (large schema summary) = 10MB in memory. Plus duplicates in `conversations` array and API request snapshot.

**Remediation:** Cap message content at 500KB (matching tab persistence limit).

### P6 — Verbose JSON encoding

`.prettyPrinted | .sortedKeys` inflates file size 2-3x. Files are machine-read, not human-inspected.

**Remediation:** Remove formatting options for production.

---

## Enterprise Production Readiness

| Category | Status | Severity | Notes |
|----------|--------|----------|-------|
| Audit Trail | FAIL | Critical | No structured log of AI interactions for compliance |
| Data Governance | PARTIAL | High | Per-connection policy exists but is user-overridable, not admin-lockable |
| Network Controls (Proxy/CA) | FAIL | Critical | `URLSession(.ephemeral)` ignores system proxy and corporate CA |
| Offline Mode | PARTIAL | Medium | Error shown but no actionable diagnostics |
| Client-Side Rate Limiting | FAIL | Medium | No throttle on chat sends — can exhaust shared API key |
| Error Recovery | PASS | — | Cancellation and retry paths work correctly |
| Accessibility (VoiceOver) | FAIL | High | Only 1 of ~10 interactive elements has `accessibilityLabel` |
| Localization | PARTIAL | Medium | Some hardcoded English strings in `AIChatMessageView` |
| Telemetry/Analytics | PASS | — | No telemetry or third-party tracking |
| MDM/Config Profiles | FAIL | High | No managed preferences support for enterprise deployment |
| Feature Flags | PARTIAL | Medium | Global `enabled` flag exists but not admin-lockable |
| Disk Cleanup | FAIL | Medium | No max conversation count, age limit, or auto-prune |
| Memory Cleanup | PASS | — | `clearSessionData()` is comprehensive |
| Schema Migration | FAIL | Medium | No version field in persisted conversations |
| Multi-Window | PASS | — | Per-window instances, actor-safe storage |

---

## Priority Actions

### Immediate (this PR / hotfix)

- [ ] **S1** — Remove Ollama `privacy: .public` log line (1 line)
- [ ] **C4** — Mark `schemaFetchTask` as `nonisolated(unsafe)`, cancel in `deinit` (3 lines)
- [ ] **S5** — Call `AIProviderFactory.invalidateCache()` from `clearSessionData()` (1 line)

### Short-term (next sprint)

- [ ] **P1/P2** — Token batching: accumulate off-main, flush on 50-100ms timer
- [ ] **D1** — Persist conversations on `applicationWillTerminate`
- [ ] **P3** — `loadAll()` pagination: load only recent N conversations
- [ ] **C3** — Mark `AIProvider: Sendable`, implementations `@unchecked Sendable`
- [ ] **S4** — Sanitize/truncate error bodies before displaying to user
- [ ] **Accessibility** — Add `accessibilityLabel` to all icon-only buttons

### Medium-term (roadmap)

- [ ] **Enterprise: Audit trail** — Append-only log of AI interactions
- [ ] **Enterprise: MDM support** — Read managed preferences for AI settings
- [ ] **Enterprise: Network** — Replace `.ephemeral` with `.default` URLSession for proxy/CA
- [ ] **S6** — HTTPS enforcement for non-Ollama endpoints
- [ ] **S3** — Exclude AI keys from iCloud Keychain sync
- [ ] **D5/D6** — Fix actor task ordering races in conversation delete/clear
- [ ] **Enterprise: Disk cleanup** — Max conversation count + age-based auto-prune
- [ ] **Enterprise: Schema migration** — Version field in `AIConversation`
- [ ] **P5** — Cap message content at 500KB
- [ ] **D3** — Confirmation dialog for destructive `editMessage`

### Long-term (future releases)

- [ ] **Enterprise: Data governance** — Admin-lockable connection policies via MDM
- [ ] **Enterprise: Rate limiting** — Per-session request throttle
- [ ] **Enterprise: Feature flags** — Per-team/per-user AI access control
- [ ] **C1** — `DatabaseDriver: Sendable` audit across all plugin implementations
- [ ] **Swift 6 readiness** — Enable `SWIFT_STRICT_CONCURRENCY=complete`, fix all violations
