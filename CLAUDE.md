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
7. **Testability** — every testable code change needs unit/function tests, and UI/user-flow changes should add UI automation where they run deterministically. When tests fail, fix the source code — never adjust tests to match incorrect output.
8. **Maintainability** — follow existing patterns but offer refactors when they improve quality. Extract into extensions when approaching size limits. Group by domain logic.
9. **Scalability** — design for the plugin system's open-ended nature. `DatabaseType` is a struct, not an enum. All switches need `default:`.

## Project Overview

TablePro is a native macOS database client (SwiftUI + AppKit) — a fast, lightweight alternative to TablePlus. macOS 14.0+, Swift 5.9, Universal Binary (arm64 + x86_64).

- **Source**: `TablePro/` — `Core/` (business logic, services), `Views/` (UI), `Models/` (data structures), `ViewModels/`, `Extensions/`, `Theme/`
- **Plugins**: `Plugins/` — `.tableplugin` bundles + `TableProPluginKit` shared framework.
    - **Bundled in app**: MySQL, PostgreSQL, SQLite, ClickHouse, Redis, CSV, JSON, SQL export, XLSX export, MQL export, SQL import. Shipped only inside the app bundle. **Never publish bundled plugins to the registry.** Updates ride with the next app release.
    - **Registry-only**: MongoDB, Oracle, DuckDB, MSSQL, Cassandra, Etcd, CloudflareD1, DynamoDB, BigQuery, LibSQL, Snowflake, Elasticsearch. Distributed via [TableProApp/plugins](https://github.com/TableProApp/plugins) `plugins.json`, installed into the user plugins directory.
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
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation -only-testing:TableProUITests

# DMG
scripts/create-dmg.sh

# Static libraries (first-time setup or after lib updates)
scripts/download-libs.sh          # Download from GitHub Releases (skips if already present)
scripts/download-libs.sh --force  # Re-download and overwrite
```

### Updating Static Libraries

Static libs (`Libs/*.a`) are hosted on the `libs-v1` GitHub Release (not in git). When adding or updating a library:

```bash
# 1. Update the .a files in Libs/ (build scripts write them there)
# 2. Publish: verifies all OTHER local libs still match the checksums at HEAD,
#    regenerates checksums.sha256, uploads the archive. Name every lib you rebuilt.
scripts/publish-libs.sh libmongoc_arm64.a libmongoc_x86_64.a libmongoc_universal.a libmongoc.a
# 3. Commit the updated checksums
git add Libs/checksums.sha256 && git commit -m "build: update static library checksums"
```

Never run `shasum -a 256 Libs/*.a > Libs/checksums.sha256` by hand: regenerating from a stale `Libs/` reverts other libraries silently (this shipped a broken libmongoc and rolled back DuckDB once). `publish-libs.sh` exists to make that impossible.

```bash

# iOS xcframeworks (Libs/ios/*.xcframework)
tar czf /tmp/tablepro-libs-ios-v1.tar.gz -C Libs/ios .
gh release upload libs-v1 /tmp/tablepro-libs-ios-v1.tar.gz --clobber --repo TableProApp/TablePro
```

## Architecture

### Plugin System

All database drivers are `.tableplugin` bundles loaded at runtime by `PluginManager` (`Core/Plugins/`):

- **TableProPluginKit** (`Plugins/TableProPluginKit/`) — shared framework with `PluginDatabaseDriver`, `DriverPlugin`, `TableProPlugin` protocols and transfer types (`PluginQueryResult`, `PluginColumnInfo`, etc.). This is the single source of truth; the SwiftPM target at `Packages/TableProCore/Sources/TableProPluginKit` is a symlink to it, so edit the files under `Plugins/TableProPluginKit/` only.
- **PluginDriverAdapter** (`Core/Plugins/PluginDriverAdapter.swift`) — bridges `PluginDatabaseDriver` → `DatabaseDriver` protocol
- **DatabaseDriverFactory** (`Core/Database/DatabaseDriver.swift`) — looks up plugins via `DatabaseType.pluginTypeId`
- **DatabaseManager** (`Core/Database/DatabaseManager.swift`) — connection pool, lifecycle, primary interface for views/coordinators
- **ConnectionHealthMonitor** — 30s ping, auto-reconnect with exponential backoff

When adding a new driver: create a new plugin bundle under `Plugins/`, implement `DriverPlugin` + `PluginDatabaseDriver`, add target to pbxproj, add `DatabaseType` static constant, add case to `resolve_plugin_info()` in `.github/workflows/build-plugin.yml`, add row to `docs/index.mdx` supported databases table, and add CHANGELOG entry. See `docs/development/plugin-system/` for details.

When adding a new method to the driver protocol: add to `PluginDatabaseDriver` (with default implementation), then update `PluginDriverAdapter` to bridge it to `DatabaseDriver`. This is an additive, ABI-safe change (see below) and needs no version bump.

**PluginKit ABI (resilient)**: TableProPluginKit is built with `BUILD_LIBRARY_FOR_DISTRIBUTION = YES` (Swift Library Evolution), so its public ABI is resilient. The Swift runtime instantiates witness tables for already-built plugins and fills any requirement the plugin did not implement from the protocol's default, so a plugin built against an older PluginKit keeps loading under a newer app.

**Additive changes are binary-compatible and need NO version bump**: adding a requirement to `DriverPlugin` / `PluginDatabaseDriver` that has a default implementation, reordering requirements, or adding a field to a non-`@frozen` transfer struct.

**Never remove a published protocol requirement, even one that defaulted to `nil`.** Library Evolution fills in requirements *added* after a plugin was built, but it cannot rescue a requirement *removed* out from under an already-built plugin. Removing one deletes both its method descriptor and its default-implementation symbol, and every shipped plugin that relied on the default hard-references both in its witness table, so it fails to load with "Bundle failed to load executable". If the app stops using a requirement, leave it in place with its default (it costs nothing). Removing it is a breaking change: bump `currentPluginKitVersion` and re-release every plugin. (#1917, and it broke MongoDB, Oracle, Cassandra, and Elasticsearch on 0.58.)

**Adding a field to a transfer struct is additive ONLY if every existing public initializer keeps its exact signature.** Adding a parameter to an existing public init or function, even with a default value, replaces its mangled symbol and breaks every already-built plugin (this shipped in 0.49.0: `PluginQueryResult` gained `columnMeta:` on its init and every registry plugin failed to load with "Bundle failed to load executable"). Add a NEW overload for the new field and keep the old signature; mark the old overload `@_disfavoredOverload` so new code resolves to the full init while old binaries keep their symbol. Before any PluginKit change run `scripts/check-pluginkit-abi.sh` (see below) and act on the result: either the diff is additive (verify no symbol disappeared) or it is breaking (bump and re-release).

**Bump `currentPluginKitVersion` (in `PluginManager.swift`) and `TableProPluginKitVersion` in every plugin `Info.plist` ONLY for a breaking change**: changing or removing an existing requirement's signature, adding a requirement without a default, adding a case to a `@frozen` enum, or changing a frozen type's layout. Mark a public enum `@frozen` only when an exhaustive switch over it forces it (the compiler flags the switch) and its case set is genuinely closed; leave the rest non-frozen so they can gain cases. `PluginCapability` stays non-frozen with `@unknown default` because it is a growing capability set, not a closed vocabulary. The driver protocols and transfer structs stay non-frozen so they can grow. The strict version gate in `validateBundleVersions` still rejects a stale plugin cleanly after a breaking bump (no `EXC_BAD_INSTRUCTION`).

**ABI check** (manual): `scripts/check-pluginkit-abi.sh [base-ref]` builds TableProPluginKit at the current tree and at the base ref with the same toolchain, then diffs their public interfaces. There is no committed baseline, so a Swift version difference between machines never produces a false diff. Run it before merging any change under `Plugins/TableProPluginKit/**`, comparing against the merge base. A reported diff is a real ABI change: additive needs no bump; breaking needs the version bump above plus `release-all-plugins.sh`. (Until Library Evolution is on the base too, the base emits no interface and the check passes as a bootstrap.)

**Post-ABI-bump checklist (mandatory, breaking bumps only)**: Bumps are now rare (only the breaking changes listed above). After one, every registry-published plugin must be rebuilt against the new ABI. Run `release-all-plugins.sh` for the new version BEFORE or WITH the app release, never after, or users on the new app hit `noCompatibleBinary` until the registry catches up. App auto-update reconciliation handles the user-facing recovery, but the registry has to carry binaries for the new PluginKit version first.

1. Commit the bump (updates `PluginManager.swift` and every bundled plugin's `Info.plist`). Bundled plugins ship with the next app release. Do not tag them.
2. Trigger the bulk re-release:
   ```bash
   ./scripts/release-all-plugins.sh <newPluginKitVersion>
   ```
   The workflow runs all registry plugins as a parallel matrix, publishes ZIPs to GitHub Releases, and updates `plugins.json` (via `.github/scripts/update-registry.py`, which appends new binaries and prunes per the `--keep-kit-versions 2` policy). No manual `plugins.json` editing.
3. Verify by installing one plugin from the registry on a build with the new PluginKit version.

**Binary retention policy**: The registry keeps binaries for the two most recent PluginKit versions per plugin (`--keep-kit-versions 2`). Users on the previous app version can still install plugins; users two or more versions behind hit `noCompatibleBinary` and need to update the app.

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

**Window tab titles**: The native tab label follows `NSWindow.title`, and AppKit renders it for background tabs too, so the title must be correct from creation, not from first activation. Every title resolves through `WindowTitleResolver` (pure, AppKit-free): `MainSplitViewController.init` for the payload-driven initial title, `updateWindowTitleAndFileState()` in `MainContentView+Setup.swift` for ongoing tab-driven updates. The resolver treats a blank string as absent at every tier and always recomputes a `.table` tab's name from `tableName`+`schemaName` instead of trusting a carried-over title. `TabWindowController.init` pushes the resolved title onto `window.title`/`window.subtitle` right after assigning `contentViewController`, because a joined-but-never-activated tab window never runs `viewWillAppear` or its SwiftUI lifecycle. `MainSplitViewController.windowTitle`'s `didSet` is the single guarded sink and never lets an empty string reach `NSWindow.title`. Never write `window.title` or `NSApp.keyWindow?.title` directly; mutate `tab.title` and call `QueryTabManager.markTabRenamed(_:)` so the resolver re-runs. A restored tab whose persisted title decoded to "" shipped as a blank tab label that only healed on activation.

**Schema loading**: `SQLSchemaProvider` (actor) stores an in-flight `loadTask: Task<Void, Never>?`. Concurrent callers `await` the same Task instead of firing duplicate `fetchTables()` queries. Never use a boolean `isLoading` guard that returns without data — callers need to await the result.

**Selection indices are display positions**: `GridSelectionState.indices` come from `NSTableView.selectedRowIndexes` and are display-row positions, not indices into `TableRows.rows`. They match array indices only when `displayIDs` (`valueFilteredIDs ?? sortedIDs`) is nil; a per-column value filter makes them diverge. Resolve any selected index through `DisplayRowMapping` (or `TableViewCoordinator.displayRow(at:)` / `tableRowsIndex(forDisplayRow:)`) before reading or mutating a row; never index `TableRows.rows` with a display position. The row details inspector shipped this bug (#1837).

**Cancelling a connect does not stop the driver**: `Task.cancel()` is cooperative, so it cannot interrupt a driver blocked in a C call. A cancelled attempt keeps running and completes late. Two rules follow. First, a driver that blocks on connect must expose its own abort path and poll it (the PostgreSQL driver uses `PQconnectStart`/`PQconnectPoll` with an app-owned deadline and a cancel flag flipped from `withTaskCancellationHandler`; a blocking `PQconnectdb` cannot be cancelled at all). When the driver's C API has no pollable connect (FreeTDS db-lib's `dbopen`), the other valid shape is to resume the awaiting caller on cancel or an app-owned deadline through a resume-once continuation gate (`SingleResumeGate` / `runCancellableBlocking`), keep the blocking call on its own serial queue, and have the late-completing call tear down its own handle (the loser `dbclose`s the `dbproc`) instead of adopting it; a process-global set before the blocking call (e.g. `KRB5CCNAME` for Kerberos) is set and restored inside that queue block so its lifetime tracks the real completion, not the early return (#1889). Second, never assume the losing attempt is gone: every attempt validates its `ConnectionAttemptRegistry` generation before adopting a driver into `activeSessions` or tearing session state down, so a late attempt discards its own driver instead of clobbering the winner. Cancelling also drops the connection from `LastOpenConnections.json` (via `MainContentCoordinator.syncRecoveryList()`, activated windows only) so "Reopen Last Session" never replays a connect the user cancelled. This area shipped the same bug four times (#1185, #1358, #1369).

**A split pane's `holdingPriority` must stay below 490**: AppKit applies a divider drag as a layout change at `dragThatCannotResizeWindow` (490). Any pane whose `holdingPriority` is at or above that outranks the drag, so its width constraint wins and the divider cannot move at all. `.defaultHigh` (750) freezes it outright, which shipped as three dead dividers (Users & Roles, Structure triggers, Server Dashboard). Use `.splitPaneHolding` (260, the value AppKit itself gives a sidebar item): high enough to outrank a `.defaultLow` (250) sibling so the pane holds its size when the window resizes, low enough that a drag still wins. `.defaultLow` is not the fix, since the pane then grows with the window instead of holding. (#1872)

**Tab content must never pin the window's split dividers**: `NSSplitViewItem.minimumThickness` is a required constraint, so a nested `NSSplitViewController` reports `sum(minimums) + dividers` as its `fittingSize`. SwiftUI adopts that number for an `NSViewControllerRepresentable` and the enclosing `NSHostingView` turns it into a `minWidth` at priority 999.9, which beats the 490 (`dragThatCannotResizeWindow`) a divider drag runs at: the window's sidebar and inspector dividers go dead. Two rules follow. First, every hosting controller that is a split item's view controller sets `sizingOptions = []` (`MainSplitViewController`'s `detailHosting` and `inspectorHosting`, and both panes inside `AutosavingSplitView`), and `AutosavingSplitView` returns the proposal from `sizeThatFits` so its own minimums never escape into SwiftUI. Second, a tab that genuinely needs more width than `defaultDetailMinThickness` declares it through `resolveDetailMinimumThickness(for:)` instead of leaking it; the detail pane's minimum is a per-tab contract, and `recomputeWindowMinSize()` reads it live. AppKit will not rescue you here: `.sidebar` behaviour and `canCollapseFromWindowResize` only auto-collapse on a window live-resize, which an embedded split view never sees, and no form of collapsibility lowers `fittingSize` (only an actual `isCollapsed = true` does). `CollapsingSplitViewController` collapses the pane itself for that reason. This shipped as a dead inspector divider on Users & Roles tabs (#1872).

**A SwiftUI-hosted split view needs an explicit divider cursor**: `NSSplitView` shows the resize cursor over its dividers through AppKit's cursor-rects system, which does not fire once the split view is mounted inside an `NSHostingController` (every tab-content split is, several SwiftUI layers deep under `MainSplitViewController.detailHosting`). The divider still drags because drag hit-testing is independent of cursor rects, but the pointer never changes. Every SwiftUI-hosted split-view controller must subclass `ResizeCursorSplitViewController`, which adds a key-window tracking area to its own split view and sets `NSCursor.columnResize`/`rowResize` (falling back to `resizeLeftRight`/`resizeUpDown` before macOS 15) in `mouseMoved`, the same hand-rolled approach `SortableHeaderView` uses for column resize. It attaches the tracking area to the framework's split view in `viewDidLoad` rather than replacing the split view, so `NSSplitViewController`'s own layout and divider orientation stay intact; replacing the split view through a `loadView` override that skips `super` leaves the controller half-initialized and its panes stack instead of laying out side by side. Do not swap the controller back to a plain `NSSplitViewController` expecting the stock cursor to work; the window's own sidebar and inspector dividers only get the cursor for free because `MainSplitViewController` is the window's `contentViewController` directly, with no SwiftUI host in between. This shipped as Users & Roles, Structure, Server Dashboard, and query editor dividers that dragged but never showed the resize cursor (#1905).

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
| Filter defaults      | UserDefaults     | `FilterSettingsStorage` (default column/operator, panel state) |
| Filter presets       | UserDefaults     | `FilterPresetStorage`                       |
| Per-table filters    | JSON files       | `FilterSettingsStorage` (one file per connection + database + schema + table; saves the valid working set, each row's enabled flag included) |
| Favorite tables      | UserDefaults     | `FavoriteTablesStorage` (per connection + database + schema; iCloud-synced) |
| Tree database filter | UserDefaults     | `DatabaseTreeFilterStorage` (per connection; selected database set, empty = show all; device-local). Live value held in `SharedSidebarState`. |
| Recent tables        | UserDefaults     | `RecentTablesStore` (per connection, keyed by database, last 10 each; device-local). Live value held in `SharedSidebarState`, recorded at the `QueryTabManager` open chokepoint. |
| Trusted external links | UserDefaults   | `ExternalConnectionTrustStore` (keyed by database type + host + database + username + URL `name`, never the port; loopback hosts only, enforced on read and write). Consulted by `ExternalConnectionGate` before the external-URL confirmation alert. |

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

4. **Tests**: Every change with testable behavior must include or update unit/function tests. UI and user-flow changes should add or update `TableProUITests` UI automation where the flow runs deterministically; if it can't, note why in the PR description. When tests fail, fix the source code — never adjust tests to match incorrect output. Tests define expected behavior.

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

**Plugin CI** (`.github/workflows/build-plugin.yml`): triggered by `plugin-*-v*` tags or `workflow_dispatch`. The dispatch input accepts comma-separated `tag:pluginKitVersion` pairs; if `:pluginKitVersion` is omitted, the workflow reads `currentPluginKitVersion` from `PluginManager.swift`. Registry update logic lives in `.github/scripts/update-registry.py` (atomic write, per-binary `pluginKitVersion`, prune-old policy). Use `scripts/release-all-plugins.sh <version>` for bulk re-release after an ABI bump.

**Plugin tag naming**: Tag names must match the CI workflow's `resolve_plugin_info()` mapping. Notable non-obvious mappings: `CloudflareD1DriverPlugin` → `plugin-cloudflare-d1-v*`, `EtcdDriverPlugin` → `plugin-etcd-v*`. Check existing tags with `git tag -l "plugin-*"` before creating new ones.
