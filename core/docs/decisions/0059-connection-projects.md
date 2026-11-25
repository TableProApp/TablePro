# 0059: Connection projects scope the library, stored as optional keys of version 1

- **Status**: Accepted
- **Date**: 2026-11-20

## Context

Every app lists the whole connection library: search, Recent, saved queries, history and the MCP server's `list_connections` all show every connection, so a user who works on several products sees them mixed ([#4307](https://github.com/TableProApp/TablePro/issues/4307)). The library ([0006](0006-connection-library.md)) has groups, tags and favourites, and nothing above a connection. History and saved queries are keyed by connection id.

## Decision

`connections.json` holds a list of projects. A top-level group or an ungrouped connection names its project by id, `ConnectionList::scoped(project)` gives the list one project shows, and the keys are optional keys of version 1.

- **Project.** `ConnectionProject`: `id`, `name` (`ConnectionProjectName`), `order`, and an optional `color` and `icon` of the types a group uses. All Connections is no project: it has no entry and cannot be renamed or deleted.
- **Membership.** A connection is in at most one project. A top-level group's `project_id` is its project, and its subtree and their connections follow it. A connection's own `project_id` counts only while it has no group. `ProjectMembership`, `ConnectionList::effective_project` and `effective_group_project` are the one reading of this. A `project_id` stored on a subgroup or on a grouped connection is ignored.
- **Scope.** `ConnectionList::scoped(Some(id))` keeps the project's connections, its groups (empty ones too), the favourites among them, and every tag and project. `None`, and an id no project holds, give the whole list: the fallback for a deleted project a setting still names is in this function. `recent` and `connections_in` of the result are the project's. Lookups by id stay on the unscoped list.
- **The active project is the app's.** It is a per-device view preference, as 0006 leaves sort mode and the Recent switch to each app, so it is not in `connections.json` and each caller passes it in.
- **Writes.** `ConnectionStore` creates, renames, recolours, reorders and deletes projects, and moves ungrouped connections and top-level groups to a project. Deleting a project keeps its groups and connections, in no project. `move_connections_to_project_blocking` refuses a grouped connection with `ConnectionGrouped`, since moving its top-level group would take the connections beside it along; `move_groups_to_project_blocking` refuses a subgroup with `GroupNotTopLevel`.
- **One normalizer.** `keep_membership` runs on every local change and on no cloud pull. Only a top-level group and an ungrouped connection store a project. A connection filed in a group drops its own; one moved out to the top, or left there by a deleted group, stays in the project it was in unless the change named another. A group moved under another drops its own; a subgroup moved to the top stays in the project of the top-level group it left.
- **Names.** A project name follows the group name's rules: shown form, NFC, not empty, no control characters. Two projects may not share a name in any case (`ProjectNameTaken`). A top-level group's name is its own among the top-level groups of its project, so two projects each have a `Production`.
- **Repair.** Every read and write drops a `project_id` no project holds, keeps the first of two projects with one id, and numbers the projects from 0.
- **Import and export.** An export is the whole document, projects included. An import matches a project by id, then by name in any case (the first in order when two share one), and adds the rest. A top-level group is matched by name among its project's groups. `preview_import_into_blocking` and `ImportedConnection::project_id` name the project that whatever the file files under none lands in; an entry the import only updates keeps its project unless the file names one.
- **History and saved queries.** No schema change. `HistoryQuery::connections`, `QueryHistory::connections_with_history_in` and `SavedQueries::list_for` take the scope's connection ids, bound as one JSON array read through `json_each`, so a large project stays under SQLite's limit on bound parameters.
- **Through the FFI.** `ConnectionLibrary::snapshot` stays the whole library for readers by id, and `snapshot_in(project_id)` is the scoped one, with `LibrarySnapshot.projects` and the resolved `scope`. `ConnectionRecord.project_id` and `GroupRecord.project_id` are the project the entry shows in, so an app never works membership out itself; on `save` the field places a connection with no group and `None` keeps the stored one. `create_project`, `rename_project`, `set_project_color`, `delete_project`, `move_projects`, `move_to_project` and `move_groups_to_project` are the writes. `create_group`, `import_file`, `export_file` and `ForeignImportReview::apply` take the project; a project's export holds its connections, its groups, the tags they use and that project alone (`ConnectionStore::export_scoped_blocking`). `QueryHistoryStore::search` takes a project and resolves its connections in the core, so paging stays there, and `delete_for_connection` removes a deleted connection's runs. `McpService::set_active_project` is what `McpHost::active_project` returns for the FFI's host.
- **MCP.** `McpHost::active_project` (default `None`) is read for each call. `ToolContext::visible_library` is the scoped list without the blocked connections, so `list_connections`, and the command line, which resolves every connection through it, follow the project. A call by id to a saved, unblocked connection outside the project fails with `out_of_scope`; a blocked one stays `not_found`.

## Rationale

- **A project is an entity, not a root group or a tag.** A group is a place in a tree and a tag marks many connections; the maintainer's decision is one project per connection, with groups inside it and tags shared.
- **Membership on the top-level group.** A subtree cannot straddle two projects, and a move of one group moves everything in it. The read rule (the top-level group decides) makes a stale id below it harmless, which matters when a sync merges two devices' edits field by field.
- **Optional keys, not version 2.** A version bump makes every build before this one refuse the file ([storage.md](../../../linux/docs/storage.md), Changing a format), and both apps on the core have released builds. With optional keys an older build opens the library and shows every connection.
- **A scope function over the list, not a filtered store.** Tab titles, session restore, deep links and the session registry look a connection up by id whatever the project; only listings narrow. A pure function also makes Recent correct: it is computed after the filter.
- **A refusal for a grouped connection.** The other moves change the entries named and no others. Moving the top-level group instead would move connections the caller did not name.
- **`out_of_scope` apart from `not_found` and `denied`.** The connection's window can still be open in the app, so "no connection has the id" would be false, and the user's settings did not refuse it.

## Consequences

- **An older build erases projects on its next write.** It reads the file, drops the keys it does not know and writes the list without them. In the core that is the next connect, since `touch_last_opened_blocking` writes on every one. The connections, groups, tags and favourites are kept; the project list and every membership are gone. `a_build_before_projects_reads_a_list_with_them_and_drops_them_on_its_write` pins it.
- The MCP scope is a listing scope the user switches in the app, not an access control. Tokens, External Clients levels and write approvals are unchanged, and it can change between two calls of one client.
- `apply_cloud_pull_blocking` keeps each group's and connection's `project_id`: no CloudKit record carries one in the core's mapping ([0010](0010-macos-on-the-core.md)), and a pull never normalizes.
- Deleting a project can leave two top-level groups of one name in no project. They stay two groups, as an import's `Work` and `work` do, and still reorder.
- `move_connections_to_group_named_blocking` takes the project to look the name up in at the top.
- Errors: `storage.project_not_found`, `project_exists`, `project_name_taken`, `connection_grouped`, `group_not_top_level`; `project_name.empty` and `project_name.control_character`; the tool code `out_of_scope`.

## Alternatives considered

- **Version 2 with an upgrade step.** No silent loss, but an older build refuses the whole library, and a user who runs two builds side by side loses access to every connection instead of the project list.
- **Membership in the project (group ids and connection ids per project).** An older build would still drop the `projects` key, and two lists would have to agree on every move and delete.
- **`project_id` on every group and connection.** A subgroup could disagree with its parent, and each move would rewrite a subtree.
- **A scoped `ConnectionStore`.** By-id readers would need a second, unscoped store, and a switch would look like a change of the list to every subscriber.
