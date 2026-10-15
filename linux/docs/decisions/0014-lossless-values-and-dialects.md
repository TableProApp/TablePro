# 0014: Lossless values and engine dialects

- **Status**: Accepted
- **Date**: 2026-10-15

## Context

The first `Value` had one integer type, one float type and a `rust_decimal` decimal, and a value the driver could not decode became NULL. Core built the app's SQL, matching on driver ids for each engine's spelling. The 2026-09-14 audit traced lost and wrong data to this. A decode failure read as NULL, so a save keyed on it wrote `WHERE id IS NULL` and matched no row (F-006). The grid filled its editors from display text, so text cut short for display and floats rounded by a spin button went back to the database (F-005). Columns were typed from their type names, and SQL was spelled for the wrong engine (F-018, F-021, F-022).

## Decision

A value goes from the server to the user and back without losing anything, and every piece of SQL the app writes is spelled by the dialect of the connection that runs it.

## Rationale

**Values that keep what the server sent.** `tablepro_core::Value` has a variant for each shape a value can take: `Int(i64)`, `UInt(u64)` and `WideInt` for integers past 64 bits; `Float32` and `Float64`, with NaN and the infinities kept; `Decimal(SqlDecimal)`, a validated decimal string that holds NaN, the infinities and every digit PostgreSQL's numeric allows; `Date`, `Timestamp` and `TimestampTz` wrapped in `Temporal`, which carries `infinity`, with `TimestampTz` holding an `OffsetTimestamp` that keeps the offset the server sent; `Time(SqlTime)`, which goes past 24 hours, and `TimeTz`; `Json(JsonText)`, the server's text, validated, in its own key order; and `Interval`, `Bits`, `Uuid` and `Array`. Two variants are not NULL and never become it: `Other` is a value the app has no type for but can show, and `Undecodable` is one the driver could not read. `BoundParam::new` refuses `Undecodable`, and a write whose row key holds one is refused as `UndecodableKey`, so it never reaches a `WHERE` clause. `Value` and the column types are in-memory types with no serde derive: nothing persists them.

**Kinds from the catalog.** Each driver gives every column a `ColumnKind` from its engine's catalog, with a `ColumnType` that also says how the column is read and bound: PostgreSQL from `pg_type`, its enums and its domains; SQL Server from `sys.types`; ClickHouse from its own type grammar; SQLite from its affinity rules and a table's STRICT flag; MySQL from `COLUMN_TYPE`, read by a scanner of its own because sqlparser has no ZEROFILL. `column::classify_type_name` in core is the fallback for a type only a name describes. sqlparser 0.63 reads a catalogue default through `parse_expression`, and `SqlDialect::parse_type` and `parse_expression` check the types and defaults a user types before they reach DDL.

**The dialect belongs to the connection.** `Connection::dialect()` returns the `SqlDialect` the driver built from the `ServerInfo` of the server it connected to, such as the version and, for MySQL, the flavour, and never from session state ([adding-drivers.md](../adding-drivers.md#7-dialects)). A reconnect builds it again, so SQL is never spelled for the server before. It quotes names, renders placeholders and literals, escapes LIKE patterns and writes the LIKE predicate, projects each column for reading, writes row windows, keyset predicates and engine row ids, writes UPDATE, DELETE and the key probe, classifies SQL for the history, and plans DDL ([ADR 0010](0010-ddl-plans-and-table-definitions.md)). Core holds the structure of a statement and no engine's spelling: `browse::build_page`, `plan_save` and the export builders ask the dialect for every engine-specific part, and `Connection` has no `fetch_rows`.

**One encoding decision.** `SqlDialect::placeholder` takes the value and the column it is bound to and returns a `Placeholder`: the SQL that names the parameter and, unless the engine has no parameters, a `BoundParam`. `BoundParam::new` is the only way to build one, and it checks the value against the `ParamType` the dialect chose, so the driver binds what the marker decided and a value that does not fit fails before anything is sent. ClickHouse names its parameters `{p<n>:<type>}` from the same decision.

**PostgreSQL reads by read form.** No statement is prepared under a name, so the driver works behind PgBouncer with `max_prepared_statements = 0` ([ADR 0016](0016-driver-contract-v2.md)). tokio-postgres would look a type it has no decoder for up with a named statement, so the catalogue marks each column's `ReadForm`: `Native` for a type with an exact binary decoder, `ServerText` for any other, projected as `::text`, and `ServerNumeric` for money, projected as `::numeric`. Every result column is then a built-in type, and every value still arrives exact. SQL Server reads money the same way in a table tab, cast to a decimal of its own scale.

**Edits from exact text.** `edit_text` fills an editor from the value, never from the grid's display text. `parse_edit_text` turns what the user typed back into a value for the column, and what an empty field means depends on the `EditContext`: an inserted row's empty field can take the column's default, an updated row's cannot. `is_unchanged` compares the result with the value it came from, so opening and closing an editor records no edit.

**Saves prove their rows.** `plan_save` gives every update and delete a `RowGuard` from how the row is identified, and an insert none: `AffectedExactly` for a unique key on an engine that counts affected rows exactly, or for the engine's own row id, and `ProbeExactly`, a count read first in the same transaction, otherwise. A guard that fails stops the save: an engine with transactions takes it all back, and one without reports how far it got ([ADR 0016](0016-driver-contract-v2.md)). A table with no key that identifies a row takes inserts and refuses row changes.

**Literals that read the same everywhere.** A value copied as SQL or exported as INSERT goes through `SqlDialect::literal`, which writes it so the server reads it the same under any session setting: PostgreSQL through `postgres_protocol`'s escaping, MySQL as a hex string literal once the text holds a backslash or a control character, so `NO_BACKSLASH_ESCAPES` cannot change it. A value no literal can spell is exported as NULL with a comment that says so, and copying it is refused. The app's own MySQL workspace sessions pin `sql_mode` and the time zone, because generated DDL has literals with no hex form ([drivers/mysql.md](../drivers/mysql.md)).

## Consequences

- A new engine brings a dialect, a decoder and a catalogue classifier in its driver crate ([adding-drivers.md](../adding-drivers.md)), and core gains no branch on a driver id.
- A column of a type the app does not model still shows its value, as `Other` or the server's text, and never as NULL.
- An editor tab's PostgreSQL result columns arrive as text: the simple protocol gives them no type, until rust-postgres #1358 ships ([drivers/postgresql.md](../drivers/postgresql.md)).
- MySQL's `tinyint(1)` is a boolean stored as an integer: it edits as a toggle, and a stored value other than 0 or 1 shows the toggle as inconsistent, with the exact value in its tooltip.
- CSV formula neutralisation follows the value's variant: free text, JSON and `Other` are neutralised, and a number, date or UUID is written as it is.
- JSON keeps its key order end to end: `clippy.toml` bans `serde_json::Map`, which sorts keys.
- ClickHouse binds every value but NULL as a typed server-side parameter, `{p<n>:<type>}`, rather than writing a literal into the statement.
- The `f006_` tests and the conformance case `f006_unsupported_types_never_decode_as_null` guard the decode rule on every engine ([regression-tests.md](../regression-tests.md)).

## Alternatives considered

- **Text for every value the app cannot type.** Binding text into a PostgreSQL enum or domain fails, and the app could not tell editable text from bytes it could not read.
- **One `Unknown` variant.** The same problem: a value the app can show and edit as text and one it could not read at all need different handling.
- **rust_decimal or bigdecimal.** rust_decimal stops at 28 digits and neither has NaN, which PostgreSQL's numeric holds.
- **serde_json::Value for JSON.** Its map sorts keys, so a document would come back reordered.
- **Typing PostgreSQL columns with a prepared statement.** A named statement is what a transaction pooler forbids.
- **One SQL builder in core, keyed by driver id.** The design the audit found spelling SQL for the wrong engine; it also cannot follow a server's version.
