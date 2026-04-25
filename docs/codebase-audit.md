# TablePro Codebase Audit

**Date:** 2026-04-24
**Scope:** Full codebase analysis across 4 categories — code anti-patterns, UI/UX issues, anti-native macOS patterns, and Apple HIG violations.

---

## Table of Contents

1. [Critical Issues](#1-critical-issues)
2. [Code Anti-Patterns](#2-code-anti-patterns)
3. [UI/UX Anti-Patterns](#3-uiux-anti-patterns)
4. [Anti-Native macOS Patterns](#4-anti-native-macos-patterns)
5. [Apple HIG Violations](#5-apple-hig-violations)
6. [Summary Matrix](#6-summary-matrix)

---

## 1. Critical Issues

These require immediate attention — they cause crashes, violate mandatory project rules, or create significant user-facing problems.

### 1.1 `String(localized:)` with string interpolation (CLAUDE.md mandatory rule violation)
- **File:** `Views/Main/Extensions/MainContentCoordinator+Alerts.swift:60-63`
- **Issue:** `String(localized: "The following \(statements.count) queries...")` creates a dynamic key that never matches the strings catalog.
- **Fix:** Use `String(format: String(localized: "The following %d queries..."), statements.count)`

### 1.2 `string.count` on potentially large cell values (CLAUDE.md performance rule violation)
- **File:** `Views/Main/Extensions/MainContentView+Helpers.swift:113-114`
- **Issue:** `raw.count` is O(n) in Swift. Called on every inspector update (row selection change) — hot path.
- **Fix:** Use `(raw as NSString).length` for O(1).

### 1.3 `MainActor.assumeIsolated` in `deinit` — latent crash
- **File:** `Views/Main/MainContentCoordinator.swift:614`
- **Issue:** `deinit` runs on whichever thread releases the last reference. If a `Task` holds the last strong reference and releases off-main, `assumeIsolated` traps with a precondition failure.
- **Fix:** Replace with `Task { @MainActor [weak self] in self?.unregisterFromPersistence() }`.

### 1.4 `@unchecked Sendable` Bundle with off-main-thread access
- **File:** `Core/Plugins/PluginManager.swift:178-261`
- **Issue:** `LoadedBundle` is `@unchecked Sendable` but `principalClass` is accessed via ObjC runtime dynamic dispatch during `loadBundlesOffMain` — not guaranteed thread-safe during initial load.
- **Fix:** Resolve `principalClass` on main thread in `registerLoadedPlugins` using `NSClassFromString`.

### 1.5 ConnectionFormView fixed 480x520 — SSH tab overflows
- **File:** `Views/Connection/ConnectionFormView.swift:168`
- **Issue:** `.frame(width: 480, height: 520)` with no scroll fallback. SSH tab with jump hosts + TOTP can exceed 520pt, pushing fields off screen.
- **Fix:** Use `minHeight` or wrap in `ScrollView`.

### 1.6 Group delete has no confirmation dialog
- **File:** `ViewModels/WelcomeViewModel.swift:318`
- **Issue:** `deleteGroup` immediately executes with no confirmation. Silently unparents all contained connections without informing the user.
- **Fix:** Add confirmation alert explaining what happens to contained connections.

---

## 2. Code Anti-Patterns

### Architecture

| # | Issue | File | Severity |
|---|-------|------|----------|
| 2.1 | God object: `MainContentCoordinator` spans 10+ extension files, 30+ stored properties, single 190-line `executeQueryInternal` method near SwiftLint limit | `MainContentCoordinator.swift` (1440 lines) | Medium |
| 2.2 | `AnyView` type erasure in `treeRows` defeats SwiftUI diffing — entire connection list rebuilt on every update | `WelcomeWindowView.swift:293-317` | High |
| 2.3 | O(n) helpers (`connectionCount`, `depthOf`, `maxDescendantDepth`) called per-row inside `ForEach` in view body | `WelcomeWindowView.swift:396-399` | Medium |

### Concurrency

| # | Issue | File | Severity |
|---|-------|------|----------|
| 2.4 | Unstructured `Task {}` in `initializeAndRestoreTabs` with no cancellation handle — runs against torn-down coordinator if view disappears | `MainContentView+Setup.swift:24-29` | High |
| 2.5 | `loadPendingPlugins` blocks main thread with synchronous `bundle.load()` — can freeze UI 100-500ms on first use | `PluginManager.swift:323-344` | High |
| 2.6 | Strong `self` capture in 5-second delayed removal task | `SchemaProviderRegistry.swift:52-57` | Medium |

### Error Handling

| # | Issue | File | Severity |
|---|-------|------|----------|
| 2.7 | `try?` silently swallows `cancelQuery()` error — cancellation failure invisible, tab can get stuck in "executing" state | `MainContentCoordinator.swift:947` | Medium |

### Performance

| # | Issue | File | Severity |
|---|-------|------|----------|
| 2.8 | New `JSONDecoder()` allocated per connection during deserialization (50+ allocations at startup for large connection lists) | `ConnectionStorage.swift:673` | Medium |

---

## 3. UI/UX Anti-Patterns

### Interaction Problems

| # | Issue | File | Severity |
|---|-------|------|----------|
| 3.1 | Export "Don't show again" checkbox state lost when clicking "Open Folder" instead of "Close" | `ExportSuccessView.swift:43-55` | High |
| 3.2 | Connection failure re-opens welcome window with potential race condition — error sheet may fail to attach | `WelcomeViewModel.swift:589-599` | High |
| 3.3 | Export stop button has no confirmation — partial files can result from accidental clicks | `ExportProgressView.swift:62-66` | Medium |
| 3.4 | Linked-connection row requires double-click; single-click gives no visual feedback | `WelcomeWindowView.swift:369-374` | Medium |
| 3.5 | Export progress sheet doesn't handle Escape key despite `.interactiveDismissDisabled()` | `ExportDialog.swift:143-144` | Medium |

### Poor Feedback

| # | Issue | File | Severity |
|---|-------|------|----------|
| 3.6 | AI provider test result not cleared when endpoint/API key fields change — stale green tick | `AISettingsView.swift:406-418` | Medium |
| 3.7 | Connection test success state not invalidated on `additionalFieldValues` changes (plugin-specific fields) | `ConnectionFormView+Footer.swift:19-33` | Medium |
| 3.8 | SSH profile test failure shows NSAlert sheet (dismisses context) instead of inline error state | `SSHProfileEditorView.swift:428-481` | Medium |
| 3.9 | Export dialog shows empty tree with no explanation when database load returns 0 items | `ExportDialog.swift:228-247` | Medium |
| 3.10 | DDL results show "0 row(s) affected" with large green checkmark — misleading for CREATE/DROP | `ResultSuccessView.swift:22-24` | Medium |
| 3.11 | Empty history panel shows nothing — no empty state message | `HistoryDataProvider.swift:58` | Medium |

### Accessibility

| # | Issue | File | Severity |
|---|-------|------|----------|
| 3.12 | Hardcoded font sizes (`.system(size: N)`) in welcome, onboarding, and empty states — ignore Accessibility Large Text | `OnboardingContentView.swift`, `WelcomeWindowView.swift`, `MainEditorContentView.swift` | High |
| 3.13 | Onboarding page dots are tappable `Circle()` with no accessibility labels or button traits | `OnboardingContentView.swift:192-200` | Medium |
| 3.14 | Icon-only toolbar buttons have `.help()` but no `.accessibilityLabel` — VoiceOver can't read them | `WelcomeWindowView.swift:128-150` | Medium |

### Layout

| # | Issue | File | Severity |
|---|-------|------|----------|
| 3.15 | Settings window fixed 720x500 — clips on small displays or with large text | `SettingsView.swift:65` | Medium |
| 3.16 | Welcome window fixed 700x450 with no minimum size constraint | `WelcomeWindowView.swift:37` | Medium |
| 3.17 | SSH profile editor `minHeight: 500` overflows when jump host sections expand | `SSHProfileEditorView.swift:97` | Medium |
| 3.18 | Export dialog hardcoded panel widths — long table names truncate | `ExportDialog.swift:192-198` | Medium |

### Discoverability

| # | Issue | File | Severity |
|---|-------|------|----------|
| 3.19 | Onboarding hardcodes "MySQL, PostgreSQL & SQLite" — 11+ plugin databases undiscoverable at first run | `OnboardingContentView.swift:113-114` | Medium |
| 3.20 | XLSX format gate only appears after clicking Export, not when selecting the format | `ExportDialog.swift:271-275, 296-301` | Medium |
| 3.21 | Vim mode has no in-editor status indicator | `EditorSettingsView.swift:24` | Low |

### Inconsistency

| # | Issue | File | Severity |
|---|-------|------|----------|
| 3.22 | Group rename uses alert with TextField; all other editing uses sheets | `WelcomeWindowView.swift:100-106` | Low |
| 3.23 | Export format uses segmented picker; all other pickers use dropdown style | `ExportDialog.swift:267-280` | Medium |
| 3.24 | Plugins settings uses segmented picker for sub-tabs; other settings panes don't | `PluginsSettingsView.swift:13-19` | Low |
| 3.25 | Appearance settings uses custom `VStack + HSplitView`; all other settings panes use `Form.formStyle(.grouped)` | `AppearanceSettingsView.swift:52-82` | Low |

---

## 4. Anti-Native macOS Patterns

### Custom Components Replacing Native Ones

| # | Issue | Native Equivalent | File | Severity |
|---|-------|-------------------|------|----------|
| 4.1 | Custom About window (NSPanel with manual layout) | `NSApplication.orderFrontStandardAboutPanel(options:)` | `AboutWindowController.swift`, `AboutView.swift` | High |
| 4.2 | Three duplicate double-click NSViewRepresentables with different strategies | `TapGesture(count: 2)` (already used elsewhere in codebase) | `DoubleClickDetector.swift`, `WelcomeConnectionRow.swift`, `QuickSwitcherView.swift` | High |
| 4.3 | `NativeSearchField` wrapping `NSSearchField` | `.searchable(text:)` or SwiftUI `TextField` with search style | `Sidebar/NativeSearchField.swift` | Medium |
| 4.4 | Imperative `NSOpenPanel` for file picking | `.fileImporter(isPresented:allowedContentTypes:)` | `ConnectionSSHTunnelView.swift:337-367` | Low |
| 4.5 | `QuickSwitcherView` overrides native `List` selection highlighting with manual colors | `List(selection:)` with `.tag()` handles this natively | `QuickSwitcherView.swift:143-192` | Low |

### Non-Native Communication Patterns

| # | Issue | Native Equivalent | File | Severity |
|---|-------|-------------------|------|----------|
| 4.6 | `NotificationCenter` for `openDatabaseSwitcher` across views | Closure injection or `@Environment` action | `ConnectionStatusView.swift:63` | Medium |

### Non-Native System Integration

| # | Issue | Native Equivalent | File | Severity |
|---|-------|-------------------|------|----------|
| 4.7 | Dark mode detection via `DistributedNotificationCenter` + reading `AppleInterfaceStyle` UserDefaults | `NSApp.effectiveAppearance` observer or `@Environment(\.colorScheme)` | `ThemeEngine.swift:356-381` | Medium |
| 4.8 | File menu replaces `.newItem` entirely — removes standard Cmd+N | `CommandGroup(after: .newItem)` to supplement | `TableProApp.swift:171-176` | High |

### Justified Custom Implementations (Not Issues)

- **DataGridView** (`NSTableView`) — correct for high-performance database grid with complex editing
- **ShortcutRecorderView** — no native API exists for keyboard shortcut capture
- **StartupCommandsEditor** — `NSTextView` needed for disabling smart substitutions
- **WindowAccessor** — no SwiftUI API for `tabbingIdentifier` or NSToolbar installation

---

## 5. Apple HIG Violations

### High Severity

| # | Issue | HIG Section | File |
|---|-------|------------|------|
| 5.1 | `window.isRestorable = false` — window size/position not persisted across launches | Windows | `TabWindowController.swift:71` |
| 5.2 | Toolbar `autosavesConfiguration = false` — user customizations lost on relaunch | Toolbars | `MainWindowToolbar.swift:54` |
| 5.3 | File menu replaces `.newItem` (Cmd+N) with non-standard "Manage Connections" | Menus | `TableProApp.swift:171` |
| 5.4 | Settings uses inner `TabView` instead of letting macOS 14 render native sidebar style | Settings | `SettingsView.swift:18-63` |

### Medium Severity

| # | Issue | HIG Section | File |
|---|-------|------------|------|
| 5.5 | Welcome window and connection form use hardcoded pixel frames — don't adapt to accessibility text sizes | Windows / Accessibility | `WelcomeWindowView.swift:37`, `ConnectionFormView.swift:168` |
| 5.6 | Toolbar `displayMode = .iconOnly` overrides user's system preference | Toolbars | `MainWindowToolbar.swift:52` |
| 5.7 | `ConnectionFormView` uses segmented picker for full-panel tab navigation instead of `TabView` | Controls | `ConnectionFormView.swift:151-158` |
| 5.8 | `WelcomeConnectionRow` uses raw `mouseDown` NSView for double-click — bypasses VoiceOver activation routing | Accessibility | `WelcomeConnectionRow.swift:87-110` |
| 5.9 | Sidebar tab switching (Tables/Favorites) placed in toolbar instead of within sidebar | Sidebars | `MainWindowToolbar.swift:519-543` |
| 5.10 | No Edit > Find menu item (Cmd+F) | Menus | `TableProApp.swift` |
| 5.11 | `.focusable(false)` on toolbar items breaks Tab-key traversal (accessibility) | Accessibility | `MainWindowToolbar.swift:241` |
| 5.12 | `.design(.rounded)` fonts in welcome/onboarding — diverges from SF Pro used system-wide | Typography | `OnboardingContentView.swift:94`, `WelcomeLeftPanel.swift:23` |

### Low Severity

| # | Issue | HIG Section | File |
|---|-------|------------|------|
| 5.13 | No search-in-settings functionality | Settings | `SettingsView.swift` |
| 5.14 | Custom sidebar toggle button instead of standard `NSSplitViewItem` toggle | Toolbars | `MainWindowToolbar.swift:519-543` |
| 5.15 | Onboarding uses `DragGesture` for swipe navigation — iOS pattern on macOS | Input | `OnboardingContentView.swift:52-61` |
| 5.16 | Sidebar search field placeholder says "Filter" not "Search" | Search Fields | `SidebarContainerViewController.swift:38` |
| 5.17 | 24pt onboarding dot targets at minimum recommended size | Touch Targets | `OnboardingContentView.swift:196-201` |

---

## 6. Summary Matrix

### By Severity

| Severity | Count | Categories |
|----------|-------|------------|
| Critical | 6 | Crash risk, mandatory rule violations, data loss |
| High | 14 | Major UX problems, native violations, architectural issues |
| Medium | 30 | Noticeable deviations, feedback gaps, accessibility issues |
| Low | 14 | Minor conventions, cosmetic inconsistencies |

### Top 10 Priority Fixes

| Priority | Issue | Category | File |
|----------|-------|----------|------|
| 1 | `String(localized:)` with interpolation | Code | `MainContentCoordinator+Alerts.swift` |
| 2 | `string.count` on large cell values | Code | `MainContentView+Helpers.swift` |
| 3 | `assumeIsolated` in `deinit` — crash | Code | `MainContentCoordinator.swift` |
| 4 | Group delete with no confirmation | UX | `WelcomeViewModel.swift` |
| 5 | Connection form overflow (fixed frame) | UX/HIG | `ConnectionFormView.swift` |
| 6 | Window position not restored | HIG | `TabWindowController.swift` |
| 7 | Toolbar customization not saved | HIG | `MainWindowToolbar.swift` |
| 8 | `@unchecked Sendable` Bundle race | Code | `PluginManager.swift` |
| 9 | `AnyView` type erasure in connection list | Code | `WelcomeWindowView.swift` |
| 10 | Export "Don't show again" preference lost | UX | `ExportSuccessView.swift` |

### By Component

| Component | Critical | High | Medium | Low |
|-----------|----------|------|--------|-----|
| Connection/Welcome views | 1 | 4 | 8 | 3 |
| Main coordinator/editor | 2 | 2 | 3 | 0 |
| Plugin system | 1 | 1 | 0 | 0 |
| Export views | 0 | 1 | 4 | 0 |
| Settings | 0 | 1 | 2 | 2 |
| Toolbar/menus | 0 | 2 | 3 | 2 |
| Window management | 0 | 1 | 2 | 0 |
| Sidebar | 0 | 1 | 1 | 3 |
| Theme/appearance | 0 | 0 | 2 | 1 |
| About/feedback | 0 | 1 | 0 | 0 |
| Other | 1 | 0 | 5 | 3 |
