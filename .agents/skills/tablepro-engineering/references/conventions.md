# Conventions

6. **No hacky solutions**: no backward-compatibility shims, no temporary workarounds left in place, no duct tape. If the right fix is harder, do the right fix.
7. **Testability**: every testable code change needs unit/function tests, and UI/user-flow changes should add UI automation where they run deterministically. When tests fail, fix the source code, never adjust tests to match incorrect output.

### Logging & Debugging

Use OSLog for all logging, never `print()`. When debugging issues, add structured OSLog statements to trace the problem, don't guess.

```swift
import os
private static let logger = Logger(subsystem: "com.TablePro", category: "ComponentName")
```


- **Access control**: always explicit (`private`, `internal`, `public`). Specify on extension, not individual members:
    ```swift
    public extension NSEvent {
        var semanticKeyCode: KeyCode? { ... }
    }
    ```
- **No force unwrapping/casting**: use `guard let`, `if let`, `as?`
- **Acronyms as words**: `JsonEncoder` not `JSONEncoder` (except SDK types)

### SwiftLint Limits

| Metric                | Warning | Error |
| --------------------- | ------- | ----- |
| File length           | 1200    | 1800  |
| Type body             | 1100    | 1500  |
| Function body         | 160     | 250   |
| Cyclomatic complexity | 40      | 60    |

When approaching limits: extract into `TypeName+Category.swift` extension files in an `Extensions/` subfolder. Group by domain logic, not arbitrary line counts.


3. **Documentation**: Update docs in `docs/` (Mintlify-based) when adding/changing features:
    - New keyboard shortcuts → `docs/features/keyboard-shortcuts.mdx`
    - UI/feature changes → relevant `docs/features/*.mdx` page
    - Settings changes → `docs/customization/settings.mdx`
    - Database driver changes → `docs/databases/*.mdx`


    **Canonical scopes** (reuse these instead of inventing new ones):
    - AI: `ai-chat`, `ai-providers`, `mcp`, `copilot`, `inline-suggest`
    - App UI: `editor`, `datagrid`, `tabs`, `coordinator`, `sidebar`, `connections`, `connection-form`, `welcome`, `settings`, `toolbar`, `hig`
    - Infra: `ssh`, `ios`, `windows`, `perf`, `launch`, `plugins`
    - Plugins: `plugin-<name>` (e.g. `plugin-mongodb`, `plugin-redis`, `plugin-clickhouse`)
    - Docs and release: `changelog`, `claude-md`, `docs`, `ci`, `release`

    **Examples**: `feat(ai-chat): add /refactor slash command`, `fix(editor): prevent crash on empty query result`, `refactor(mcp): migrate pairing store to actor`, `docs(changelog): adopt Keep a Changelog 1.1.0`.

7. **Atomic API changes**: When you rename, remove, or change a public type, property, or function signature, update every caller AND every test in the same commit. Do not split a rename from "fix tests for rename" into separate commits; the in-between commit is broken, fails CI, and pollutes `git bisect`. If a refactor crosses too many files for one reviewable commit, narrow the change first or stage it behind a typealias the renaming commit removes.

## Performance Pitfalls

These have caused real production bugs:

- **Never use `ForEach($bindable.array) { $item in }`** on `@Observable` arrays that can be cleared externally, index-based bindings crash with out-of-bounds when the array shrinks during SwiftUI evaluation. Use `ForEach(array) { item in` with a manual `Binding` via `binding(for: item)`.
- **Never use `string.count`** on large strings, O(n) in Swift. Use `(string as NSString).length` for O(1).
- **Never use `string.index(string.startIndex, offsetBy:)` in loops** on bridged NSStrings, O(n) per call. Use `(string as NSString).character(at:)` for O(1) random access.
- **Never call `ensureLayout(forCharacterRange:)`**: defeats `allowsNonContiguousLayout`. Let layout manager queries trigger lazy local layout.
- **SQL dumps can have single lines with millions of characters**: cap regex/highlight ranges at 10k chars.
- **Tab persistence**: `QueryTab.toPersistedTab()` truncates queries >500KB to prevent JSON freeze. `TabStateStorage.saveLastQuery()` skips writes >500KB.


**No em dashes (—).** Anywhere. Use a comma, period, colon, or rewrite the sentence. Hyphens (-) for compound words are fine.

**No AI-generated filler.** If it sounds like a chatbot wrote it, rewrite it. Banned words: seamless, robust, comprehensive, intuitive, effortless, powerful (as filler), streamlined, leverage, elevate, harness, supercharge, unlock, unleash, dive into, game-changer, empower, delve, utilize, facilitate. No "Absolutely!" / "Ready to dive in?" / "Let's get started!" openers.

**Be specific.** Numbers, tech names, file paths. "Runs in 200ms" beats "runs fast". "Uses `PQexecParams`" beats "uses native binding".
