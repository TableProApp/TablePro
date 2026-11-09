# Feature parity

Which of the macOS app's features the Linux and Windows apps have. A feature with no row has not been compared yet.
What the Linux app does in each area, in detail: [linux/ROADMAP.md](../../linux/ROADMAP.md#implemented).

`scripts/feature-parity.py` writes this file from [features.yml](features.yml). Edit that file, then run the script.

| Status | Meaning |
|---|---|
| Yes | On `main`. |
| In #N | In that open pull request. |
| Partial | Part of it is on `main`. The note says which part. |
| No | Not built. |
| n/a | Does not apply to that app. The note says why. |
| Unknown | Not checked yet. |

## Connections

| Feature | Linux | Windows |
|---|---|---|
| Saved connections, groups, favorites and tags | Yes | Yes |
| SSH tunnels with jump hosts | Yes | Partial: no jump hosts |
| Safe Mode per connection (off, confirm writes, read only) | Yes | Partial: Confirm Writes does not ask before a write |
| Import connections from other apps | Yes | No: imports a TablePro JSON file only |
| Application menu with Quit | Yes: a main menu, since GNOME apps have no menu bar; [#4139](https://github.com/TableProApp/TablePro/pull/4139) splits the session's commands into a menu of their own | Yes |
| The server's other databases in the sidebar | Yes: each opened from the sidebar's menu | No |

## Sidebar

| Feature | Linux | Windows |
|---|---|---|
| Schemas and tables, with search | Yes | Yes |
| A schema's objects grouped by kind | In [#4159](https://github.com/TableProApp/TablePro/pull/4159) | Yes |
| Width set by dragging its edge | In [#4155](https://github.com/TableProApp/TablePro/pull/4155) | Yes |
| Toggle in the window header | Yes | Partial: View > Object Tree and Ctrl+B; no button in the title bar |
| Bottom bar with an Add menu | In [#4146](https://github.com/TableProApp/TablePro/pull/4146) | No |
| Choose which schemas the sidebar lists | In [#4150](https://github.com/TableProApp/TablePro/pull/4150) | No |
| Tables and Favorites scope switch | Yes | No |
| Favorite folders | In [#4130](https://github.com/TableProApp/TablePro/pull/4130) | No |
| Favorite keywords that expand in the editor | No | No |
| Favorite tables and databases, with environments | No | No |
| Open Quickly (find a table by name) | In [#4121](https://github.com/TableProApp/TablePro/pull/4121): tables and views; saved queries in [#4133](https://github.com/TableProApp/TablePro/pull/4133), past queries in [#4144](https://github.com/TableProApp/TablePro/pull/4144) | Partial: Ctrl+P moves to the sidebar's filter |

## Data grid

| Feature | Linux | Windows |
|---|---|---|
| Virtualized grid with paging and an exact or estimated count | Yes | Yes |
| Alternate row shading | Yes | No |
| Values in the monospace font | Yes | No |
| Row numbers stay in view while scrolling sideways | Yes | Yes |
| Inline cell editing with pending changes, undo and redo | Yes | No |
| Filters per column and as a WHERE fragment | Yes | No |
| Open a referenced row and the rows that reference one | Yes | No |
| Set Value on every selected row (Empty, NULL, DEFAULT, UUID, an expression, any value) | Partial: Empty, NULL, DEFAULT and the engine's expressions | No |
| Show row numbers, row height and the text shown for NULL | Yes | No |
| Highlight rules (color rows and cells by a condition) | In [#4127](https://github.com/TableProApp/TablePro/pull/4127): kept per table in [#4129](https://github.com/TableProApp/TablePro/pull/4129) | No |
| The grid in the editor theme's colors | In [#4128](https://github.com/TableProApp/TablePro/pull/4128) | No |
| Font of the grid's cells, and zoom | In [#4135](https://github.com/TableProApp/TablePro/pull/4135): family and size; no zoom | No |
| Date format of the cells | In [#4142](https://github.com/TableProApp/TablePro/pull/4142) | No |
| Default sort of a table (none, primary key, first column) | In [#4140](https://github.com/TableProApp/TablePro/pull/4140) | No |
| The format Copy writes for several rows | In [#4137](https://github.com/TableProApp/TablePro/pull/4137) | No: copies tab-separated values only |
| Open the row details when a row is selected | In [#4138](https://github.com/TableProApp/TablePro/pull/4138) | No |
| Mark zero-width, control and special space characters in the value editor | No: [#4141](https://github.com/TableProApp/TablePro/pull/4141) marks spaces, tabs and line breaks instead | No |

## Bottom bar

| Feature | Linux | Windows |
|---|---|---|
| Columns button | Yes | No |
| Time a page or a query took | Yes | Yes |
| Data and Structure in one tab | Yes | No |
| JSON view of the rows | In [#4122](https://github.com/TableProApp/TablePro/pull/4122): table tabs; not query results | No |
| Chart view of a result | No | No |
| Map view of a result | No | No |

## Row details

| Feature | Linux | Windows |
|---|---|---|
| Row details pane | Yes | No |
| Type, key and edit marks on a field | Yes | No |
| Foreign key mark on a field | In [#4131](https://github.com/TableProApp/TablePro/pull/4131) | No |
| Field search and an edited-only filter | Yes | No |
| A field drawn as its name over its value | In [#4156](https://github.com/TableProApp/TablePro/pull/4156) | No |
| An editor inside each field row | In [#4157](https://github.com/TableProApp/TablePro/pull/4157) | No |
| A menu on each field | In [#4158](https://github.com/TableProApp/TablePro/pull/4158) | No |
| A row as JSON | Partial: a dialog from the grid's menu, not a view of the row details | No |

## SQL editor

| Feature | Linux | Windows |
|---|---|---|
| Highlighting, completion, snippets and formatting | Yes | Partial: highlighting only |
| Move a query tab to another database | Yes | No |
| Color schemes | Yes | No |
| Vim keybindings | Yes | No |

## Structure and schema

| Feature | Linux | Windows |
|---|---|---|
| Structure editor with a reviewed ALTER | Yes | No |
| ER diagram | Yes | No |

## History, import and export

| Feature | Linux | Windows |
|---|---|---|
| Query history with search, pins and export | Yes | No |
| Saved queries | Yes | No |
| Export results (CSV, JSON, Markdown, HTML, XML, Excel, SQL) | Yes | No |
| Export a database as SQL and import a SQL file | Yes | No |

## Assistant, MCP, account and command line

| Feature | Linux | Windows |
|---|---|---|
| AI assistant | Yes | No |
| MCP server for outside clients | Yes | No |
| TablePro account and entitlement | Yes | No |
| The `tablepro` command line tool | In [#4145](https://github.com/TableProApp/TablePro/pull/4145) | No: `tablepro.exe` opens the app and reads no arguments |

## Window toolbar

| Feature | Linux | Windows |
|---|---|---|
| Safe Mode level in the toolbar | In [#4124](https://github.com/TableProApp/TablePro/pull/4124) | No |
| Refresh button | Yes | Yes |
| Save Changes button | In [#4126](https://github.com/TableProApp/TablePro/pull/4126) | No |
| Connection and database chips | Partial: the title names the connection and the sidebar lists every open connection and database; no chips | Partial: the title bar names the connection; no database chip |
| Back and Forward through a tab's browse history | n/a: a referenced row opens in a new tab, where macOS moves the tab to it | No |
| Actions menu (Preview SQL, Show and Copy DDL, Users and Roles, Query Insights, Server Dashboard) | Partial: Show CREATE TABLE is in the sidebar's menu; the rest is not built | No |
| Reconnect after a lost connection | Yes | Yes |
