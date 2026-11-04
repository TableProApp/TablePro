# Architecture Decision Records

Decisions that hold for every platform that builds the shared core: its crates, their contracts and how each app reaches them. A decision only one app makes goes in that app's folder, such as `linux/docs/decisions/`.

The format, the statuses and how a later ADR changes an earlier one follow [the Linux decisions' README](../../../linux/docs/decisions/README.md). An ADR here that changes a Linux ADR updates only that ADR's Status line and its row in the Linux index.

## Index

| # | Title | Status | Summary |
|---|---|---|---|
| [0001](0001-shared-core.md) | One shared Rust core, a native UI per platform | Accepted | The UI-free crates move to `core/crates` and build on Linux, Windows and macOS; each app keeps a native UI and passes its platform services in. |
| [0002](0002-uniffi-bindings.md) | One UniFFI API for Swift and C#, with a C ABI beside it | Accepted | UniFFI proc macros in the core; Swift through UniFFI's generator and C# through uniffi-bindgen-cs v0.11.1+v0.31.0, each with a thin layer for cancel, progress, streams and off-UI-thread calls; `extern "C"` and csbindgen for hot paths and as the fallback. |
| [0003](0003-result-windows-for-native-grids.md) | The core owns the result set, and a native grid pulls windows of text | Accepted; amended by 0007 | A columnar result set in the core; one packed UTF-8 window per visible range with exact, locale-free text; one coalesced rows-arrived callback; Arrow only for bulk export. |
| [0004](0004-driver-plugin-abi.md) | Downloadable drivers over a small C ABI of our own | Accepted | A static descriptor, minor-version negotiation, protobuf messages, Arrow C Data rows, a runtime per driver and `catch_unwind` at every export; signed per platform, never unloaded, linked statically on iOS. |
| [0005](0005-sql-server-transport.md) | SQL Server on tiberius everywhere, with Kerberos added and ODBC as a Windows option | Accepted | tiberius on every platform with SSPI Negotiate added in a fork, Entra ID tokens from the core, and an optional Windows connection type over an installed ODBC Driver 18 for Always Encrypted; msodbcsql18 is never bundled. |
| [0006](0006-connection-library.md) | The connection library holds a group tree, manual order and favourites | Accepted; how the Linux app shows groups superseded by linux 0032 | Groups form a tree by id, connections and groups carry an explicit order, favourites are one ordered list; version 2 group names become top-level groups. |
| [0007](0007-sorting-a-result.md) | A sort names its column by name or position, else the core sorts the rows held | Accepted | `sort_reference` names a unique plain column, else its position on PostgreSQL, SQLite, SQL Server and DuckDB; otherwise, and for a statement that cannot run again, `value::order` sorts the rows held, which `ResultSet::sorted` gives the FFI as a view. |
| [0008](0008-importers-from-other-apps.md) | Importers from other apps live in the core | Accepted | One crate reads each app's files on every platform into one record shape, takes keychains and directories from the app, says what it cannot carry, and reviews the result against the library with the macOS duplicate handling. |
