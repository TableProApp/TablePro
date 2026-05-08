# 06 - HIG and Design-System Audit

**Reviewer**: hig-specialist
**Scope**: Per-surface delta of TablePro UI vs Apple HIG and AppKit. Each finding names the specific native primitive and the HIG page that authorises the swap. Code locations are line-accurate against `main` at audit time.

References used throughout:

- HIG root: https://developer.apple.com/design/human-interface-guidelines/macos
- Tab views: https://developer.apple.com/design/human-interface-guidelines/tab-views
- Popovers: https://developer.apple.com/design/human-interface-guidelines/popovers
- Sheets: https://developer.apple.com/design/human-interface-guidelines/sheets
- Inspectors: https://developer.apple.com/design/human-interface-guidelines/inspectors
- Color: https://developer.apple.com/design/human-interface-guidelines/color
- Accessibility: https://developer.apple.com/design/human-interface-guidelines/accessibility
- Menus: https://developer.apple.com/design/human-interface-guidelines/menus
- Toolbars: https://developer.apple.com/design/human-interface-guidelines/toolbars
- Window anatomy: https://developer.apple.com/design/human-interface-guidelines/windows

Per CLAUDE.md and the user's "full Apple-correct refactor" preference, this audit recommends complete replacements grounded in documented APIs. No phased patches.

---

## Severity legend

- **CRIT**: ships a non-Apple-feeling experience users notice (focus theft, look-and-feel, missing system gestures). Must fix in the rewrite.
- **HIGH**: visible HIG departure or accessibility hole. Should fix before next release.
- **MED**: subtle correctness gap (semantic colors, restoration, services). Fix during rewrite.
- **LOW**: polish.

---

## Surface-by-surface findings

### H1 [CRIT] Custom `ResultTabBar` reimplements native tab semantics

- **Location**: `TablePro/Views/Results/ResultTabBar.swift:11-104`. Pure-SwiftUI HStack of buttons with hover state, manual close X, manual context menu (Pin / Close / Close Others).
- **HIG violation**: Tab views, https://developer.apple.com/design/human-interface-guidelines/tab-views. Tabs that switch among co-equal panes within the same window are exactly what `NSTabView` / `NSTabViewController` exists for. The current bar omits drag-reorder, drop, keyboard navigation (`NSTabViewController` gives `tabView(_:shouldSelect:)` + arrow-key cycling free), and standard accessibility role `AXTabGroup`.
- **Apple-correct primitive**: `NSTabViewController` configured with `tabStyle = .unspecified` (you draw the bar) or `.toolbar` (system draws it). Use `transitionOptions = []` for instant switching to match the current UX. Reference: https://developer.apple.com/documentation/appkit/nstabviewcontroller.
- **Why not window tabs here**: result sets belong to one query and one tab; they are not co-equal documents. Window tabs would imply users can drag a result set into a separate window, which makes no semantic sense for "results 1..N of one query".
- **Specifics**:
  - Pin / unpin / close-others go on the same `NSMenu` AppKit builds for the tab control, with `NSMenuItem.keyEquivalent` for Cmd+W, Cmd+Option+W.
  - `setAccessibilityRole(.tabGroup)` is implicit on `NSTabView`; the SwiftUI wrapper has zero a11y role, so VoiceOver currently announces "button" for each tab.
  - Drag-reorder is satisfied via `NSTabView.tabViewItem(at:)` plus a `pasteboardWriter` strategy as already used in `DataGridView+RowActions.swift:178`.

### H2 [CRIT] Custom `EditorTabBar` does not exist - top-level tabs use NSWindow tabs but app-level tab bar logic is reimplemented across SwiftUI

- **Location**: window-level tabs are correctly using `NSWindow.tabbingMode = .preferred` at `TablePro/Core/Services/Infrastructure/TabWindowController.swift:60-64` and `MainContentView+Setup.swift:223-225`. There is no `EditorTabBar.swift` file (the audit reference at `02-overview` was speculative). However, the **payload-routing logic** that decides whether to replace the current tab vs open a new window-tab is hand-rolled in `MainContentCoordinator+Tabs` and the "active work" guard is bespoke (CLAUDE.md invariant "Tab replacement guard").
- **HIG violation**: none for the tab bar itself (window tabs are the recommended pattern per Window anatomy → Tab bar). The departure is in the **per-tab content swap**: a single window already hosts multiple `QueryTab`s in `tabManager.tabs`, and these are swapped via SwiftUI re-render against a `selectedTabId`. That is `NSTabViewController` semantics implemented in SwiftUI.
- **Apple-correct primitive**: collapse the in-window `QueryTab` swap into native window tabs only. One `NSWindow` per `QueryTab`; share state through `MainContentCoordinator` (already keyed by `windowId`). The `tabManager.tabs` array becomes redundant because each window IS a tab.
- **User-memory caveat (`Native NSWindow tab perf cost accepted`)**: the user has explicitly accepted the Cmd+Number rapid-burst lag inherent to per-window tabs and rejected a custom-tab-bar refactor as not worth it. Honour that - keep `tabbingMode = .preferred`, do **not** propose a custom AppKit tab bar above an `NSTabView`. The recommendation here is to delete the SwiftUI-side `tabManager.tabs` parallel ledger and let `NSWindow` be the single source of truth for tab identity, which removes the "in two places must stay in sync" pain documented in CLAUDE.md (`updateWindowTitleAndFileState()` vs `ContentView.init` title chain).

### H3 [CRIT] QuickSwitcher uses a SwiftUI sheet, takes app focus, blocks all other windows

- **Location**: `TablePro/Views/QuickSwitcher/QuickSwitcherView.swift:14-249`, presented at `MainContentView.swift:100-218` via `.sheet(item: Bindable(coordinator).activeSheet)`.
- **HIG violation**: Sheets, https://developer.apple.com/design/human-interface-guidelines/sheets. A sheet is for "a task that's directly related to the window, ideally one with a definite end." Quick Switcher is the macOS Spotlight pattern: ephemeral search, dismiss on Esc / outside click / selection. It must not be a sheet (which is modal to its window and inherits the title bar).
- **Apple-correct primitive**: `NSPanel` with style mask `[.nonactivatingPanel, .titled, .fullSizeContentView]`, `becomesKeyOnlyIfNeeded = true`, `hidesOnDeactivate = true`, and `level = .floating`. Wrap content in `NSHostingController`. Reference: https://developer.apple.com/documentation/appkit/nspanel/init(contentrect:stylemask:backing:defer:) and the `.nonactivatingPanel` mask doc https://developer.apple.com/documentation/appkit/nswindow/stylemask/nonactivatingpanel.
- **Behaviour spec (Spotlight parity)**:
  - Esc dismiss: AppKit free via `cancelOperation:` on `NSPanel`.
  - Click-outside dismiss: `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])` + close.
  - Centred on the active screen, not the window: `NSScreen.main.visibleFrame`.
  - Cmd+P (Quick Switcher shortcut) toggles open/close: re-using the same panel instance.
- **Why a sheet is wrong here, concretely**: `MainContentView.swift:100` wraps the entire content tree in a `.sheet(item:)`. Opening Quick Switcher in window A, then trying to drag-paste from window B's data grid, fails because window B is no longer key (sheet steals key from A and prevents B from becoming key in some macOS versions). The on-key-press shortcut handler at lines 73-82 cannot fire when the user has switched apps and switched back.
- **Bonus benefits**: `NSPanel` participates in `NSApplication.windows` so `Window > Bring All to Front` works; sheet does not.

### H4 [CRIT] FilterPanelView is a hand-rolled predicate editor

- **Location**: `TablePro/Views/Filter/FilterPanelView.swift:8-248`, plus `FilterRowView.swift`, `FilterValueTextField.swift`. Logical mode picker (AND/OR), per-row column/operator/value, save-as-preset, preview SQL.
- **HIG violation**: macOS exposes `NSPredicateEditor` exactly for this: rule rows (AND/OR), template-driven operators per column type, drag-to-reorder, automatic compound expression, full VoiceOver support. The current view ships none of those for free. From the Color/Inspectors HIG: "Use system controls so people get familiar behaviors and your interface reflects current standards."
- **Apple-correct primitive**: `NSPredicateEditor` with `NSPredicateEditorRowTemplate` per column-type bucket. Reference: https://developer.apple.com/documentation/appkit/nspredicateeditor and https://developer.apple.com/documentation/appkit/nspredicateeditorrowtemplate. The `NSPredicate` returned drops directly into `SQLStatementGenerator` because the existing filter model already maps to SQL; you replace the UI, not the codegen.
- **Mapping plan**:
  - One `NSPredicateEditorRowTemplate` per column data-type group: numeric (`<`, `<=`, `=`, `!=`, `>=`, `>`, `BETWEEN`), text (`contains`, `beginsWith`, `endsWith`, `matches`, `IS NULL`), date (relative + absolute pickers), boolean (toggle).
  - Compound predicate at root for AND/OR (`NSCompoundPredicate.LogicalType`).
  - Saved presets become `NSPredicate` archives via `NSKeyedArchiver` (already shipped with `requiresSecureCoding`); replaces the bespoke `FilterPreset` JSON.
  - "Preview SQL" stays - it just reads the predicate via your existing visitor.
- **Accessibility unlock**: `NSPredicateEditor` rows expose row-add and row-remove buttons with correct labels, focus rings, and AXChildren for VoiceOver. The current `FilterRowView` lacks any `accessibilityLabel` for the per-row Add / Duplicate / Remove buttons.

### H5 [HIGH] Enum and Foreign-Key pickers are custom `List + NativeSearchField` inside a SwiftUI popover

- **Location**: `TablePro/Views/Results/EnumPopoverContentView.swift:12-99`, `TablePro/Views/Results/ForeignKeyPopoverContentView.swift:12-184`.
- **HIG violation**: Popovers, https://developer.apple.com/design/human-interface-guidelines/popovers. For a closed enum set (Postgres `ENUM`, MySQL `ENUM(…)`), the canonical control is `NSPopUpButton`: it owns its own popover-like menu, lazy-builds rows on click, and is the AXSyntheticControl `AXPopUpButton`. For a searchable open list (foreign-key reference), `NSComboBox` carries `usesDataSource = true` and a `completes` property, with a built-in expand affordance.
- **Apple-correct primitives**:
  - **Enum cell editor**: `NSPopUpButton` configured as a pull-down with the enum members. Reference: https://developer.apple.com/documentation/appkit/nspopupbutton. The NULL marker becomes `NSMenuItem` with `representedObject = nil`. Replace `EnumPopoverContentView` entirely.
  - **FK cell editor**: `NSComboBox` with `usesDataSource = true`. Reference: https://developer.apple.com/documentation/appkit/nscombobox. Set `numberOfVisibleItems = 12`, `completes = true`, `completionsForSubstring:` returns the matching FK rows. The "1000-row fetch" stays the same; you just hand it to the data source. Replace `ForeignKeyPopoverContentView` entirely.
  - For very large referenced tables (>1000), keep the popover model but wrap an `NSTableView` inside it (with section headers and `NSTextFinder` for in-popover find). Reference popover sizing per HIG ("Make a popover the right size for its content; avoid scrolling").
- **String violations also present here** - see H6.

### H6 [CRIT] Hardcoded English strings in user-facing surfaces

CLAUDE.md mandate: "Use `String(localized:)` for new user-facing strings in computed properties, AppKit code, alerts, and error descriptions." Verified the following keys already exist in `TablePro/Resources/Localizable.xcstrings` (so the only work is wrapping the call site):

| File:line | Current | Replacement | Catalog key exists |
|---|---|---|---|
| `Views/QuickSwitcher/QuickSwitcherView.swift:34` | `Text("Quick Switcher")` | `Text(String(localized: "Quick Switcher"))` or `Text("Quick Switcher", comment: "...")` (SwiftUI auto-localises literals at view layer, but this is the sheet header that needs explicit comment) | yes (line 36408) |
| `Views/QuickSwitcher/QuickSwitcherView.swift:184` | `Text("Loading...")` | localised key exists | yes (line 27358) |
| `Views/QuickSwitcher/QuickSwitcherView.swift:198` | `Text("No objects found")` | localised key exists | yes (line 30764) |
| `Views/QuickSwitcher/QuickSwitcherView.swift:201` | `Text("No matching objects")` | localised key exists | yes (line 30629) |
| `Views/QuickSwitcher/QuickSwitcherView.swift:204` | `Text("No objects match \"\(viewModel.searchText)\"")` | **bug per CLAUDE.md** - this is a `String(localized:)` with interpolation antipattern even though the immediate site uses `Text`. Use `String(format: String(localized: "No objects match \"%@\""), viewModel.searchText)` | needs new key |
| `Views/QuickSwitcher/QuickSwitcherView.swift:235-241` | `case .table: return "TABLES"` etc. | All six need `String(localized:)`. These are section headers, not technical terms | needs keys: `TABLES`, `VIEWS`, `SYSTEM TABLES`, `DATABASES`, `SCHEMAS`, `RECENT QUERIES` |
| `Views/Filter/FilterPanelView.swift:60` | `Text("Filters")` | wrap explicitly given ambiguity with column-named "Filters" | already exists (21746) |
| `Views/Filter/FilterPanelView.swift:65-66` | `Text("AND")`, `Text("OR")` | logical operators, **technically borderline** - `AND` and `OR` are SQL keywords (per CLAUDE.md "Do NOT localize technical terms"). Recommend leaving as-is and adding a comment explaining. CLAUDE.md is explicit: technical terms (font names, database types, SQL keywords, encoding names) are not localised. |
| `Views/Filter/FilterPanelView.swift:107` | `Text("Enter a name for this filter preset")` | needs wrapping | catalog check needed |
| `Views/Results/ForeignKeyPopoverContentView.swift:55` | `Text("No values found")` | localised key exists | yes (line 31363) |
| `Views/Results/ForeignKeyPopoverContentView.swift:163` | `displayVal = "\(idVal) - \(second)"` | **CLAUDE.md violation: em dash forbidden anywhere**. Replace with `" - "` (hyphen-space-hyphen) or `": "`. Display string only, no key. |

The QuickSwitcher header at line 34 sits inside a `Text(...)` literal, which SwiftUI does auto-localise - but the entry currently in the catalog has only English. The audit recommends explicit `String(localized:)` for headers in NSPanel mode (after H3) where `Text` literals will move into `NSAttributedString` paths that don't auto-localise.

### H7 [MED] Theme engine bypasses semantic colors when a custom theme overrides them

- **Location**: `TablePro/Theme/ResolvedThemeColors.swift:177-225`. Pattern is: `colors.windowBackground?.nsColor ?? .windowBackgroundColor`. The fallback is correct; the **override** is the issue. A user-defined theme that sets `windowBackground: "#FFFFFF"` produces a hardcoded sRGB white that ignores `Increase Contrast`, `Reduce Transparency`, and `accessibilityDisplayShouldReduceTransparency`. From the existing 03 audit (`docs/refactor/03-hig-native-macos-delta.md:65-79`), the asset catalog has zero color sets.
- **HIG violation**: Color, https://developer.apple.com/design/human-interface-guidelines/color. "Use system colors and dynamic colors so the app adapts to the current appearance and accessibility settings." Reduce Transparency, https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency. Increase Contrast, https://developer.apple.com/documentation/swiftui/environmentvalues/colorschemecontrast.
- **Apple-correct primitives**:
  - Move all base colours into `Assets.xcassets` color sets with three or four variants: `Any Appearance`, `Dark`, `Any Appearance / High Contrast`, `Dark / High Contrast`. Reference: https://developer.apple.com/documentation/xcode/specifying-your-apps-color-scheme.
  - Replace the optional-overlay model: a theme may **substitute** a SwiftUI `Color` from the catalog (`Color("StatusWarning")`) but must not ship a hex literal that bypasses the catalog. The hex path is fine for syntax-highlighter colours (`SyntaxColors`) where dark/light variants don't apply, but UI surfaces (`UIThemeColors.windowBackground`, `controlBackground`, `selectionBackground`) should resolve to named asset entries.
  - Add `@Environment(\.accessibilityReduceTransparency)` and `\.colorSchemeContrast` reads in every site that uses `.ultraThinMaterial` or hex-derived colours, fall back to `.controlBackgroundColor` when set.
- **Theme accent colour**: `colors.accentColor` should be allowed only when the user explicitly opts into "override system accent". Default path must be `NSColor.controlAccentColor`, https://developer.apple.com/documentation/appkit/nscolor/2998125-controlaccentcolor, which respects the user's System Settings → Appearance → Accent picker.
- **The existing fallbacks at lines 178-208 are correct** - they reach for `.windowBackgroundColor`, `.controlBackgroundColor`, `.separatorColor`, `.labelColor`, `.selectedContentBackgroundColor`, `.unemphasizedSelectedContentBackgroundColor`, `.tertiaryLabelColor`, `.secondaryLabelColor`. Audit confirms these are the right semantic colors and the `?? `defaults are not the issue - only theme overrides bypass them.

### H8 [MED] Window state restoration is opt-out

- **Location**: `TablePro/Core/Services/Infrastructure/TabWindowController.swift:61` `window.isRestorable = false`. Same in `Views/Infrastructure/WindowChromeConfigurator.swift:43` (configurable, defaulted false in welcome / connection-form). No `encodeRestorableState(with:)` / `restoreState(with:)` overrides anywhere in the project (`grep` confirms 0 hits beyond `DataChangeManager.restoreState(from:)` which is unrelated).
- **HIG violation**: Window anatomy + system-document patterns. NSResponder ships `encodeRestorableState(with:)` / `restoreState(with:)` so apps survive Quit-and-Restart, Time Machine restore, and macOS state-restoration restarts (system-initiated restart for software updates). Reference: https://developer.apple.com/documentation/appkit/nsresponder/encoderestorablestate(with:) and https://developer.apple.com/documentation/appkit/nsresponder/restorestate(with:). HIG Windows says "When the user reopens your app, return to the previous state."
- **Apple-correct primitives**:
  - Set `window.isRestorable = true`; supply a non-nil `restorationClass: AnyClass` that conforms to `NSWindowRestoration`.
  - Override `encodeRestorableState(with coder:)` on `MainSplitViewController` (or a small `NSResponder` subclass): encode `connectionId`, `selectedTabId`, `tabbingIdentifier`, sidebar split position, scroll offset of the data grid (`tableView.enclosingScrollView?.contentView.bounds`), selected row indexes, applied filter NSPredicate, schema name.
  - Implement `class func restoreWindow(withIdentifier:state:completionHandler:)` on the restoration class. The completion handler receives a fully-configured `NSWindow` and the state coder; you decode in the same order.
  - The `TabPersistenceService` JSON layer can stay (it survives launches better than NSCoder state), but `isRestorable = true` lights up the OS-level "Reopen windows when logging back in" path that JSON-restore on `app launch` cannot replicate - that path runs *before* `applicationDidFinishLaunching` and is what users see when their machine restarts mid-session.
- **Quick win nearby**: `TablePro/Views/Settings/AppearanceSettingsView.swift` and the `Settings` scene at `TableProApp.swift:676` are also non-restorable. Settings panes that aren't restorable are fine; the main editor windows are not.

### H9 [DONE] Cells already announce row X of Y to VoiceOver

- **Location**: `TablePro/Views/Results/Cells/DataGridBaseCellView.swift:130-131` and `DataGridCellRegistry.swift:136`. Both `setAccessibilityRowIndexRange(NSRange(location:state.row, length: 1))` and `setAccessibilityColumnIndexRange(...)` are wired.
- **Status**: prior audit table H8 marked this as missing; the code was added since. **No action required.** Verify in the rewrite that cell-view subclasses (`NumericCell`, `BooleanCell`, etc.) inherit from `DataGridBaseCellView` so they pick up the calls, and that the row/column ranges update on row deletion/insertion (`tableRowsController.move` callsites). Reference: https://developer.apple.com/documentation/appkit/nsaccessibilityrow.

### H10 [HIGH] Keyboard shortcuts split between SwiftUI `.keyboardShortcut` and `NSMenuItem`

- **Location**: `TableProApp.swift:402-549` (SwiftUI `Button(...).keyboardShortcut(...)` declarations across `CommandGroup` blocks), `Views/QuickSwitcher/QuickSwitcherView.swift:69-82` (`.onKeyPress(.return)` and `.onKeyPress(characters:phases:)` used in lieu of menu items).
- **HIG violation**: Menus, https://developer.apple.com/design/human-interface-guidelines/menus. "Display the keyboard shortcut in a menu so people can discover it." Items hidden behind `.onKeyPress` modifiers are invisible to (a) the menu bar, (b) VoiceOver "VO+M" menu enumeration, (c) the system shortcut conflict report at System Settings → Keyboard → Keyboard Shortcuts → App Shortcuts.
- **Apple-correct primitives**:
  - Quick Switcher's Ctrl+J / Ctrl+K / Ctrl+N / Ctrl+P movement should be `NSMenuItem.keyEquivalent` items inside a hidden menu installed when the panel is key window, OR use `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` on the panel's content view. The latter is simpler since these shortcuts are only active when the panel is up. Reference: https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:).
  - Return key in Quick Switcher: native `NSPanel` `cancelOperation:` / `insertNewline:` via responder chain rather than SwiftUI `.onKeyPress(.return)`.
  - Where SwiftUI menu items are correct (most of `TableProApp.swift`), keep them - they DO reach `NSMenu`. The audit issue is exclusively the SwiftUI-internal `.onKeyPress` keypress handlers.
- **Conflict report sourced from prior audit** (`docs/refactor/03-hig-native-macos-delta.md:31-36`): five P0 shortcut conflicts (Cmd+D, Cmd+Y, Cmd+Option+Delete, Cmd+Ctrl+C, Cmd+L) are hard-coded in `KeyboardShortcutModels.swift`. Those are out of scope for this audit but flagged here because they live in the same shortcut machinery this finding asks you to centralise.

### H11 [LOW] Custom pasteboard type without parallel public types

- **Location**: `TablePro/Views/Results/DataGridView+RowActions.swift:178-181` (`com.TablePro.rowDrag`). `Core/Services/Infrastructure/ClipboardService.swift:21-32` already does the right thing for **copy**: `public.utf8-tab-separated-values-text` plus `public.utf8-plain-text` plus `com.TablePro.gridRows`. The drag-out path on the table view does NOT.
- **HIG violation**: Drag and drop (System experiences). Drag sources should write all the public types they can satisfy so that the destination chooses. Apple's `NSPasteboardWriting` doc: "An object that conforms to NSPasteboardWriting writes data to the pasteboard in one or more types." https://developer.apple.com/documentation/appkit/nspasteboardwriting.
- **Apple-correct primitive**: extend the pasteboard item produced at line 178-181 to also write `public.utf8-tab-separated-values-text` (the row rendered as TSV) and `public.utf8-plain-text` (concatenated cell values). Existing TSV serialiser in `ClipboardService.swift` already exists - call it. Result: drag a row out of the data grid into Numbers, TextEdit, Mail, or any text input and it pastes correctly.
- **Cross-link**: the prior audit `docs/refactor/03-hig-native-macos-delta.md:43` notes drag-out is also blocked at `validateDrop`. That P1 must be fixed first or this finding is unreachable.

### H12 [LOW] Toolbar customisation works; window subtitle and represented URL are correctly used; one missing primitive

- **Already correct**:
  - `TabWindowController.swift:62` `window.toolbarStyle = .unified`. https://developer.apple.com/documentation/appkit/nswindow/toolbarstyle/unified.
  - `MainWindowToolbar.swift:53` `allowsUserCustomization = true`. https://developer.apple.com/documentation/appkit/nstoolbar/allowsusercustomization.
  - `MainContentView+Setup.swift:206-207, 218-220, 239-240` `window.representedURL = sourceFileURL`, `window.isDocumentEdited`, `window.subtitle`. https://developer.apple.com/documentation/appkit/nswindow/representedurl, https://developer.apple.com/documentation/appkit/nswindow/subtitle.
- **Missing**:
  - Per-instance toolbar identifier `NSToolbar(identifier: "com.TablePro.main.toolbar.\(UUID().uuidString)")` at `MainWindowToolbar.swift:49`. UUIDs in toolbar identifiers defeat the system's per-toolbar customization autosave because the identifier changes on every launch. Reference: prior audit `docs/refactor/03-hig-native-macos-delta.md:47`. Replace with a stable `"com.TablePro.main.toolbar"` and route per-window state through `NSToolbar.autosavesConfiguration = true` + `NSToolbar.configuration` (macOS 13+).
  - `NSToolbar.centeredItemIdentifiers` for the principal item (the connection name / database name combo) is not set - that means hover behaviour and overflow handling treats the principal item as a normal trailing item. Reference: https://developer.apple.com/documentation/appkit/nstoolbar/centereditemidentifiers.

### H13 [MED] No App Intents / Spotlight integration

- **Location**: codebase-wide. `grep` for `AppIntent`, `IndexableEntity`, `CSSearchableItem` returns zero hits in TablePro source. `NSUserActivity` is published in `TabWindowController.swift:198` for Handoff but is not eligible for Spotlight (no `isEligibleForSearch = true`, no `contentAttributeSet`).
- **HIG violation**: System experiences > Search/Shortcuts. App Intents make app actions discoverable from Spotlight, Shortcuts.app, Siri, and the Action Button.
- **Apple-correct primitives**:
  - Add an `AppIntent` `OpenConnectionIntent` with a `@Parameter` for connection name, conforming to `OpenIntent`. Reference: https://developer.apple.com/documentation/appintents/openintent.
  - Expose connections via `IndexedEntity` so Spotlight can suggest "Open <connection name>" without TablePro running. Reference: https://developer.apple.com/documentation/appintents/indexedentity.
  - Backfill `NSUserActivity.isEligibleForSearch = true` and `contentAttributeSet` (CSSearchableItemAttributeSet with title = `"<connection> - <database> - <table>"`) at `TabWindowController.swift:198-233` so already-opened tabs are also Spotlight-indexed. Reference: https://developer.apple.com/documentation/foundation/nsuseractivity/iseligibleforsearch.
- **Bonus**: an `AppShortcutsProvider` static list with `OpenConnectionIntent`, `RunFavoriteQueryIntent`, `OpenSampleDatabaseIntent` adds three Siri / Shortcuts entries with zero per-user setup. Reference: https://developer.apple.com/documentation/appintents/appshortcutsprovider.

### H14 [LOW] No Services menu integration

- **Location**: codebase-wide. `grep` for `NSServicesMenuRequestor`, `validRequestor(forSendType:returnType:)` returns zero hits.
- **HIG violation**: macOS Services menu, https://developer.apple.com/design/human-interface-guidelines/services. The Services menu lets the user pipe a selected SQL string to another app (e.g. "Open in Xcode", "New Note from Selection"). Implementing `NSServicesMenuRequestor` on `SQLEditorView` and on `DataGridView` lights up that menu for free.
- **Apple-correct primitive**: implement `validRequestor(forSendType:returnType:)` on the editor's `NSTextView` subclass and on `DataGridView`'s tableview. Reference: https://developer.apple.com/documentation/appkit/nsservicesmenurequestor.

### H15 [LOW] Inspector right panel is custom, not `NSSplitViewController` inspector style

- **Location**: `RightPanelState`, `MainContentView.toggleRightSidebar()`. The right panel is a SwiftUI view tree placed inside the split view.
- **HIG violation**: Inspectors, https://developer.apple.com/design/human-interface-guidelines/inspectors. macOS 14+ `NSSplitViewItem.behavior = .inspector` provides system-standard divider, collapse chevron in the toolbar (auto-installed when `NSToolbarItem.Identifier.toggleInspector` is in the toolbar - which TablePro already uses at `MainWindowToolbar.swift:93`).
- **Apple-correct primitive**: declare the right pane as `NSSplitViewItem(viewController:)` with `behavior = .inspector`. AppKit then handles all collapse / restore, animates correctly, sets `.canCollapseFromWindowResize`, and shows the right collapse chevron. Reference: https://developer.apple.com/documentation/appkit/nssplitviewitem/behavior/inspector.

---

## Summary table

| ID | Sev | Surface | File:line | Native primitive | HIG section |
|---|---|---|---|---|---|
| H1 | CRIT | Result tab bar | `Views/Results/ResultTabBar.swift:11-104` | `NSTabViewController` (`tabStyle = .toolbar`) | Tab views |
| H2 | CRIT | Per-window tab parallel ledger | `MainContentView.swift:53,77`, `Setup.swift:223-225` | Single source of truth: `NSWindow` tabs (already `.preferred`); delete SwiftUI `tabManager.tabs` | Window anatomy |
| H3 | CRIT | Quick Switcher sheet | `Views/QuickSwitcher/QuickSwitcherView.swift:14-249`, presented at `MainContentView.swift:201-210` | `NSPanel` with `[.nonactivatingPanel, .titled, .fullSizeContentView]` + `hidesOnDeactivate` | Sheets / Popovers |
| H4 | CRIT | Filter UI | `Views/Filter/FilterPanelView.swift`, `FilterRowView.swift` | `NSPredicateEditor` + `NSPredicateEditorRowTemplate` | (no specific HIG section; AppKit doc) |
| H5 | HIGH | Enum & FK pickers | `Views/Results/EnumPopoverContentView.swift`, `ForeignKeyPopoverContentView.swift` | `NSPopUpButton` (enum), `NSComboBox` (FK), `NSTableView`-in-popover for very large FK | Popovers |
| H6 | CRIT | Hardcoded English strings | listed in body | `String(localized:)` per CLAUDE.md | n/a (project rule) |
| H7 | MED | Theme color override path | `Theme/ResolvedThemeColors.swift:177-225`, `Settings/AppearanceSettingsView.swift:18-50` | Asset catalog color sets + `accessibilityReduceTransparency` reads | Color, Accessibility |
| H8 | MED | Window restoration off | `TabWindowController.swift:61`, `WindowChromeConfigurator.swift:43` | `NSWindowRestoration` + `encodeRestorableState/restoreState` | Window anatomy |
| H9 | DONE | Row/column index ranges | `Cells/DataGridBaseCellView.swift:130-131` | already correct | Accessibility |
| H10 | HIGH | `.onKeyPress` shortcuts not in menu | `QuickSwitcherView.swift:69-82` | `NSEvent.addLocalMonitorForEvents` on panel + standard responder chain | Menus |
| H11 | LOW | Drag pasteboard single type | `DataGridView+RowActions.swift:178-181` | Add `public.utf8-tab-separated-values-text` + `public.utf8-plain-text` | n/a (NSPasteboard doc) |
| H12 | LOW | Toolbar identifier UUID | `MainWindowToolbar.swift:49` | Stable identifier + `centeredItemIdentifiers` | Toolbars |
| H13 | MED | No App Intents / Spotlight | codebase | `OpenIntent`, `IndexedEntity`, `AppShortcutsProvider`, `NSUserActivity.isEligibleForSearch` | (App Intents framework) |
| H14 | LOW | No Services menu | codebase | `NSServicesMenuRequestor` | Services |
| H15 | LOW | Custom right inspector | `RightPanelState`, split view | `NSSplitViewItem.behavior = .inspector` | Inspectors |

Crit/High count: 6 CRIT + 2 HIGH. These are the items the unified blueprint (task #10) must address.

---

## Notes on overlaps and de-scoping

- The 2026-05-03 prior audit (`docs/refactor/03-hig-native-macos-delta.md`) already catalogued H3 (QuickSwitcher sheet), H8 (no NSWindowRestoration), H10 (shortcut conflicts in `KeyboardShortcutModels.swift`), and the asset-catalog gap referenced in H7. Findings here are intentionally compatible: the citations cross-reference the prior doc rather than re-deriving them. The rewrite blueprint (task #10) should consume both documents.
- Per-cell accessibility (H9) was a known gap when the prior audit and the section-2.6 table were written; it has since been fixed in `DataGridBaseCellView.swift`. Marked DONE here so the rewrite does not re-implement what already works.
- Per user memory `Native NSWindow tab perf cost accepted`, H1/H2 do **not** propose a custom AppKit tab bar above an `NSTabView`. H1 is constrained to result-set tabs (within one window); H2 explicitly preserves `tabbingMode = .preferred` and only proposes deleting the SwiftUI parallel ledger.
- "Filters" key vs SQL-keyword "AND/OR": kept English under CLAUDE.md technical-term carve-out. The audit flags it for explicit comment in source rather than localisation.
- Em-dash hit at `ForeignKeyPopoverContentView.swift:163` is a CLAUDE.md violation for source files; included in H6 because it ships into the FK display string at runtime.
