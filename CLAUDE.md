# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TablePro is a native macOS database client (SwiftUI + AppKit) — a fast, lightweight alternative to TablePlus. macOS 14.0+, Swift 5.9, Universal Binary (arm64 + x86_64).

- **Source**: `TablePro/` — `Core/` (business logic, services), `Views/` (UI), `Models/` (data structures), `ViewModels/`, `Extensions/`, `Theme/`
- **Plugins**: `Plugins/` — `.tableplugin` bundles + `TableProPluginKit` shared framework. Built-in (bundled in app): MySQL, PostgreSQL, SQLite, ClickHouse, MSSQL, Redis, CSV, JSON, SQL export, XLSX, MQL, SQLImport, DynamoDB. Separately distributed via plugin registry: MongoDB, Oracle, DuckDB, Cassandra, Etcd, CloudflareD1
- **C bridges**: Each plugin contains its own C bridge module (e.g., `Plugins/MySQLDriverPlugin/CMariaDB/`, `Plugins/PostgreSQLDriverPlugin/CLibPQ/`)
- **Static libs**: `Libs/` — pre-built `libmariadb*.a`, `libpq*.a`, etc. Downloaded from GitHub Releases via `scripts/download-libs.sh` (not in git)
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
gh release upload libs-v1 /tmp/tablepro-libs-v1.tar.gz --clobber --repo datlechin/TablePro
# 4. Commit the updated checksums
git add Libs/checksums.sha256 && git commit -m "build: update static library checksums"
```

## Architecture

### Plugin System

All database drivers are `.tableplugin` bundles loaded at runtime by `PluginManager` (`Core/Plugins/`):

- **TableProPluginKit** (`Plugins/TableProPluginKit/`) — shared framework with `PluginDatabaseDriver`, `DriverPlugin`, `TableProPlugin` protocols and transfer types (`PluginQueryResult`, `PluginColumnInfo`, etc.)
- **PluginDriverAdapter** (`Core/Plugins/PluginDriverAdapter.swift`) — bridges `PluginDatabaseDriver` → `DatabaseDriver` protocol
- **DatabaseDriverFactory** (`Core/Database/DatabaseDriver.swift`) — looks up plugins via `DatabaseType.pluginTypeId`
- **DatabaseManager** (`Core/Database/DatabaseManager.swift`) — connection pool, lifecycle, primary interface for views/coordinators
- **ConnectionHealthMonitor** — 30s ping, auto-reconnect with exponential backoff

Plugin bundles under `Plugins/`:

| Plugin                 | Database Types       | C Bridge             | Distribution |
| ---------------------- | -------------------- | -------------------- | ------------ |
| MySQLDriverPlugin      | MySQL, MariaDB       | CMariaDB             | Built-in     |
| PostgreSQLDriverPlugin | PostgreSQL, Redshift | CLibPQ               | Built-in     |
| SQLiteDriverPlugin     | SQLite               | (Foundation sqlite3) | Built-in     |
| ClickHouseDriverPlugin | ClickHouse           | (URLSession HTTP)    | Built-in     |
| MSSQLDriverPlugin      | SQL Server           | CFreeTDS             | Built-in     |
| RedisDriverPlugin      | Redis                | CRedis               | Built-in     |
| MongoDBDriverPlugin    | MongoDB              | CLibMongoc           | Registry     |
| DuckDBDriverPlugin     | DuckDB               | CDuckDB              | Registry     |
| OracleDriverPlugin     | Oracle               | OracleNIO (SPM)      | Registry     |

When adding a new driver: create a new plugin bundle under `Plugins/`, implement `DriverPlugin` + `PluginDatabaseDriver`, add target to pbxproj. See `docs/development/plugin-system/` for details.

When adding a new method to the driver protocol: add to `PluginDatabaseDriver` (with default implementation), then update `PluginDriverAdapter` to bridge it to `DatabaseDriver`.

**PluginKit ABI versioning**: When `DriverPlugin` or `PluginDatabaseDriver` protocol changes (new methods, changed signatures), bump `currentPluginKitVersion` in `PluginManager.swift` AND `TableProPluginKitVersion` in every plugin's `Info.plist`. Stale user-installed plugins with mismatched versions crash on load with `EXC_BAD_INSTRUCTION` (not catchable in Swift).

### DatabaseType (String-Based Struct)

`DatabaseType` is a string-based struct (not an enum). Key rules:
- All `switch` statements on `DatabaseType` must include `default:` — the type is open
- Use static constants (`.mysql`, `.postgresql`) for known types
- Unknown types (from future plugins) are valid — they round-trip through Codable
- Use `DatabaseType.allKnownTypes` (not `allCases`) for the canonical list of built-in types

### Editor Architecture (CodeEditSourceEditor)

- **`SQLEditorTheme`** — single source of truth for editor colors/fonts
- **`TableProEditorTheme`** — adapter to CodeEdit's `EditorTheme` protocol
- **`CompletionEngine`** — framework-agnostic; **`SQLCompletionAdapter`** bridges to CodeEdit's `CodeSuggestionDelegate`
- **`EditorTabBar`** — pure SwiftUI tab bar
- Cursor model: `cursorPositions: [CursorPosition]` (multi-cursor via CodeEditSourceEditor)

### Change Tracking Flow

1. User edits cell → `DataChangeManager` records change
2. User clicks Save → `SQLStatementGenerator` produces INSERT/UPDATE/DELETE
3. `DataChangeUndoManager` provides undo/redo
4. `AnyChangeManager` abstracts over concrete manager for protocol-based usage

### Main Coordinator Pattern

`MainContentCoordinator` is the central coordinator, split across 7+ extension files in `Views/Main/Extensions/` (e.g., `+Alerts`, `+Filtering`, `+Pagination`, `+RowOperations`). When adding coordinator functionality, add a new extension file rather than growing the main file.

### Source Organization

`Core/Services/` is split into domain subdirectories:

| Subdirectory      | Contents                                                               |
| ----------------- | ---------------------------------------------------------------------- |
| `Export/`         | ExportService, ImportService, XLSXWriter                               |
| `Formatting/`     | SQLFormatterService, DateFormattingService                             |
| `Infrastructure/` | AppNotifications, DeeplinkHandler, WindowOpener, UpdaterBridge, etc.   |
| `Licensing/`      | LicenseManager, LicenseAPIClient, LicenseSignatureVerifier             |
| `Query/`          | SQLDialectProvider, TableQueryBuilder, RowParser, RowOperationsManager |

`Models/` is split into: `AI/`, `Connection/`, `Database/`, `Export/`, `Query/`, `Settings/`, `UI/`, `Schema/`, `ClickHouse/`

`Core/Utilities/` is split into: `Connection/`, `SQL/`, `File/`, `UI/`

`Core/QuerySupport/` contains MongoDB and Redis query builders/statement generators (non-driver query logic).

### Storage Patterns

| What                 | How              | Where                                       |
| -------------------- | ---------------- | ------------------------------------------- |
| Connection passwords | Keychain         | `ConnectionStorage`                         |
| User preferences     | UserDefaults     | `AppSettingsStorage` / `AppSettingsManager` |
| Query history        | SQLite FTS5      | `QueryHistoryStorage`                       |
| Tab state            | JSON persistence | `TabPersistenceService` / `TabStateStorage` |
| Filter presets       | —                | `FilterSettingsStorage`                     |

### Logging

Use OSLog, never `print()`:

```swift
import os
private static let logger = Logger(subsystem: "com.TablePro", category: "ComponentName")
```

## Code Style

**Authoritative sources**: `.swiftlint.yml` and `.swiftformat` — check those files for the full rule set. Key points that aren't obvious from config:

- **4 spaces** indentation (never tabs except Makefile/pbxproj)
- **120 char** target line length (SwiftFormat); SwiftLint warns at 180, errors at 300
- **K&R braces**, LF line endings, no semicolons, no trailing commas
- **Imports**: system frameworks alphabetically → third-party → local, blank line after imports
- **Access control**: always explicit (`private`, `internal`, `public`). Specify on extension, not individual members.
- **No force unwrapping/casting** — use `guard let`, `if let`, `as?`
- **Acronyms as words**: `JsonEncoder` not `JSONEncoder` (except SDK types)
- **No unnecessary comments**: Don't add comments that restate what the code already says. Only comment to explain non-obvious "why" reasoning or clarify genuinely complex logic.
- **Extension access modifiers on the extension itself**:
    ```swift
    // Good
    public extension NSEvent {
        var semanticKeyCode: KeyCode? { ... }
    }
    ```

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

1. **CHANGELOG.md**: Update under `[Unreleased]` section (Added/Fixed/Changed) for new features and notable changes. But do **not** add a "Fixed" entry for fixing something that is itself still unreleased — if a feature under `[Unreleased]` has a bug, just fix it without adding another CHANGELOG entry. "Fixed" entries are only for bugs in already-released features. Documentation-only changes (`docs/`) do **not** need a CHANGELOG entry.

2. **Localization**: Use `String(localized:)` for new user-facing strings in computed properties, AppKit code, alerts, and error descriptions. SwiftUI view literals (`Text("literal")`, `Button("literal")`) auto-localize. Do NOT localize technical terms (font names, database types, SQL keywords, encoding names).

3. **Documentation**: Update docs in `docs/` (Mintlify-based) when adding/changing features. Key mappings:
    - New keyboard shortcuts → `docs/features/keyboard-shortcuts.mdx`
    - UI/feature changes → relevant `docs/features/*.mdx` page
    - Settings changes → `docs/customization/settings.mdx`
    - Database driver changes → `docs/databases/*.mdx`
    - Update both English (`docs/`) and Vietnamese (`docs/vi/`) pages

4. **Test-first correctness**: When tests fail, fix the **source code** — never adjust tests to match incorrect output. Tests define expected behavior.

5. **Lint after changes**: Run `swiftlint lint --strict` to verify compliance.

6. **Commit messages**: Follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). Single line only, no description body. Examples: `docs: fix installation instructions for unsigned app`, `fix: prevent crash on empty query result`, `feat: add CSV export`.

## Agent Execution Strategy

- **Plans must include edge cases.** When creating implementation plans, identify edge cases, thread safety concerns, and boundary conditions. Include them as explicit checklist items in the plan — don't defer discovery to code review.
- **Implementation includes self-review.** Before committing, agents must check: thread safety (lock coverage, race conditions), all code paths (loops, early returns, between iterations), error handling, and flag/state reset logic. This eliminates the review→fix→review cycle.
- **Tests are part of implementation, not a separate step.** When implementing a feature, write tests in the same commit or immediately after — don't wait for a separate `/write-tests` invocation. The implementation agent should include test writing in its scope.
- **Always use team agents** for implementation work. Use the Agent tool (not subagents/tasks) to delegate coding to specialized agents (e.g., `feature-dev:feature-dev`, `feature-dev:code-architect`, `code-simplifier:code-simplifier`).
- **Always parallelize** independent tasks. Launch multiple agents in a single message.
- **Main context = orchestrator only.** Read files, launch agents, summarize results, update tracking. Never do heavy implementation directly.
- **Agent prompts must be self-contained.** Include file paths, the specific problem, and clear instructions.
- **Use worktree isolation** (`isolation: "worktree"`) for agents making code changes. This keeps the main branch clean and allows parallel work without conflicts.
- **Implementation standards** (apply to ALL new features and refactors): Clean architecture, correct macOS/Apple platform approach, proper design patterns, no backward compatibility hacks, easy to maintain and extensible. Always include these requirements in agent prompts.

## Performance Pitfalls

These have caused real production bugs — be aware when working in editor/autocomplete/persistence code:

- **Never use `string.count`** on large strings — O(n) in Swift. Use `(string as NSString).length` for O(1).
- **Never use `string.index(string.startIndex, offsetBy:)` in loops** on bridged NSStrings — O(n) per call. Use `(string as NSString).character(at:)` for O(1) random access.
- **Never call `ensureLayout(forCharacterRange:)`** — defeats `allowsNonContiguousLayout`. Let layout manager queries trigger lazy local layout.
- **SQL dumps can have single lines with millions of characters** — cap regex/highlight ranges at 10k chars.
- **Tab persistence**: `QueryTab.toPersistedTab()` truncates queries >500KB to prevent JSON freeze. `TabStateStorage.saveLastQuery()` skips writes >500KB.

## Writing Style (Docs & Marketing Copy)

Write like a developer, not a marketing AI. Be specific (numbers, tech names) over generic adjectives. Vary sentence rhythm. Cut filler.

**Banned words**: seamless, robust, comprehensive, intuitive, effortless, powerful (as filler), streamlined, leverage, elevate, harness, supercharge, unlock, unleash, dive into, game-changer, empower, delve. No "Absolutely!" / "Ready to dive in?" openers.

**Em dashes**: minimize; use colons or periods instead. Use hyphens (-) in `<title>` tags, never em dashes (—).

## CI/CD

GitHub Actions (`.github/workflows/build.yml`) triggered by `v*` tags: lint → build arm64 → build x86_64 → release (DMG/ZIP + Sparkle signatures). Release notes auto-extracted from `CHANGELOG.md`.

**Plugin CI** (`.github/workflows/build-plugin.yml`): triggered by `plugin-*-v*` tags. GitHub only fires one workflow per multi-tag `git push` — push tags individually or use `workflow_dispatch` with comma-separated tags for bulk releases.
