# Windows, Tabs, Sheets, and Interactions Audit

**Agent**: window-interaction-auditor
**Date**: 2026-05-01
**Scope**: Main `TablePro/` target. AppKit + SwiftUI hybrid. Source: `TablePro/Core/Services/Infrastructure/*`, `TablePro/Views/**`, `TablePro/AppDelegate.swift`, `TablePro/TableProApp.swift`.

---

## P0 — Broken native contracts

### [P0] Window-modal sheets used for sheets-of-sheets across export, import, AI provider, database switcher

- **File**: `TablePro/Views/Export/ExportDialog.swift:97`, `:132`, `:146`; `TablePro/Views/Import/ImportDialog.swift:95`, `:103`, `:112`; `TablePro/Views/DatabaseSwitcher/DatabaseSwitcherSheet.swift:117`, `:120`; `TablePro/Views/Connection/ConnectionFormView+GeneralTab.swift:220`, `:223`
- **Current**: A sheet (`ExportDialog`, `ImportDialog`, `DatabaseSwitcherSheet`, `ConnectionFormView`) presents another sheet on top of itself: `LicenseActivationSheet`, `ExportProgressView`, `ExportSuccessView`, `ImportProgressView`, `ImportSuccessView`, `ImportErrorView`, `CreateDatabaseSheet`, `DropDatabaseSheet`, URL import. SwiftUI does present these stacked, but the result is a sheet presented from a sheet, which is what HIG explicitly tells you not to do.
- **HIG says**: "Avoid presenting a sheet from a sheet. Generally, only one sheet is visible at a time. Avoid letting people open a sheet from within a sheet, because hierarchies of sheets can become confusing." (Sheets — macOS).
- **Native examples**: Mail's compose window swaps inline panels for "send later" / attachment errors. Xcode's project settings push the sub-screens inside the same sheet (NavigationStack). Notes' export uses an NSSavePanel attached to the document, not chained sheets.
- **Fix**:
  - Replace stacked progress/success sheets with **inline state inside the parent sheet** (a single sheet that swaps between configure → progress → success/error, like Mail's send sheet).
  - For `ExportDialog → LicenseActivationSheet` and `ImportDialog → LicenseActivationSheet`: dismiss the parent sheet first, then present activation. Or push activation as a NavigationStack screen inside the parent.
  - For `DatabaseSwitcherSheet → CreateDatabaseSheet / DropDatabaseSheet`: turn these into a NavigationStack push inside the switcher (it already has the room — 420×480), or close the switcher and open the create/drop dialog standalone.
- **Effort**: M (each dialog), L overall (5 dialogs)

### [P0] QuickSwitcher is a window-modal sheet, but it should be a floating panel

- **File**: `TablePro/Views/QuickSwitcher/QuickSwitcherView.swift:14-249`, presented from `TablePro/Views/Main/MainContentView.swift:204-213`
- **Current**: `QuickSwitcherSheet` is presented via `.sheet(item: coordinator.activeSheet)` and dims the parent window. It is a Spotlight/Cmd+P-style "go to symbol" search.
- **HIG says**: "Use a popover or a panel for short, focused, transient input. A modal sheet stops everything else." Spotlight, Xcode's "Open Quickly", Safari's Tab Switcher, Notes' "Find Note" are all `NSPanel` or popover, not window-modal sheets.
- **Native examples**: Xcode "Open Quickly" (Cmd+Shift+O) — floats above the window, doesn't dim it, dismisses on focus loss. Spotlight, Raycast.
- **Fix**: Promote to `NSPanel` (`.titled, .nonactivatingPanel`, `.fullSizeContentView`) shown via a small factory, similar to `FeedbackWindowController`. Center over the key window, dismiss on Escape or focus loss. Remove from `ActiveSheet` enum.
- **Effort**: M

### [P0] QuickSwitcher Cmd+1...Cmd+9 selection is not handled — only opening selected item

- **File**: `TablePro/Views/QuickSwitcher/QuickSwitcherView.swift:69-82`
- **Current**: Only `.return`, Ctrl+J/N/K/P, and the search field arrow keys move/select. No way to jump directly with Cmd+1...Cmd+9 like Spotlight or VS Code Quick Open.
- **HIG says**: Spotlight-style switchers consistently support Cmd+digit jumps for the top N results.
- **Native examples**: Spotlight, Safari Tab Switcher (Cmd+1...Cmd+9 jumps to that tab), Xcode "Open Quickly".
- **Fix**: Add `.onKeyPress` handlers for digit keys with `.command` modifier that select and open the Nth item.
- **Effort**: S

### [P0] FeedbackWindowController uses NSPanel, but tied to NSApp.keyWindow lifecycle through `viewModel.captureTargetWindow`

- **File**: `TablePro/Views/Feedback/FeedbackWindowController.swift:18-64`
- **Current**: `showFeedbackPanel` resolves `NSApp.keyWindow` once at open time and stashes it on `viewModel.captureTargetWindow`. If the user switches windows / closes the original window before submitting feedback, capture target is stale or nil. The panel is a singleton, so opening once-then-switching-windows reuses the old captureTargetWindow.
- **HIG says**: Panels are utility windows whose context can update as the user changes the underlying document or window. They should resolve their target lazily when the action runs (on submit) rather than freezing it at open.
- **Native examples**: Mail's "Report Junk" sheet attaches to the active message window. Xcode's "Report a Bug" reads the front document at submit time.
- **Fix**: Resolve `captureTargetWindow` at submit time, not at open time, by inspecting `NSApp.mainWindow` (or by binding the panel to the front main window via parentWindow).
- **Effort**: S

### [P0] EditorWindow.performClose collapses last tab to empty state instead of closing window

- **File**: `TablePro/Core/Services/Infrastructure/TabWindowController.swift:27-36`; `TablePro/Views/Main/MainContentCommandActions.swift:352-373`
- **Current**: Cmd+W on a window with one tab and zero query tabs → window closes. With one window and one or more open query tabs → calls `closeTab()` which clears all tabs and leaves an empty "no tabs" main window. Effectively, Cmd+W twice is required to close a single-tab single-window setup.
- **HIG says**: "Cmd+W closes the focused window. If the window is a tab inside a tabbed window group, Cmd+W closes that tab. If only one tab remains, the window itself closes." Cmd+W must never leave an empty window.
- **Native examples**: Safari, Notes, Xcode — Cmd+W closes the tab; if only one tab remains, the window closes. Cmd+Option+W closes all tabs/windows.
- **Fix**:
  - Cmd+W should close the active tab if multiple query tabs exist, otherwise close the window. The existing code path is inverted for the single-tab case.
  - Reserve "no tabs visible" as a transient empty state, not a destination Cmd+W can drive the window into.
  - On the last window's last tab close, fall through to the standard "show welcome" behavior (already in `AppDelegate.windowWillClose`).
- **Effort**: M

### [P0] No "Show All Tabs" / Cmd+Shift+\\ support

- **File**: Menu commands in `TablePro/TableProApp.swift:543-578`
- **Current**: Only Cmd+1...Cmd+9, Cmd+Shift+[, Cmd+Shift+] are wired. There is no menu item or shortcut for `NSWindow.toggleTabOverview(_:)` (Show All Tabs / Cmd+Shift+\\), which Safari/Notes/Finder/Mail all expose.
- **HIG says**: When using native window tabs, the standard "View > Show All Tabs" / Cmd+Shift+\\ binding is part of the contract. Users expect it.
- **Native examples**: Safari, Notes, Finder, Mail — every native tabbed app supports `toggleTabOverview`.
- **Fix**: Add `Button("Show All Tabs")` to `CommandGroup(after: .windowArrangement)` in `AppMenuCommands` that calls `NSApp.sendAction(#selector(NSWindow.toggleTabOverview(_:)), to: nil, from: nil)` with `.keyboardShortcut("\\", modifiers: [.command, .shift])`.
- **Effort**: S

### [P0] No "Move Tab to New Window" command

- **File**: Menu commands in `TablePro/TableProApp.swift`, no menu item; `EditorWindow` does not override or expose `moveTabToNewWindow:`.
- **Current**: There is no menu, context menu, or shortcut to break a tab out into its own window. Native window tabs support `NSWindow.moveTabToNewWindow(_:)` but it's not surfaced.
- **HIG says**: "When a window can have tabs, the system adds Move Tab to New Window and Merge All Windows to the Window menu automatically. If you replace the menu, you must reinclude these items."
- **Native examples**: Safari, Finder, Notes — both items appear in Window menu.
- **Fix**: Add to the Window menu:
  - "Move Tab to New Window" → `NSWindow.moveTabToNewWindow(_:)`
  - "Merge All Windows" → `NSWindow.mergeAllWindows(_:)`
  Both actions should validate against `validateUserInterfaceItem(_:)` (only enabled when the key window has siblings or is part of a tab group).
- **Effort**: S

### [P0] Multiple windows for the same connection silently share toolbar/coordinator state

- **File**: `TablePro/Core/Services/Infrastructure/WindowManager.swift:23-85`; `TablePro/Core/Services/Infrastructure/MainWindowToolbar.swift:32`
- **Current**: `WindowManager.openTab` adds new windows to a tab group keyed by `tabbingIdentifier(for: connectionId)` (or "com.TablePro.main" if `groupAllConnectionTabs` is on). With "groupAllConnectionTabs" off, each connection gets its own tab group, but separate tab groups for the same connection are possible if a user drags one tab out. Toolbar identifiers use `UUID()` (line 49) so each window has its own toolbar — good — but the coordinator is per-window, and multiple coordinators for the same connection share `DatabaseManager.shared.activeSessions[connectionId]`. There's no documented behavior for "should the same connection live in two windows".
- **HIG says**: A document/connection is the user's mental unit. Multi-window per document is allowed (Pages does it) but each window must look first-class — same toolbar, same data, no surprising side effects.
- **Native examples**: Pages, Notes, Xcode — multi-window per document is consistent; closing one window does not close the document, closing the last window does.
- **Fix**: Decide and document one of the following:
  1. **Single window per connection** (TablePlus model) — block `moveTabToNewWindow:` and gate "Open Connection" to focus an existing window. Simpler.
  2. **Multi-window per connection** (Pages model) — verify all per-window state (filter panel, history panel, change manager) is window-scoped (today some of these are not — `FilterStateManager` is created per coordinator, but `DataChangeManager`'s relationship to the underlying session needs review).

  Either is fine, but pick one and enforce. The current state is "accidentally allowed multi-window".
- **Effort**: L

---

## P1 — Non-idiomatic patterns

### [P1] Welcome window blocks miniaturize and zoom — unnecessary restriction

- **File**: `TablePro/Core/Services/Infrastructure/WelcomeWindowFactory.swift:47-49`
- **Current**: `standardWindowButton(.miniaturizeButton)?.isHidden = true`, `standardWindowButton(.zoomButton)?.isHidden = true`, `collectionBehavior.insert(.fullScreenNone)`
- **HIG says**: "Don't disable the standard window buttons unless your window genuinely shouldn't be miniaturized." A welcome window can be miniaturized (Xcode, Pages, Sketch all do).
- **Native examples**: Xcode's welcome window — minimizes, can't be resized, can't fullscreen (those are correct restrictions). Sketch's welcome — same. None hide the close button row entirely.
- **Fix**: Re-enable miniaturize. Keep `.fullScreenNone`. Hiding zoom is acceptable for a fixed-size window, but consider showing it greyed-out instead of hidden (matches Xcode behavior).
- **Effort**: S

### [P1] Connection form window disables miniaturize and zoom and removes from style mask

- **File**: `TablePro/Core/Services/Infrastructure/ConnectionFormWindowFactory.swift:52-55`
- **Current**: Sets `miniaturizeButton.isEnabled = false`, `zoomButton.isEnabled = false`, then `styleMask.remove(.miniaturizable)`. The first two lines disable greyed buttons; the third removes the affordance entirely so the button hole disappears.
- **HIG says**: Connection editing is a long-running task — users want to alt-tab away or minimize.
- **Native examples**: Notes new note, Mail compose, System Settings panes — all minimizable.
- **Fix**: Drop both blocks. Allow miniaturize. Allow zoom (the form is resizable already). Add `.fullScreenAuxiliary` so the form opens above a fullscreen main window when triggered from inside it.
- **Effort**: S

### [P1] FavoriteEditDialog is a sheet but should be a panel

- **File**: `TablePro/Views/Sidebar/FavoriteEditDialog.swift:62-156`, presented via `.sheet(item:)` from `FavoritesTabView.swift:52` and `MainEditorContentView.swift:95`
- **Current**: A 480-wide form-sheet that includes a TextEditor (160 px tall) plus name/keyword/folder/global. Used both from the sidebar (favorites tab) and the editor (Save as Favorite from the query editor).
- **HIG says**: A sheet is appropriate when the action is tied to a single document. This form is a stand-alone object editor — it could outlive the current window context. Other native object-editor flows (Calendar new event, Reminders detail, Photos info) are panels or popovers.
- **Native examples**: Calendar's New Event panel, Reminders' detail panel.
- **Fix**: Decision call. If the favorite is always tied to the current connection, a sheet is fine. If it's a global object (Global toggle exists at line 109), a panel is better. Lean toward panel since the same dialog is reachable from multiple places.
- **Effort**: M

### [P1] License activation as a sheet, but reachable from many places — duplicates and stacks

- **File**: `TablePro/Views/Settings/LicenseActivationSheet.swift`, presented from `SafeModeBadgeView.swift:71`, `ProFeatureGate.swift:28`, `SyncStatusIndicator.swift:33`, `ExportDialog.swift:97`, `ConnectionFormView+GeneralTab.swift:223`, `WelcomeWindowView.swift:91`
- **Current**: Six different presentation sites. If the user has the export sheet open and clicks "Activate License" inside it, the activation sheet stacks on top of the export sheet (which is a sheet on the main window). Same for the connection form.
- **HIG says**: A licensing dialog is an app-level action. It is not tied to any particular document. It belongs in Settings, or as a panel/window reachable from any context, but not as a sheet that stacks.
- **Native examples**: Sparkle's update window is a panel. Affinity, Pixelmator Pro use a panel for license activation.
- **Fix**: Convert `LicenseActivationSheet` to an NSPanel reachable via `LicenseWindowController.shared.show()`. Each of the six call sites simply triggers the controller.
- **Effort**: M

### [P1] Sheets sized with hard-coded `.frame(width:)` lose the user's resize state

- **File**: `MaintenanceSheet.swift:75` (`.frame(width: 420)`), `TableOperationDialog.swift:165` (`.frame(width: 320)`), `LicenseActivationSheet.swift:83` (`.frame(width: 400)`), `MCPTokenRevealSheet.swift:40` (`.frame(width: 540, height: 520)`), `DatabaseSwitcherSheet.swift:110` (`.frame(width: 420, height: 480)`), `QuickSwitcherView.swift:59` (`.frame(width: 460, height: 480)`), `FavoriteEditDialog.swift:132` (`.frame(width: 480)`), `AIProviderDetailSheet.swift:91` (`.frame(minWidth: 520, minHeight: 480)`)
- **Current**: Most sheets are fixed-size. Only `AIProviderDetailSheet` allows resize.
- **HIG says**: "Use a sheet that's small enough to fit the content but large enough that people don't have to scroll a lot. If the content can be longer, allow the sheet to grow." Sheets containing a TextEditor (FavoriteEditDialog, MCP token, JSON viewer) should be resizable.
- **Native examples**: Mail's compose, Notes' share sheet — resizable.
- **Fix**: Add `.frame(minWidth:idealWidth:maxWidth:)` and rely on the platform to remember user-set size where the sheet is editor-like (any sheet containing a TextEditor or a long form).
- **Effort**: S per dialog

### [P1] No drag-out support on data grid rows — only intra-grid reorder

- **File**: `TablePro/Views/Results/DataGridView+RowActions.swift:175-227`
- **Current**: `pasteboardWriterForRow` writes `com.TablePro.rowDrag` (custom UTI), TSV, and HTML. `validateDrop` rejects any drag whose source is not the same NSTableView (line 203: `info.draggingSource as? NSTableView === tableView`). So you cannot drag selected rows into Numbers, Excel, a text editor, Mail, or Finder.
- **HIG says**: "Where dragging makes sense, support it broadly. Tables and lists usually allow dragging selected rows out of the app." TSV+HTML on the pasteboard would be enough to drag rows into Numbers as a table.
- **Native examples**: Numbers, Finder list view, Mail attachment list — all support drag out.
- **Fix**: Drop the `info.draggingSource as? NSTableView === tableView` check from `validateDrop`. Implement `tableView(_:writeRowsWith:to:)` (or its newer pasteboardWriter equivalent) so that dragging out writes both the custom `rowDrag` type (intra-grid moves), and standard `string` + `html` types (cross-app drops). External apps will see TSV/HTML; internal moves still see the custom type.
- **Effort**: M

### [P1] No drop-onto-window for SQL files and CSVs

- **File**: No NSWindow drop target outside `Views/Settings/Plugins/InstalledPluginsView.swift:46` (which accepts `.fileURL` for plugin install) and `Views/Feedback/FeedbackView.swift:122`.
- **Current**: Dragging a `.sql`, `.csv`, or `.json` file onto the main editor window does nothing. The Open command exists, but drag-drop is the macOS norm.
- **HIG says**: "Documents that can be opened by your app should accept drop." Apple's CFBundleDocumentTypes is registered (per the recent commit referenced in git log) but the receiving window doesn't implement drop.
- **Native examples**: Xcode (drag a `.swift` onto the project), TextEdit (drag a `.txt` onto the window), VS Code, Sublime Text.
- **Fix**: Add `.onDrop(of: [.fileURL], isTargeted: nil) { providers in ... }` at the level of the editor's main content view (or implement `NSDraggingDestination` on the `EditorWindow`'s contentView). Route through the same path as File > Open.
- **Effort**: M

### [P1] Welcome window has no drop target for `.tablepro` import files

- **File**: `TablePro/Views/Connection/WelcomeWindowView.swift`
- **Current**: Has `.fileImporter` for `.tableproConnectionShare` (line 137-145) but no `onDrop`. Users with a `.tablepro` file in Finder can't drag it onto the welcome window.
- **HIG says**: Anywhere you accept a file via "Import...", you should accept the same file via drop.
- **Native examples**: Apple Music welcome (drag .m4a), iMovie welcome (drag .mp4).
- **Fix**: Add `.onDrop(of: [.tableproConnectionShare], isTargeted: ...)` on the welcome view that routes to the same `vm.activeSheet = .importFile(url)` path.
- **Effort**: S

### [P1] Multi-select in WelcomeWindowView connection list does not follow Finder selection conventions

- **File**: `TablePro/Views/Connection/WelcomeWindowView.swift:280-326`
- **Current**: Selection is implemented as a `Set<UUID>` on the SwiftUI `List`. Cmd+A (line 316-320) selects all visible. Cmd+Click and Shift+Click are handled by the `List` natively, so this is OK at first glance — but the connection rows themselves are wrapped in `WelcomeConnectionRow` with custom hit testing. Connect-on-double-click is wired through `DoubleClickDetector` (used elsewhere in `connectionList` rendering).
- **HIG says**: Lists with selection follow Finder/Mail conventions: click selects, Shift+click extends, Cmd+click toggles, double-click activates, Return activates the focused row.
- **Native examples**: Finder, Mail, Notes.
- **Fix**: Verify Shift+Click range selection works against the visible flat list (not just the in-group order). Verify Cmd+Click toggles a single row in/out of the selection without clearing other selections. Add tests if missing.
- **Effort**: S to verify, M if broken

### [P1] Sidebar table list uses `.contextMenu` only — important destructive actions hidden

- **File**: `TablePro/Views/Sidebar/SidebarView.swift:197-216`, `SidebarContextMenu.swift:35-`
- **Current**: "Drop View", "Truncate Table" (via `TableOperationDialog`), and others live only in the right-click context menu. There's no menu-bar equivalent, so a user without a right mouse button (or who has never right-clicked the sidebar) won't discover them.
- **HIG says**: "If a context menu has actions not available elsewhere, it's a discoverability problem. Important destructive actions should also live in the menu bar (with a sensible disable rule)."
- **Native examples**: Finder — every "right-click new folder" action is also under File or Edit. Notes — delete note appears in both the context menu and Edit menu.
- **Fix**: Promote drop/truncate/edit-view-definition into the Edit menu under a "Tables" submenu, gated on `actions.hasTableSelection`.
- **Effort**: M

### [P1] DatabaseSwitcherSheet drop key uses `delete` (forward delete on a Mac Magic Keyboard) instead of backspace

- **File**: `TablePro/Views/DatabaseSwitcher/DatabaseSwitcherSheet.swift:145-149`
- **Current**: `.onKeyPress(.delete) { ... initiateDropForSelected() }` — `KeyEquivalent.delete` in SwiftUI maps to the forward-delete key (fn+delete on most Apple keyboards).
- **HIG says**: Lists conventionally use **Backspace** (the regular Delete key, character `\u{7F}`) for "remove selected", not forward Delete.
- **Native examples**: Finder uses Cmd+Delete (backspace); Mail uses Delete (backspace); Music uses Delete (backspace).
- **Fix**: Replace with `.onKeyPress(characters: .init(charactersIn: "\u{7F}\u{08}"), phases: .down) { ... }` matching the pattern already used in `WelcomeWindowView.swift:229` and `:308`. Consider gating on `.command` modifier (Cmd+Delete) since dropping a database is unusually destructive.
- **Effort**: S

### [P1] `MaintenanceSheet` Execute button uses `.defaultAction` keyboard shortcut for a destructive operation

- **File**: `TablePro/Views/Sidebar/MaintenanceSheet.swift:66-71`
- **Current**: Execute (which can run `VACUUM FULL` and rewrite a table while blocking access) is bound to Return via `.keyboardShortcut(.defaultAction)`.
- **HIG says**: For destructive defaults, either make Cancel the default action and require the user to click Execute, or attach Return to a non-destructive primary action. Apple's NSAlert convention places Cancel last (right) and emphasized via Escape; destructive primaries are usually distinct from the default.
- **Native examples**: Finder Empty Trash — Empty is on the right but Cancel is highlighted as the default. System Settings Reset — same pattern.
- **Fix**: Mark Cancel as `.keyboardShortcut(.cancelAction)` (already done at `:65`) and remove the `.defaultAction` from Execute. Force a deliberate click to execute, or require holding Option to enable Return-to-execute. Consider also adding `.role(.destructive)` for the right styling.
- **Effort**: S

### [P1] `TableOperationDialog` Drop button uses `.keyboardShortcut(.return, modifiers: [])` and is destructive default

- **File**: `TablePro/Views/Sidebar/TableOperationDialog.swift:154-162`
- **Current**: Drop button is destructive but bound to Return as the default action. Cancel has no `.cancelAction`.
- **HIG says**: Same as above — Cancel should be default for destructive sheets, or at minimum no Return shortcut.
- **Native examples**: Finder's "Move to Trash" prompt makes Cancel the default; Trash is on the right.
- **Fix**: Add `.keyboardShortcut(.cancelAction)` to Cancel (line 148), remove the Return shortcut from Drop, mark Drop as `.role(.destructive)`.
- **Effort**: S

### [P1] AlertHelper destructive confirms put confirm button first (left) and don't use .destructive role

- **File**: `TablePro/Core/Utilities/UI/AlertHelper.swift:24-39`, `:43-65`, `:130-163`
- **Current**: `confirmDestructive` adds the confirm button first (`addButton(withTitle: confirmButton)`), which puts it on the **right** in macOS 11+ NSAlert layout (NSAlert lays out buttons right-to-left in addition order). Confirm/Execute is on the right, Cancel on the left, but `confirmDestructive` does not call `hasDestructiveAction = true` on the destructive button. `confirmSaveChanges` does set it on Don't Save (line 142), so the pattern is known.
- **HIG says**: Destructive buttons should be on the **leading** (left) side, with Cancel as the default on the right. NSAlert's `hasDestructiveAction = true` puts the button on the left in macOS 11+.
- **Native examples**: Finder's "Move to Trash", Mail's "Delete Message" — destructive action on the left, Cancel on the right (default).
- **Fix**:
  - Set `hasDestructiveAction = true` on the destructive button in every confirm helper.
  - Audit each call site — many places (`confirmDangerousQueryIfNeeded`, `confirmDiscardChanges`) intend the action button to be destructive.
- **Effort**: S

### [P1] Settings TabView at fixed 720×500 — lots of content gets clipped on small screens

- **File**: `TablePro/Views/Settings/SettingsView.swift:64`
- **Current**: `.frame(width: 720, height: 500)` regardless of which tab is selected.
- **HIG says**: Preferences/settings windows should size to their content. Each pane has different needs.
- **Native examples**: System Settings, Xcode Settings, Notes Settings — each pane sizes itself.
- **Fix**: Drop the fixed frame. Add `.frame(minWidth: 600)` and let each tab grow vertically. Or use `Settings` scene with per-tab `idealWidth/idealHeight`.
- **Effort**: S

### [P1] AIProviderDetailSheet uses NavigationStack inside a sheet — odd nesting

- **File**: `TablePro/Views/Settings/AIProviderDetailSheet.swift:52-91`
- **Current**: A sheet that wraps its body in `NavigationStack` purely to get a navigation title bar with Cancel/Save toolbar items. Presented from inside the Settings TabView (which is itself a sheet-like preferences window).
- **HIG says**: NavigationStack belongs inside a navigable container. A sheet can have a title via `.navigationTitle` only if the sheet's root is NavigationStack — but a single-screen sheet doesn't need the stack overhead.
- **Native examples**: Mail's compose sheet uses an explicit toolbar instead of NavigationStack.
- **Fix**: Replace the NavigationStack wrapper with a manual header strip (Cancel/title/Save buttons) or with the standard sheet button placement at the bottom. The existing `.toolbar` items will move into a footer HStack.
- **Effort**: S

### [P1] Cmd+Shift+P (Preview SQL) opens a popover from a Toolbar button — popover anchor is fragile under window resize

- **File**: `TablePro/Views/Toolbar/TableProToolbarView.swift:154-168`
- **Current**: The Preview SQL toolbar item wraps a Button in a VStack and attaches `.popover(isPresented:)` to the VStack. When the toolbar overflows into the chevron (narrow window), the popover anchor moves to the chevron menu, which can produce a misanchored popover.
- **HIG says**: Popovers should anchor to a stable visible control. A toolbar item can collapse, so the popover must be tolerant.
- **Native examples**: Safari's "Tab Group" toolbar popover uses `NSToolbarItem.itemIdentifier` and a sourceItemIdentifier to anchor correctly.
- **Fix**: Anchor the popover to the toolbar item identifier (NSToolbarItem itemIdentifier) via `popover(isPresented:attachmentAnchor:arrowEdge:)` with a fixed source. Or move the SQL preview into a sheet/panel since the content is rich.
- **Effort**: M

### [P1] Result tab bar (custom `ResultTabBar`) duplicates native window-tab-bar styling but isn't native

- **File**: `TablePro/Views/Results/ResultTabBar.swift:11-75`
- **Current**: A custom horizontal scrolling tab bar that visually mimics window tabs. It is for switching between multiple result sets within a single query tab — different conceptual layer than NSWindow tabs.
- **HIG says**: This is fine in principle (it's a sub-tab bar, like Xcode's "Issues / Errors / Warnings" segmented control), but the visual treatment is borrowed from window tabs which can mislead users. Consider using a `Picker(.segmented)` or NSSegmentedControl, both of which are unambiguous.
- **Native examples**: Xcode's debug tab bar uses segmented controls. Numbers/Pages chapter switches use a thinner accent bar.
- **Fix**: Either re-style with `Picker(.segmented)` style or accept a thinner pill design without rounded-rectangle backgrounds. Differentiate from NSWindow tabs.
- **Effort**: M

### [P1] No "New Window" or "Open in New Window" affordance — only "New Tab"

- **File**: `TableProApp.swift:204-228` (only "New Tab"), `WindowManager.swift:23-85`
- **Current**: Cmd+T → New Tab. There's no Cmd+N or any other shortcut for "open this connection in a new window separate from the current tab group". Combined with the auto-grouping logic in WindowManager, every connection-open ends up tabbed into an existing group.
- **HIG says**: Apps that support window tabs should also expose "New Window" — Cmd+N is conventional.
- **Native examples**: Safari (Cmd+N new window, Cmd+T new tab), Notes, Finder, Mail.
- **Fix**: Decide based on the multi-window-per-connection decision (see P0 above). If multi-window is allowed, expose Cmd+N as "New Window" (open the same connection without joining the existing tab group) — implementation: temporarily set `tabbingMode = .disallowed` for the new window. If single-window-per-connection is enforced, this finding becomes obsolete.
- **Effort**: M

---

## P2 — Polish

### [P2] DatabaseSwitcherSheet `current` badge uses lowercase string literal "current" — not localized, capitalization off

- **File**: `TablePro/Views/DatabaseSwitcher/DatabaseSwitcherSheet.swift:236`
- **Current**: `Text("current")` — lowercase, in English only.
- **HIG says**: Localized, sentence-case for non-title text.
- **Fix**: `Text(String(localized: "Current"))`.
- **Effort**: S

### [P2] FavoriteEditDialog "Save" / "Add" buttons need consistent verb

- **File**: `TablePro/Views/Sidebar/FavoriteEditDialog.swift:124`
- **Current**: Button text alternates between `"Save"` (edit) and `"Add"` (new). Other forms use "Add" or "Create" — inconsistency across the app.
- **HIG says**: Form action verbs should be consistent — pick one of "Save" / "Add" / "Create" / "Done" and use it everywhere.
- **Fix**: Use "Add" for new + "Save" for edit. Cross-check `CreateGroupSheet`, `ConnectionFormView` Save/Add buttons.
- **Effort**: S

### [P2] DataGrid drag pasteboard writer always sets `string` and `html` even for intra-grid moves

- **File**: `TablePro/Views/Results/DataGridView+RowActions.swift:175-194`
- **Current**: Every drag carries TSV and HTML on the pasteboard, even though `validateDrop` blocks anything other than `rowDrag`. Wasted serialization on every drag.
- **HIG says**: N/A — this is a perf/correctness polish.
- **Fix**: Only set TSV+HTML when the drag is going to leave the table view (i.e. always, once cross-app drop is allowed — see P1 above). Until then, only set `rowDrag`.
- **Effort**: S

### [P2] WelcomeWindowView `Frame(minWidth: 350)` on the right panel can clip column headers in narrow mode

- **File**: `TablePro/Views/Connection/WelcomeWindowView.swift:271`
- **Current**: Right panel has `minWidth: 350`. Welcome window itself has `idealWidth: 700`. With 250-px left panel, this can cramp.
- **HIG says**: Resizing should not produce clipped UI.
- **Fix**: Either set a higher `minWidth` on the right panel, or add `idealWidth: 450` plus a higher minimum window width.
- **Effort**: S

### [P2] `MCPTokenRevealSheet` is a sheet but contains lots of read-only setup info — could be a panel

- **File**: `TablePro/Views/Settings/Sections/MCPTokenRevealSheet.swift:9-41`
- **Current**: 540×520 sheet showing token + setup snippets for three clients. The "this token will not be shown again" warning is critical, but once dismissed, the user often wants to copy the token while reading docs in another app — sheet blocks that.
- **HIG says**: Information that the user might reference while doing something else should not be modal.
- **Fix**: Convert to NSPanel that floats above Settings, allowing the user to alt-tab to a terminal and copy without dismissing.
- **Effort**: M

### [P2] No I-beam cursor over the SQL editor when the editor isn't focused

- **File**: `TablePro/Views/Editor/SQLEditorView.swift` (CodeEditSourceEditor handles cursor when focused)
- **Current**: CodeEditSourceEditor sets the I-beam cursor when the text view is the first responder. Before focus, hovering shows the arrow cursor.
- **HIG says**: Text-editable areas should show the I-beam cursor on hover regardless of focus, like every native text view.
- **Native examples**: TextEdit, Mail compose, Xcode editor.
- **Fix**: Verify CodeEditSourceEditor sets `addCursorRect(_, cursor: .iBeam)` in `resetCursorRects()`. If not, override on the wrapping NSView.
- **Effort**: S to verify

### [P2] Welcome window allows zero-letter search — no clear-search affordance other than Esc

- **File**: `TablePro/Views/Connection/WelcomeWindowView.swift:212-258`
- **Current**: `NativeSearchField` (custom). No visible "x" clear button mentioned — needs verification.
- **HIG says**: Search fields show a clear button when text is present.
- **Fix**: Verify `NativeSearchField` provides the standard clear button (`(searchField.cell as? NSSearchFieldCell)?.cancelButtonCell`).
- **Effort**: S verify

### [P2] EditorWindow doesn't customize the proxy icon click behavior for unsaved files

- **File**: `TablePro/Views/Main/Extensions/MainContentView+Setup.swift:206-208`, `:239-240`
- **Current**: `representedURL` is set, `isDocumentEdited` is set — both correct. The "click and drag the proxy icon to copy" works automatically. But Cmd+Click on the proxy icon (which shows the path popup) is blocked when `titleVisibility = .hidden` (set in TabWindowController.swift:84) because there's no visible title to host the proxy icon dropdown.
- **HIG says**: Proxy icon Cmd+Click revealing the path is a long-standing macOS contract.
- **Native examples**: TextEdit, Pages, Numbers — all support proxy icon Cmd+Click.
- **Fix**: Don't set `titleVisibility = .hidden`. Instead, rely on the toolbar's principal item to display content, but keep the title strip visible so the proxy icon shows. Or implement a custom title bar that includes the proxy icon dropdown.
- **Effort**: M

### [P2] FeedbackWindowController hides miniaturize and zoom buttons

- **File**: `TablePro/Views/Feedback/FeedbackWindowController.swift:42-43`
- **Current**: Miniaturize and zoom hidden.
- **HIG says**: Feedback panels can be minimized so the user can collect screenshots and return.
- **Fix**: Show miniaturize. Zoom is fine to disable for a fixed-size panel.
- **Effort**: S

### [P2] Settings tab labels use single-word verbs ("General", "Editor", "AI") but "Integrations" is a long word — squeezes layout

- **File**: `TablePro/Views/Settings/SettingsView.swift:52-54`
- **Current**: 9 tabs in a TabView at 720 px width. With "Integrations" + "Plugins" + "Account", labels are tight.
- **HIG says**: Settings tab labels should be short. "Integrations" is fine but could be "MCP" if the only sub-feature is the MCP server (verify scope).
- **Fix**: If "Integrations" only covers MCP today, consider renaming to "MCP" or moving to a sub-page in General.
- **Effort**: S

### [P2] `JSONViewerWindowController` uses raw `NSWindow` size persistence to UserDefaults — works, but doesn't use `setFrameAutosaveName`

- **File**: `TablePro/Views/Results/JSONViewerWindowController.swift:36-71`, `:127-138`
- **Current**: Custom `UserDefaults` getter/setter for `NSSize`. Doesn't use `window.setFrameAutosaveName(...)`.
- **HIG says**: macOS provides `setFrameAutosaveName` precisely for window-frame persistence — both size and origin.
- **Fix**: Replace with `window.setFrameAutosaveName("JSONViewer")` and let AppKit handle the disk format.
- **Effort**: S

---

## Summary

| Severity | Count |
|----------|-------|
| P0 | 7 |
| P1 | 18 |
| P2 | 11 |
| **Total** | **36** |

### Highest-impact fixes (do first)

1. **Sheet-from-sheet stacking** (multiple P0/P1) — refactor Export, Import, DatabaseSwitcher, ConnectionForm to use inline state or NavigationStack push instead of nested sheets. This is the single biggest user-visible departure from native pattern.
2. **QuickSwitcher → panel** — standalone panel anchored above the key window, dismissed on focus loss. Add Cmd+1...Cmd+9 quick-jump.
3. **Window menu completeness** — add "Show All Tabs (Cmd+Shift+\\)", "Move Tab to New Window", "Merge All Windows".
4. **Cmd+W behavior** — fix the inverted single-tab close logic so Cmd+W never produces an empty window.
5. **Drag-out from data grid** — drop the same-table-only check, write TSV/HTML so rows can be dropped into Numbers/Excel.
6. **Multi-window-per-connection decision** — pick TablePlus model (single window) or Pages model (multi-window first-class) and enforce.
7. **Destructive button conventions** — set `hasDestructiveAction = true` everywhere, default Cancel for destructive prompts, remove `.defaultAction` Return shortcut from Drop / Truncate / Vacuum.
8. **License activation as a panel** — six call sites today, all stacking sheets. One panel, six triggers.

### Cross-cutting refactors (do these as a group)

- Sheet sizing: every sheet that contains a TextEditor or long form needs `minWidth/idealWidth/maxWidth` and `minHeight/maxHeight` so the user can resize.
- Backspace vs forward Delete: audit every `.onKeyPress(.delete)` site and replace with the `\u{7F}\u{08}` characters set already used in WelcomeWindowView.
- Drag-and-drop: every "Open" / "Import" surface should also be a drop target.
- Standard window-button visibility: WelcomeWindow, ConnectionForm, FeedbackWindow all hide miniaturize without good reason — re-enable.
