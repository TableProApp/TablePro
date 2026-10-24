# 0026: Document collections open in the table tab, and their statements are shell calls

- **Status**: Accepted
- **Date**: 2026-10-24

## Context

[ADR 0021](0021-engines-without-sql.md) kept one driver contract for engines without SQL and left a document engine to add its own `DataModel` and listing. MongoDB holds databases of collections, and a collection is what a user browses, filters, sorts, pages, edits a field of, inserts into, deletes from and exports: everything the table tab already does for a table, with its paging, its filter strip, its save review and Safe Mode, its export and the MCP server's reads. The table tab reaches the engine through the builders in `tablepro-core` (`build_page`, `build_count`, `build_export`, `plan_save`, `build_filter`), which write SQL through the connection's `SqlDialect`.

## Decision

A document engine states `DataModel::Document`, lists databases as schemas and collections and views as tables and views, opens a collection in the table tab, and every builder writes the engine's own shell statement, a mongosh call with each value bound as `$n`, through a document arm chosen by the dialect's grammar (`SqlGrammar::Mongo`, `tablepro_core::document`).

## Rationale

- The table tab's paging, keyset over a key, filter rules, save review, row guards, Safe Mode gate, history, export and MCP reads are the work the user asked for, and each already reaches the engine through one builder. A document arm per builder keeps all of it, and each arm is tested where its SQL sibling is.
- One language for generated statements and the editor: what the history and the Safe Mode dialog show is text the editor runs as it is, and the driver reads both through one parser, so a generated statement passes the same read-only check as a typed one.
- A collection's top-level fields are its columns, `_id` first and the key, with nested documents and arrays as JSON cells in Extended JSON. A grid of fields is what a document browser shows, and the JSON cell keeps every BSON type through an edit.
- Values stay bound parameters, never spliced into the text, as [ADR 0014](0014-lossless-values-and-dialects.md) requires of SQL.

## Consequences

- `DataModel` has `Document`. The workspace reads it with `Relational` for the sidebar and the table tab, and keeps out what is SQL's only: the structure editor, `CREATE TABLE` in the sidebar menu and the grid's `IN` filter from a selection.
- `SqlGrammar::Mongo` has its module, `sql_syntax/mongo`: lexer, parser, printer, statement split, access, history and catalogue-change rules. A document dialect's `literal`, `placeholder` and `quote_identifier` write shell text, and its `ddl()` is `None`.
- A field whose name holds a `.` or starts with `$` is shown, read through `$getField`, and cannot be filtered, sorted or edited, since a query cannot name it.
- `NetworkOptions` on a saved connection carries what one engine reads beyond host, port and database (DNS Seed List, Authentication Database), offered where `DriverCapabilities::network_options` lists it.
- `document_conformance_suite!` is a document engine's contract test, beside the TLS suite.
- The client library builds TLS from files for the servers it dials, so the driver writes the system store and the CA file as one bundle, and a client identity, into a private directory for the moment the client is built (`docs/drivers/mongodb.md`, Trust).

## Alternatives considered

- **A document tab of its own.** A tree of documents per collection would have needed its own paging, filter, edit, save review, Safe Mode gate, export and MCP path, each a second copy of the table tab's, and each a place for the two to drift.
- **Generated statements as server command documents.** Builders could have written the `find` or `aggregate` command as BSON instead of shell text. The history and Safe Mode would then show documents the editor cannot run, and the driver would need a second reader and a second read-only check.
- **SQL over documents.** Translating SQL to aggregation pipelines would have let the SQL builders run unchanged, but a user would read SQL the server never ran, and fields with any type in any document do not fit SQL's columns.
