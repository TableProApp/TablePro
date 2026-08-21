# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Principles

These govern every decision about code, architecture, tooling and process:

1. **Security first**: never introduce vulnerabilities (injection, XSS, OWASP top 10). Validate at system boundaries.
2. **Native only**: use native macOS/iOS components (AppKit, SwiftUI, system frameworks). No cross-platform abstractions, no web views for native UI.
3. **Clean architecture**: proper separation of concerns, protocol-oriented design, dependency injection where appropriate. Every task must consider its impact on architecture and code quality, not just the immediate problem.
4. **Clean code**: self-explanatory naming, early returns over nested conditionals, small focused functions. No comments in the codebase, code must be self-documenting through clear naming and structure.
5. **Root cause fixes**: don't patch symptoms. Diagnose the underlying issue, add logging to debug if needed, then fix the actual cause.
6. **No hacky solutions**: no backward-compatibility shims, no temporary workarounds left in place, no duct tape. If the right fix is harder, do the right fix.
7. **Testability**: every testable code change needs unit/function tests, and UI/user-flow changes should add UI automation where they run deterministically. When tests fail, fix the source code, never adjust tests to match incorrect output.
8. **Maintainability**: follow existing patterns but offer refactors when they improve quality. Extract into extensions when approaching size limits. Group by domain logic.
9. **Scalability**: design for the plugin system's open-ended nature. `DatabaseType` is a struct, not an enum. All switches need `default:`.

## Project Overview

TablePro is a native macOS database client (SwiftUI + AppKit), a fast, lightweight alternative to TablePlus. macOS 14.0+, `SWIFT_VERSION = 6.0` (`Configs/Base.xcconfig`), Universal Binary (arm64 + x86_64).

- **Source**: `TablePro/` holds `Core/` (business logic, services), `Views/` (UI), `Models/` (data structures), `ViewModels/`, `Extensions/` and `Theme/`
- **Plugins**: `Plugins/` holds the `.tableplugin` bundles plus the `TableProPluginKit` shared framework.
    - **Bundled in app** (the 14 targets in the app's `copy: { destination: plugins }` phase in `project.yml`): MySQL, PostgreSQL, SQLite, ClickHouse, Redis, CSV export, JSON export, SQL export, XLSX export, MQL export, SQL import, JSON import, CSV import, CSV inspector. These ship inside the app bundle and their updates normally ride with the next app release. Six of them (`sqlite`, `clickhouse`, `redis`, `xlsx`, `mql`, `sqlimport`) also have registry arms in `build-plugin.yml`, so a bundled plugin can be published when users on an already-shipped app need the fix sooner. `scripts/build-plugin.sh:10` explains the flag that makes that work.
    - **Registry-only** (the other 17): MongoDB, Oracle, DuckDB, MSSQL, Cassandra, Etcd, CloudflareD1, DynamoDB, BigQuery, LibSQL, Snowflake, Elasticsearch, Beancount, SurrealDB, Teradata, Trino, Dameng. Distributed via [TableProApp/plugins](https://github.com/TableProApp/plugins) `plugins.json`, installed into the user plugins directory.
- **C bridges**: Each plugin contains its own C bridge module (e.g., `Plugins/MySQLDriverPlugin/CMariaDB/`, `Plugins/PostgreSQLDriverPlugin/CLibPQ/`)
- **Static libs**: `Libs/` holds pre-built `.a` files and `Libs/ios/` holds the iOS xcframeworks. Both are downloaded by `scripts/download-libs.sh` and are not in git.
- **SPM deps**: declared in `project.yml`. Vendored local packages under `LocalPackages/` (CodeEditSourceEditor, CodeEditTextView, CodeEditLanguages) and `Packages/` (TableProCore, TableProOracle); remote packages are Sparkle, swift-certificates and Yams. Revisions are pinned by the tracked `Package.resolved` inside each generated `.xcodeproj`.
    - `SWIFT_VERSION` in `Configs/Base.xcconfig` sets the language mode for the Xcode-native targets only. A SwiftPM package takes its mode from its own manifest, so `Packages/TableProCore` and `Packages/TableProOracle` carry `swift-tools-version: 6.0` of their own. The vendored `LocalPackages/` forks stay on 5.9 so they can still take upstream changes, and a remote dependency keeps whatever its own manifest says. Never pass `SWIFT_VERSION=` on an `xcodebuild` command line to test a language-mode change: the override reaches the package targets too and reports their errors as yours.

## Build & Development Commands

```bash
# First-time setup (and after any project.yml / Configs change, or adding a source file)
scripts/download-libs.sh          # static libraries, not in git
scripts/generate-project.sh       # generates both .xcodeproj bundles from project.yml

# Build (development), -skipPackagePluginValidation required for SwiftLint plugin in CodeEditSourceEditor
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

# Static libraries (after lib updates)
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

### Project Generation

`TablePro.xcodeproj` and `TableProMobile/TableProMobile.xcodeproj` are **generated artifacts**. They are gitignored and must never be hand-edited or committed. The source of truth is:

- `project.yml` / `TableProMobile/project.yml`: targets, sources, dependencies, schemes, and per-target build settings
- `Configs/*.xcconfig`: project-wide and per-configuration build settings, shared by both projects
- `Configs/Version.xcconfig`: the app's `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, read by the release skill and by `build-plugin.yml`
- `Configs/Secrets.xcconfig`: gitignored, pulled in with `#include?`, holds `ANALYTICS_HMAC_SECRET` and per-developer signing overrides. `Configs/Secrets.xcconfig.example` is the template.

Run `scripts/generate-project.sh` after editing any of those, and after adding, moving, or deleting a source file: XcodeGen globs sources at generation time, so a new file is not in the project until you regenerate. Changing signing in the Xcode UI is pointless, because the next generate discards it; set `TABLEPRO_DEVELOPMENT_TEAM` and `TABLEPRO_APP_BUNDLE_IDENTIFIER` in `Configs/Secrets.xcconfig` instead.

The 31 plugin bundles share one `DriverPlugin` target template; a plugin declares only its folder, principal class, and any C-library link flags. Every target gets a shared scheme named after it, which is what `scripts/build-plugin.sh <PluginTarget> [arm64|x86_64|both] [version]` builds. The `AllPlugins` aggregate target compile-checks all 31, including the registry-only ones the app does not embed, and PR CI runs it: the `Compile every plugin` step in the `app-tests` job of `.github/workflows/macos-tests.yml` builds that scheme whenever the change touches `Plugins/` or any other watched path. What PR CI still does not cover is plugin packaging, signing and notarization, which only `build-plugin.yml` does and only on a release tag.

### Plugin System

All database drivers are `.tableplugin` bundles loaded at runtime by `PluginManager` (`Core/Plugins/`):

- **TableProPluginKit** (`Plugins/TableProPluginKit/`), shared framework with `PluginDatabaseDriver`, `DriverPlugin`, `TableProPlugin` protocols and transfer types (`PluginQueryResult`, `PluginColumnInfo`, etc.). This is the single source of truth; the SwiftPM target at `Packages/TableProCore/Sources/TableProPluginKit` is a symlink to it, so edit the files under `Plugins/TableProPluginKit/` only.
- **PluginDriverAdapter** (`Core/Plugins/PluginDriverAdapter.swift`), bridges `PluginDatabaseDriver` → `DatabaseDriver` protocol
- **DatabaseDriverFactory** (`Core/Database/DatabaseDriver.swift`), looks up plugins via `DatabaseType.pluginTypeId`
- **DatabaseManager** (`Core/Database/DatabaseManager.swift`), connection pool, lifecycle, primary interface for views/coordinators
- **ConnectionHealthMonitor**: 30s ping, auto-reconnect with exponential backoff

When adding a new driver: create a new plugin bundle under `Plugins/`, implement `DriverPlugin` + `PluginDatabaseDriver`, add the target to `project.yml`, add `DatabaseType` static constant, add an entry to `.github/plugin-registry.json`, add row to `docs/index.mdx` supported databases table, and add CHANGELOG entry. See `docs/development/plugin-development.mdx` and `docs/development/plugin-registry.mdx` for details.

When adding a new method to the driver protocol: add to `PluginDatabaseDriver` (with default implementation), then update `PluginDriverAdapter` to bridge it to `DatabaseDriver`. This is an additive, ABI-safe change (see below) and needs no version bump.

**PluginKit ABI (resilient)**: TableProPluginKit is built with `BUILD_LIBRARY_FOR_DISTRIBUTION = YES` (Swift Library Evolution), so its public ABI is resilient. The Swift runtime instantiates witness tables for already-built plugins and fills any requirement the plugin did not implement from the protocol's default, so a plugin built against an older PluginKit keeps loading under a newer app.

**Additive changes are binary-compatible and need NO version bump**: adding a requirement to `DriverPlugin` / `PluginDatabaseDriver` that has a default implementation, reordering requirements, or adding a field to a non-`@frozen` transfer struct.

**Never remove a published protocol requirement, even one that defaulted to `nil`.** Library Evolution fills in requirements *added* after a plugin was built, but it cannot rescue a requirement *removed* out from under an already-built plugin. Removing one deletes both its method descriptor and its default-implementation symbol, and every shipped plugin that relied on the default hard-references both in its witness table, so it fails to load with "Bundle failed to load executable". If the app stops using a requirement, leave it in place with its default (it costs nothing). Removing it is a breaking change: bump `currentPluginKitVersion` and re-release every plugin. (#1917, and it broke MongoDB, Oracle, Cassandra, and Elasticsearch on 0.58.)

**Adding a field to a transfer struct is additive ONLY if every existing public initializer keeps its exact signature.** Adding a parameter to an existing public init or function, even with a default value, replaces its mangled symbol and breaks every already-built plugin (this shipped in 0.49.0: `PluginQueryResult` gained `columnMeta:` on its init and every registry plugin failed to load with "Bundle failed to load executable"). Add a NEW overload for the new field and keep the old signature; mark the old overload `@_disfavoredOverload` so new code resolves to the full init while old binaries keep their symbol. Before any PluginKit change run `scripts/check-pluginkit-abi.sh` (see below) and act on the result: either the diff is additive (verify no symbol disappeared) or it is breaking (bump and re-release).

**Bump `currentPluginKitVersion` (in `PluginManager.swift`) and `TableProPluginKitVersion` in every plugin `Info.plist` ONLY for a breaking change**: changing or removing an existing requirement's signature, adding a requirement without a default, adding a case to a `@frozen` enum, or changing a frozen type's layout. Mark a public enum `@frozen` only when an exhaustive switch over it forces it (the compiler flags the switch) and its case set is genuinely closed; leave the rest non-frozen so they can gain cases. `PluginCapability` stays non-frozen with `@unknown default` because it is a growing capability set, not a closed vocabulary. The driver protocols and transfer structs stay non-frozen so they can grow. The strict version gate in `validateBundleVersions` still rejects a stale plugin cleanly after a breaking bump (no `EXC_BAD_INSTRUCTION`).

**ABI check** (manual): `scripts/check-pluginkit-abi.sh [base-ref]` generates the project from `project.yml` on both sides, builds TableProPluginKit at the current tree and at the base ref with the same toolchain, then diffs their public interfaces. A base ref that predates `project.yml` cannot be compared. There is no committed baseline, so a Swift version difference between machines never produces a false diff. Run it before merging any change under `Plugins/TableProPluginKit/**`, comparing against the merge base. A reported diff is a real ABI change: additive needs no bump; breaking needs the version bump above plus `release-all-plugins.sh`. (Until Library Evolution is on the base too, the base emits no interface and the check passes as a bootstrap.)

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
- All `switch` statements must include `default:`, the type is open
- Use static constants (`.mysql`, `.postgresql`) for known types
- Unknown types (from future plugins) are valid, they round-trip through Codable
- Use `DatabaseType.allKnownTypes` (not `allCases`) for the canonical list

### Editor Architecture (CodeEditSourceEditor)

- **`SQLEditorTheme`**: single source of truth for editor colors/fonts
- **`TableProEditorTheme`**: adapter to CodeEdit's `EditorTheme` protocol
- **`CompletionEngine`**: framework-agnostic; **`QueryCompletionAdapter`** bridges to CodeEdit's `CodeSuggestionDelegate`
- Editor tabs are drawn by `EditorTabStrip`, not by native window tabs. A window belongs to exactly one `NSWindow` tab group and that group's bar shows every window in it, so a window hosting several connections could only ever show all of their tabs interleaved. Window tabbing itself stays on AppKit's terms: `TabWindowController` leaves `tabbingMode` at `.automatic`, which is the user's own System Settings preference, and never forces `.preferred`.
- Cursor model: `cursorPositions: [CursorPosition]` (multi-cursor via CodeEditSourceEditor)

### Change Tracking Flow

1. User edits cell → `DataChangeManager` records change
2. User clicks Save → `SQLStatementGenerator` produces INSERT/UPDATE/DELETE
3. Undo and redo come from a private `UndoManager` inside `StructureChangeManager`, plus `ConnectionWorkspace.undoManager`
4. `AnyChangeManager` abstracts over concrete manager for protocol-based usage

### Invariants

These have caused real bugs when violated:

**A synced CKRecord record type or field must be deployed to Production before anything writes it**: both apps pin `com.apple.developer.icloud-container-environment` to `Production`, and CloudKit only auto-creates record types and fields in the Development environment. So no build, not even a local Debug one, can create either on the server. Saving a record that carries a field the Production schema does not declare makes CloudKit reject **that whole record**; saving a record whose *type* is undeclared fails with "Cannot create new type X in production schema". With `isAtomic = false` the rest of the batch still saves, so the symptom is one record type silently never syncing while everything else looks healthy, and because a rejected record never clears its dirty flag it is retried on every sync forever.

Every wire key is declared by a `SyncSchemaField` enum in `Packages/TableProCore/Sources/TableProSyncTransport/` (`ConnectionSyncField` and the rest in `SyncSchemaFields.swift`), and writes go through `record.fields(SomeSyncField.self)`, whose gated subscript refuses any field that is not `.verified`. Never reach a CKRecord field by raw string: that bypasses the gate, which is exactly how `FavoriteTable`, `SQLFavorite`, `SQLFavoriteFolder` and `SSHProfile.jumpHostsJson` reached users undeployed. `SyncMapperFieldAccessTests` scans both mappers for `record["` and fails on a match. `SyncRecordType.verifiedInProduction` gates whole record types the same way, and `CloudKitSyncEngine.push` withholds any record whose type is not verified rather than letting the server reject it. Verification is a membership set, not a `default:` arm, so a case added without being listed is `.unverified` and therefore inert rather than destructive.

To ship one: add the record type or field in CloudKit Console (or `xcrun cktool import-schema --environment development`, the only environment `cktool` can write), deploy Development to Production in the Console, run `scripts/export-cloudkit-schema.sh`, commit the refreshed `CloudKit/production-schema.ckdb`, then add it to the matching `verifiedInProduction`. `ProductionSchemaParityTests` checks every record type and every field against the snapshot in both directions, so it fails both when the app would write something undeployed and when the gate is needlessly withholding something that is deployed. This shipped as `isFavorite` (#1452, unconditional on every connection) killing every Mac connection push for two months while the UI reported success (#643), and again as three favorite record types that never synced at all.

**Sync delete ordering**: In `ConnectionStorage` (and all storage classes), `SyncChangeTracker.markDeleted()` must be called AFTER `saveConnections()`. The `markDeleted` call fires `postChangeNotification` which can trigger a sync. If the file on disk still contains the deleted item when sync runs, it may re-upload the deleted record. Persist first, then notify.

**WelcomeViewModel tree rebuild**: The welcome screen renders `treeItems` (grouped/filtered), not `connections` directly. Every mutation to `connections` must call `rebuildTree()` afterward, or the UI won't update.

**Tab replacement guard**: `openTableTab` checks for active work (unsaved edits, applied filters, sorting) before replacing the current tab. A tab with active work is left alone and the table opens as a new editor tab in the same window's strip. This check runs before the preview tab branch.

**Window tab titles**: The native tab label follows `NSWindow.title`, and AppKit renders it for background tabs too, so the title must be correct from creation, not from first activation. Every title resolves through `WindowTitleResolver` (pure, AppKit-free): `MainSplitViewController.init` for the payload-driven initial title, `updateWindowTitleAndFileState()` in `MainContentView+Setup.swift` for ongoing tab-driven updates. The resolver treats a blank string as absent at every tier and always recomputes a `.table` tab's name from `tableName`+`schemaName` instead of trusting a carried-over title. `TabWindowController.init` pushes the resolved title onto `window.title`/`window.subtitle` right after assigning `contentViewController`, because a joined-but-never-activated tab window never runs `viewWillAppear` or its SwiftUI lifecycle. `MainSplitViewController.windowTitle`'s `didSet` is the single guarded sink and never lets an empty string reach `NSWindow.title`. Never write `window.title` or `NSApp.keyWindow?.title` directly; mutate `tab.title` and call `QueryTabManager.markTabRenamed(_:)` so the resolver re-runs. A restored tab whose persisted title decoded to "" shipped as a blank tab label that only healed on activation. Editor tabs are no longer windows, so there are now two labels with two owners: the window titlebar goes through `WindowTitleResolver` and the guarded `windowTitle` sink, while the editor tab label is `Text(tab.title)` in `EditorTabStrip` with no resolver between it and the string. Blank-title healing therefore has to hold at `QueryTab.title` itself.

**Schema loading**: `SQLSchemaProvider` (actor) stores an in-flight `loadTask: Task<Void, Never>?`. Concurrent callers `await` the same Task instead of firing duplicate `fetchTables()` queries. Never use a boolean `isLoading` guard that returns without data, callers need to await the result.

**A refresh never clears the cache it is refreshing**: fetch first, then commit over the old value. A loading flag that discards data is a blank screen: `SchemaService.runLoad` used to write `states[id] = .loading` before the network call, which made `tables(for:)` return `[]`, so `SidebarView`'s `case .loading where tables.isEmpty` matched on every refresh and the whole object list became a spinner (#1916). Only enter `.loading` when there is no loaded content (`hasLoadedContent`), signal an in-flight refresh separately (`isRefreshing`), and keep a failed refresh from replacing good data (the guard `markLoadFailed` already had). The same rule covers per-schema state and `StructureTabDataState`, where "has data" (drives the tab counts) is deliberately separate from "needs refetch" (drives the reload) so marking everything stale never blanks a count. `DatabaseTreeMetadataService.reloadTablesInPlace` is the reference shape. Use `prepareForReload` before a reload and reserve `invalidate` for genuine teardown (disconnect, database switch); invalidating to force a reload wipes the visible tree.

**Selection indices are display positions**: `GridSelectionState.indices` come from `NSTableView.selectedRowIndexes` and are display-row positions, not indices into `TableRows.rows`. They match array indices only when `displayIDs` (`valueFilteredIDs ?? sortedIDs`) is nil; a per-column value filter makes them diverge. Resolve any selected index through `DisplayRowMapping` (or `TableViewCoordinator.displayRow(at:)` / `tableRowsIndex(forDisplayRow:)`) before reading or mutating a row; never index `TableRows.rows` with a display position. The row details inspector shipped this bug (#1837).

**Cancelling a connect does not stop the driver**: `Task.cancel()` is cooperative, so it cannot interrupt a driver blocked in a C call. A cancelled attempt keeps running and completes late. Two rules follow. First, a driver that blocks on connect must expose its own abort path and poll it (the PostgreSQL driver uses `PQconnectStart`/`PQconnectPoll` with an app-owned deadline and a cancel flag flipped from `withTaskCancellationHandler`; a blocking `PQconnectdb` cannot be cancelled at all). When the driver's C API has no pollable connect (FreeTDS db-lib's `dbopen`), the other valid shape is to resume the awaiting caller on cancel or an app-owned deadline through a resume-once continuation gate (`SingleResumeGate` / `runCancellableBlocking`), keep the blocking call on its own serial queue, and have the late-completing call tear down its own handle (the loser `dbclose`s the `dbproc`) instead of adopting it; a process-global set before the blocking call (e.g. `KRB5CCNAME` for Kerberos) is set and restored inside that queue block so its lifetime tracks the real completion, not the early return (#1889). Second, never assume the losing attempt is gone: every attempt validates its `ConnectionAttemptRegistry` generation before adopting a driver into `activeSessions` or tearing session state down, so a late attempt discards its own driver instead of clobbering the winner. Cancelling also drops the connection from `LastOpenConnections.json` (via `SessionRecoveryTracker.sync()`) so "Reopen Last Session" never replays a connect the user cancelled, but a connect that merely *failed* keeps its place in the list: a database that was down is not a user who gave up. That distinction is `ConnectionWindowPhaseMachine.retainsRestoreIntent`, read per workspace through `ConnectionWorkspace.retainsRestoreIntent` and aggregated per window by `MainSplitViewController.connectionIdsRetainingRestoreIntent`, and it is the whole reason `RecoveryCandidate` carries `retainsRestoreIntent` alongside `isActivated`. Collapsing the two back into one flag makes one launch against a stopped server erase the session permanently. This area shipped the same bug four times (#1185, #1358, #1369).

**A workspace's content is a function of its own `ConnectionWindowPhase`, never of `activeSessions` membership**: the global session dictionary can only say *present* or *absent*, and that vocabulary cannot tell "never started" from "connecting" from "failed" from "the user cancelled" from "the window is closing". Deriving the pane from it shipped a window that painted a live spinner forever after a failed launch restore, could not be repainted by a later successful connect, and left no route back to the connection list except the Dock icon's context menu. `ConnectionWorkspace` owns the `phase`, one per connection the window hosts; `ConnectionWindowPhaseMachine` owns the transitions (pure, exhaustive, `.closing` absorbing), and `ConnectionWindowPaneResolver` owns the pane choice (pure). `MainSplitViewController` renders the selected workspace and routes a transition by `connectionId` through `transition(to:for:)`; it is only an adapter, and its `phase` property is a pass-through to `workspaces.selected`. Three rules follow. First, every phase must have an exit: the old `closingSessionId` latch was set once and never cleared, so the controller went permanently deaf to `connectionStatusChanged`. Second, a cancel updates the UI synchronously with the button press and never waits on the driver, because `Task.cancel()` is cooperative and may have no observable effect; the attempt is fenced by a per-workspace `attemptToken` (`ConnectionWorkspace.attemptToken`) plus `DatabaseManager.invalidateConnectionAttempt`, so a late failure cannot write into a workspace that moved on. The token cannot live on the window, because the window did not move on: one of the connections it hosts did. Closing a window therefore cancels the in-flight attempt of every workspace it hosts, not just the one its original payload named, and a completion that finds its workspace gone discards itself rather than resurrecting it. Third, a failure is presented inline through `ConnectionUnavailableView`, never as an alert, per the HIG's rule against alerts at startup and its one-alert-at-a-time rule (N restored connections would mean N modals). Only one presenter per failure: `LaunchIntentRouter.presentError` stays silent when a window for that connection exists.

**The app runs the AppKit lifecycle, and AppKit owns the menu bar**: `main.swift` assigns the delegate before `NSApplicationMain`, and `MainMenuBuilder.install` runs in `applicationWillFinishLaunching`. Do not reintroduce a SwiftUI `App`. SwiftUI reconciles `NSApp.mainMenu` once shortly after launch and removes every item it did not build itself, and no hook can undo it: `NSApp.mainMenu` is not KVO-compliant, `didUpdateNotification`, `didBecomeKeyNotification` and the `applicationDidUpdate(_:)` delegate method never fire under `@NSApplicationDelegateAdaptor`, and `applicationDidBecomeActive` fires before the reconciliation. Only a wall-clock delay worked, which is why #2057 shipped a menu bar that vanished half a second after launch and had to be reverted (#2071). Every window is an `NSWindowController`; the Welcome window is one too, so closing it is an ordinary `close()` and the old "closed, never ordered out" rule no longer applies.

**An emptied tab manager is not the same as "the user closed every tab"**: a coordinator torn down by a lost session has already emptied `tabManager.tabs`, so any persistence path that reads "no tabs" as "clear the saved tabs" wipes tabs the user never closed. The fix is that the teardown path cannot clear at all: `TabPersistenceCoordinator.saveAggregatedSync()`, which disconnect and window-close call, opens with `guard !tabs.isEmpty else { return }`. Clearing requires explicit consent and happens on the `closeTabsByUser` path instead. Keep those two paths separate; the moment a teardown path can write an empty aggregate, the bug is back.

**A split pane's `holdingPriority` must stay below 490**: AppKit applies a divider drag as a layout change at `dragThatCannotResizeWindow` (490). Any pane whose `holdingPriority` is at or above that outranks the drag, so its width constraint wins and the divider cannot move at all. `.defaultHigh` (750) freezes it outright, which shipped as three dead dividers (Users & Roles, Structure triggers, Server Dashboard). Use `.splitPaneHolding` (260, the value AppKit itself gives a sidebar item): high enough to outrank a `.defaultLow` (250) sibling so the pane holds its size when the window resizes, low enough that a drag still wins. `.defaultLow` is not the fix, since the pane then grows with the window instead of holding. (#1872)

**Tab content must never pin the window's split dividers**: `NSSplitViewItem.minimumThickness` is a required constraint, so a nested `NSSplitViewController` reports `sum(minimums) + dividers` as its `fittingSize`. SwiftUI adopts that number for an `NSViewControllerRepresentable` and the enclosing `NSHostingView` turns it into a `minWidth` at priority 999.9, which beats the 490 (`dragThatCannotResizeWindow`) a divider drag runs at: the window's sidebar and inspector dividers go dead. Two rules follow. First, every hosting controller that is a split item's view controller sets `sizingOptions = []` (`MainSplitViewController`'s `detailHosting` and `inspectorHosting`, and both panes inside `AutosavingSplitView`), and `AutosavingSplitView` returns the proposal from `sizeThatFits` so its own minimums never escape into SwiftUI. Second, a tab that genuinely needs more width than `defaultDetailMinThickness` declares it through `resolveDetailMinimumThickness(for:)` instead of leaking it; the detail pane's minimum is a per-tab contract, and `recomputeWindowMinSize()` reads it live. AppKit will not rescue you here: `.sidebar` behaviour and `canCollapseFromWindowResize` only auto-collapse on a window live-resize, which an embedded split view never sees, and no form of collapsibility lowers `fittingSize` (only an actual `isCollapsed = true` does). `CollapsingSplitViewController` collapses the pane itself for that reason. This shipped as a dead inspector divider on Users & Roles tabs (#1872).

**A SwiftUI-hosted split view needs an explicit divider cursor**: `NSSplitView` shows the resize cursor over its dividers through AppKit's cursor-rects system, which does not fire once the split view is mounted inside an `NSHostingController` (every tab-content split is, several SwiftUI layers deep under `MainSplitViewController.detailHosting`). The divider still drags because drag hit-testing is independent of cursor rects, but the pointer never changes. Every SwiftUI-hosted split-view controller must subclass `ResizeCursorSplitViewController`, which adds a key-window tracking area to its own split view and sets `NSCursor.columnResize`/`rowResize` (falling back to `resizeLeftRight`/`resizeUpDown` before macOS 15) in `mouseMoved`, the same hand-rolled approach `SortableHeaderView` uses for column resize. It attaches the tracking area to the framework's split view in `viewDidLoad` rather than replacing the split view, so `NSSplitViewController`'s own layout and divider orientation stay intact; replacing the split view through a `loadView` override that skips `super` leaves the controller half-initialized and its panes stack instead of laying out side by side. Do not swap the controller back to a plain `NSSplitViewController` expecting the stock cursor to work; the window's own sidebar and inspector dividers only get the cursor for free because `MainSplitViewController` is the window's `contentViewController` directly, with no SwiftUI host in between. This shipped as Users & Roles, Structure, Server Dashboard, and query editor dividers that dragged but never showed the resize cursor (#1905).

**Appearance is not lifetime, so `onDisappear` is never a destructor**: switching connection unparents the outgoing connection's panes (`WorkspacePaneHost.show`) while `WorkspacePanes` keeps the hosting controllers alive, and SwiftUI reports that as `onDisappear` followed by `onAppear` again on the same view identity with the same `@State`. Measured: `removeFromSuperview` fires the pair, `isHidden` and `window.orderOut` fire neither, and nothing fires on window close. Everything released under a pane's `onDisappear` must therefore be rebuilt by its `onAppear`, and anything that cannot be rebuilt must not be released there. `SQLEditorView` released the editor's text storage, highlighter, tree-sitter client, text coordinators and local key monitor from `onDisappear`, and `TextViewController` installs the last three in `loadView` alone, so one connection switch left a blank editor with no highlighting, no undo, no Cmd+/ or Cmd+[ and no Vim mode, permanently (#2236). Terminal teardown belongs to `NSViewControllerRepresentable.dismantleNSViewController`, which fires only on identity destruction, or to the explicit `ConnectionWorkspace.teardown()` chain. One catch there: SwiftUI reconciles a hosting controller on a layout pass and nothing lays out a detached view, so a `rootView` write on a pane that may be unparented needs `layoutSubtreeIfNeeded()` to take effect at all. `WorkspacePanes.teardown()` is the reference shape; `MainSplitViewController.refreshPanes` still writes `rootView` without one.

**The data grid header owns all of its own chrome, so nothing may ask AppKit to paint any of it**: `NSTableHeaderCell` and `NSTableHeaderView` both paint a fixed 28pt band that they centre vertically in whatever frame they are given, a 16pt column divider on `midY` and a 1pt rule at `midY + 13`. The data grid grows its header to 42pt for a column comment, so that band lands mid-cell: the rule crosses the comment's descenders and sits 8pt above the real bottom edge. `SortableHeaderChrome` is therefore the single owner of header geometry and colours, `SortableHeaderCell.draw(withFrame:in:)` never calls `super`, and `SortableHeaderView.draw(_:)` fills the background and rules the bottom edge itself. The trap is that the header view paints a second copy of that same band for `NSTableView.highlightedTableColumn`, driven by *state* rather than by a drawing call, so no cell override can reach it: setting it gives the sorted column a stray divider and a rule no other column has. TablePro already draws the sorted-column affordance itself (bold title, chevron, priority number, with `drawSortIndicator` overridden to nothing), so `highlightedTableColumn` is a redundant second channel and must stay unset. All sorted-column presentation goes through `SortableHeaderView.applySortState(_:schema:)`, which publishes the order natively through `tableView.sortDescriptors` (for accessibility; it paints nothing) and updates the cells. `SortableHeaderRenderingTests` rasterises the header and guards this. This shipped as a rule through the comment line and a stray divider on the sorted column (#2017).

**Decoding a MongoDB binary UUID is a per-column decision, and the column's type name is load-bearing**: BSON binary subtype 3 is the legacy UUID format, and the Java, C# and Python drivers each wrote it with a different byte order with nothing in the stored bytes to say which. `MongoDBUuidCodec` therefore decodes subtype 3 only when the connection names one (`mongoUuidRepresentation`); subtype 4 is unambiguous and always decodes. The choice is made once per column from `BsonDocumentFlattener.columnKinds`' majority vote, never per value, because a decoded cell is `.text` and an undecoded one is `.bytes`, and `CellDisplayFormatter` runs blob formatting over a `.text` cell whenever its column type is BLOB. One UUID decoded inside a column the app still types `BLOB` renders as `0x4c65676163...`. For the same reason `BsonDocumentFlattener.typeName` must keep `BLOB` as the base name for undecoded binary: `ColumnTypeClassifier` splits a type name at the first `(` and looks the base up, so `BLOB` and `BLOB(3)` both classify as `.blob`, and that classification is the only thing keeping a binary cell out of the inline editor. The parenthesised part carries the BSON subtype so MQL export can write it back; `MongoDBUuidCodec.columnTypeName(forSubtype:)` and `binarySubtype(fromColumnTypeName:)` are the only two places that spelling is produced or read, and MQL export is `supportedDatabaseTypeIds = ["MongoDB"]`, so it never sees another driver's `BLOB`. Once a column does decode, both edit guards (`isBlobType` and `asBytes != nil`) fall together, so every write path must parse the wrapper back to `$binary`: `MongoDBStatementGenerator.jsonValue` and `idValueJson`, `MongoDBQueryBuilder.jsonValue` plus its `=`, `!=` and `IN` arms (a case-insensitive regex can never match a binary field), and `MQLExportHelpers.mqlJsonValue`. An `_id` filter left as wrapper text matches zero documents while the UI reports the save succeeded. (#2086)

**A pooled metadata read assumes a second connection reaches the same database, and an embedded engine breaks that assumption**: `MetadataConnectionPool` builds a whole new driver, so it is only correct when the database lives on a server the driver reconnects to. When the database lives *inside* the driver instance, the pool gets a different database: a second `duckdb_open(":memory:")` is a fresh empty database, and a second `duckdb_open` on the same *file* is a second independent read-write instance that the first never sees (DuckDB's file lock does not conflict within one process). The failure is silent, because an empty catalog is indistinguishable from "no tables", which is why #2108 survived a manual refresh. `supportsConnectionPooling` is the opt-out, and it is read only by `DatabaseManager.canPool`; DuckDB and PGlite set it `false`. SQLite-family engines keep pooling, because multi-connection access to one file is what they are built for. Two rules follow. First, every metadata read goes through `DatabaseManager.withMetadataDriver` so `metadataRoute` can apply the rule; reaching for `MetadataConnectionPool.shared.withDriver` directly bypasses it, which is how routines kept pooling after the sidebar stopped. Second, a capability with no `DriverPlugin` static is curated per type and `buildMetadataSnapshot` must carry it over from the built-in snapshot, or `register(snapshot:forTypeId:)` resets it to the struct default the moment the plugin loads. That is not hypothetical: it silently disabled MongoDB's `authenticationIsDatabaseScoped` (#1970) for every build that had the plugin installed. `registerVariant` already treats the curated entry as authoritative, which is the only reason PGlite's flag ever worked.

**A MongoDB update or delete is anchored on `_id` or it does not run**: `generateDelete` used to fall back to a filter built from the remaining columns, which silently dropped every value it could not stringify (all binary) and then `deleteOne`d the first partial match, so a document with a binary `_id` could delete a different document. Both paths now skip with a logged warning instead, matching what `generateUpdate` already did.

**Redis Cluster routing follows the server's own answer, and the curated table is only a fallback**: `RedisCommandRouting` fetches `COMMAND` once at connect, which supplies key positions on every Redis and, from Redis 7, the `request_policy` / `response_policy` tips that say which commands fan out and how their replies combine. A policy lives on the *subcommand* entry, not the container (`COMMAND INFO config` carries no tips at all; `config|set` is what says `all_nodes`), so the table is keyed `container|sub`. Redis 6 reports no tips, so a parsed reply is merged *over* the curated table rather than replacing it, or `DBSIZE`, `KEYS` and `FLUSHDB` would each go to one shard of a cluster and report success. The curated table is a hand-written list that has to agree with Redis and that nothing at runtime checks, so `scripts/check-redis-command-routing.sh [host] [port]` diffs it against a live Redis 7+; it found 32 disagreements the first time it ran, including a container command hashed on its literal subcommand name and `MSETNX` marked splittable when splitting it breaks the guarantee it exists for. Two rules follow. A container command takes no key of its own, so `OBJECT`, `MEMORY` and `CONFIG` declare no key positions and their keyed subcommands are listed separately, at the index the key sits in the *full* argument list (`OBJECT ENCODING k` puts it at 2, not 1). And an unknown command is routed as keyless rather than by hashing `argv[1]`: a keyless container like `SCRIPT LOAD` answers `+OK` from one node and never sends a `MOVED` to correct the guess.

### Main Coordinator Pattern

`MainContentCoordinator` is the central coordinator, split across 51 extension files in `Views/Main/Extensions/` (e.g., `+Alerts`, `+Filtering`, `+Pagination`, `+RowOperations`). When adding coordinator functionality, add a new extension file rather than growing the main file.

### Window Close (Cmd+W)

`EditorWindow` (NSWindow subclass in `TabWindowController.swift`) overrides `performClose:` to route Cmd+W through `closeTab()`. SwiftUI's `.commands { Button(...).keyboardShortcut("w") }` does NOT replace AppKit's built-in "File > Close", both fire, and AppKit's wins. The NSWindow subclass is the correct native pattern.

### Storage Patterns

| What                 | How              | Where                                       |
| -------------------- | ---------------- | ------------------------------------------- |
| Connection passwords | Keychain         | `ConnectionStorage`                         |
| User preferences     | UserDefaults     | `AppSettingsStorage` / `AppSettingsManager` |
| Query history        | SQLite FTS5      | `QueryHistoryStorage`                       |
| Tab state            | JSON persistence | `TabPersistenceCoordinator` / `TabDiskActor` |
| Filter defaults      | UserDefaults     | `FilterSettingsStorage` (default column/operator, panel state) |
| Filter presets       | UserDefaults     | `FilterPresetStorage`                       |
| Per-table filters    | JSON files       | `FilterSettingsStorage` (one file per connection + database + schema + table; saves the valid working set, each row's enabled flag included) |
| Favorite tables      | UserDefaults     | `FavoriteTablesStorage` (per connection + database + schema; iCloud-synced) |
| Tree database filter | UserDefaults     | `DatabaseTreeFilterStorage` (per connection; selected database set, empty = show all; device-local). Live value held in `SharedSidebarState`. |
| Recent tables        | UserDefaults     | `RecentTablesStore` (per connection, keyed by database, last 10 each; device-local). Live value held in `SharedSidebarState`, recorded at the `QueryTabManager` open chokepoint. |
| History drawer state | UserDefaults     | `HistoryPanelPreferencesStorage` (per connection; visibility, connection scope, source/date/outcome filters; device-local). Live value held in `HistoryPanelState.forConnection`, cleared alongside `SharedSidebarState` when a session ends. |
| Trusted external links | UserDefaults   | `ExternalConnectionTrustStore` (keyed by database type + host + database + username + URL `name`, never the port; loopback hosts only, enforced on read and write). Consulted by `ExternalConnectionGate` before the external-URL confirmation alert. |

### Logging & Debugging

Use OSLog for all logging, never `print()`. When debugging issues, add structured OSLog statements to trace the problem, don't guess.

```swift
import os
private static let logger = Logger(subsystem: "com.TablePro", category: "ComponentName")
```

## Code Style

**Authoritative sources**: `.swiftlint.yml` and `.swiftformat`, check those files for the full rule set. Key points:

- **No comments**: code must be self-explanatory through naming and structure. Never add comments that describe what code does, reference tasks/tickets, or explain callers.
- **Early returns**: use `guard` and early `return` instead of nested `if/else` blocks. Flatten control flow.
- **4 spaces** indentation (never tabs)
- **120 char** target line length (SwiftFormat); SwiftLint warns at 180, errors at 300
- **K&R braces**, LF line endings, no semicolons, no trailing commas
- **Imports**: system frameworks alphabetically → third-party → local, blank line after imports
- **Access control**: always explicit (`private`, `internal`, `public`). Specify on extension, not individual members:
    ```swift
    public extension NSEvent {
        var semanticKeyCode: KeyCode? { ... }
    }
    ```
- **No force unwrapping/casting**: use `guard let`, `if let`, `as?`

### SwiftLint Limits

| Metric                | Warning | Error |
| --------------------- | ------- | ----- |
| File length           | 1200    | 1800  |
| Type body             | 1100    | 1500  |
| Function body         | 160     | 250   |
| Cyclomatic complexity | 40      | 60    |

When approaching limits: extract into `TypeName+Category.swift` extension files in an `Extensions/` subfolder. Group by domain logic, not arbitrary line counts.

## Mandatory Rules

These are **non-negotiable**, never skip them:

1. **CHANGELOG.md**: Follow [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). Update under `[Unreleased]` using the canonical sections: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`. Each section appears **at most once per version, in that order**; a second `### Security` under one version is a defect, not a second topic. Do **not** add a "Fixed" entry for fixing something that is itself still unreleased; fold the fix into the Added or Changed entry instead. Documentation-only changes (`docs/`, `CLAUDE.md`, `CHANGELOG.md` formatting) do **not** need a CHANGELOG entry.

    **Entry shape**: a changelog is a curated list of notable changes, not the explanation of them. One entry is **one sentence, two at the outside, and under 200 characters**. State what changed and, where it is not obvious, what it does now instead. No file paths, class names, or method signatures; reference IDs go in parens at the end: `(#1234)`. The reasoning, the mechanism and the before-and-after belong in the PR body, which is where a reader who wants them can find them. Two entries describing one change get merged, not listed twice. 0.67.0 arrived with 211 entries averaging 300 characters, one of them 1,685, and had to be rewritten wholesale at release time.

2. **Localization**: Use `String(localized:)` for new user-facing strings in computed properties, AppKit code, alerts, and error descriptions. SwiftUI view literals (`Text("literal")`, `Button("literal")`) auto-localize. Do NOT localize technical terms (font names, database types, SQL keywords, encoding names). Never use `String(localized:)` with string interpolation, `String(localized: "Preview \(name)")` creates a dynamic key that never matches the strings catalog. Use `String(format: String(localized: "Preview %@"), name)`.

3. **Documentation**: Update docs in `docs/` (Mintlify-based) when adding/changing features:
    - New keyboard shortcuts → `docs/features/keyboard-shortcuts.mdx`
    - UI/feature changes → relevant `docs/features/*.mdx` page
    - Settings changes → `docs/customization/settings.mdx`
    - Database driver changes → `docs/databases/*.mdx`

4. **Tests**: Every change with testable behavior must include or update unit/function tests. UI and user-flow changes should add or update `TableProUITests` UI automation where the flow runs deterministically; if it can't, note why in the PR description. When tests fail, fix the source code, never adjust tests to match incorrect output. Tests define expected behavior.

5. **Lint after changes**: Run `swiftlint lint --strict` to verify compliance. `.swiftlint.yml` sets `included: [TablePro]`, so a bare run never sees `Plugins/`, `Packages/`, `LocalPackages/` or the test targets. Pass those paths explicitly when your change is outside the app target, or the run passes while your code is broken.

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

- **Never use `ForEach($bindable.array) { $item in }`** on `@Observable` arrays that can be cleared externally, index-based bindings crash with out-of-bounds when the array shrinks during SwiftUI evaluation. Use `ForEach(array) { item in` with a manual `Binding` via `binding(for: item)`.
- **Never use `string.count`** on large strings, O(n) in Swift. Use `(string as NSString).length` for O(1).
- **Never use `string.index(string.startIndex, offsetBy:)` in loops** on bridged NSStrings, O(n) per call. Use `(string as NSString).character(at:)` for O(1) random access.
- **Never call `ensureLayout(forCharacterRange:)`**: defeats `allowsNonContiguousLayout`. Let layout manager queries trigger lazy local layout.
- **SQL dumps can have single lines with millions of characters**: cap regex/highlight ranges at 10k chars.
- **Tab persistence**: a query longer than `TabQueryContent.maxPersistableQuerySize` (500,000 UTF-16 units) is blanked by `QueryTab.toPersistedTab()` to prevent a JSON freeze, and the full text moves to `TabQueryOverflowStore`. `RecentlyClosedTabStore` applies the same cap.

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

GitHub Actions (`.github/workflows/build.yml`) triggered by `v*` tags. The `release` job needs all four of `lint`, `test`, `build` (a matrix over arm64 and x86_64) and `registry-readiness`, so a red test suite or a registry missing a compatible plugin binary blocks the tag. It produces the DMG and ZIP plus Sparkle signatures, and release notes are auto-extracted from `CHANGELOG.md`.

**Repo hygiene** (`.github/workflows/repo-hygiene.yml`): runs `actionlint` over every workflow (which shells out to `shellcheck` for each inline `run:` block, the only way those get checked), `shellcheck --severity=warning` over every script, and the plugin manifest check. Ubuntu, under a minute, free on a public repo. The scripts hold at zero warning-level findings; the remaining informational ones are almost all `SC2012`.

**Plugin CI** (`.github/workflows/build-plugin.yml`): triggered by `plugin-*-v*` tags or `workflow_dispatch`. The dispatch input accepts comma-separated `tag:pluginKitVersion` pairs; if `:pluginKitVersion` is omitted, the workflow reads `currentPluginKitVersion` from `PluginManager.swift`. Registry update logic lives in `.github/scripts/update-registry.py` (atomic write, per-binary `pluginKitVersion`, prune-old policy). Use `scripts/release-all-plugins.sh <version>` for bulk re-release after an ABI bump.

**Plugin tag naming**: The slug in a tag must be a key in `.github/plugin-registry.json`, which maps it to the target and the release metadata. Notable non-obvious mappings: `CloudflareD1DriverPlugin` → `plugin-cloudflare-d1-v*`, `EtcdDriverPlugin` → `plugin-etcd-v*`. Check existing tags with `git tag -l "plugin-*"` before creating new ones.
