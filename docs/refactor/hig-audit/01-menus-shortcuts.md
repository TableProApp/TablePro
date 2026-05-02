# HIG Audit: Menus & Keyboard Shortcuts

Audit of `TablePro/` against Apple's macOS Human Interface Guidelines for menu
structure, menu wording, command placement, and keyboard shortcut semantics.

Source of truth audited:

- `TablePro/Models/UI/KeyboardShortcutModels.swift` (`KeyboardSettings.defaultShortcuts`)
- `TablePro/TableProApp.swift` (`AppMenuCommands`, `PasteboardCommands`)
- Context menus in `TablePro/Views/**`
- AppKit menus in `TablePro/Views/Results/TableRowViewWithMenu.swift`,
  `TablePro/Views/Editor/AIEditorContextMenu.swift`,
  `TablePro/Views/Terminal/TerminalTabContentView.swift`

The pre-existing finding for `Cmd+N` -> "Manage Connections" is intentionally
excluded; everything else below is new.

---

## P0 — Broken native contracts

### [P0] `Cmd+Option+Delete` is the system shortcut for "Empty Trash"

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:493`
- **Current**: `.truncateTable: KeyCombo(key: "delete", option: true, isSpecialKey: true)` (no Cmd modifier; raw `Option+Delete`).
- **HIG says**: `Option+Delete` (without Command) deletes the previous word in any text field. `Shift+Cmd+Delete` is "Empty Trash" in Finder. Bare modified-Delete combinations on table data are dangerous because the same chord may be interpreted as a destructive Finder action when focus is ambiguous, and `Option+Delete` already has a meaning in any text field that takes focus inside the data grid.
- **Native examples**: Finder "Empty Trash" `Shift+Cmd+Delete`; `Option+Delete` deletes-word in TextEdit, Mail, Notes, Safari URL bar.
- **Fix**: Drop a default shortcut entirely for `truncateTable`. Truncating an entire table is a rare, destructive, multi-step operation; it should require an explicit menu pick or context menu and a confirmation sheet. If a default is desired, scope it to data-grid focus only and pick a non-text-mutating chord (e.g. `Cmd+Backspace` only when the sidebar/data grid is first responder).
- **Effort**: S

### [P0] `Cmd+L` collides with the system "address bar" semantic and Apple's text-list shortcut

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:512`
- **Current**: `.aiExplainQuery: KeyCombo(key: "l", command: true)`. Bare `Cmd+L` triggers an AI feature that isn't even visible in the toolbar by default.
- **HIG says**: `Cmd+L` is the macOS "Open Location" / address-bar / link-to convention (Safari, Chrome, Mail "Add Link", Messages "Add Link", any Finder window with "Go to Folder" via `Cmd+Shift+G`). Allocating `Cmd+L` to an AI explanation is surprising and steals a system-typical chord.
- **Native examples**: Safari, Chrome, Firefox -> focus URL bar. Notes / Mail -> add link. Pages -> "Show/Hide List Format Inspector".
- **Fix**: Move AI to the standard "Writing Tools" / "Smart" cluster: `Cmd+Ctrl+E` or `Cmd+Shift+A` (DataGrip uses `Cmd+Shift+A` for "Find Action"; Xcode reserves `Cmd+Shift+A` for "Action") - or, since AI features already live behind a settings toggle, ship without a default shortcut and let users assign one in Settings -> Keyboard.
- **Effort**: S

### [P0] `Cmd+D` is mapped to "Save as Favorite", inverting the macOS "Duplicate" convention

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:495` (`.saveAsFavorite`), `TablePro/Models/UI/KeyboardShortcutModels.swift:492` (`.duplicateRow`).
- **Current**: `Cmd+D` -> Save as Favorite. `Cmd+Shift+D` -> Duplicate Row.
- **HIG says**: `Cmd+D` is the standard "Duplicate" chord across Finder, Pages, Numbers, Keynote, Photos, and the AppKit responder chain (`duplicate:`). `Cmd+Shift+D` has no fixed Apple meaning, but Mail uses it for "Send Again" and Safari for "Add Bookmark to Favorites". Putting Duplicate behind Shift inverts user muscle memory and competes with macOS's own bookmarking chord on `Cmd+D`.
- **Native examples**: Finder "Duplicate" `Cmd+D`; Pages/Keynote/Numbers "Duplicate Selection" `Cmd+D`; Photos "Duplicate" `Cmd+D`.
- **Fix**: Bind `Cmd+D` to `.duplicateRow`. Move `.saveAsFavorite` to `Cmd+Shift+D` (matches Safari "Add to Favorites") or to a non-conflicting modifier such as `Cmd+Option+S`.
- **Effort**: S

### [P0] `Cmd+Y` is reserved by macOS for Quick Look

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:501`
- **Current**: `.toggleHistory: KeyCombo(key: "y", command: true)` (bare `Cmd+Y`).
- **HIG says**: `Cmd+Y` is the system Quick Look shortcut (Finder, Mail, Messages). Apple also uses `Cmd+Y` for "Show History" in Safari, but that is a window-opening action, not a sidebar toggle. Either way, the bare `Cmd+Y` chord is owned by Finder Quick Look, and shadowing it with a panel toggle is non-idiomatic.
- **Native examples**: Finder/Mail/Messages -> Quick Look. Safari -> Show History (full window, not a side panel).
- **Fix**: Move history-panel toggle to a chord consistent with the other side-panel toggles in the app: e.g. `Cmd+Option+H` (mirrors `Cmd+Option+I` for Inspector) or `Cmd+Shift+H` (note: macOS reserves `Cmd+Shift+H` for "Go Home" in Finder, so prefer `Cmd+Option+H`).
- **Effort**: S

### [P0] `Cmd+Shift+E` overlaps with Mail's "Send Later" / Notes' "Show All Tags" but more importantly inverts the menu-vs-shortcut hierarchy

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:473` (`.export`), `TablePro/Models/UI/KeyboardShortcutModels.swift:471` (`.explainQuery`).
- **Current**: `.export` = `Cmd+Shift+E`, `.explainQuery` = `Cmd+Option+E`. Both `Cmd+Shift+E` and `Cmd+Option+E` are non-standard chords and both share the `e` key, leading to conflicts when users are scanning a Query menu.
- **HIG says**: Apple does not reserve `Cmd+E` for Export; its meaning across apps is "Use Selection for Find" (`findFromSelection:`). Shift/Option variants of `Cmd+E` do not have Apple-mandated meanings, but stacking two near-identical `e` chords on different actions in adjacent menus violates "Avoid Modifier Combinations That Are Hard to Remember" (HIG: Keyboard).
- **Native examples**: Numbers "Export to..." has no default keyboard shortcut. Pages "Export to..." has no default keyboard shortcut. Xcode "Export..." has no default keyboard shortcut. Apps that bind Export typically use `Cmd+Shift+E` (VS Code) but never alongside another `e` chord.
- **Fix**: Drop the default shortcut for `.explainQuery` (it lives behind a menu item and is rarely used by keyboard). Keep `Cmd+Shift+E` for Export only.
- **Effort**: S

### [P0] `Cmd+R` for "Refresh" is in the Query menu, not the View menu

- **File**: `TablePro/TableProApp.swift:344-348` (Refresh button is inside `CommandMenu("Query")`).
- **Current**: Refresh sits in the Query menu next to Execute / Format / Cancel.
- **HIG says**: `Cmd+R` is universally a refresh/reload action and the menu placement convention is the View menu (Safari "Reload Page", Mail "Get New Mail", Finder "Refresh") or the Window menu (older apps). Putting it in Query implies the action only refreshes the query, when it actually fires the global `.refreshData` notification (sidebar + coordinator + structure view) and reloads the selected table.
- **Native examples**: Safari View > Reload Page `Cmd+R`. Mail Mailbox > Get New Mail `Cmd+Shift+N` (but `Cmd+R` reloads). Xcode View > Reload `Cmd+Shift+H`.
- **Fix**: Move "Refresh" into the View menu. Optionally add a separate "Re-run Query" item in the Query menu if desired (but `.executeQuery` already covers that).
- **Effort**: S

### [P0] "Switch Connection..." and "Quick Switcher..." are in the Query menu

- **File**: `TablePro/TableProApp.swift:386-390` (Switch Connection in Query), `TablePro/TableProApp.swift:350-354` (Quick Switcher in Query).
- **Current**: Both connection-level navigation actions are in the Query command menu.
- **HIG says**: The Query menu's purpose is operations on the current query/result. Switching the active connection or jumping to another table is a File-menu or Window-menu concern. Apple HIG: "Group menu items by the kind of action they perform."
- **Native examples**: TablePlus "Switch Connection..." in File menu. Sequel Ace "Choose Connection..." in File menu. DataGrip "Open Recent" in File menu.
- **Fix**: Move "Switch Connection..." to File. Move "Quick Switcher..." to File (or keep as Window-menu "Show Tab Bar" style action). Cmd+K and Cmd+Shift+O semantics also drift toward "open something" rather than "do something with this query".
- **Effort**: S

### [P0] "Open Database..." (`Cmd+K`) collides with Finder's "Connect to Server..."

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:463` (`.openDatabase`).
- **Current**: `Cmd+K` opens the database switcher (the panel that lets you pick which database/schema this connection should target).
- **HIG says**: `Cmd+K` in macOS is "Connect to Server" in Finder, "Add Link" in mail/notes, "Clear Screen" in Terminal. It is not a "switch context within the current connection" chord. Furthermore, "Open Database" reads like an action that opens a `.sqlite` file - which would conflict with `.openFile` (`Cmd+O`).
- **Native examples**: Xcode `Cmd+Shift+O` "Open Quickly". TablePlus "Switch Database" `Cmd+K` (TablePlus has the same problem). DataGrip "Switch Database" no default chord.
- **Fix**: Rename the menu item to "Switch Database..." (it is not opening anything). Move the chord to `Cmd+Shift+K` or unbind by default. `Cmd+K` is also the de-facto chord for the AI "Command Palette" pattern in modern editors (Cursor, Continue) - consider that too.
- **Effort**: S

### [P0] "Open File..." labeled and shortcut-mapped as a generic file open, but it is SQL-only

- **File**: `TablePro/TableProApp.swift:222-226`, `TablePro/Models/UI/KeyboardShortcutModels.swift:464`.
- **Current**: Menu item "Open File..." with `Cmd+O` calls `actions?.openSQLFile()`.
- **HIG says**: `Cmd+O` is the standard Open File chord and users expect a generic `NSOpenPanel` that accepts "everything this app can read". TablePro can also open `.sqlite`/`.duckdb` database files (per the registered UTIs), and connection import files (`.tablepro`). The single "Open File..." entry only handles SQL. This violates HIG "Make a menu item's behavior match its name".
- **Native examples**: TextEdit, Pages, Xcode -> Open File dialog supports all known doc types. Finder Open With -> uses UTIs.
- **Fix**: Either rename to "Open SQL File..." (clearer scope) or expand the Open dialog to accept SQL + import + standalone database files and route appropriately in the openHandler.
- **Effort**: M

### [P0] "Toggle Sidebar" / "Toggle Inspector" / "Toggle Filters" / "Toggle History" / "Toggle Results" use static "Toggle" labels

- **File**: `TablePro/TableProApp.swift:461,466,474,480,488` (View menu).
- **Current**: All five menu items are statically labeled "Toggle X". The label never changes when the panel is open vs closed.
- **HIG says**: "Use accurate, descriptive titles for menu items. ... When a menu item toggles between two states, change the title to reflect the action it will perform." (Apple HIG: Menus -> Use Toggle Items Sparingly.) Apple's own apps use "Show Sidebar" / "Hide Sidebar".
- **Native examples**: Finder "Show Sidebar" / "Hide Sidebar" (`Cmd+Ctrl+S`). Mail "Show Mailbox List" / "Hide Mailbox List". Xcode "Show Navigator" / "Hide Navigator". Notes "Show Folders" / "Hide Folders".
- **Fix**: Read the panel state at menu build time and switch labels: `splitViewController.isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar"`, etc. Same for inspector/filters/history/results.
- **Effort**: M (state has to be observable from the menu builder; `@FocusedValue` already provides the actions object - extend it with `isFilterPanelVisible`, `isInspectorVisible`, ...).

### [P0] `Cmd+Ctrl+C` for "Switch Connection" is reserved by macOS for the Color Picker

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:465`
- **Current**: `.switchConnection: KeyCombo(key: "c", command: true, control: true)`.
- **HIG says**: `Cmd+Ctrl+C` is the system-wide Color Picker shortcut on macOS (NSColorPanel's pickup tool); it also clashes with VoiceOver `Cmd+Ctrl+C` "Read All". Reusing it is an accessibility regression.
- **Native examples**: Apple Color Picker, VoiceOver.
- **Fix**: Drop the default. Leave switching to the menu item (the user can rebind in Settings -> Keyboard if they want a chord). If a default is needed, prefer `Cmd+Shift+C` (note Mail uses `Cmd+Shift+C` for "Reply with iMessage" but TablePro is not in Mail's contention space).
- **Effort**: S

### [P0] `Cmd+Ctrl+`` for "Open Terminal" is non-standard and ambiguous with Cmd+`` (window cycling)

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:476`.
- **Current**: `.openTerminal: KeyCombo(key: "`", command: true, control: true)`.
- **HIG says**: `Cmd+`` is the macOS window-cycling chord for the same app (already in `KeyCombo.systemReserved`). Adding `Ctrl` produces a chord that is genuinely free, but the convention for "Show Terminal" in IDEs is `Cmd+Option+T` (DataGrip), `Cmd+`` (VS Code, conflicts with system), or `Ctrl+`` (Xcode does not have a built-in terminal).
- **Native examples**: VS Code `Ctrl+`` (without Cmd) toggles terminal. JetBrains `Cmd+Option+0` shows the Terminal tool window. Xcode opens external Terminal.
- **Fix**: Either drop the default chord, or move to `Cmd+Option+T` (matches DataGrip) which has no built-in macOS conflict. Keep the menu item under "View" only if the terminal is a panel; if it opens a separate window, move it to File ("Open Terminal Window").
- **Effort**: S

### [P0] No "New Window" (`Cmd+N`) anywhere in the menu

- **File**: `TablePro/TableProApp.swift:197-202` (already-known finding for the wrong `Cmd+N` mapping).
- **Current**: `CommandGroup(replacing: .newItem)` removes SwiftUI's default New Window entry entirely. There is no replacement; users have no way to spawn a fresh main window.
- **HIG says**: HIG Window Menu / File Menu both call out "New Window" as a standard, app-level action. Document-based apps must support `Cmd+N`. TablePro is not formally document-based, but the connection-tabbed window is its document analogue.
- **Native examples**: Safari File > New Window `Cmd+N`. Mail File > New Viewer Window `Cmd+Option+N`. Xcode File > New > Window `Cmd+Ctrl+N`.
- **Fix**: Add an explicit "New Main Window" entry (e.g. `Cmd+Ctrl+N`) that opens a new `TabWindowController` for the most-recently-active connection. Or repurpose the to-be-renamed `Cmd+N` ("New Connection") and add `Cmd+Shift+N` for "New Window".
- **Effort**: M

---

## P1 — Non-idiomatic placement, modifier conventions, label problems

### [P1] "GitHub Repository" wording is inconsistent with the rest of the Help menu

- **File**: `TablePro/TableProApp.swift:594`.
- **Current**: Help menu has "TablePro Website", "Documentation", and then "GitHub Repository".
- **HIG says**: Help-menu entries should describe the user-visible result, not the technical artifact. "Repository" is a Git concept; users expect a verb-noun or noun phrase like "TablePro on GitHub" / "Source Code on GitHub".
- **Native examples**: Notion Help menu "Visit Notion", Linear "Linear on GitHub". Native apps rarely link to GitHub but follow noun-phrase patterns (Mail "About Mail Filtering").
- **Fix**: Rename to "TablePro on GitHub" or "Source Code on GitHub".
- **Effort**: S

### [P1] Help menu omits the standard "TablePro Help" item

- **File**: `TablePro/TableProApp.swift:583-603` (`CommandGroup(replacing: .help)`).
- **Current**: Replaces the entire Help menu with website / documentation / GitHub / report-issue.
- **HIG says**: Apple HIG (Help menu): "Provide a Help menu and a Help command, and use the standard Help title (App Name Help)." The standard menu item should be "TablePro Help" pointing at help content (in this case: docs.tablepro.app). The Help search field is preserved automatically.
- **Native examples**: Mail "Mail Help", Safari "Safari Help", Notes "Notes Help". All point to Apple-hosted help books or web docs.
- **Fix**: Keep the existing items but rename "Documentation" to "TablePro Help" and place it first, as the canonical Help entry. The search field will continue to work.
- **Effort**: S

### [P1] "Save As..." chord (`Cmd+Shift+S`) without the Apple-recommended hidden default of "Duplicate"

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:467`, `TablePro/TableProApp.swift:242-246`.
- **Current**: `Cmd+Shift+S` invokes "Save As...".
- **HIG says**: Since macOS 10.7 Apple recommends `Cmd+Shift+S` = "Duplicate" by default and reveals "Save As..." only when the user holds `Option` (Pages, Numbers, Keynote, TextEdit). Document-based apps follow this. TablePro's `.saveFileAs()` is closer to a Pages "Save As" so this is borderline-acceptable, but worth noting.
- **Native examples**: Pages, Numbers, Keynote, TextEdit, Preview - all show "Duplicate" by default and toggle to "Save As..." on Option.
- **Fix**: Hold for now (TablePro is not document-based and "Duplicate" doesn't map to anything sensible). If TablePro ever adds a true SQL-document mode, revisit.
- **Effort**: M (defer)

### [P1] "Refresh" sits in the Query menu but uses the View menu chord

- **File**: `TablePro/TableProApp.swift:344-348`.
- **Current**: Refresh in Query menu, `Cmd+R`.
- **HIG says**: See P0 above for placement; chord is correct. Same fix moves both.
- **Effort**: S (combined with the P0 above)

### [P1] "Cancel Query" (Cmd+.) is correct but lacks ellipsis-or-not consistency

- **File**: `TablePro/TableProApp.swift:338-342`.
- **Current**: "Cancel Query" - no ellipsis (correct, it acts immediately).
- **HIG says**: Cancel actions never take ellipsis. Already correct.
- **Note**: Just confirming. No change.

### [P1] Top-level "Query" menu name overlaps with another database client convention

- **File**: `TablePro/TableProApp.swift:296` (`CommandMenu("Query")`).
- **Current**: Top-level menu is named "Query", containing Execute / Explain / Format / Refresh / Quick Switcher / Switch Connection / Save as Favorite / AI / Preview FK.
- **HIG says**: Custom menus are allowed but should be tightly scoped. Today the Query menu is a grab-bag of unrelated actions (FK preview, AI, connection switching, refresh). HIG: "Limit the scope of each menu so that it contains related items only."
- **Native examples**: TablePlus uses two menus: "Connection" and "Query". DataGrip uses "Database" and "Code".
- **Fix**: Split into two menus: "Database" (Switch Connection, Switch Database, Refresh, Quick Switcher, Server Dashboard) and "Query" (Execute, Execute All, Explain, Format, Cancel, Preview SQL, AI, Preview FK).
- **Effort**: M

### [P1] AI commands placed at the bottom of "Query" with no visual section header

- **File**: `TablePro/TableProApp.swift:366-376`.
- **Current**: `Divider()` + two AI buttons inside Query.
- **HIG says**: When a feature cluster (AI) is conditionally available (settings flag), Apple typically places it under its own submenu or hides it entirely when off. Right now AI menu items remain enabled but call into a feature that can be off, leaking surface area.
- **Native examples**: Apple Intelligence "Writing Tools" submenu in Mail, Notes (single "Writing Tools..." entry).
- **Fix**: Group AI under a `Menu("AI")` submenu in Query. Also disable when `AppSettingsManager.shared.ai.enabled == false`.
- **Effort**: S

### [P1] Edit menu lacks a Find submenu structure

- **File**: `TablePro/TableProApp.swift:430-433`.
- **Current**: Single "Find..." item, `Cmd+F`. No "Find Next" / "Find Previous" / "Use Selection for Find" / "Replace...".
- **HIG says**: Apple's standard Find submenu in TextEdit / Mail / Pages contains: Find..., Find Next, Find Previous, Use Selection for Find, Jump to Selection. The Edit menu lays them out as a `Menu("Find")` submenu or in the dedicated Find category.
- **Native examples**: TextEdit Edit > Find submenu. Mail Edit > Find submenu. Xcode Find menu (separate top-level).
- **Fix**: Add Edit > Find submenu with Find / Find Next (`Cmd+G`) / Find Previous (`Cmd+Shift+G`) / Use Selection for Find (`Cmd+E`) / Jump to Selection (`Cmd+J`). Most are already supported by the underlying CodeEditTextView - only need menu items routing through `findFromSelection:` etc.
- **Effort**: M

### [P1] Edit menu lacks Spelling / Substitutions submenus

- **File**: `TablePro/TableProApp.swift` (Edit menu).
- **Current**: No Spelling and Grammar submenu. SwiftUI's `CommandGroup(replacing: .pasteboard)` removes the entire pasteboard cluster and rebuilds it; the Spelling submenu lives outside that group and would be auto-included, but TablePro overrides too aggressively (see next finding). Verify behavior.
- **HIG says**: The Edit menu standard order is: Undo/Redo, Cut/Copy/Paste/Delete/Select All, Find, Spelling and Grammar, Substitutions, Speech, AutoFill. Most are auto-injected by SwiftUI when you don't replace the relevant CommandGroups.
- **Native examples**: TextEdit, Mail, Notes - all show Spelling, Substitutions, Speech.
- **Fix**: Verify which default CommandGroups are still applied. If Spelling is missing in the SQL editor (where it makes sense for comments), add it.
- **Effort**: S

### [P1] "Increase Text Size" / "Decrease Text Size" wording

- **File**: `TablePro/TableProApp.swift:532-540`.
- **Current**: "Increase Text Size" `Cmd+=` / "Decrease Text Size" `Cmd+-`.
- **HIG says**: Apple's standard wording is "Make Text Bigger" / "Make Text Smaller" (Mail, Safari, Messages, Notes). "Increase/Decrease" is engineering-speak.
- **Native examples**: Safari View > Zoom In `Cmd++` / Zoom Out `Cmd+-`. Mail Format > Style > Bigger `Cmd++`. Notes "Make Text Bigger" `Cmd++`.
- **Fix**: Rename to "Bigger" / "Smaller" or "Zoom In" / "Zoom Out". Also add an "Actual Size" `Cmd+0` ... but `Cmd+0` is taken by `.toggleTableBrowser` (see P2).
- **Effort**: S

### [P1] `Cmd+0` (`.toggleTableBrowser`) overlaps with the universal "Actual Size" convention

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:498`.
- **Current**: `Cmd+0` toggles the sidebar.
- **HIG says**: `Cmd+0` is "Actual Size" in Safari, Preview, Photos. Xcode does use `Cmd+0` for "Show Navigator", which gives TablePro precedent, but mixing the two conventions is confusing in an app that also has zoom shortcuts.
- **Native examples**: Xcode `Cmd+0` Show Navigator (matches TablePro). Safari/Preview/Photos `Cmd+0` Actual Size.
- **Fix**: Match Apple's HIG default for sidebars: `Cmd+Ctrl+S` (Finder, Mail). Free up `Cmd+0` for a future "Actual Size" / "Reset Zoom" if the editor zoom is added.
- **Effort**: S

### [P1] `Cmd+Shift+F` (`.toggleFilters`) collides with IDE "Find in Project"

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:500`.
- **Current**: `Cmd+Shift+F` toggles the filter panel.
- **HIG says**: `Cmd+Shift+F` is "Find in Project / All Files" in every IDE (Xcode, VS Code, JetBrains, Sublime). TablePro does not have a global find, but using this chord for a panel toggle wastes the slot.
- **Native examples**: Xcode "Find in Project" `Cmd+Shift+F`. VS Code "Find in Files" `Cmd+Shift+F`.
- **Fix**: Move filter-panel toggle to `Cmd+Option+F` (matches the other Option-modified panel toggles like `Cmd+Option+I` for Inspector).
- **Effort**: S

### [P1] "New Tab" (`Cmd+T`) opens a query tab but does not clarify that

- **File**: `TablePro/TableProApp.swift:205-208`, `TablePro/Models/UI/KeyboardShortcutModels.swift:462`.
- **Current**: "New Tab" `Cmd+T` calls `actions?.newTab()`.
- **HIG says**: HIG: "Be clear about what tabs are." `Cmd+T` is universally "new tab in this window" (Safari, Terminal, Finder, Xcode). TablePro's tab is a query-editor tab. Label should be "New Query Tab" if a future "New Connection Tab" is conceivable.
- **Native examples**: Safari "New Tab" - one tab type. Xcode "New Tab" - one tab type. Terminal "New Tab" - one tab type.
- **Fix**: Hold. Acceptable as-is.

### [P1] "Save Changes" wording

- **File**: `TablePro/TableProApp.swift:230-233`.
- **Current**: Menu item "Save Changes" `Cmd+S`.
- **HIG says**: Apple's File menu standard label is "Save" - never "Save Changes". The "Changes" suffix is implied by the verb. HIG: "Use short, simple verbs."
- **Native examples**: TextEdit, Pages, Xcode - all say "Save".
- **Fix**: Rename menu item to "Save". (The action's `displayName` in `KeyboardShortcutModels.swift:128` can stay "Save Changes" if the settings UI explicitly differentiates from Save File - but the menu label should match Apple's.)
- **Effort**: S

### [P1] "Manage Connections" should follow `New X` ellipsis convention

- **File**: `TablePro/TableProApp.swift:198`.
- **Current**: "Manage Connections" with no ellipsis. Already known the chord is wrong; separately the wording lacks an ellipsis even though the action opens a separate window (the Welcome window).
- **HIG says**: HIG: "Append an ellipsis to the title of any menu item that requires further input from the person before the action takes place." Opening a separate window for management is a borderline case - some Apple apps use ellipsis, some don't. The rule of thumb: if the user has to do anything in the new window before something happens, add ellipsis.
- **Native examples**: System Settings > Network "Manage Locations..." (ellipsis). Mail "Manage Mailboxes..." (ellipsis).
- **Fix**: When this is renamed to "New Connection..." per the existing finding, the ellipsis is correct.
- **Effort**: S (folded into existing finding)

### [P1] "Quick Switcher..." in `KeyboardShortcutModels` displayName is fine, but the menu label should specify what is being switched

- **File**: `TablePro/TableProApp.swift:350`.
- **Current**: "Quick Switcher..." `Cmd+Shift+O`.
- **HIG says**: The label is generic. Users don't know if it switches connections, tables, queries, or all of the above. HIG: "Use accurate, descriptive titles."
- **Native examples**: Xcode "Open Quickly..." `Cmd+Shift+O`. VS Code "Go to File..." `Cmd+P`.
- **Fix**: Rename to "Open Quickly..." (matches Apple/Xcode) or "Go to..." with a specific scope.
- **Effort**: S

### [P1] "Preview SQL" label is dynamic with `String(format:)` but uses placeholder for unconnected state

- **File**: `TablePro/TableProApp.swift:321-329`.
- **Current**: Shows "Preview SQL" when no connection, otherwise "Preview \(language)" (e.g. "Preview MongoDB").
- **HIG says**: Menu items should not change between connected and disconnected states except to enable/disable. The label flicker between "Preview SQL" and "Preview MongoDB" violates HIG: "Maintain stable menu item titles where possible".
- **Native examples**: Xcode menus do not change titles based on document type.
- **Fix**: Always show "Preview Statement..." or "Preview Pending Changes..." (the latter is more honest - this previews INSERT/UPDATE/DELETE for pending row edits). The current label even misleads users into thinking it previews the editor query.
- **Effort**: S

### [P1] AI menu items in editor right-click only show when text is selected, hiding the feature

- **File**: `TablePro/Views/Editor/AIEditorContextMenu.swift:75-96`.
- **Current**: `guard AppSettingsManager.shared.ai.enabled, hasSelection?() == true else { return }` - AI items disappear entirely when no selection.
- **HIG says**: HIG: "Prefer disabling a menu item to removing it." Menu items that vanish based on selection are jarring; users learn the menu's geometry by repetition.
- **Native examples**: Notes "Writing Tools" submenu always visible, individual items disable when nothing is selected.
- **Fix**: Always show the AI items, disable them when `hasSelection?() != true`.
- **Effort**: S

### [P1] Right-click on data grid row does not show a "Show in Sidebar" / "Reveal" type entry, but does show "Open <referenced table>" inconsistently

- **File**: `TablePro/Views/Results/TableRowViewWithMenu.swift:119-126` (FK navigation).
- **Current**: FK preview/navigation only appears when the column is a foreign key AND the cell has a value. Reasonable, but the sub-section appears mid-menu without a label.
- **HIG says**: Conditional sub-sections in context menus should be labeled (use a non-clickable header item or leading divider with a `Menu` submenu) when they appear/disappear based on context. HIG: "Group related items."
- **Fix**: Wrap FK actions in a `Menu("Foreign Key")` submenu, or move them under a labelled section. Otherwise the row context menu shifts visually each time.
- **Effort**: S

### [P1] Result tab right-click menu uses non-standard wording for its "Pin/Unpin" toggle but proper Show/Hide-style toggling

- **File**: `TablePro/Views/Results/ResultTabBar.swift:62-72`.
- **Current**: `Button(rs.isPinned ? String(localized: "Unpin") : String(localized: "Pin Result"))`.
- **HIG says**: Toggle wording should match: either "Pin Result" / "Unpin Result" (matched verb-noun pair) or "Pin" / "Unpin" (matched single verb). Current pair is mismatched.
- **Native examples**: Safari pinned tabs: "Pin Tab" / "Unpin Tab".
- **Fix**: "Pin Result" / "Unpin Result".
- **Effort**: S

### [P1] Sidebar context menu "Create New Table..." and "Create New View..." but File menu uses "New View..." (no Create prefix)

- **File**: `TablePro/Views/Sidebar/SidebarContextMenu.swift:59,64` vs `TablePro/TableProApp.swift:211`.
- **Current**: Sidebar context menu prefixes with "Create"; File menu omits it.
- **HIG says**: HIG: "Use consistent terminology." If the action is the same, the label should be the same.
- **Native examples**: Finder "New Folder" (no "Create"). Pages "New Document" (no "Create").
- **Fix**: Standardize on "New Table..." / "New View..." (drop "Create").
- **Effort**: S

### [P1] Welcome window context menu "Edit" lacks the noun ("Edit Connection")

- **File**: `TablePro/Views/Connection/WelcomeContextMenus.swift:97`.
- **Current**: `Label(String(localized: "Edit"), systemImage: "pencil")`.
- **HIG says**: Bare verbs in context menus are ambiguous when a row is selected. Should be "Edit Connection" so the action is unambiguous when read out by VoiceOver, or screenshotted, or skim-read.
- **Native examples**: Mail context menu "Edit Account..." not "Edit". Calendar "Edit Event" not "Edit".
- **Fix**: "Edit Connection" / "Duplicate Connection" / "Delete Connection".
- **Effort**: S

### [P1] Welcome window deletion path uses "Delete" without ellipsis but opens a confirm dialog

- **File**: `TablePro/Views/Connection/WelcomeContextMenus.swift:74-81,183-188`.
- **Current**: "Delete" / "Delete %d Connections" - no ellipsis - even though `vm.showDeleteConfirmation = true` opens a confirmation sheet.
- **HIG says**: Apple's HIG (Menus): the ellipsis indicates the user must take additional steps before the action completes. A destructive confirm dialog counts.
- **Native examples**: Finder "Move to Trash" (no ellipsis - the action is the one-step move). But "Delete Immediately..." has ellipsis because it requires confirmation.
- **Fix**: Either remove the confirmation dialog (menus already provide enough friction for simple deletes via the destructive role styling) or add ellipsis: "Delete...".
- **Effort**: S

### [P1] "Bring All to Front" duplicated between SwiftUI default and custom Window menu group

- **File**: `TablePro/TableProApp.swift:575-577`.
- **Current**: Adds a "Bring All to Front" button under `CommandGroup(after: .windowArrangement)`. SwiftUI's default Window menu already includes this.
- **HIG says**: Standard menu items must not appear twice.
- **Native examples**: Every Apple app has exactly one "Bring All to Front".
- **Fix**: Remove the manually-added "Bring All to Front" button.
- **Effort**: S

### [P1] "Cancel Query" in Query menu uses `Cmd+.` but sits below higher-frequency items

- **File**: `TablePro/TableProApp.swift:336-342`.
- **Current**: Cancel Query is below Format Query / Preview SQL.
- **HIG says**: HIG: "Order menu items by frequency or importance." Cancel is a critical, high-importance action - should sit just below Execute / Execute All.
- **Fix**: Reorder the Query menu so Execute / Execute All / Cancel cluster at the top.
- **Effort**: S

### [P1] Hardcoded Find shortcut `Cmd+F` is not customizable through `KeyboardSettings`

- **File**: `TablePro/TableProApp.swift:431-433`.
- **Current**: `.keyboardShortcut("f", modifiers: .command)` is hardcoded; `KeyboardSettings.defaultShortcuts` has no `.find` action.
- **HIG says**: Not strictly a HIG violation, but inconsistent with the rest of the menu (every other shortcut routes through `optionalKeyboardShortcut(shortcut(for:))` so users can rebind).
- **Fix**: Add `.find` to `ShortcutAction` and `defaultShortcuts`, route through the same path.
- **Effort**: S

### [P1] Hardcoded Execute / Execute All Statements / Cancel / Bigger / Smaller shortcuts are not customizable

- **File**: `TablePro/TableProApp.swift:300, 306, 341, 535, 540`.
- **Current**: `.keyboardShortcut(.return, modifiers: .command)`, `[.command, .shift]`, `Cmd+.`, `Cmd+=`, `Cmd+-` all hardcoded.
- **HIG says**: Same as above - inconsistent customization story.
- **Fix**: Add corresponding `ShortcutAction` cases (`.executeAllStatements`, `.cancelQuery`, `.makeTextBigger`, `.makeTextSmaller`) and route through `KeyboardSettings`.
- **Effort**: M

### [P1] `KeyCombo.systemReserved` list is incomplete

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:360-376`.
- **Current**: 15 reserved chords listed.
- **HIG says**: macOS reserves many more system chords for accessibility (VoiceOver `Cmd+F5`, Zoom `Cmd+Option+8`/`Cmd+Option+=`/`Cmd+Option+-`, Reduce/Increase Contrast `Cmd+Option+Ctrl+,`/`.`), Mission Control (`Ctrl+UpArrow`, etc.), Spaces (`Ctrl+LeftArrow`/`RightArrow`), and the Color Picker (`Cmd+Shift+C`).
- **Native examples**: Apple's "Keyboard Shortcuts" pane in System Settings is the authoritative list.
- **Fix**: Expand the list. At minimum add: `Cmd+F5` (VoiceOver), `Cmd+Option+8`, `Cmd+Option+Ctrl+,`/`.`, `Ctrl+UpArrow`, `Ctrl+DownArrow`, `Ctrl+LeftArrow`, `Ctrl+RightArrow`, `Cmd+Ctrl+C` (Color Picker - which is currently used by `.switchConnection`).
- **Effort**: S

### [P1] `Cmd+Option+I` for Inspector overlaps with Safari's "Show Web Inspector"

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:499`.
- **Current**: `.toggleInspector: KeyCombo(key: "i", command: true, option: true)`.
- **HIG says**: `Cmd+Option+I` is Safari Web Inspector. Most users have it bound system-wide via developer tools enable. Inside TablePro this is fine, but be aware.
- **Native examples**: Xcode "Show Inspectors" `Cmd+Option+0`. Pages "Show Inspector" `Cmd+Option+I`. So Apple's apps disagree.
- **Fix**: Hold. `Cmd+Option+I` is acceptable.

### [P1] "Truncate Table" lives in Edit menu, not in a database-specific menu

- **File**: `TablePro/TableProApp.swift:451-456`.
- **Current**: "Truncate Table" is a row in the Edit menu's row-operations cluster.
- **HIG says**: Edit menu is for Cut/Copy/Paste/Find/Undo/Redo, not destructive table-level operations. HIG: "Group menu items by the kind of action they perform."
- **Native examples**: TablePlus places destructive ops on the table in a per-table context menu, not in Edit.
- **Fix**: Remove from Edit menu, leave only in the sidebar context menu (where it already lives via `SidebarContextMenu`). Or move to a top-level "Database" menu (see Query-menu split finding).
- **Effort**: S

---

## P2 — Polish, label wording, separators, ellipses

### [P2] "Manage Connections" missing ellipsis (folded into existing rename to "New Connection...")

- See P1 entry above.

### [P2] "Open Database..." ellipsis is correct, but the action does not actually open a file - it opens an in-app sheet

- **File**: `TablePro/TableProApp.swift:216-220`.
- **Current**: "Open Database..." opens the database switcher sheet.
- **HIG says**: Ellipsis is fine because the user must pick a database.
- **Note**: Confirming. The bigger issue (label wording) is P0.

### [P2] "Documentation" (in Help menu) lacks any indication that it opens a web URL

- **File**: `TablePro/TableProApp.swift:588-590`.
- **Current**: "Documentation" with no leading icon, no trailing arrow, no ellipsis.
- **HIG says**: Apple's help-menu items that link out usually use unadorned text. No change needed; just noting that `tablepro.app` and `docs.tablepro.app` open in the browser silently. `NSWorkspace.shared.open(...)` on an `https://` URL is the correct approach.
- **Note**: No change.

### [P2] "Report an Issue..." ellipsis is correct (opens FeedbackWindowController sheet)

- **File**: `TablePro/TableProApp.swift:600-602`.
- **Note**: Already correct.

### [P2] "About TablePro" item bundled with `Check for Updates...` and `MCPServerMenuItem`

- **File**: `TablePro/TableProApp.swift:145-178`.
- **Current**: `CommandGroup(replacing: .appInfo)` puts About + Check for Updates... + Divider + MCP Status into the App menu.
- **HIG says**: App menu standard order: About App, Settings..., Services, Hide App, Hide Others, Show All, Quit App. "Check for Updates..." is a common third-party addition, placed right after About. The MCP server status item is unusual at this level - it's tool / dev-feature, and should live under Services or its own menu.
- **Native examples**: Sparkle apps: About, Check for Updates..., separator, Settings, Services... TablePro almost matches.
- **Fix**: Keep About + Check for Updates... in the App menu. Move "MCP Server Status" to a non-App-menu location (Help menu, or a new "Developer" menu).
- **Effort**: S

### [P2] "MCP Server: Running (X clients)" label changes between launches and clutters the App menu

- **File**: `TablePro/TableProApp.swift:687-712`.
- **Current**: Live-updating MCP server status item in App menu.
- **HIG says**: HIG: "Avoid showing dynamic status in menu titles."
- **Fix**: Move to a status-bar icon (NSStatusItem) or to Settings. Keep a static "Manage MCP Server..." menu entry instead.
- **Effort**: M

### [P2] "Save as Favorite" appearance in Query menu lacks ellipsis but opens a sheet

- **File**: `TablePro/TableProApp.swift:358-360`.
- **Current**: "Save as Favorite" - no ellipsis.
- **HIG says**: Action opens a sheet asking for a name. HIG mandates ellipsis.
- **Fix**: Rename to "Save as Favorite...".
- **Effort**: S

### [P2] "View ER Diagram" lacks parallel structure with "Server Dashboard"

- **File**: `TablePro/TableProApp.swift:514-522`.
- **Current**: "View ER Diagram" vs "Server Dashboard" (no verb).
- **HIG says**: Sibling menu items should follow the same grammatical pattern. Either both verb-noun or both noun.
- **Native examples**: Xcode View > Show Activity / Show Issues / Show Reports - parallel.
- **Fix**: "Show ER Diagram" / "Show Server Dashboard". Or drop "View" so both are noun-only.
- **Effort**: S

### [P2] "Open Terminal" has no ellipsis - implies an immediate action, but in some configurations it opens an SSH credential picker

- **File**: `TablePro/TableProApp.swift:524-528`.
- **Current**: "Open Terminal" - no ellipsis.
- **HIG says**: If the action takes additional input (SSH credentials, host pick), use ellipsis.
- **Fix**: Verify path. If it always opens directly, no change. If it ever requires input, add ellipsis.
- **Effort**: S

### [P2] Welcome window context-menu "Copy Connection String" / "Copy TablePro Link" / "Copy as JSON" -- inconsistent capitalization

- **File**: `TablePro/Views/Connection/WelcomeContextMenus.swift:126,134,141`.
- **Current**: "Copy Connection String", "Copy TablePro Link", "Copy as JSON".
- **HIG says**: Title case everywhere. "as" in the middle of "Copy as JSON" is HIG-correct lowercase preposition. Actually fine. The label is fine.
- **Note**: No change.

### [P2] Welcome window "iCloud Sync" toggle copy: "Include in iCloud Sync" / "Exclude from iCloud Sync"

- **File**: `TablePro/Views/Connection/WelcomeContextMenus.swift:64-67,170-176`.
- **Current**: Two distinct labels (Include / Exclude) used as a toggle.
- **HIG says**: Toggling labels is correct. But "Include in" / "Exclude from" is wordy. Simpler would be "Sync to iCloud" / "Don't Sync to iCloud" or a direct binary "Sync This Connection".
- **Fix**: Consider tightening, but acceptable.
- **Effort**: S (defer)

### [P2] Sidebar context menu mixes "Show Structure" with "View ER Diagram"

- **File**: `TablePro/Views/Sidebar/SidebarContextMenu.swift:80-89`.
- **Current**: "Show Structure" and "View ER Diagram" sit adjacent with no divider.
- **HIG says**: Show vs View - inconsistent verbs.
- **Fix**: Pick one verb. "Show Structure" / "Show ER Diagram".
- **Effort**: S

### [P2] Sidebar context menu "Create New Subgroup" lacks ellipsis but renames inline (probably correct)

- **File**: `TablePro/Views/Connection/WelcomeWindowView.swift:537-541`.
- **Current**: "New Subgroup" - inline rename in tree.
- **HIG says**: When the new entity is created and immediately ready for inline rename, no ellipsis is appropriate (Finder New Folder).
- **Note**: Correct.

### [P2] Help menu "TablePro Website" bare URL action lacks an indicator that it's external

- **File**: `TablePro/TableProApp.swift:584-586`.
- **Current**: "TablePro Website" with no symbol.
- **HIG says**: Apple's Help menu generally uses bare text for external URLs. No HIG violation.
- **Note**: No change.

### [P2] Edit > Find (`Cmd+F`) has no in-menu indicator that it routes to the editor's Find bar (vs grid search)

- **File**: `TablePro/TableProApp.swift:430-433`.
- **Current**: `EditorEventRouter.shared.showFindPanelForKeyWindow()` - editor-only.
- **HIG says**: A single Find item that only finds in one of multiple focusable views is ambiguous. Most users hitting `Cmd+F` over the data grid will expect to filter rows.
- **Fix**: Route `Cmd+F` through the responder chain (`performTextFinderAction:`) so the focused view chooses; in the data grid, that should bring up the filter panel.
- **Effort**: M

### [P2] Editor right-click "Format SQL" has no shortcut shown, even though `.formatQuery` (`Cmd+Shift+L`) is bound

- **File**: `TablePro/Views/Editor/AIEditorContextMenu.swift:53-62`.
- **Current**: `keyEquivalent: ""` - no key equivalent shown in the context menu.
- **HIG says**: Showing key equivalents in context menus helps users learn the shortcut.
- **Native examples**: Finder context menu "Get Info" shows `Cmd+I`. Mail context menu "Reply" shows `Cmd+R`.
- **Fix**: Set `keyEquivalent` and `keyEquivalentModifierMask` on the NSMenuItem.
- **Effort**: S

### [P2] Data grid row context menu "Copy" does not show `Cmd+C`, "Paste" does not show `Cmd+V`

- **File**: `TablePro/Views/Results/TableRowViewWithMenu.swift:39-99`.
- **Current**: All `keyEquivalent: ""` - no shortcuts visible in context menu.
- **HIG says**: Same as above. Useful affordance for keyboard learners.
- **Fix**: Set `keyEquivalent` for items that have a global shortcut.
- **Effort**: S

### [P2] Terminal context menu shows Copy/Paste with empty `keyEquivalent`

- **File**: `TablePro/Views/Terminal/TerminalTabContentView.swift:251-261`.
- **Current**: `keyEquivalent: ""`.
- **HIG says**: Same as above.
- **Fix**: Set `keyEquivalent`.
- **Effort**: S

### [P2] Editor right-click "Save as Favorite..." has ellipsis (correct), but "Format SQL" does not (correct - it's an immediate action). Asymmetry could confuse users

- **File**: `TablePro/Views/Editor/AIEditorContextMenu.swift:54,66`.
- **Current**: Mixed correctly.
- **Note**: Confirmed correct, no change.

### [P2] AI right-click "Explain with AI" / "Optimize with AI" no ellipsis - actions stream output to a panel

- **File**: `TablePro/Views/Editor/AIEditorContextMenu.swift:81,90`.
- **Current**: No ellipsis.
- **HIG says**: Streaming AI is closer to a chat than a dialog. No ellipsis is conventional in modern AI UIs. Borderline.
- **Note**: Hold.

### [P2] Context menu "Set Value -> NULL / Empty / Default" submenu nests deeper than necessary

- **File**: `TablePro/Views/Results/TableRowViewWithMenu.swift:135-167`.
- **Current**: Submenu with 1-3 items.
- **HIG says**: HIG: "Avoid one-item or two-item submenus."
- **Fix**: When only 1 entry would be shown (e.g. NOT NULL column with no default), inline as "Set Empty"; when 2+, keep submenu. Or always show all three with appropriate disabled states.
- **Effort**: S

### [P2] Window menu's "Select Tab N" entries (Cmd+1..9) clutter the menu

- **File**: `TablePro/TableProApp.swift:546-555`.
- **Current**: Nine permanent menu entries.
- **HIG says**: Apple's native macOS tabs auto-populate the Window menu with tab titles when `tabbingMode = .preferred`. TablePro is adding redundant tab-by-number entries.
- **Native examples**: Safari's Window menu lists tabs by title, not "Select Tab 1". Cmd+1..9 still works via `selectTab(_:)` system-wide.
- **Fix**: Remove the manual "Select Tab N" buttons. Let macOS's native tab handling fire `selectTab:` selectors. The menu becomes self-populating.
- **Effort**: S

### [P2] No "Move Tab to New Window" / "Merge All Windows" entries

- **File**: `TablePro/TableProApp.swift:544-578`.
- **Current**: Custom Window menu lacks the standard tab-management entries.
- **HIG says**: Apple's Window menu standard for tabbed apps: Show Previous Tab, Show Next Tab, Move Tab to New Window, Merge All Windows. SwiftUI / NSWindow injects most of these automatically when `tabbingMode = .preferred`. Verify presence.
- **Fix**: Verify with the running app. If missing, add via `NSWindow.moveTabToNewWindow:` and `NSWindow.mergeAllWindows:` selectors.
- **Effort**: S

### [P2] `Cmd+Shift+P` for "Preview SQL" overlaps with the macOS "Page Setup" chord in document apps

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:468`.
- **Current**: `Cmd+Shift+P`.
- **HIG says**: `Cmd+Shift+P` = "Page Setup..." in print-aware apps. TablePro doesn't print, so safe in scope, but unusual.
- **Fix**: Hold.

### [P2] `KeyCombo.cleared` sentinel value uses an empty `key` string and is conceptually fragile

- **File**: `TablePro/Models/UI/KeyboardShortcutModels.swift:519-526`.
- **Current**: Sentinel value with empty key.
- **HIG says**: Not a HIG concern, but worth flagging. A `nil` is more idiomatic.
- **Fix**: Refactor `KeyboardSettings.shortcuts` to `[String: KeyCombo?]` so the absent state is the empty/nil case.
- **Effort**: M

### [P2] Settings vs Preferences naming

- **File**: `TablePro/TableProApp.swift:634-637`.
- **Current**: SwiftUI's `Settings { ... }` scene auto-injects "Settings..." in the App menu (macOS 13+).
- **HIG says**: Correct. Apple renamed "Preferences" to "Settings" in macOS 13.
- **Note**: No change.

### [P2] Custom about panel has links separated by ` | ` — not a HIG style

- **File**: `TablePro/TableProApp.swift:159-164`.
- **Current**: Uses `"  |  "` separator between credits links.
- **HIG says**: Apple's about panels (Sparkle apps included) use separate lines or a dedicated credits view.
- **Native examples**: Most Sparkle apps put each link on its own line.
- **Fix**: Stack vertically using `\n` separators in the attributed string.
- **Effort**: S

---

## Summary

| Severity | Count | Areas covered |
| --- | --- | --- |
| **P0** | 13 | App menu, File menu, View menu, Edit menu, Query menu, key conflicts |
| **P1** | 22 | Wording, customization gaps, menu placement, label parallelism, system-reserved list |
| **P2** | 22 | Polish, ellipses, key equivalents in context menus, About panel |
| **Total** | **57** | |

By area:

| Area | P0 | P1 | P2 |
| --- | --- | --- | --- |
| App menu | 0 | 0 | 3 |
| File menu | 5 | 4 | 1 |
| Edit menu | 1 | 4 | 4 |
| View menu | 4 | 3 | 1 |
| Query menu | 2 | 5 | 3 |
| Window menu | 1 | 1 | 2 |
| Help menu | 0 | 2 | 1 |
| Keyboard defaults (`KeyboardShortcutModels.swift`) | 6 | 6 | 1 |
| Context menus (welcome, sidebar, data grid, editor, terminal, results, history) | 0 | 5 | 6 |
| Cross-cutting (settings infrastructure, sentinel) | 0 | 2 | 2 |

Top-priority fixes (suggest doing first):

1. Rebind `Cmd+D` to Duplicate (move Save as Favorite to Cmd+Shift+D).
2. Drop the `Cmd+Y` mapping (Quick Look conflict).
3. Drop the `Cmd+Option+Delete` mapping (Empty Trash conflict).
4. Drop the `Cmd+Ctrl+C` mapping (Color Picker conflict).
5. Drop the `Cmd+L` mapping (URL bar conflict; it also collides with `Cmd+Shift+L = Format Query`).
6. Move Refresh, Switch Connection, Quick Switcher out of the Query menu.
7. Toggle Sidebar / Inspector / Filters / History / Results: switch labels Show/Hide.
8. Re-add a real "New Window" item with a non-`Cmd+N` shortcut.
9. Fix label parallelism: "Save Changes" -> "Save", "Toggle X" -> "Show/Hide X", "View ER Diagram" / "Server Dashboard" parallel.
10. Add Find submenu (Find, Find Next, Find Previous, Use Selection for Find).
