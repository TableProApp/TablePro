# 0004: The app shell: one window, a rail of connections, a page per surface

- **Status**: Accepted
- **Date**: 2026-11-02

## Context

The Windows app needs its window, navigation, the Connections page, the connection form, Settings, session restore and a workspace per connection, before the data grid (0003) is wired in. The maintainer fixed the shape on 2026-11-02: one window; a NavigationView rail with the Connections page, one item per open connection and Settings, hidden until a connection opens; a tab strip per connection, as on macOS; a MenuBar plus a CommandBar per tab; Settings as a page; launch reopens the previous session and connects only the front connection; Get started cards on first run; the connection form in its own owned, non-modal window; a TreeView object tree that pages huge folders; MSIX per user for Windows 10 1809 and later on x64 and Arm64. Every control is stock WinUI or the Windows Community Toolkit's settings controls, used as the Fluent guidance describes.

## Decision

`src/TablePro.App` is one `MainWindow` with the WinUI `TitleBar`, a `MenuBar` under it and a `NavigationView` in `LeftCompact` whose content is a page object kept per surface: `HomeView`, `SettingsView` and a `WorkspaceView` per open connection. The core keeps the saved connections and their secrets; the app keeps its settings and its session in two JSON files in the package's LocalState folder.

## Design

### Window and navigation

- `ExtendsContentIntoTitleBar` with `SetTitleBar` on the `TitleBar` control, which also holds the rail's pane toggle and a back button, as the title bar page shows for NavigationView ([Title bar](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/title-bar)). The subtitle names the front connection.
- The rail is `IsPaneVisible="False"` until the first connection opens. While it is hidden, Settings is reached from a button on the Connections page or File > Settings, and the title bar's back button returns.
- Pages are swapped as `NavigationView.Content`, not navigated in a Frame, so a workspace keeps its tabs, editors and tree when another rail item is selected.
- The window opens at 1280 by 820 effective pixels, scaled by `GetDpiForWindow` and clamped to the display's work area; `AppWindow` takes physical pixels ([Windowing overview](https://learn.microsoft.com/en-us/windows/apps/develop/ui/windowing-overview)).
- `MicaBackdrop` when `MicaController.IsSupported()`; otherwise no backdrop and the theme's solid background, which is what Windows 10 gets.
- App theme: Light, Dark or Use system setting. The root's `RequestedTheme` takes it, and `AppWindowTitleBar.PreferredTheme` keeps the caption buttons in step.

### Rail items while connecting

- A rail item appears at once. `NavigationViewItem.Icon` takes an `IconElement`, which cannot host a `ProgressRing`, so the item shows an attention-dot `InfoBadge` while connecting and a critical-icon `InfoBadge` after a failure, with the state in `AutomationProperties.ItemStatus` and the tooltip. The page shows the `ProgressRing`, "Connecting to name..." and Cancel.
- A failure is an Error `InfoBar` with Retry, Edit connection and Copy details in its content. It is closed and opened again on each failure, since Narrator reads an InfoBar when it opens ([InfoBar](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/infobar)).
- Cancel removes the item. At launch, only the front connection connects; another restored item connects when it is selected.

### Commands and keys

- MenuBar File, Edit, View, Database, Query, Help, each with an access key from the resources ([Access keys](https://learn.microsoft.com/en-us/windows/apps/develop/input/access-keys)). Menu items carry their `KeyboardAccelerator`, which the menu shows.
- The SQL editor handles its own editing keys, so Edit's items show them with `KeyboardAcceleratorTextOverride` and send the same key to the editor through `SqlEditor.HandleKey`: a menu command and its key cannot do different things.
- Each tab has a `CommandBar` (Run and Stop; Refresh and Stop) with its status in `CommandBar.Content` ([Command bar](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/command-bar)).

| Keys | Command |
|---|---|
| Ctrl+N, Ctrl+O | New connection, open a database file |
| Ctrl+T, Ctrl+W | New query tab, close the tab |
| Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+F4 | TabView's own |
| Ctrl+1 to Ctrl+8, Ctrl+9 | That tab, the last tab ([Tab view](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/tab-view)) |
| Ctrl+Enter, Shift+F5 | Run the selection or the whole text, stop |
| F5 | Refresh the object tree |
| Ctrl+B, Ctrl+P | Show or hide the object tree, filter objects |
| Ctrl+Shift+H | The Connections page |
| F1 | Documentation |
| Enter, F2, Delete on the Connections page | Connect; rename a group or edit a connection; delete, confirmed |

### Connections page

- First run, with nothing saved: a Get started group of `SettingsCard`s that are clickable: New connection, Open a database file, Import from another app, Try the sample database ([App settings guidelines](https://learn.microsoft.com/en-us/windows/apps/design/app-settings/guidelines-for-app-settings)).
- Then a `CommandBar` (New connection, Open file, Import, New group), an `AutoSuggestBox` search and a `TreeView` with Favorites, Recent and All connections, the last holding the nested groups (core ADR 0006). Search matches every word against name, host, database, user, engine and group path, as Linux and macOS do; Enter in the box connects to the first match.
- The tree is rebuilt from a library snapshot after every change. A row's identity is its section and its id, so a favourite's two rows expand and collapse apart.
- Row menus are built when asked for (`ContextRequested`, `MenuFlyout.ShowAt` at the pointer or the item): Connect, Edit, Add to or Remove from Favorites, Move to group, Delete; for a group, New group inside, Rename, Delete. Delete asks first in a `ContentDialog`, since it cannot be undone ([Commanding basics](https://learn.microsoft.com/en-us/windows/apps/design/basics/commanding-basics)). A group name is asked in a `ContentDialog` that stays open with the core's reason under the field.
- Try the sample database copies the Chinook file the macOS app ships into the data folder once and saves it as "Chinook (Sample)".
- Import reads a TablePro connections file through the core; it carries no passwords.

### Connection form

- Its own `Window`, owned by the main one and not modal, so a `ContentDialog` elsewhere can still open: only one opens per thread across windows ([ContentDialog](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.contentdialog)). `AppWindow.OwnerWindowId` is read-only and set only by `AppWindow.Create`, so the owner is set the Win32 way, `GWLP_HWNDPARENT`, which keeps the form above the main window, minimizes it with it and gives it no taskbar button. One form per connection; asking again brings it forward.
- Page one is the engine chooser: a `GridView` grouped through a `CollectionViewSource` (Relational, Document, Key-value, Files), a search box, and "From connection URL..." with a flyout. The core parses the URL (`parse_connection_url`). `EngineGroup` carries `GeneratedBindableCustomProperty`, since the view reads `Items` by name.
- Page two scrolls: the basic fields, then `SettingsExpander`s for SSH, SSL/TLS, Options and Appearance, each with a summary in its description while folded. A file engine shows File with Browse and New file; a new file is made when Connect runs.
- Test on the left with its result beside it; Connect, Save and Cancel on the right. Connect is the accent button for a new connection, Save for an edit. Escape closes.
- Errors sit under their field in `TextBox.Description`, with the same text as the field's `AutomationProperties.FullDescription`, and the expander holding the field opens.
- A new connection stores the password as typed, empty included, for a server that takes none; an edit keeps the stored one unless something is typed.

### Workspace

- The object tree is a `TreeView` in ItemsSource mode with lazy children (`HasUnrealizedChildren`, `Expanding`) ([Tree view](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/tree-view)). Schemas show only when there is more than one that is not a system schema. Objects go into a folder per kind with their count.
- TreeView is not virtualized, so a folder realizes its first 500 objects, then "Show all N", which opens the whole folder in the virtualized `ListView`, and "Type in the filter box to find the rest". Typing in the filter switches to the same list of matches across schemas, names that start with the text first.
- Invoking a table or view opens its table tab, or brings the open one forward. The core writes the statement (`DatabaseSession.GetTableQueryAsync`, over the core's `build_page`), quoted, ordered and limited as the engine writes it.
- A query tab is the SQL editor over the run's results; a table tab is the results alone. Each opens its own editor connection on first use.
- Results: the run's first result set in `DataGridView` (ADR 0003), given to the grid as the set starts and grown on each `RowsAppended`. The rows shown stay until the next run's first set starts. Copy and Select All in the Edit menu reach the grid when it had focus last.
- A header click on a table tab runs the table's query again with the sort: `build_page` writes the ORDER BY, with the row key as the tiebreak, so it orders the whole table, not the rows already read. A row address the engine adds for edits (SQLite's rowid, PostgreSQL's ctid) follows the visible columns and is not shown. An engine that pages in its own order refuses the sort, and the grid keeps the shown one.
- A header click on a query result does what the macOS app does: the result's statement runs again with the column's ORDER BY in place of its own and before its row limit (`DatabaseSession.SortedQuery`, the core's `with_order_by`). Only one statement that reads runs again; for a script, a write, SHOW or EXPLAIN the grid keeps its order and the status says why. macOS sorts those rows where they are; the core has no sort of held rows yet.

### Settings

A page in the window, built from `SettingsCard` and `SettingsExpander`: Appearance (theme, with a link to Windows color settings), Startup (reopen the previous session), Editor (font size), Queries (row limit, query timeout), About (version, documentation, report an issue, the data folder). A change applies at once; there is no Save ([App settings guidelines](https://learn.microsoft.com/en-us/windows/apps/design/app-settings/guidelines-for-app-settings)).

### Where things are kept

| What | Where | Why |
|---|---|---|
| Saved connections, groups, favourites | `connections.json` through the core, in the data folder | Core ADR 0006; the core's `StoragePaths` roots all point at the data folder |
| Passwords and passphrases | Credential Manager, written by the core | Generic credentials named `TablePro/connection/<id>/<kind>`, persisted for the user on this PC, the core's label in the comment |
| Settings | `settings.json` in the data folder | No shared settings spec: Linux keeps its preferences in GSettings |
| Session | `session.json` in the data folder, written as the window closes | No shared spec: Linux keeps its workspace store in the app |

The data folder is the package's `ApplicationData.Current.LocalFolder` (`%LOCALAPPDATA%\Packages\<family>\LocalState`), which Windows removes with the app ([Store and retrieve settings and other app data](https://learn.microsoft.com/en-us/windows/apps/design/app-settings/store-and-retrieve-app-data)). An unpackaged development build uses `%LOCALAPPDATA%\TablePro`, and `TABLEPRO_DATA_DIR` overrides both for the UI tests. The session holds each open connection (a saved one by id, a file by path), its tabs (a query tab's text, a table tab's table), the selected tab and the front connection.

### Strings and accessibility

- Every string is in `Strings/en-US/Resources.resw`: XAML through `x:Uid`, code through `ResourceLoader`. The core's error codes are worded as `Error_<code>` with dots as underscores; the innermost code with wording wins, and the server's own message follows it.
- Icon-only controls have names; list items are named on their containers in `ContainerContentChanging`, since a template's name is not the item's; page titles and section headers carry heading levels; status text is a polite live region.

### Packaging

Single-project MSIX for x64 and Arm64, minimum 10.0.17763, identity `TablePro` with publisher `CN=TablePro Development` until signing lands, and a `tablepro.exe` execution alias. A development build runs unpackaged with the Windows App SDK beside it (`WindowsAppSDKSelfContained`), which is what the UI tests launch; `-p:WindowsPackageType=MSIX` builds the package.

## What the runner showed

Facts the CI runs on `windows-2025` and `windows-11-arm` established, which the code relies on:

- TabView's default style sets `VerticalAlignment` to `Top`, so a tab's content gets its smallest height. The workspace sets it to `Stretch`.
- A `TreeViewItem.IsExpanded` binding loses its first value when the row joins the tree, in ItemsSource mode. Rows open through their container instead: `ContainerFromItem` after a layout pass, or the row's `Loaded`.
- UI Automation lists an owned window under its owner, not under the desktop.
- The `windows-11-arm` image opens "Choose privacy settings for your device" over the desktop while the tests run, and it takes their clicks. CI turns the experience off by policy and stops it first, with the grid gate's `ci/desktop.ps1`.
- The image's provisioning agent (`provjobd`) runs `wsl.exe` every 30 seconds, and now and then its "update WSL" console opens over the app. CI stops each one (`Start-WslWatch`), and the tests bring the app to the front before each click and click again when nothing happened.
- The Community Toolkit's clickable `SettingsCard` offers no Invoke pattern, so the UI tests click it.
- Concurrent Credential Manager writes from one process lost each other's changes: a stored secret read back as missing, a deleted one came back. The core serializes its calls.
- System.Text.Json's source generator sets every init-only property when it builds a record, so a key a file leaves out took the type's default, not the property's initializer. The stored records use settable properties.
- The signed MSIX, self-contained and not AOT-compiled, is 144.5 MB for x64 and 142.6 MB for Arm64.

## Consequences

- The core gained the library and connecting through it: `Core::library`, `connect_saved`, `test_connection`, `parse_connection_url`, `DatabaseSession::table_query` and `sorted_query` with `sql_syntax::with_order_by`, and `Core::with_system_secrets`, which keeps secrets in Credential Manager on Windows (`core/ARCHITECTURE.md`, Platforms).
- `tests/TablePro.App.Model.Tests` covers settings, the session file, the library tree and search, the form's fields and the object folders on any machine. `tests/TablePro.App.UITests` drives the unpackaged build through UI Automation (FlaUI): first run, Settings, the form, connecting to a SQLite file, opening and sorting a table, a query and its sort, a failed connect and session restore, in light and dark, with screenshots.
- SSH fields are saved, but the core has no SSH transport on Windows yet, so such a connection fails with `ssh.open_ssh_client_missing`.
- Not built yet: drag and drop and multi-select on the Connections page, inline rename, tags, importing from other apps (the core reads only TablePro's own file), a password asked when connecting, a resizable object pane, window placement restore, tab tear-out, Reopen closed tab, the open-transaction and reconnect bars, paging past the row limit, sorting a result the core cannot run again, and column widths kept across a sort.
- Unverified: the Community Toolkit settings controls target Windows 10 2004 (19041) and the app 1809; Native AOT publishing of the app; the app on Windows 10 at all.

## Alternatives considered

- **The form in a ContentDialog.** Blocks every other ContentDialog in the app while open and caps the width near 548 pixels.
- **A Frame that navigates between pages.** Recreates or caches pages by type; a workspace per connection has to live while another is shown.
- **Credential Manager in the app, behind `ISecretStore`.** Two implementations of one store; the core already has the secret traits, so it keeps the store itself and the app never holds a saved password.
- **WinUI `ApplicationData` for unpackaged runs too.** It has no folder without package identity, and the tests run unpackaged.
- **One GridView per engine group.** Arrow keys would stop at each group; one grouped GridView moves across them.
