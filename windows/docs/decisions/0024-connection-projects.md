# 0024: Connection projects on the Connections page

- **Status**: Accepted
- **Date**: 2026-11-20

## Context

The Connections page listed the whole library: its tree, search, Favorites and Recent showed every connection, and the history pane of a file opened without saving listed every connection's runs ([#4307](https://github.com/TableProApp/TablePro/issues/4307)). The core now keeps projects in `connections.json` and narrows a list to one ([core 0041](../../../core/docs/decisions/0041-connection-projects.md)). [0004](0004-app-shell.md) describes the page this adds to.

## Decision

- **The core narrows.** The page reads `ConnectionLibrary.GetSnapshotAsync(projectId)`, whose connections, groups, Favorites and Recent are the project's. `LibrarySnapshot.Scope` says which project the core resolved, so an id no project holds shows all connections. `LibraryScope` in `TablePro.App.Model` holds only what the page asks about that snapshot.
- **The active project is a setting.** `AppSettings.ActiveProjectId` in `settings.json`, per PC. `Workbench.ActiveProject` reads it, and `SetActiveProject` writes it and tells the MCP server. A project deleted while active resets the setting to all connections on the next snapshot.
- **One signal for scope.** `Workbench.ScopeChanged` is raised when the active project or the set of connections in it changes: after a switch and after every `NotifyLibraryChanged`, the workbench reads the project's snapshot and `ScopeWatch` in `TablePro.App.Model` compares it with the last one, so a move, a delete, an import and the fallback from a deleted project raise it and a rename does not. Every list narrowed to the project reads again on it and drops a read of the old scope. `ProjectChanged` says only that the list of projects changed, for the switchers' names.
- **A scope read that fails.** `ScopeWatch.Fail` decides, and `Workbench.ScopeReadFailed` carries the core's error to the Connections page's InfoBar, worded as a failed reload is. The lists stay, as they do after a failed reload. A failed switch puts `ActiveProjectId` back on the project the lists show, so the switchers, the subtitle and the MCP server name it and picking the project again retries; a failed read after a library change keeps the setting, and so does one before the first read, which has no list to go back to. The next library change or switch reads again, and a failed read a later one overtook says nothing.
- **The switcher.** A `DropDownButton` beside the page's title whose content is the active project's name, with `RadioMenuFlyoutItem`s (All connections first), then New project... and Manage projects.... File > Project holds the same items in every window, and the title bar's subtitle names the active project while the Connections page shows. All connections adds no subtitle.
- **What follows the project.** The tree, search, Favorites, Recent, the Move to group menu, the connection form's group list, Export connections and the history pane of a file opened without saving. A new connection, a new top-level group, an imported file's entries that name no project and an import from another app land in the active project. A duplicate stays beside its source.
- **What does not.** The rail, restored sessions, `tablepro://` links, a client's open by id through `IMcpAppHost`, the sample and one saved connection's own history and saved queries panes. Open connections stay open on a switch.
- **Moving.** Move to project on an ungrouped connection and on a top-level group, since the core moves a grouped connection only with its group.
- **Managing.** A ContentDialog lists the projects with Rename, Move up, Move down and Delete. The core's refusal (`storage.project_name_taken`, `project_name.empty`) shows under the name box. Delete asks in a flyout on its button and says the connections and groups are kept.
- **Empty states.** A project with nothing in it shows its name and New connection, not the first-run cards. A search that finds nothing inside a project offers Search all connections, which switches to all connections and keeps the text.
- **Deleting a connection.** The dialog gains "Also delete its query history", off by default as on Linux. Saved queries always go. A step that could not run, as when the history database did not open, is counted in `DeletedConnectionCleanup` and the page says what stayed.

## Rationale

- **A DropDownButton, not a ComboBox.** The Fluent guidance gives a button with a flyout to "more options"; the flyout also carries the two commands, which a ComboBox cannot hold.
- **The scope in the core.** Recent is capped at 8, so a filter in the app after the cap would leave a project with fewer than it has. History paging has the same problem: `QueryHistory.SearchAsync` takes the project and the core resolves its connections.
- **Per PC.** The active project is a view preference, as the theme is; core 0041 leaves it to each app.
- **A flyout for Delete.** WinUI opens one ContentDialog per thread, and the manage dialog is open.

## Consequences

- The MCP server and the `tablepro` command list the active project's connections and refuse a call by id outside it with `out_of_scope`. This is a listing scope the user switches, not an access control.
- A history run whose connection was deleted shows only under all connections.
- An older build that writes `connections.json` drops the projects (core 0041, Consequences).
- The UI test `TheConnectionsPageShowsOneProjectAndItsSearchStaysInside` makes two projects, moves a connection into each and takes the `185-project-switcher` and `186-project-home` screenshots.
