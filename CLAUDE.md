# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Principles

These govern every decision — code, architecture, tooling, and process:

1. **Security first** — never introduce vulnerabilities (injection, XSS, OWASP top 10). Validate at system boundaries.
2. **Native only** — use native macOS/iOS components (AppKit, SwiftUI, system frameworks). No cross-platform abstractions, no web views for native UI.
3. **Clean architecture** — proper separation of concerns, protocol-oriented design, dependency injection where appropriate. Every task must consider its impact on architecture and code quality, not just the immediate problem.
4. **Clean code** — self-explanatory naming, early returns over nested conditionals, small focused functions. No comments in the codebase — code must be self-documenting through clear naming and structure.
5. **Root cause fixes** — don't patch symptoms. Diagnose the underlying issue, add logging to debug if needed, then fix the actual cause.
6. **No hacky solutions** — no backward-compatibility shims, no temporary workarounds left in place, no duct tape. If the right fix is harder, do the right fix.
7. **Testability** — if a feature is testable, write tests. When tests fail, fix the source code — never adjust tests to match incorrect output.
8. **Maintainability** — follow existing patterns but offer refactors when they improve quality. Extract into extensions when approaching size limits. Group by domain logic.
9. **Scalability** — design for the plugin system's open-ended nature. `DatabaseType` is a struct, not an enum. All switches need `default:`.

## Project Overview

TablePro is a native macOS database client (SwiftUI + AppKit) — a fast, lightweight alternative to TablePlus. macOS 14.0+, Swift 5.9, Universal Binary (arm64 + x86_64).

- **Source**: `TablePro/` — `Core/` (business logic, services), `Views/` (UI), `Models/` (data structures), `ViewModels/`, `Extensions/`, `Theme/`
- **Plugins**: `Plugins/` — `.tableplugin` bundles + `TableProPluginKit` shared framework.
    - **Bundled in app**: MySQL, PostgreSQL, SQLite, ClickHouse, Redis, CSV, JSON, SQL export, XLSX export, MQL export, SQL import. Shipped only inside the app bundle. **Never publish bundled plugins to the registry.** Updates ride with the next app release.
    - **Registry-only**: MongoDB, Oracle, DuckDB, MSSQL, Cassandra, Etcd, CloudflareD1, DynamoDB, BigQuery, LibSQL. Distributed via [TableProApp/plugins](https://github.com/TableProApp/plugins) `plugins.json`, installed into the user plugins directory.
- **C bridges**: Each plugin contains its own C bridge module (e.g., `Plugins/MySQLDriverPlugin/CMariaDB/`, `Plugins/PostgreSQLDriverPlugin/CLibPQ/`)
- **Static libs**: `Libs/` — pre-built `.a` files. `Libs/ios/` — xcframeworks for iOS. Both downloaded via `scripts/download-libs.sh` (not in git)
- **SPM deps**: CodeEditSourceEditor (`main` branch, tree-sitter editor), Sparkle (2.8.1, auto-update), OracleNIO. Managed via Xcode, no `Package.swift`.

## Build & Development Commands

```bash
# Build (development) — -skipPackagePluginValidation required for SwiftLint plugin in CodeEditSourceEditor
xcodebuild -project TablePro.xcodeproj -scheme TablePro -configuration Debug build -skipPackagePluginValidation

# Clean build
xcodebuild -project TablePro.xcodeproj -scheme TablePro clean

# Build and run
xcodebuild -project TablePro.xcodeproj -scheme TablePro -configuration Debug build -skipPackagePluginValidation && open build/Debug/TablePro.app

# Release builds
scripts/build-release.sh arm64|x86_64|both

# Lint & format
swiftlint lint                    # Check issues
swiftlint --fix                   # Auto-fix
swiftformat .                     # Format code

# Tests
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation -only-testing:TableProTests/TestClassName
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation -only-testing:TableProTests/TestClassName/testMethodName

# DMG
scripts/create-dmg.sh

# Static libraries (first-time setup or after lib updates)
scripts/download-libs.sh          # Download from GitHub Releases (skips if already present)
scripts/download-libs.sh --force  # Re-download and overwrite
```

### Updating Static Libraries

Static libs (`Libs/*.a`) are hosted on the `libs-v1` GitHub Release (not in git). When adding or updating a library:

```bash
# 1. Update the .a files in Libs/
# 2. Regenerate checksums
shasum -a 256 Libs/*.a > Libs/checksums.sha256
# 3. Recreate and upload the archive
tar czf /tmp/tablepro-libs-v1.tar.gz -C Libs .
gh release upload libs-v1 /tmp/tablepro-libs-v1.tar.gz --clobber --repo TableProApp/TablePro
# 4. Commit the updated checksums
git add Libs/checksums.sha256 && git commit -m "build: update static library checksums"

# iOS xcframeworks (Libs/ios/*.xcframework)
tar czf /tmp/tablepro-libs-ios-v1.tar.gz -C Libs/ios .
gh release upload libs-v1 /tmp/tablepro-libs-ios-v1.tar.gz --clobber --repo TableProApp/TablePro
```

## Architecture

### Plugin System

All database drivers are `.tableplugin` bundles loaded at runtime by `PluginManager` (`Core/Plugins/`):

- **TableProPluginKit** (`Plugins/TableProPluginKit/`) — shared framework with `PluginDatabaseDriver`, `DriverPlugin`, `TableProPlugin` protocols and transfer types (`PluginQueryResult`, `PluginColumnInfo`, etc.)
- **PluginDriverAdapter** (`Core/Plugins/PluginDriverAdapter.swift`) — bridges `PluginDatabaseDriver` → `DatabaseDriver` protocol
- **DatabaseDriverFactory** (`Core/Database/DatabaseDriver.swift`) — looks up plugins via `DatabaseType.pluginTypeId`
- **DatabaseManager** (`Core/Database/DatabaseManager.swift`) — connection pool, lifecycle, primary interface for views/coordinators
- **ConnectionHealthMonitor** — 30s ping, auto-reconnect with exponential backoff

When adding a new driver: create a new plugin bundle under `Plugins/`, implement `DriverPlugin` + `PluginDatabaseDriver`, add target to pbxproj, add `DatabaseType` static constant, add case to `resolve_plugin_info()` in `.github/workflows/build-plugin.yml`, add row to `docs/index.mdx` supported databases table, and add CHANGELOG entry. See `docs/development/plugin-system/` for details.

When adding a new method to the driver protocol: add to `PluginDatabaseDriver` (with default implementation), then update `PluginDriverAdapter` to bridge it to `DatabaseDriver`.

**PluginKit ABI versioning**: When `DriverPlugin` or `PluginDatabaseDriver` protocol changes (new methods, changed signatures), bump `currentPluginKitVersion` in `PluginManager.swift` AND `TableProPluginKitVersion` in every plugin's `Info.plist`. Stale user-installed plugins with mismatched versions crash on load with `EXC_BAD_INSTRUCTION` (not catchable in Swift). Removing protocol methods that have default `nil` implementations does NOT require a version bump. Adding new `static var` or `func` requirements to `DriverPlugin` DOES require a version bump even with default implementations via protocol extension — Swift protocol witness tables are compiled statically.

**Post-ABI-bump checklist (mandatory)**: After bumping `currentPluginKitVersion`, every registry-published plugin must be re-tagged and republished — otherwise users see "Plugin was built with PluginKit version N, but version M is required" when they try to update. `PluginManager` rejects any user-installed plugin whose `TableProPluginKitVersion` does not match exactly (`PluginManager.swift:387`).
1. Re-tag every registry plugin with a bumped patch version (MongoDB, Oracle, DuckDB, MSSQL, Cassandra, Etcd, CloudflareD1, DynamoDB, BigQuery, LibSQL). Bundled plugins (Redis, ClickHouse, etc.) are NOT re-tagged; they ship with the next app release. Push tags individually because `build-plugin.yml` only fires once per multi-tag push.
2. Wait for CI to publish each ZIP to its `plugin-<name>-v<version>` GitHub Release.
3. Update `plugins.json` in [TableProApp/plugins](https://github.com/TableProApp/plugins): bump `version`, `downloadURL`, and both architecture `sha256` entries for every plugin.
4. Verify by installing one plugin from registry on the new app build.

### DatabaseType (String-Based Struct)

`DatabaseType` is a string-based struct (not an enum):
- All `switch` statements must include `default:` — the type is open
- Use static constants (`.mysql`, `.postgresql`) for known types
- Unknown types (from future plugins) are valid — they round-trip through Codable
- Use `DatabaseType.allKnownTypes` (not `allCases`) for the canonical list

### Editor Architecture (CodeEditSourceEditor)

- **`SQLEditorTheme`** — single source of truth for editor colors/fonts
- **`TableProEditorTheme`** — adapter to CodeEdit's `EditorTheme` protocol
- **`CompletionEngine`** — framework-agnostic; **`SQLCompletionAdapter`** bridges to CodeEdit's `CodeSuggestionDelegate`
- Editor tabs use native NSWindow tabs (`NSWindow.tabbingMode = .preferred` in `TabWindowController`); there is no custom tab bar.
- Cursor model: `cursorPositions: [CursorPosition]` (multi-cursor via CodeEditSourceEditor)

### Change Tracking Flow

1. User edits cell → `DataChangeManager` records change
2. User clicks Save → `SQLStatementGenerator` produces INSERT/UPDATE/DELETE
3. `DataChangeUndoManager` provides undo/redo
4. `AnyChangeManager` abstracts over concrete manager for protocol-based usage

### Invariants

These have caused real bugs when violated:

**Sync delete ordering**: In `ConnectionStorage` (and all storage classes), `SyncChangeTracker.markDeleted()` must be called AFTER `saveConnections()`. The `markDeleted` call fires `postChangeNotification` which can trigger a sync. If the file on disk still contains the deleted item when sync runs, it may re-upload the deleted record. Persist first, then notify.

**WelcomeViewModel tree rebuild**: The welcome screen renders `treeItems` (grouped/filtered), not `connections` directly. Every mutation to `connections` must call `rebuildTree()` afterward, or the UI won't update.

**Tab replacement guard**: `openTableTab` checks for active work (unsaved edits, applied filters, sorting) before replacing the current tab. Tabs with active work open a new native window tab instead. This check runs before the preview tab branch.

**Window tab titles**: Resolved in TWO places that must stay in sync:
1. `ContentView.init` (title resolution chain) — initial title from payload
2. `MainContentView+Setup.swift` `updateWindowTitleAndFileState()` — ongoing title updates
Missing a case produces a wrong "{Language} Query" title on the first frame.

**Schema loading**: `SQLSchemaProvider` (actor) stores an in-flight `loadTask: Task<Void, Never>?`. Concurrent callers `await` the same Task instead of firing duplicate `fetchTables()` queries. Never use a boolean `isLoading` guard that returns without data — callers need to await the result.

### Main Coordinator Pattern

`MainContentCoordinator` is the central coordinator, split across 7+ extension files in `Views/Main/Extensions/` (e.g., `+Alerts`, `+Filtering`, `+Pagination`, `+RowOperations`). When adding coordinator functionality, add a new extension file rather than growing the main file.

### Window Close (Cmd+W)

`EditorWindow` (NSWindow subclass in `TabWindowController.swift`) overrides `performClose:` to route Cmd+W through `closeTab()`. SwiftUI's `.commands { Button(...).keyboardShortcut("w") }` does NOT replace AppKit's built-in "File > Close" — both fire, and AppKit's wins. The NSWindow subclass is the correct native pattern.

### Storage Patterns

| What                 | How              | Where                                       |
| -------------------- | ---------------- | ------------------------------------------- |
| Connection passwords | Keychain         | `ConnectionStorage`                         |
| User preferences     | UserDefaults     | `AppSettingsStorage` / `AppSettingsManager` |
| Query history        | SQLite FTS5      | `QueryHistoryStorage`                       |
| Tab state            | JSON persistence | `TabPersistenceService` / `TabStateStorage` |
| Filter presets       | UserDefaults     | `FilterSettingsStorage`                     |
| Per-table filters    | UserDefaults     | `FilterSettingsStorage` (saves `appliedFilters` only) |

### Logging & Debugging

Use OSLog for all logging, never `print()`. When debugging issues, add structured OSLog statements to trace the problem — don't guess.

```swift
import os
private static let logger = Logger(subsystem: "com.TablePro", category: "ComponentName")
```

## Code Style

**Authoritative sources**: `.swiftlint.yml` and `.swiftformat` — check those files for the full rule set. Key points:

- **No comments** — code must be self-explanatory through naming and structure. Never add comments that describe what code does, reference tasks/tickets, or explain callers.
- **Early returns** — use `guard` and early `return` instead of nested `if/else` blocks. Flatten control flow.
- **4 spaces** indentation (never tabs except Makefile/pbxproj)
- **120 char** target line length (SwiftFormat); SwiftLint warns at 180, errors at 300
- **K&R braces**, LF line endings, no semicolons, no trailing commas
- **Imports**: system frameworks alphabetically → third-party → local, blank line after imports
- **Access control**: always explicit (`private`, `internal`, `public`). Specify on extension, not individual members:
    ```swift
    public extension NSEvent {
        var semanticKeyCode: KeyCode? { ... }
    }
    ```
- **No force unwrapping/casting** — use `guard let`, `if let`, `as?`
- **Acronyms as words**: `JsonEncoder` not `JSONEncoder` (except SDK types)

### SwiftLint Limits

| Metric                | Warning | Error |
| --------------------- | ------- | ----- |
| File length           | 1200    | 1800  |
| Type body             | 1100    | 1500  |
| Function body         | 160     | 250   |
| Cyclomatic complexity | 40      | 60    |

When approaching limits: extract into `TypeName+Category.swift` extension files in an `Extensions/` subfolder. Group by domain logic, not arbitrary line counts.

## Mandatory Rules

These are **non-negotiable** — never skip them:

1. **CHANGELOG.md**: Follow [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). Update under `[Unreleased]` using the canonical sections: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`. Do **not** add a "Fixed" entry for fixing something that is itself still unreleased; fold the fix into the Added or Changed entry instead. Documentation-only changes (`docs/`, `CLAUDE.md`, `CHANGELOG.md` formatting) do **not** need a CHANGELOG entry. Each entry is one line, user-facing, with no file paths, class names, or method signatures; reference IDs go in parens at the end: `(#1234)`.

2. **Localization**: Use `String(localized:)` for new user-facing strings in computed properties, AppKit code, alerts, and error descriptions. SwiftUI view literals (`Text("literal")`, `Button("literal")`) auto-localize. Do NOT localize technical terms (font names, database types, SQL keywords, encoding names). Never use `String(localized:)` with string interpolation — `String(localized: "Preview \(name)")` creates a dynamic key that never matches the strings catalog. Use `String(format: String(localized: "Preview %@"), name)`.

3. **Documentation**: Update docs in `docs/` (Mintlify-based) when adding/changing features:
    - New keyboard shortcuts → `docs/features/keyboard-shortcuts.mdx`
    - UI/feature changes → relevant `docs/features/*.mdx` page
    - Settings changes → `docs/customization/settings.mdx`
    - Database driver changes → `docs/databases/*.mdx`

4. **Tests**: Write tests for testable features. When tests fail, fix the source code — never adjust tests to match incorrect output. Tests define expected behavior.

5. **Lint after changes**: Run `swiftlint lint --strict` to verify compliance.

6. **Commit messages**: Follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/). Single line only, no description body. Format: `<type>(<scope>): <description>`. Scope is optional but preferred when the change has a clear domain. Use `!` after type or scope for breaking changes (e.g. `refactor(ai-providers)!: drop OpenAI legacy completion endpoint`).

    **Types**: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`, `style`, `revert`.

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

- **Never use `ForEach($bindable.array) { $item in }`** on `@Observable` arrays that can be cleared externally — index-based bindings crash with out-of-bounds when the array shrinks during SwiftUI evaluation. Use `ForEach(array) { item in` with a manual `Binding` via `binding(for: item)`.
- **Never use `string.count`** on large strings — O(n) in Swift. Use `(string as NSString).length` for O(1).
- **Never use `string.index(string.startIndex, offsetBy:)` in loops** on bridged NSStrings — O(n) per call. Use `(string as NSString).character(at:)` for O(1) random access.
- **Never call `ensureLayout(forCharacterRange:)`** — defeats `allowsNonContiguousLayout`. Let layout manager queries trigger lazy local layout.
- **SQL dumps can have single lines with millions of characters** — cap regex/highlight ranges at 10k chars.
- **Tab persistence**: `QueryTab.toPersistedTab()` truncates queries >500KB to prevent JSON freeze. `TabStateStorage.saveLastQuery()` skips writes >500KB.

## Writing Style

Applies to **everything**: docs, commit messages, CHANGELOG entries, UI strings, error messages, PR descriptions.

**Write like a human developer.** Short sentences. Plain words. Say what it does, not how great it is. If a sentence works without a word, drop the word.

**No em dashes (—).** Anywhere. Use a comma, period, colon, or rewrite the sentence. Hyphens (-) for compound words are fine.

Before any commit that touches user-facing strings, CHANGELOG.md, PR bodies, or files you authored this session, run:
```bash
git diff --cached -U0 | grep -nE '—|seamless|robust|comprehensive|intuitive|effortless|streamlined|leverage|elevate|delve|utilize|facilitate'
```
If anything matches, rewrite before committing.

**No AI-generated filler.** If it sounds like a chatbot wrote it, rewrite it. Banned words: seamless, robust, comprehensive, intuitive, effortless, powerful (as filler), streamlined, leverage, elevate, harness, supercharge, unlock, unleash, dive into, game-changer, empower, delve, utilize, facilitate. No "Absolutely!" / "Ready to dive in?" / "Let's get started!" openers.

**Be specific.** Numbers, tech names, file paths. "Runs in 200ms" beats "runs fast". "Uses `PQexecParams`" beats "uses native binding".

## CI/CD

GitHub Actions (`.github/workflows/build.yml`) triggered by `v*` tags: lint → build arm64 → build x86_64 → release (DMG/ZIP + Sparkle signatures). Release notes auto-extracted from `CHANGELOG.md`.

**Plugin CI** (`.github/workflows/build-plugin.yml`): triggered by `plugin-*-v*` tags. GitHub only fires one workflow per multi-tag `git push` — push tags individually or use `workflow_dispatch` with comma-separated tags for bulk releases.

**Plugin tag naming**: Tag names must match the CI workflow's `resolve_plugin_info()` mapping. Notable non-obvious mappings: `CloudflareD1DriverPlugin` → `plugin-cloudflare-d1-v*`, `EtcdDriverPlugin` → `plugin-etcd-v*`. Check existing tags with `git tag -l "plugin-*"` before creating new ones.
