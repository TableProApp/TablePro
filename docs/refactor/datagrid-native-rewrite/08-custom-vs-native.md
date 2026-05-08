# 08 - Custom code that should be native

Sweep of the TablePro codebase for custom abstractions where AppKit, Foundation, SwiftUI, Combine, or system frameworks already provide the primitive. Each row names file:line, what is reimplemented, and the exact Apple API replacement (with SDK header reference). Some entries note that the native API is the *wrong* fit and the custom code stays.

Severity legend: **HIGH** = clear native replacement, drop-in; **MED** = native fit with caveats; **LOW** = custom code is justified, document the reasoning; **N/A** = native already in use, audit row stale.

---

## 1. Pre-existing audit findings (N1–N5) - re-evaluated

### N1. `ConnectionDataCache` instance dictionary

- **File:** `TablePro/ViewModels/ConnectionDataCache.swift:13`
- **What it reimplements:** Per-connection multiton: `private static var instances: [UUID: ConnectionDataCache] = [:]`. The audit calls this a "manual cache dict" and suggests `NSCache<K,V>`.
- **Audit recommendation is wrong.** This is not a value cache - it stores a long-lived `@Observable` view model that SwiftUI views subscribe to via `@Bindable`. `NSCache` (`Foundation/NSCache.h`) evicts entries under memory pressure or when its `countLimit`/`totalCostLimit` is hit, which would silently invalidate active SwiftUI bindings and detach Combine subscriptions in `cancellables`. That is a correctness bug, not a perf win.
- **Correct native API:** `NSMapTable<NSUUID, ConnectionDataCache>` constructed with `.strongMemory` keys and `.weakMemory` values (`Foundation/NSMapTable.h`). Entries auto-clear when no SwiftUI view holds the cache, no eviction under pressure. Alternative: keep the dictionary but add removal in `deinit` (not on a class with `deinit` cancelling its own task - it would be the *last* user of that ID).
- **Severity:** LOW. Current dict leaks one cache per ever-opened connection until app quit. Memory cost is small (folder/favorite arrays). `NSMapTable` is the right primitive but not urgent.

### N2. `CopilotIdleStopController` Task.sleep debounce

- **File:** `TablePro/Core/AI/Copilot/CopilotIdleStopController.swift:48–58`
- **What it reimplements:** Manual `Task { try await Task.sleep(for: timeout); … }` that re-checks predicates and fires `onStopRequest`. Schedule cancels the prior task before starting a new one.
- **Native API:** Combine `Publishers.Debounce` (`Combine/Combine.h`, `Combine/Publishers+Debounce.swift`) on a `PassthroughSubject<Void, Never>`. The pattern: send a tick on `schedule()`, debounce by `timeout`, sink fires the predicate-gated stop. Or `AsyncSequence.debounce(for:)` from `swift-async-algorithms`. Both handle "newest input wins" with a single subscription, no manual task lifecycle.
- **Caveat:** Combine's debounce schedules on a `Scheduler` (e.g. `DispatchQueue.main`), so the predicate re-checks must still be `@MainActor`-aware. The current code is already `@MainActor` so the migration is straightforward.
- **Severity:** LOW. Custom is ~25 lines, Combine equivalent ~10 lines. Behaviour identical. Worth doing for consistency with `InlineSuggestionManager` and `SQLCompletionAdapter`, both of which already use Combine.

### N3. `DateFormattingService` cached `DateFormatter`

- **File:** `TablePro/Core/Services/Formatting/DateFormattingService.swift:18–123`
- **What it reimplements:** Singleton wrapping a primary `DateFormatter` (output) plus six `DateFormatter` parsers (input formats) plus an `NSCache<NSString, NSString>` for parsed-format memoization.
- **Native API for new code:** `Date.FormatStyle` (Foundation, macOS 12+, declared in `<Foundation/FormatStyle.h>` and `Foundation/Date+FormatStyle.swift` in the open-source Foundation layout). Build once with `Date.FormatStyle(date:.numeric, time:.standard).locale(.current).timeZone(.current)`, call `style.format(date)`. Parses via `try Date("…", strategy: .iso8601)` or `Date.ParseStrategy`. The format style is a value type, copy-on-write, eliminates the locked formatter pattern entirely.
- **Caveat:** TablePro supports six legacy database formats (`yyyy-MM-dd HH:mm:ss`, etc.). `Date.ParseStrategy` covers ISO 8601 cleanly via `.iso8601`; the MySQL-style naive timestamps need a custom `Date.ParseStrategy` or fall back to `Date.VerbatimFormatStyle` for parsing. Migration is per-format, not all-or-nothing.
- **Note on the existing `NSCache`:** the cache is correct (`Foundation/NSCache.h`), bounded at 10k entries, cleared on format change. Keep it. Migration replaces the `DateFormatter` instances, not the cache.
- **Severity:** LOW. Performance is fine (cached). Migration is a code-style win, not a perf win.

### N4. `FuzzyMatcher` custom scorer

- **File:** `TablePro/Core/Utilities/UI/FuzzyMatcher.swift:15–92`
- **What it reimplements:** Subsequence fuzzy match with weighted bonuses (consecutive run, word boundary, camelCase break, position, length ratio). Caller: `QuickSwitcherViewModel.swift:161`.
- **Native API for *simple* matching:** `String.localizedStandardCompare(_:)` (`Foundation/NSString.h` declares `localizedStandardCompare:` since 10.6) is Finder-style: case-insensitive, diacritic-insensitive, locale-aware, with natural numeric ordering. Or `String.range(of:options: [.caseInsensitive, .diacriticInsensitive])` for substring containment.
- **Custom is justified.** A quick switcher needs subsequence matching ("`rdb`" → "`r`ed`b`lack`d`atabase") and ranking by run length and word-boundary hits, which `localizedStandardCompare` does not do. `NSPredicate` `MATCHES` regex would not produce a numeric score for ranking. Apple's `Spotlight` ranking uses `MDItem`s and is not exposed for in-app strings.
- **Severity:** LOW (no change). Document that fuzzy ranking is an intentional custom path. Do not replace.

### N5. `ResponderChainActions` documentation protocol

- **File:** `TablePro/Core/KeyboardHandling/ResponderChainActions.swift`
- **What it reimplements:** Nothing. The file is an `@objc` protocol whose only purpose is to centralize selector names for `NSApp.sendAction(_:to:from:)` so every responder-chain action used in the app has a single declaration site. The protocol carries `@objc optional func` declarations; no class implements it.
- **Native idiom check.** This is the textbook AppKit pattern: define `@objc` selectors, send via `NSApp.sendAction(#selector(Foo.bar(_:)), to: nil, from: nil)`, validate via `NSUserInterfaceValidations`. Apple uses this exact shape in `NSResponder.h` (`<AppKit/NSResponder.h>`) for `copy:`, `paste:`, `cut:`, `selectAll:`, `cancelOperation:`, `delete:`, etc. Verified no shortcut interception - `TableProApp.swift` `.commands { … }` calls `NSApp.sendAction` directly without bypassing validation.
- **Severity:** N/A. Already correct. Keep the protocol-as-doc pattern.

---

## 2. Additional findings discovered during sweep

### A1. `ColumnVisibilityPopover` SwiftUI list

- **File:** `TablePro/Views/Results/ColumnVisibilityPopover.swift:27–103`
- **What it reimplements:** A 260pt-wide popover with a search field plus a `List` of `Toggle(.checkbox)` rows, presented from a toolbar/header button. Bound through closure callbacks.
- **Native API:** `NSTableView.headerView?.menu` (`AppKit/NSTableHeaderView.h`, `AppKit/NSView.h` for `menu`). Right-clicking a column header shows the menu; toggling a `NSMenuItem` with `.state = .on/.off` hides/shows the column via `NSTableColumn.isHidden` (since 10.5). Apple's Mail and Finder use this exact pattern. For "Show All / Hide All", add separator items above the column list.
- **Caveat:** The current popover supports a search field for tables with many columns (>5 trigger). `NSMenu` does not support inline search; for >40-column tables the menu becomes unwieldy. A practical pattern is: short-list (<40) → `NSMenu`; long-list → keep the popover. Or use `NSMenu` always plus an NSWindow-backed "Choose Columns…" sheet for power users.
- **Severity:** MED. Drop-in for the common case; keep popover for wide tables. Either way, expose the menu on the table header so right-click works as users expect.

### A2. `ResultTabBar` SwiftUI horizontal tab strip

- **File:** `TablePro/Views/Results/ResultTabBar.swift:11–104`
- **What it reimplements:** A horizontal `ScrollView(.horizontal)` of `Button`-backed tabs with active tint, hover background, pin/close affordances, and contextual menu (Pin / Close / Close Others). Used to switch between multiple result sets returned by a single query.
- **Native API options:**
  - `NSTabViewController` (`<AppKit/NSTabViewController.h>`, since 10.10) with `tabStyle = .toolbar` or `.segmentedControlOnTop`. Manages segmented selection, view swapping, and animation. Does *not* support pin or in-tab close affordances.
  - `NSSegmentedControl` (`<AppKit/NSSegmentedControl.h>`) with `.segmentStyle = .texturedRounded`, `.trackingMode = .selectOne`. Same - no per-segment close.
  - **Custom is justified for the close/pin affordances.** `NSTabViewController` and `NSSegmentedControl` do not expose per-tab "x" buttons or pin glyphs. Sequel Ace, Xcode, and Safari all build custom tab bars for the same reason.
- **Severity:** LOW. Document the choice. The current SwiftUI implementation is fine; its only weakness vs `NSTabViewController` is no built-in keyboard navigation (Ctrl+Tab to cycle). Add `.keyboardShortcut` to the activate button or an `onKeyPress` handler.

### A3. `EditorTabBar` referenced in CLAUDE.md but does not exist

- CLAUDE.md says "`EditorTabBar` - pure SwiftUI tab bar". Verified via `grep -rn "struct EditorTabBar"` in `TablePro/Views/Editor/` - no such symbol. Editor tabs are now native NSWindow tabs (`NSWindow.tabbingMode`, `<AppKit/NSWindow.h>`) per `WindowManager.swift` and `MainContentView+Setup.swift`. Already correct.
- **Severity:** N/A. Update CLAUDE.md to drop the stale reference.

### A4. `CellOverlayEditor` borderless `NSPanel`

- **File:** `TablePro/Views/Results/CellOverlayEditor.swift:97–123, 215–224`
- **What it reimplements:** A floating, non-activating, borderless `NSPanel` containing an `NSScrollView` + `NSTextView`, anchored to a cell rect, used for multi-line cell editing. Custom panel subclass overrides `canBecomeKey` and forwards `resignKey` to a closure. `NSTextView` subclass intercepts Cmd+S `performKeyEquivalent`.
- **Native API check:** This *is* the correct primitive. `NSPanel` (`<AppKit/NSPanel.h>`) with `.nonactivatingPanel` style is exactly what Pages/Numbers/Xcode use for floating editors. The audit's suggestion of "standard NSText field editor + custom NSTextView for multi-line via `windowWillReturnFieldEditor:to:`" applies to *single*-line cell editing; multi-line needs the scrollable editor that `NSCell.fieldEditor` cannot provide (no vertical scroll, no multi-line layout in a `NSTextField` cell).
- **Note:** Sequel Ace uses the same pattern (`AppKitDataGrid.swift` from Gridex floats an editor on the table view, audit §3.1).
- **Severity:** N/A. Custom is correct. Keep.

### A5. `SortableHeaderView` custom click-cycle and indicator

- **File:** `TablePro/Views/Results/SortableHeaderView.swift:84–287`
- **What it reimplements:** Subclass of `NSTableHeaderView` that intercepts `mouseDown:`, runs `HeaderSortCycle.nextTransition` (asc → desc → clear, plus shift+click multi-sort), and writes sort indicator state into a custom `SortableHeaderCell`. Also handles cursor rects for resize zones.
- **Native API check:** The audit suggests `NSTableColumn.sortDescriptorPrototype` (`<AppKit/NSTableColumn.h>`, since 10.3). `sortDescriptorPrototype` + `tableView.sortDescriptors` + `NSTableViewDelegate.tableView(_:sortDescriptorsDidChange:)` is the documented way to drive single-column sort indicators with the standard chevron glyph; AppKit handles asc/desc toggle and indicator drawing via `NSTableView.indicatorImage(in:)`.
- **Custom is justified.** Three reasons:
  1. **Multi-column sort with priority numbers.** AppKit shows only one sort chevron at a time; multi-column needs custom drawing of "1↑ 2↓" badges. `NSSortDescriptor` array supports multi-key, but the indicator UI does not.
  2. **Click-cycle with clear-on-third-click.** AppKit's default cycle is asc → desc → asc. TablePro's three-state cycle (asc → desc → cleared) requires intercepting `mouseDown:`.
  3. **Server-side sort dispatch.** Sort needs to issue a SQL `ORDER BY` round-trip to the database, not sort an `NSArrayController`. Custom dispatch is unavoidable.
- **Severity:** N/A. Document why. Possible micro-cleanup: when sort is single-column, fall back to `NSTableColumn.sortDescriptorPrototype` for the indicator drawing only (still custom for dispatch). Probably not worth the divergence.

### A6. `FilterPanelView` custom WHERE-clause builder

- **File:** `TablePro/Views/Filter/FilterPanelView.swift:8–248`
- **What it reimplements:** SwiftUI form rendering rows of `(column, operator, value, [secondValue])`, AND/OR mode picker, preset save/load, raw-SQL escape hatch.
- **Native API:** `NSPredicateEditor` (`<AppKit/NSPredicateEditor.h>`, since 10.5) with `NSPredicateEditorRowTemplate`s.
- **Native is the wrong fit.** Three blockers:
  1. `NSPredicateEditor` produces an `NSPredicate`. TablePro emits *SQL strings* via `quoteIdentifier`-aware driver methods (different per dialect: MySQL backticks vs Postgres double-quotes vs MSSQL brackets). Translating `NSPredicate` to dialect-specific SQL requires a full predicate visitor; there is no Apple API for that.
  2. The operator vocabulary differs. TablePro uses `CONTAINS` (LIKE-wrapped), `IN`, `BETWEEN`, `REGEX`, `IS NULL` distinct from `IS EMPTY`. `NSPredicate` has CONTAINS but not the LIKE-with-leading/trailing-wildcard distinction or BETWEEN with two scalar inputs (you must compose `>= AND <=`).
  3. Raw-SQL escape (`__RAW__` column) cannot be expressed in `NSPredicateEditor`'s row templates at all.
- **Severity:** N/A. Custom is correct. Keep.

### A7. `QuickSwitcherSheet` SwiftUI `.sheet`

- **File:** `TablePro/Views/QuickSwitcher/QuickSwitcherView.swift:14–249`
- **What it reimplements:** Search-then-list overlay shown via SwiftUI `.sheet`. Spotlight-style.
- **Native API:** Borderless non-activating `NSPanel` (`<AppKit/NSPanel.h>`) with `.styleMask = [.borderless, .nonactivatingPanel, .titled, .fullSizeContentView]`, `.level = .floating`, `.collectionBehavior = [.canJoinAllSpaces, .moveToActiveSpace]`. This is what Spotlight, Raycast, and Alfred use; the panel does not steal focus from the previous app, dismisses on `resignKey`, and hosts a SwiftUI view via `NSHostingController`.
- **Caveat:** SwiftUI `.sheet` attaches to the parent window and cannot float over it the way Spotlight does. The current implementation works but feels less "command-palette-like" than a floating panel. The team has already accepted that native sheets are the project standard ([Active Sheet pattern, see comment at file:13]). Migration is optional, not required.
- **Severity:** MED. If the goal is Spotlight-like presentation (always-on-top, overlay style), migrate to NSPanel via `NSHostingController`. Otherwise leave as `.sheet`.

### A8. `EnumPopoverContentView` searchable enum picker

- **File:** `TablePro/Views/Results/EnumPopoverContentView.swift:12–99`
- **What it reimplements:** SwiftUI `List` with a `NativeSearchField` header and a NULL-marker first row. Used for `ENUM`-type cells (MySQL ENUM, Postgres CHECK enums).
- **Native API:** `NSPopUpButton` (`<AppKit/NSPopUpButton.h>`) for static lists, or `NSComboBox` (`<AppKit/NSComboBox.h>`) for searchable+typeable lists. `NSPopUpButton` is non-searchable and becomes unusable past ~30 items. `NSComboBox` is searchable but combines text-entry with selection, which is wrong for ENUM (must be one of the predefined values, not free text).
- **Custom is justified.** The "search-then-pick" UX with a fixed value list is what `NSPopUpButton` *should* support but doesn't. The closest native primitive is the popover-table pattern Xcode uses for "Run Destinations" - which is itself custom (popover hosting an `NSTableView`). Either way the win from going pure-AppKit here is small.
- **Severity:** LOW. Keep custom. If a future macOS version adds a searchable popup button (rumored for SwiftUI's `Picker(searchable:)`), revisit.

### A9. `ForeignKeyPopoverContentView` searchable FK picker

- **File:** `TablePro/Views/Results/ForeignKeyPopoverContentView.swift:12–192`
- **What it reimplements:** SwiftUI `List` (with async DB fetch of up to 1000 referenced rows + display column) inside an `NSPopover`.
- **Native API:** Same conclusion as A8 - `NSComboBox` allows free text entry which corrupts FK values; `NSPopUpButton` does not search. Apple's `NSPopover` (`<AppKit/NSPopover.h>`) is already what hosts this view. The custom part is the `List` body, which is appropriate.
- **Caveat:** The async fetch runs on `.task` and does not cancel if the popover dismisses mid-flight. Verify cancellation is wired (out of scope for this task).
- **Severity:** LOW. Keep. Same reasoning as A8.

### A10. `UnifiedRightPanelView` inspector picker + content switch

- **File:** `TablePro/Views/RightSidebar/UnifiedRightPanelView.swift:8–157`
- **What it reimplements:** A SwiftUI tab picker + history menu + new-conversation button, hosted *inside* an already-native `NSSplitViewItem(inspectorWithViewController:)` (see `MainSplitViewController.swift:144`). Switches between Details / AI Chat panes via internal state.
- **Native API:** The container is already correct - `NSSplitViewItem.behavior == .inspector` is in use. The audit's suggestion of `NSSplitViewItem.behavior = .inspector` or SwiftUI `.inspector` (macOS 14+) refers to the container, which TablePro already does natively.
- **The custom part** is the inspector's *internal* tab switcher. The natural alternative is a per-tab `NSToolbarItem` with `NSSegmentedControl` placed in the window toolbar (Mail's "Reply / Reply All / Forward" toolbar split). This is the convention for inspector-internal navigation in Apple apps. Migrating means moving the tab picker out of the inspector content and into the window toolbar - coupled with toolbar redesign, larger scope.
- **Severity:** N/A for the container, MED for the in-panel picker. Defer until toolbar redesign.

### A11. `RedisKeyTreeView` SwiftUI `DisclosureGroup` tree

- **File:** `TablePro/Views/Sidebar/RedisKeyTreeView.swift:42–66`
- **What it reimplements:** Recursive SwiftUI `DisclosureGroup` tree of namespaces and Redis keys. Children are loaded eagerly (passed in via `nodes`), expansion state lives in `expandedPrefixes: Set<String>`.
- **Native API:** `NSOutlineView` (`<AppKit/NSOutlineView.h>`) with `NSOutlineViewDataSource` and lazy `outlineView(_:numberOfChildrenOfItem:)` / `outlineView(_:child:ofItem:)`. View-based outline view (since 10.7) has the same cell-reuse story as `NSTableView`. Lazy expansion only fires the data-source children query when a row is expanded.
- **Migration is justified at scale.** The current code accepts up to 50,000 keys (file:34 message). At that scale `DisclosureGroup` builds the entire tree synchronously on every `body` invocation; `NSOutlineView` queries lazily and can scroll through 100k items at 60fps with cell reuse. This is the same root cause as the data grid's scroll lag - SwiftUI `List` / `DisclosureGroup` is fine for ~100 rows, painful past ~1000.
- **Severity:** HIGH for large Redis databases, LOW for typical use. Wrap in `NSViewRepresentable` of `NSOutlineView` if Redis users hit lag at scale. Separate decision from the main data grid rewrite.

### A12. `PopoverPresenter` triple-nest helper

- **File:** `TablePro/Views/Components/PopoverPresenter.swift:11–34`
- **What it reimplements:** Three-line helper that builds an `NSPopover`, sets an `NSHostingController` as `contentViewController`, and presents it relative to a view rect. Returns the popover for caller-managed dismissal.
- **Native API:** This *is* the native API. The "triple nest" the brief refers to is `NSPopover { contentViewController = NSHostingController(rootView: …) }` - three lines, not a custom abstraction. The helper deduplicates those three lines plus a `[weak popover]` dismiss closure.
- **Severity:** N/A. The helper is pure ergonomics over `NSPopover` (`<AppKit/NSPopover.h>`). Keep.

---

## 3. Surfaced beyond the brief - additional custom abstractions

### B1. Multiton-style `static var instances` caches across ViewModels

- **Pattern:** `static var instances: [UUID: T] = [:]` plus a `shared(for:)` lookup.
- **Where:** `ConnectionDataCache.swift:13` (covered above). Grep `static var instances:` shows this is the only instance.
- **Native API:** `NSMapTable<NSUUID, T>` with weak values, as in N1.

### B2. `DispatchQueue.main.asyncAfter` used as one-shot timer

- **Files (search hit list):**
  - `TablePro/Views/Terminal/TerminalTabContentView.swift`
  - `TablePro/Views/Results/JSONSyntaxTextView.swift`
  - `TablePro/Views/Results/HexEditorContentView.swift`
  - `TablePro/Views/Results/ResultsJsonView.swift`
  - `TablePro/Core/SSH/SSHMatchExecutor.swift`
- **Native API:** For one-shot delays in `@MainActor` code, `Task { try await Task.sleep(for: .milliseconds(n)); … }` is more cancelable than `asyncAfter`. For repeating debounce, `Combine.debounce` (see N2). For run-loop-bound timers, `Timer.scheduledTimer(withTimeInterval:repeats:block:)` (`<Foundation/NSTimer.h>`).
- **Severity:** LOW each. Per-file evaluation needed; some `asyncAfter` calls are genuinely fire-and-forget (e.g. delaying first-responder focus by a runloop tick), where AppKit's `RunLoop.main.perform { … }` or `NSAnimationContext.runAnimationGroup` is the right primitive.

### B3. Manual `NSCache` is sparse - only one instance

- Grep shows exactly one `NSCache` in the app codebase: `DateFormattingService.swift:28`. Any future work that needs a bounded LRU should use `NSCache<NSString, T>` (`<Foundation/NSCache.h>`) rather than rolling a Swift dict + size check.

### B4. `NativeSearchField` already wraps `NSSearchField`

- **File:** `TablePro/Views/Sidebar/NativeSearchField.swift`
- **Status:** Already native (`NSSearchField` from `<AppKit/NSSearchField.h>` via `NSViewRepresentable`). No action.

### B5. No custom progress spinners or path bars detected

- Grep for `Circle().stroke / trim(from:to:)` patterns produced only disclosure-rotation effects, not custom spinners. `ProgressView()` is used app-wide (SwiftUI `ProgressView` resolves to `NSProgressIndicator` on macOS, `<AppKit/NSProgressIndicator.h>`).
- No `NSPathControl` reimplementations found.
- No custom tooltip implementations found - `NSView.toolTip` (`<AppKit/NSView.h>`) and SwiftUI `.help(_:)` are used throughout.

### B6. `CopilotIdleStopController` is not the only Task.sleep debounce

Files with `Task.sleep` that might be debounce-shaped (sample, not exhaustive - full audit in task #4):

- `TablePro/Core/Services/Licensing/LicenseManager.swift`
- `TablePro/Core/AI/InlineSuggestion/InlineSuggestionManager.swift`
- `TablePro/Core/AI/Copilot/CopilotAuthManager.swift`
- `TablePro/Core/AI/Copilot/CopilotService.swift`
- `TablePro/Core/Services/Infrastructure/SessionStateFactory.swift`
- `TablePro/Core/Services/Infrastructure/PreConnectHookRunner.swift`
- `TablePro/Core/Sync/SyncCoordinator.swift`
- `TablePro/Core/Database/ConnectionHealthMonitor.swift`

Each needs case-by-case classification (debounce vs. retry-with-backoff vs. health-check timer). Combine `.debounce` / `.throttle` only fits debounce, not health checks (use `Timer.publish(every:on:in:).autoconnect()` from `<Foundation/NSTimer.h>` via Combine bridge).

---

## 4. Summary table

| ID | File:Line | Reimplements | Native API | Header | Severity | Action |
|----|-----------|--------------|-----------|--------|----------|--------|
| N1 | `ConnectionDataCache.swift:13` | Strong-ref multiton dict | `NSMapTable` weak values (NOT `NSCache`) | `Foundation/NSMapTable.h` | LOW | Migrate when convenient |
| N2 | `CopilotIdleStopController.swift:48` | Task.sleep debounce | `Combine.debounce` | `Combine/Combine.h` | LOW | Migrate for consistency |
| N3 | `DateFormattingService.swift:18` | `DateFormatter` parsers | `Date.FormatStyle` / `Date.ParseStrategy` | `Foundation/FormatStyle.h` | LOW | Migrate new code only |
| N4 | `FuzzyMatcher.swift:15` | Subsequence scorer | `localizedStandardCompare` (insufficient) | `Foundation/NSString.h` | LOW | Keep custom |
| N5 | `ResponderChainActions.swift` | Selector documentation | `NSResponder` selectors (already used) | `AppKit/NSResponder.h` | N/A | Keep |
| A1 | `ColumnVisibilityPopover.swift` | Popover toggles list | `NSTableHeaderView.menu` + `NSTableColumn.isHidden` | `AppKit/NSTableHeaderView.h` | MED | Header right-click menu, keep popover for wide tables |
| A2 | `ResultTabBar.swift` | Closeable/pinnable tab strip | `NSTabViewController` (no per-tab close) | `AppKit/NSTabViewController.h` | LOW | Keep custom |
| A3 | `EditorTabBar` (gone) | - | `NSWindow.tabbingMode` (already used) | `AppKit/NSWindow.h` | N/A | Update CLAUDE.md |
| A4 | `CellOverlayEditor.swift` | Floating multi-line editor panel | `NSPanel.nonactivatingPanel` (already used) | `AppKit/NSPanel.h` | N/A | Keep |
| A5 | `SortableHeaderView.swift` | Multi-column sort header | `NSTableColumn.sortDescriptorPrototype` (single-column only) | `AppKit/NSTableColumn.h` | N/A | Keep custom (multi-sort) |
| A6 | `FilterPanelView.swift` | SQL WHERE builder | `NSPredicateEditor` (wrong fit, NSPredicate not SQL) | `AppKit/NSPredicateEditor.h` | N/A | Keep custom |
| A7 | `QuickSwitcherView.swift` | Search-and-pick sheet | Borderless `NSPanel` (Spotlight-style) | `AppKit/NSPanel.h` | MED | Optional migration for floating UX |
| A8 | `EnumPopoverContentView.swift` | Searchable enum picker | `NSPopUpButton` (no search) / `NSComboBox` (allows free text) | `AppKit/NSPopUpButton.h` | LOW | Keep |
| A9 | `ForeignKeyPopoverContentView.swift` | Searchable FK picker | `NSPopover` + `NSTableView` (already done) | `AppKit/NSPopover.h` | LOW | Keep, verify task cancellation |
| A10 | `UnifiedRightPanelView.swift` | Inspector internal tab picker | Container is `NSSplitViewItem.inspector` (already), picker should move to window `NSToolbarItem` | `AppKit/NSSplitViewItem.h` | MED | Defer to toolbar redesign |
| A11 | `RedisKeyTreeView.swift` | Recursive `DisclosureGroup` tree | `NSOutlineView` | `AppKit/NSOutlineView.h` | HIGH | Migrate for >5k-key databases |
| A12 | `PopoverPresenter.swift` | NSPopover construction helper | `NSPopover` (this *is* it) | `AppKit/NSPopover.h` | N/A | Keep |
| B1 | (above) | Multiton dict pattern | `NSMapTable` | `Foundation/NSMapTable.h` | LOW | One instance only |
| B2 | 5 files | `asyncAfter` as timer | `Task.sleep` / `Timer.scheduledTimer` / `Combine.debounce` | `Foundation/NSTimer.h` | LOW | Per-file review |

---

## 5. Recommended priority order

1. **A11 (Redis outline view).** Only HIGH-severity item. Same root cause as the data grid scroll-lag thesis - SwiftUI list-of-N collapses past ~1k rows. Wrap `NSOutlineView` in `NSViewRepresentable`.
2. **A1 (column visibility menu).** MED, drop-in for the common case. Restore the right-click-on-header convention users expect from Finder/Mail.
3. **N2 (Combine debounce).** Code-style win, removes ~25 lines, brings Copilot in line with `InlineSuggestionManager` / `SQLCompletionAdapter`.
4. **N1 (NSMapTable).** Quiet correctness fix. No user-visible change today.
5. **N3 (Date.FormatStyle).** Tag as "for new code"; do not rewrite existing usages.
6. **A7, A10.** Defer to UX-led work (Spotlight-style command palette; toolbar redesign).
7. **B2.** Audit each `asyncAfter` site individually; classify before changing.

Everything else is justified custom code. Document the reasoning in the relevant header comment so the next sweep does not re-flag them.
