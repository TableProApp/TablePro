# 0004: The app shell: one window, a rail of connections, a page per surface

- **Status**: Accepted; packaging amended by [0005](0005-distribution.md)
- **Date**: 2026-11-02

## Context

The Windows app needs its window, navigation, the Connections page, the connection form, Settings, session restore and a workspace per connection, before the data grid (0003) is wired in. The maintainer fixed the shape on 2026-11-02: one window; a NavigationView rail with the Connections page, one item per open connection and Settings, hidden until a connection opens; a tab strip per connection, as on macOS; a MenuBar plus a CommandBar per tab; Settings as a page; launch reopens the previous session and connects only the front connection; Get started cards on first run; the connection form in its own owned, non-modal window; a TreeView object tree that pages huge folders; MSIX per user for Windows 10 1809 and later on x64 and Arm64. Every control is stock WinUI or the Windows Community Toolkit's settings controls, used as the Fluent guidance describes.

On 2026-11-03 the maintainer settled four more:

- A rail item's icon takes the connection's colour, since its `InfoBadge` shows the connecting state.
- The results pane hands the grid a new set once that set has its first rows.
- The engine artwork is the macOS app's.
- The Toolkit's `GridSplitter` (Sizers) resizes the object pane.

On 2026-11-04 the roadmap added a page size picker and Go to page to the table pager, as macOS has them, and tab tear-out through TabView's own events.

## Decision

`src/TablePro.App` is one `MainWindow` with the WinUI `TitleBar`, a `MenuBar` under it and a `NavigationView` in `LeftCompact` whose content is a page object kept per surface: `HomeView`, `SettingsView` and a `WorkspaceView` per open connection. A tab moved out of it goes to a tab window, a `MainWindow` for that one connection (Tab windows, below). The core keeps the saved connections and their secrets; the app keeps its settings and its session in two JSON files in the package's LocalState folder.

## Design

### Window and navigation

- `ExtendsContentIntoTitleBar` with `SetTitleBar` on the `TitleBar` control, which also holds the rail's pane toggle and a back button, as the title bar page shows for NavigationView ([Title bar](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/title-bar)). The subtitle names the front connection.
- The rail is `IsPaneVisible="False"` until the first connection opens. While it is hidden, Settings is reached from a button on the Connections page or File > Settings, and the title bar's back button returns.
- Pages are swapped as `NavigationView.Content`, not navigated in a Frame, so a workspace keeps its tabs, editors and tree when another rail item is selected.
- The window opens at 1280 by 820 effective pixels, scaled by `GetDpiForWindow` and clamped to the display's work area; `AppWindow` takes physical pixels ([Windowing overview](https://learn.microsoft.com/en-us/windows/apps/develop/ui/windowing-overview)).
- Later launches put it back where it stood. `AppWindow` reports a maximized window's maximized bounds, so the window keeps what `GetWindowPlacement` says: the bounds it restores to and whether it was maximized. They go back with `SetWindowPlacement` while the window is still hidden, which also moves bounds that would land on a display no longer there, and a maximized window is maximized once shown. This happens whether or not the session reopens its connections.
- `MicaBackdrop` when `MicaController.IsSupported()`; otherwise no backdrop and the theme's solid background, which is what Windows 10 gets.
- App theme: Light, Dark or Use system setting. The root's `RequestedTheme` takes it, and `AppWindowTitleBar.PreferredTheme` keeps the caption buttons in step.

### Tab windows

- A workspace tab leaves the window by dragging it out of the strip or by Move to new window, in the tab's context menu and the File menu, as a macOS window tab moves to a new window. TabView's tear-out does the drag ([Tab view](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/tab-view), Tab tear-out): `CanTearOutTabs` with `TabTearOutWindowRequested`, `TabTearOutRequested`, `ExternalTornOutTabsDropping` and `ExternalTornOutTabsDropped`, all in Windows App SDK 2.6.4.
- The window a tab goes to is a `MainWindow` for that one connection: its title bar names the connection, its window title is "name - TablePro", it has the menu bar and the workspace and no rail. The Connections page, Settings, the connection form, Exit and the file pickers are the primary window's, so a tab window hands those commands to it. Disconnect closes the tab window.
- A tab keeps the session it was opened on wherever it goes: each workspace and each tab holds the session (`SessionShare`), and the last to let go disposes it. A tab therefore joins any workspace of its connection, in any window, after a relaunch too.
- A tab is dropped only into a workspace of its own connection, never into a window kept hidden for a drag, and never from the primary window when it is that window's last tab: TabView drags the whole window when its strip holds one tab, and hides and closes the dragged window once its tab joins another strip, which for the primary would end the app.
- A connected primary workspace keeps a fresh query tab when its last tab is closed or moved out. Native `TabView::GetTabInsertionIndex` rejects an empty strip, so the remaining query keeps a drop target for returning tabs.
- Closing a tab window's last tab closes the window. A window whose last tab was dragged into another strip is closed by TabView. Closing the primary window saves every window and closes them all, since the rail, Settings and the connection form live there.
- Each tab window keeps its own tabs and its place: `session.json` lists them with their `GetWindowPlacement` bounds, restored as the primary's are, and they reopen with the session.
- TabView raises `TabTearOutWindowRequested` on every press on a tab, before any drag, and shows and hides that window at once (microsoft/microsoft-ui-xaml#10154, #10155). So the primary keeps one such window per session, hidden, cloaked (`DWMWA_CLOAK`) and out of the task switchers until a tab arrives, and cancels the close TabView sends it after a press that tore nothing out.
- The window supplied at `TabTearOutWindowRequested` is retained for `TabTearOutRequested`, as in the native sample. WinUI 2.6.4 never assigns the latter event's `NewWindowId`. An external drop carries the source window ID into the receiving workspace so the tab can leave it again within the same drag.
- Native caption right-clicks reach `WM_NCRBUTTONUP`, which WinUI handles as a system menu before XAML receives them (`DesktopWindowImpl::OnNonClientRegionButtonUp`). A window subclass routes only tab-header caption right-clicks to the tab's WinUI menu. All other messages retain native processing; XAML `ContextRequested` handles keyboard requests.
- TabView marks its tab strip as the window's caption region, which is how a press on a tab becomes a window drag, and marks it again only when the strip resizes, never when it moves or unloads (`TabView::UpdateNonClientRegion`). A workspace clears `CanTearOutTabs` before it leaves the window's content, while TabView can still reach the window to take its mark away, sets it once its strip is loaded, and sets it again when a bar over the tabs or the object pane moves the strip.
- A flyout keeps the window it first opened in (microsoft/microsoft-ui-xaml#10207), so the tab's menu and the pager's menus and flyouts are built each time they open.

### Rail items

- An item's icon is its engine's artwork (Engine artwork, below) in the connection's colour, with the engine's name as the item's `AutomationProperties.HelpText`. The macOS rail puts the colour in a dot on the glyph's corner; `NavigationViewItem.Icon` takes one `IconElement` and its `InfoBadge` slot carries the connecting state, so here the glyph itself takes the colour. The library's changes reach open items: a rename or a new colour shows at once.
- A rail item appears at once. `NavigationViewItem.Icon` takes an `IconElement`, which cannot host a `ProgressRing`, so the item shows an attention-dot `InfoBadge` while connecting and a critical-icon `InfoBadge` after a failure, with the state in `AutomationProperties.ItemStatus` and the tooltip. The page shows the `ProgressRing`, "Connecting to name..." and Cancel.
- A failure is an Error `InfoBar` with Retry, Edit connection and Copy details in its content. It is closed and opened again on each failure, since Narrator reads an InfoBar when it opens ([InfoBar](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/infobar)).
- Cancel removes the item. At launch, only the front connection connects; another restored item connects when it is selected.
- A connection the core holds no secret for (`keyring.secret_not_stored`, an imported one or one whose secret was removed) asks for it in a `ContentDialog`, as macOS asks: a `PasswordBox` named for the secret the error carries (`ErrorInfo.secret`) and "Save it in Credential Manager". The answer goes to that connect only (`connect_saved` takes it as a typed secret), and the box saves it once it has logged in, so a wrong one is asked for again on Retry. Closing the dialog cancels the connect.

### Commands and keys

- MenuBar File, Edit, View, Database, Query, Help, each with an access key from the resources ([Access keys](https://learn.microsoft.com/en-us/windows/apps/develop/input/access-keys)). Menu items carry their `KeyboardAccelerator`, which the menu shows.
- The SQL editor handles its own editing keys, so Edit's items show them with `KeyboardAcceleratorTextOverride` and send the same key to the editor through `SqlEditor.HandleKey`: a menu command and its key cannot do different things.
- Each tab has a `CommandBar` (Run and Stop; Refresh and Stop) with its status in `CommandBar.Content` ([Command bar](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/command-bar)).

| Keys | Command |
|---|---|
| Ctrl+N, Ctrl+O | New connection, open a database file |
| Ctrl+T, Ctrl+W, Ctrl+Shift+T | New query tab, close the tab, reopen the last closed tab; File also has Move tab to new window |
| Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+F4 | TabView's own |
| Ctrl+1 to Ctrl+8, Ctrl+9 | That tab, the last tab ([Tab view](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/tab-view)) |
| Ctrl+Enter, Shift+F5 | Run the selection or the whole text, stop |
| F5 | Refresh the object tree |
| Ctrl+B, Ctrl+P | Show or hide the object tree, filter objects |
| Ctrl+Shift+H | The Connections page |
| F1 | Documentation |
| Enter, F2, Delete on the Connections page | Connect; rename the row in place; delete, confirmed (every checked connection in selection mode) |
| Escape on the Connections page | Leave selection mode; in a rename, keep the old name |

### Connections page

- First run, with nothing saved: a Get started group of `SettingsCard`s that are clickable: New connection, Open a database file, Import from another app, Try the sample database ([App settings guidelines](https://learn.microsoft.com/en-us/windows/apps/design/app-settings/guidelines-for-app-settings)).
- Then a `CommandBar` (New connection, Open file, Import, New group), an `AutoSuggestBox` search and a `TreeView` with Favorites, Recent and All connections, the last holding the nested groups (core ADR 0006). Search matches every word against name, host, database, user, engine and group path, as Linux and macOS do; Enter in the box connects to the first match.
- The tree is rebuilt from a library snapshot after every change. A row's identity is its section and its id, so a favourite's two rows expand and collapse apart.
- Row menus are built when asked for (`ContextRequested`, `MenuFlyout.ShowAt` at the pointer or the item): Connect, Edit, Rename, Add to or Remove from Favorites, Move to group, Tags, Delete; for a group, New group inside, Rename, Delete. Delete asks first in a `ContentDialog`, since it cannot be undone ([Commanding basics](https://learn.microsoft.com/en-us/windows/apps/design/basics/commanding-basics)). A new group or tag name is asked in a `ContentDialog` that stays open with the core's reason under the field.
- A connection row shows its engine's artwork in the connection's colour, its endpoint, and its tags, each a dot in the tag's colour before its name.
- Rename is in place: F2 or the menu turns the row's title into a `TextBox` with the name selected; Enter or leaving it saves through the core (`rename_connection`, `rename_group`), Escape keeps the old name, and a refusal shows in the page's `InfoBar`.
- Selection mode: the Select toggle in the `CommandBar` switches the `TreeView` to `TreeViewSelectionMode.Multiple`, which gives each row the check box the [Tree view](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/tree-view) page shows for multiple selection, and adds Connect, Add to Favorites, Move to group and Delete for every checked connection. A checked group or section checks its rows. The mode checks connections, not rows (`LibrarySelection`): a connection listed under Recent and in its group is checked on both rows or neither, and each command acts on every checked connection once. A row's menu on a checked row speaks for all of them.
- Drag and drop: a connection or group row drags itself, or every checked row in selection mode. The `TreeView` starts the drag (`CanDragItems`, `DragItemsStarting`) and keeps `CanReorderItems` off, since its own reorder moves the bound items rather than writing to the library; each row's content takes the drop (`AllowDrop`, `DragOver`, `Drop`) and marks it handled before the row's own reorder sees it. A drag started from the row's content (`CanDrag`) took the press the row selects on, so a click no longer selected the row. `LibraryDrop` decides each target in the model, and the core writes it: on a group, into it; on All connections, to the top level; on a connection row, into its group before it; on Favorites or a favourite, a favourite, or a reorder before that one; a group goes into another group but not into itself or one inside it. Recent takes nothing. The drag caption says what the drop does. The Move to group menu stays as the way without a mouse.
- Tags are the core library's (`ConnectionTag`, core ADR 0006), which the FFI now lists in the snapshot with each connection's tag ids. A row's Tags submenu checks each tag on or off for its connections and makes a new one; the page's Tags button renames, recolours or deletes a tag, which reaches every connection carrying it. A new tag takes the first colour no tag holds. Search matches tag names too. The form does not show tags, and saving it keeps them.
- Try the sample database copies the Chinook file the macOS app ships into the data folder once and saves it as "Chinook (Sample)".
- Import reads a TablePro connections file through the core; it carries no passwords, so each connection asks for its own on the first connect. The Get started card says so. Importing another app's connections waits for the importers to move to the core.

### Engine artwork

- The macOS app's engine SVGs (`apple/TablePro/Assets.xcassets/*-icon.imageset`), which it draws as template images: one colour over the shape. `windows/scripts/engine-glyphs.py` turns each into one path (absolute commands, arcs as curves, group transforms applied, fitted to 16 by 16, nonzero fill as the SVGs use) and writes `Resources/EngineGlyphs.xaml`, a `DataTemplate` per engine id holding a `PathIcon`. `EngineIcons.Glyph` loads a new one per use, since an element has one parent. A `PathIcon` takes the theme's foreground the way a template image takes its tint, so the glyphs need no light and dark copies.
- The files are this repository's, under its license; most come from Simple Icons, which publishes them under CC0. The logos are their owners' trademarks and name the engine, as on macOS. An engine with no artwork shows the Library symbol.
- A connection's colour is a theme dictionary entry per colour (`ConnectionColor_<id>` in `App.xaml`), a darker shade in Light and a lighter one in Dark, each at least 3:1 against the window and a selected row. `EngineIcons` resolves it for the icon's own `ActualTheme` and again when it changes, since the app's theme is set on the root and a lookup from code sees the system's. A contrast theme keeps its own colours, so no connection colour is applied there.

### Connection form

- Its own `Window`, owned by the main one and not modal, so the workspace remains usable while the form stays open. WinUI 2.6.4 tracks open dialogs per XamlRoot, so separate windows can each show one ([ContentDialog source](https://github.com/microsoft/microsoft-ui-xaml/blob/winui3/release/2.6.4/src/dxaml/xcp/dxaml/lib/ContentDialog_Partial.cpp#L700)). `AppWindow.OwnerWindowId` is read-only and set only by `AppWindow.Create`, so the owner is set the Win32 way, `GWLP_HWNDPARENT`, which keeps the form above the main window, minimizes it with it and gives it no taskbar button. One form per connection; asking again brings it forward.
- Page one is the engine chooser: a `GridView` grouped through a `CollectionViewSource`, a search box, and "From connection URL..." with a flyout. The groups are the macOS app's families, in its order: Relational, Document, Key-value, Analytical, Wide-column. Each engine's family comes from the core (`DatabaseDriver::category`, which follows the data model unless the driver names one: ClickHouse and DuckDB are analytical, Cassandra wide-column), and each card shows the engine's artwork. The core parses the URL (`parse_connection_url`). `EngineGroup` carries `GeneratedBindableCustomProperty`, since the view reads `Items` by name.
- Page two scrolls: the basic fields, then `SettingsExpander`s for SSH, SSL/TLS, Options and Appearance, each with a summary in its description while folded. A file engine shows File with Browse and New file; a new file is made when Connect runs.
- Test on the left with its result beside it; Connect, Save and Cancel on the right. Connect is the accent button for a new connection, Save for an edit. Escape closes.
- Errors sit under their field in `TextBox.Description`, with the same text as the field's `AutomationProperties.FullDescription`, and the expander holding the field opens.
- A new connection stores the password as typed, empty included, for a server that takes none; an edit keeps the stored one unless something is typed.

### Workspace

- The object tree is a `TreeView` in ItemsSource mode with lazy children (`HasUnrealizedChildren`, `Expanding`) ([Tree view](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/tree-view)). Schemas show only when there is more than one that is not a system schema. Objects go into a folder per kind with their count.
- TreeView is not virtualized, so a folder realizes its first 500 objects, then "Show all N", which opens the whole folder in the virtualized `ListView`, and "Type in the filter box to find the rest". Typing in the filter switches to the same list of matches across schemas, names that start with the text first.
- Invoking a table or view opens its table tab, or brings the open one forward. The core writes the statement (`DatabaseSession.GetTableQueryAsync`, over the core's `build_page`), quoted, ordered and limited as the engine writes it.
- A query tab is the SQL editor over the run's results; a table tab is the results alone. Each opens its own editor connection on first use.
- Results: the run's first result set in `DataGridView` (ADR 0003), given to the grid once it has its first rows, or once it ends empty, and grown on each `RowsAppended`. The rows shown stay until then, so a sort or a refresh never shows an empty grid between the two results. Columns are sized to their content, and a sort or a refresh keeps their widths. Copy and Select All in the Edit menu reach the grid when it had focus last.
- A header click on a table tab runs the table's query again with the sort: `build_page` writes the ORDER BY, with the row key as the tiebreak, so it orders the whole table, not the rows already read. A row address the engine adds for edits (SQLite's rowid, PostgreSQL's ctid) follows the visible columns and is not shown. An engine that pages in its own order refuses the sort, and the grid keeps the shown one.
- A header click on a query result does what the macOS app does: the result's statement runs again with the column's ORDER BY in place of its own and before its row limit (`DatabaseSession.SortedQuery`, the core's `with_order_by`). The ORDER BY names the column, or gives its position where a name is not unique or not a plain column (core ADR 0007). Only one statement that reads runs again. For a script, a write, SHOW or EXPLAIN, and where the engine takes no position, the core sorts the rows the result holds (`ResultSet.SortedAsync`), as macOS sorts them where they are, and the status says so.
- The object pane resizes with the Windows Community Toolkit's `GridSplitter` (Sizers), set up as its [page](https://learn.microsoft.com/en-us/dotnet/communitytoolkit/windows/sizers/gridsplitter) lays it out, between 180 and 640 effective pixels; WinUI's `SplitView` has no user resize. Every workspace shares the width, which `session.json` keeps.
- Reopen closed tab (File menu, Ctrl+Shift+T, which the [Tab view](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/tab-view) page asks for): a workspace keeps its last 20 closed tabs, newest first, each with its text or its table and its place in the strip. Disconnecting forgets them.
- Table tabs page as macOS pages a table: a page is the default page size long (Settings, Pagination: 100, 500, 1,000, 5,000 or 10,000 rows, 1,000 unless changed, as macOS); First, Previous, Next and Last sit in the tab's `CommandBar`, and its one status words the page as the macOS status bar does, with the run's time: "1,001-2,000 of 3,503 rows · 15 ms", or "Rows 1,001-2,000 · 15 ms" until the count lands. A table that fits one page keeps "Rows: 347 · 12 ms". The core writes each page (`table_query` takes an offset, over `build_page`'s `PagePosition::Offset`) and counts the table (`table_row_count`, `build_count` as the Linux pager counts), in the background after the first full page; until the count lands, Next stays while pages come back full. A sort or a refresh goes back to the first page, and a refresh counts again. An engine that pages on the server (Cassandra) cannot seek by offset, so it has only its first page, as on macOS, and the core refuses another (`ffi.page_unsupported`).
- Rows per page: a "1,000 rows" button before First page opens the macOS sizes, 5, 10, 20, 100, 500 and 1,000, as `RadioMenuFlyoutItem`s, then All rows..., which asks first and needs the count, and Custom..., up to 1,000,000. A new size keeps the page that holds the first row shown, as macOS does. The size belongs to the tab: `session.json` keeps it with the tab's page, and Reopen closed tab brings both back.
- Go to page: between Previous and Next, "Page 3 of 36" opens a flyout with a `NumberBox` from 1 to the page count, as macOS asks in a popover. It is offered once the table is counted, as on macOS, and the box keeps a typed number inside that range (`InvalidInputOverwritten`).
- An open transaction: each run's `Finished` event carries the transaction the editor's connection is left in (the core's `RunSummary.transaction_state`). The tab that holds one shows a Warning `InfoBar` above its results, "Transaction open", with Roll back, which asks first, and Commit, hidden on a read-only connection; a failed one is an Error bar with Roll back only. Both send COMMIT or ROLLBACK as typed SQL, EXEC or DISCARD for a key-value engine, as the Linux app does. Over the tabs, a bar names another tab that holds one, with Show; macOS shows its bar above every tab of the connection, and here the owning tab carries the actions, since the transaction lives on that tab's own connection. Closing a tab that holds one asks first, since closing rolls it back. Window close and Exit confirm every affected held transaction before closing any tabs; cancelling keeps them open. A window with a dialog already open waits for it to be dismissed before accepting a close request.
- Reconnecting: the workspace waits on the core's session health (`health_change`) and shows a bar over the tabs while it is not online: Warning while it reconnects, with the attempt, or while the server cannot be reached, and Error once the session parks with the reason the core gives, with Reconnect (`reconnect`, the monitor's retry). An editor connection is never opened again by itself, since its transaction would not come back with it: a query tab whose connection was lost opens a new one on its next run and says that an open transaction went with it.

### Settings

A page in the window, built from `SettingsCard` and `SettingsExpander`: Appearance (theme, with a link to Windows color settings), Startup (reopen the previous session), Editor (font size), Queries (row limit, query timeout), Pagination (default page size), About (version, documentation, report an issue, the data folder). A change applies at once; there is no Save ([App settings guidelines](https://learn.microsoft.com/en-us/windows/apps/design/app-settings/guidelines-for-app-settings)).

### Where things are kept

| What | Where | Why |
|---|---|---|
| Saved connections, groups, favourites | `connections.json` through the core, in the data folder | Core ADR 0006; the core's `StoragePaths` roots all point at the data folder |
| Passwords and passphrases | Credential Manager, written by the core | Generic credentials named `TablePro/connection/<id>/<kind>`, persisted for the user on this PC, the core's label in the comment |
| Settings | `settings.json` in the data folder | No shared settings spec: Linux keeps its preferences in GSettings |
| Session, window placement, object pane width, tab windows | `session.json` in the data folder, written as the primary window closes | No shared spec: Linux keeps its workspace store in the app |

The data folder is the package's `ApplicationData.Current.LocalFolder` (`%LOCALAPPDATA%\Packages\<family>\LocalState`), which Windows removes with the app ([Store and retrieve settings and other app data](https://learn.microsoft.com/en-us/windows/apps/design/app-settings/store-and-retrieve-app-data)). An unpackaged development build uses `%LOCALAPPDATA%\TablePro`, and `TABLEPRO_DATA_DIR` overrides both for the UI tests. The session holds each open connection (a saved one by id, a file by path), its tabs (a query tab's text, a table tab's table with its page size and page), the selected tab, the front connection, and each tab window with its connection, its tabs and its bounds.

### Strings and accessibility

- Every string is in `Strings/en-US/Resources.resw`: XAML through `x:Uid`, code through `ResourceLoader`. The core's error codes are worded as `Error_<code>` with dots as underscores; the innermost code with wording wins, and the server's own message follows it.
- Icon-only controls have names; list items are named on their containers in `ContainerContentChanging`, since a template's name is not the item's; page titles and section headers carry heading levels; status text is a polite live region.

### Packaging

Single-project MSIX for x64 and Arm64, minimum 10.0.17763, identity `TablePro` with publisher `CN=TablePro Development` until signing lands, and a `tablepro.exe` execution alias. A development build runs unpackaged with the Windows App SDK beside it (`WindowsAppSDKSelfContained`), which is what the UI tests launch; `-p:WindowsPackageType=MSIX` builds the package.

The Toolkit packages hold that floor. CommunityToolkit.WinUI.Controls.SettingsControls and .Sizers 8.2.251219 ship their Windows assemblies as `net8.0-windows10.0.19041` (and the same for `net9.0`), and each DLL declares `SupportedOSPlatform("Windows10.0.17763.0")`: they build against the 2004 SDK and support 1809.

## What the runner showed

Facts the CI runs on `windows-2025` and `windows-11-arm` established, which the code relies on. Run 41550202718 passed 185 .NET tests and 14 UI tests on each, and 41538980893 the FFI crate's tests. With the sort of held rows and column sizing, run 41561946564 passed 192 .NET tests, 14 UI tests and the FFI crate's tests on each. With the shell's second pass on top, run 41565047628 built the core and passed the FFI crate's tests on each and on macOS, and run 41575653721 passed 214 .NET tests and the 32 UI tests four times over on each, with the committed bindings matching the library. With the paged status and selection by connection, run 41588147784 passed 217 .NET tests, the 32 UI tests and the FFI crate's 71 tests on each, and 184 .NET tests with the committed bindings matching on macOS.

- TabView's default style sets `VerticalAlignment` to `Top`, so a tab's content gets its smallest height. The workspace sets it to `Stretch`.
- A `TreeViewItem.IsExpanded` binding loses its first value when the row joins the tree, in ItemsSource mode. Rows open through their container instead: `ContainerFromItem` after a layout pass, or the row's `Loaded`.
- UI Automation lists an owned window under its owner, not under the desktop.
- The `windows-11-arm` image opens "Choose privacy settings for your device" over the desktop while the tests run, and it takes their clicks. CI turns the experience off by policy and stops it first, with `windows/ci/desktop.ps1`, which the grid gate also runs.
- The image's provisioning agent (`provjobd`) runs `wsl.exe` every 30 seconds, and now and then its "update WSL" console opens over the app. CI stops each one (`Start-WslWatch`), and the tests bring the app to the front before each click and click again when nothing happened.
- The Community Toolkit's clickable `SettingsCard` offers no Invoke pattern, so the UI tests click it.
- Concurrent Credential Manager writes from one process lost each other's changes: a stored secret read back as missing, a deleted one came back. The core serializes its calls.
- System.Text.Json's source generator sets every init-only property when it builds a record, so a key a file leaves out took the type's default, not the property's initializer. The stored records use settable properties.
- The signed MSIX, self-contained and not AOT-compiled, is 144.5 MB for x64 and 142.6 MB for Arm64.
- A `ContentDialog` opens in the popup layer, outside the root that carries the app's `RequestedTheme`, so in Dark on a Light system it came up light. Each dialog takes its page's `ActualTheme`.
- A row's content with `CanDrag` took the press the `TreeViewItem` selects on: a click no longer selected the row. The tree starts the drag instead.
- The Toolkit's `GridSplitter` in an `Auto` column of its own resized nothing; on the left edge of the star column after the pane, as its page lays it out, it resizes the pane.
- FlaUI moves the pointer with `SetCursorPos`, which WinUI does not take as a pointer moving with the button down, so neither a tree drag nor the splitter moved. The UI tests drag through `SendInput`.
- A closed `InfoBar` stays in the UI Automation tree with its content folded away, so the tests read whether a bar shows from its buttons.
- A grid given a new set as the set started had no rows until the first ones arrived, and a client that had asked for a cell before then read its name after: WinUI reports an empty name as none, so FlaUI threw `PropertyNotSupportedException` (x64, once in run 41566360608). The pane now hands the grid a set once it has rows, and a cell peer outside the grid's current data reads as empty, off screen and with no bounds, and takes no selection.
- On `windows-11-arm`, a rebuilt library tree folded rows the page had opened, in a pass of the tree's own after the page's, and the folds read as the user's. The page opens the rows again at low priority and records no fold until then.
- On `windows-2025` the app died three times in run 41581443963 (0xC0000005 in `UpdateLayout`), each in one of those low-priority passes. The page now skips a pass once its window has closed. A passing run cannot show whether it still happens: the test platform prints the app's error output only when a test fails.
- `TreeViewItem`'s multiple-selection check box is raw to UI Automation, so the tests check a row through its `SelectionItem` pattern, which reads that box.
- A click on a `MenuFlyoutSubItem` did not always open its submenu, and FlaUI's pointer glides to the next item across its neighbours, whose own submenus then open. The tests open a submenu through `ExpandCollapse` and invoke its item.
- `windows-2025` drags a window as an outline: "Show window contents while dragging" is off there (`SPI_GETDRAGFULLWINDOWS` 0), while `windows-11-arm` has it on. TabView merges a dragged tab into another strip from `InputNonClientPointerSource.WindowRectChanging`, which the outline drag raised once, on release; with window contents on, the same drag raised it 82 times and the tab merged and tore out again before the release (run 41837948701). CI turns the setting on with `Set-DragFullWindows` in `windows/ci/desktop.ps1`.
## Consequences

- The core gained the library and connecting through it: `Core::library`, `connect_saved`, `test_connection`, `parse_connection_url`, `DatabaseSession::table_query` and `sorted_query` with `sql_syntax::with_order_by` and `sort_reference`, `ResultSet::sorted` over `value::order`, and `Core::with_system_secrets`, which keeps secrets in Credential Manager on Windows (`core/ARCHITECTURE.md`, Platforms).
- Then what the shell's second pass needed: `DatabaseDriver::category` (`EngineCategory`) and `DriverInfo.category`; in the library, tags (`create_tag`, `update_tag`, `delete_tag`, `tag_connections`, and the tags in the snapshot), `rename_connection`, `add_favorites` and `remove_favorites` with a place, `move_to_group` with a place and `move_groups`; `ErrorInfo.secret`; `table_query` with an offset and `can_seek`, `table_row_count`; `health`, `health_change` and `reconnect` on the session; `QueryEditor::is_lost`; and the transaction in `RunEvent::Finished`. Each has its test in `core/crates/ffi/tests`.
- `tests/TablePro.App.Model.Tests` covers settings, the session file with the window, the pane and the tab windows, the library tree with tags and search, selection by connection, drops, the engine families, closed tabs, the pager with its page sizes and Go to page, and the workspace bars, the form's fields and the object folders on any machine. `tests/TablePro.App.UITests` drives the unpackaged build through UI Automation (FlaUI): first run, Settings, the form and its engine families, connecting to a SQLite file, opening, sorting and paging a table with a width set through Transform and the header's ItemStatus, a table's page size and Go to page kept across a relaunch, a tab moved to its own window that comes back with its place and merges back by drag, a tab dragged out whose window closes with its last tab, a query and its sort, a script's rows sorted where they are, a failed connect, a password asked for, session restore, the rail's mark, the pane's width and the window's place across a relaunch, Reopen closed tab, an open transaction's bars, and rename, tags, a drop and selection mode on the Connections page, in light and dark, with screenshots.
- SSH connections use the core's in-process transport (core ADR 0009). Host-key, passphrase and interactive login prompts use native ContentDialogs. A changed host key requires confirmation to remove its old entry, then separate confirmation of the replacement key on retry.
- Not built yet: importing from other apps (the importers move to the core first).
- Unverified: Native AOT publishing of the app, and the app on a real Windows 10 machine.

## Alternatives considered

- **The form in a ContentDialog.** Blocks every other ContentDialog in the app while open and caps the width near 548 pixels.
- **A Frame that navigates between pages.** Recreates or caches pages by type; a workspace per connection has to live while another is shown.
- **Credential Manager in the app, behind `ISecretStore`.** Two implementations of one store; the core already has the secret traits, so it keeps the store itself and the app never holds a saved password.
- **WinUI `ApplicationData` for unpackaged runs too.** It has no folder without package identity, and the tests run unpackaged.
- **One GridView per engine group.** Arrow keys would stop at each group; one grouped GridView moves across them.
- **The engine families in the app.** A second list of engine facts beside the core's; the core's driver already says what each engine is.
- **The engine artwork as images, a light and a dark copy each.** Four times the files for nine engines, and a high contrast theme would still need its own; a `PathIcon` follows every theme's foreground.
- **The connection's colour as a dot `InfoBadge` on the rail item.** The badge already carries the connecting state, and a dot badge reads as a notice to attend to.
- **The TreeView's own drag reorder.** It moves the bound items itself, so the tree and the library would disagree until the next snapshot, and it cannot say no to Recent or to a group inside itself.