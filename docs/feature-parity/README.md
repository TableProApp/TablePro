# Feature parity

Which user-visible features each app has. The macOS app is the reference, and the Linux and Windows apps
follow its behavior. This file is generated: edit [`features.yml`](features.yml), then run
`python3 scripts/parity/render.py`. A pull request that adds or finishes a feature updates its row.

Status: Yes is shipped. In PR is built in an open pull request. Partial says what ships. No is not built.
n/a does not apply. Unknown has not been checked.

## Totals

| | macOS | Linux | Windows |
|---|---|---|---|
| Yes | 64 | 26 | 0 |
| In a PR | 0 | 27 | 0 |
| Partial | 0 | 7 | 0 |
| No | 0 | 3 | 0 |
| n/a | 0 | 1 | 0 |
| Unknown | 0 | 0 | 64 |

64 features.

## Connections

| Feature | macOS | Linux | Windows | Notes |
|---|---|---|---|---|
| Saved connections, groups, favourites and tags | Yes | Yes | Unknown |  |
| SSH tunnels with jump hosts | Yes | Yes | Unknown |  |
| Safe Mode per connection (off, confirm writes, read only) | Yes | Yes | Unknown |  |
| Import connections from other apps | Yes | Yes | Unknown | DBX is read on Linux and Windows through the shared core (4147); the macOS importers are Swift and do not list it. |
| Application menu bar (File, Edit, View, Help) with Quit | Yes | In PR [#4139](https://github.com/TableProApp/TablePro/pull/4139): read by a global menu and assistive technology; GNOME draws none | Unknown |  |
| Open another database of a server beside the connection | Yes | Yes | Unknown |  |

## Sidebar

| Feature | macOS | Linux | Windows | Notes |
|---|---|---|---|---|
| Schemas and tables, with search | Yes | Yes | Unknown |  |
| Tables and Favorites scope switch | Yes | In PR [#4114](https://github.com/TableProApp/TablePro/pull/4114) | Unknown | Linux lists the saved queries of the front connection, and renames and deletes them (4115). |
| Favorite folders | Yes | In PR [#4130](https://github.com/TableProApp/TablePro/pull/4130): on the storage of 4116 | Unknown |  |
| Favorite keywords that expand in the editor | Yes | Partial ([#4116](https://github.com/TableProApp/TablePro/pull/4116)): storage only; the editor does not expand them yet | Unknown | Shared storage and the decision are core ADR 0017. |
| Favorite tables and databases, with environments | Yes | In PR [#4116](https://github.com/TableProApp/TablePro/pull/4116): storage only; no UI yet | Unknown |  |
| Open Quickly (find a table by name) | Yes | In PR [#4121](https://github.com/TableProApp/TablePro/pull/4121): tables and views, saved queries in 4133 and past queries in 4144; not databases, schemas, routines or other connections | Unknown |  |
| Bottom bar with an Add menu and a schema picker | Yes | Partial ([#4146](https://github.com/TableProApp/TablePro/pull/4146)): the Add menu (table, schema, database); a Schemas menu filters the list (4150), with no active schema | Unknown |  |
| A row's menu is shown whole, not cut with a scrollbar | Yes | In PR [#4149](https://github.com/TableProApp/TablePro/pull/4149) | Unknown |  |
| Sidebar toggle in the window header | Yes | In PR [#4117](https://github.com/TableProApp/TablePro/pull/4117) | Unknown |  |

## Data grid

| Feature | macOS | Linux | Windows | Notes |
|---|---|---|---|---|
| Virtualized grid with paging and an exact or estimated count | Yes | Yes | Unknown |  |
| Alternate row shading | Yes | Yes | Unknown |  |
| Values in the monospace font | Yes | Yes | Unknown |  |
| Row numbers stay in view while scrolling sideways | Yes | In PR [#4110](https://github.com/TableProApp/TablePro/pull/4110) | Unknown |  |
| Inline cell editing with pending changes, undo and redo | Yes | Yes | Unknown |  |
| Filters per column and as a WHERE fragment | Yes | Yes | Unknown |  |
| Open a referenced row and the rows that reference one | Yes | Yes | Unknown |  |
| Highlight rules (colour rows by a condition) | Yes | In PR [#4127](https://github.com/TableProApp/TablePro/pull/4127): kept per table in 4129; not kept for a query result | Unknown |  |
| The grid draws in the editor scheme's colours | Yes | In PR [#4128](https://github.com/TableProApp/TablePro/pull/4128) | Unknown |  |
| Show row numbers, row height and the text shown for NULL | Yes | In PR [#4134](https://github.com/TableProApp/TablePro/pull/4134) | Unknown |  |
| Font of the grid's cells | Yes | Partial ([#4135](https://github.com/TableProApp/TablePro/pull/4135)): family and size; no zoom | Unknown |  |
| Date format of the cells | Yes | In PR [#4142](https://github.com/TableProApp/TablePro/pull/4142): cells only; copy and export keep the database's text | Unknown |  |
| Default sort of a table (none, primary key, first column) | Yes | In PR [#4140](https://github.com/TableProApp/TablePro/pull/4140): one column | Unknown |  |
| The format Copy writes for several rows | Yes | In PR [#4137](https://github.com/TableProApp/TablePro/pull/4137) | Unknown |  |
| Open the row details when a row is selected | Yes | In PR [#4138](https://github.com/TableProApp/TablePro/pull/4138) | Unknown |  |
| Set Empty, NULL or DEFAULT on every selected row | Yes | In PR [#4136](https://github.com/TableProApp/TablePro/pull/4136): Empty, NULL, DEFAULT and expressions | Unknown |  |
| Mark spaces, tabs and line breaks in the value editor | Yes | In PR [#4141](https://github.com/TableProApp/TablePro/pull/4141) | Unknown |  |

## Bottom bar

| Feature | macOS | Linux | Windows | Notes |
|---|---|---|---|---|
| Columns button | Yes | In PR [#4118](https://github.com/TableProApp/TablePro/pull/4118) | Unknown |  |
| Time a page or a query took | Yes | Partial ([#4119](https://github.com/TableProApp/TablePro/pull/4119)): query results show it; table pages in the pull request | Unknown |  |
| Data and Structure in one tab | Yes | In PR [#4108](https://github.com/TableProApp/TablePro/pull/4108): one bar for it in 4111 | Unknown |  |
| JSON view of the rows | Yes | In PR [#4122](https://github.com/TableProApp/TablePro/pull/4122): table tabs; not query results | Unknown |  |
| Chart view of a result | Yes | No | Unknown |  |
| Map view of a result | Yes | No | Unknown |  |

## Row details

| Feature | macOS | Linux | Windows | Notes |
|---|---|---|---|---|
| Row details pane with an editor for the focused field | Yes | Yes | Unknown |  |
| Field rows with type badge, key and edit marks | Yes | In PR [#4112](https://github.com/TableProApp/TablePro/pull/4112) | Unknown |  |
| Field search and edited-only filter | Yes | In PR [#4113](https://github.com/TableProApp/TablePro/pull/4113) | Unknown |  |
| An editor inside each field row | Yes | No | Unknown |  |
| A row as JSON | Yes | Partial: a dialog from the grid menu, not a pane view | Unknown |  |

## SQL editor

| Feature | macOS | Linux | Windows | Notes |
|---|---|---|---|---|
| Highlighting, completion, snippets and formatting | Yes | Yes | Unknown |  |
| Move a query tab to another database | Yes | Yes | Unknown |  |
| The chosen colour scheme is drawn as chosen | Yes | In PR [#4109](https://github.com/TableProApp/TablePro/pull/4109) | Unknown |  |
| Dragging the results up keeps the query in view | Yes | In PR [#4120](https://github.com/TableProApp/TablePro/pull/4120) | Unknown |  |
| Vim keybindings | Yes | Yes | Unknown |  |

## Structure and schema

| Feature | macOS | Linux | Windows | Notes |
|---|---|---|---|---|
| Structure editor with a reviewed ALTER | Yes | Yes | Unknown |  |
| ER diagram | Yes | Yes | Unknown |  |

## History, import and export

| Feature | macOS | Linux | Windows | Notes |
|---|---|---|---|---|
| Query history with search, pins and export | Yes | Yes | Unknown |  |
| Saved queries | Yes | Yes | Unknown |  |
| Export results (CSV, JSON, Markdown, HTML, XML, Excel, SQL) | Yes | Yes | Unknown |  |
| Export a database as SQL and import a SQL file | Yes | Yes | Unknown |  |

## Assistant, MCP and account

| Feature | macOS | Linux | Windows | Notes |
|---|---|---|---|---|
| AI assistant | Yes | Yes | Unknown |  |
| MCP server for outside clients | Yes | Yes | Unknown |  |
| TablePro account and entitlement | Yes | Yes | Unknown |  |

## Window toolbar

| Feature | macOS | Linux | Windows | Notes |
|---|---|---|---|---|
| Safe Mode lock in the toolbar | Yes | In PR [#4124](https://github.com/TableProApp/TablePro/pull/4124) | Unknown |  |
| Refresh button | Yes | In PR [#4125](https://github.com/TableProApp/TablePro/pull/4125) | Unknown |  |
| Save Changes check | Yes | In PR [#4126](https://github.com/TableProApp/TablePro/pull/4126) | Unknown |  |
| Connection and database chips | Yes | Partial: the title names the connection and the sidebar holds every open connection and database; no chips | Unknown |  |
| Back and Forward through a tab's browse history | Yes | n/a: a referenced row opens in a new tab here, where macOS retargets the tab | Unknown |  |
| Actions menu (Preview SQL, Show and Copy DDL, Users and Roles, Query Insights, Server Dashboard) | Yes | Partial: Show CREATE TABLE is in the sidebar's menu; the rest is not built | Unknown |  |
| Reconnect after a lost connection | Yes | Yes | Unknown | On Linux it is the health banner's button. |
