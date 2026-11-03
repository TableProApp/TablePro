# 0007: A sort names its column by name or position, else the core sorts the rows held

- **Status**: Accepted
- **Date**: 2026-11-03

## Context

- macOS sorts a query result by running its statement again with `ORDER BY "<name>"`, and sorts the rows it holds when the statement cannot run again (`RowSortComparator`, `TableRowsSorting`). Linux sorts the rows it holds with GTK sorters over its own `value_order`. Windows needs both, and ADR [0003](0003-result-windows-for-native-grids.md) left a client sort open.
- A name cannot always reach a column. A join with two `id` columns makes `ORDER BY "id"` ambiguous. An unnamed expression's name is not an identifier: SQLite takes a double-quoted word that names no column as a string literal ([quirks](https://sqlite.org/quirks.html)), so `ORDER BY "count(*)"` sorts by a constant, with no error.
- Positions, by engine docs:
  - PostgreSQL, SQLite, SQL Server and DuckDB take `ORDER BY 2`. SQL Server advises against it but supports it.
  - MySQL 8.4 takes it but marks it deprecated: "the syntax has been removed from the SQL standard".
  - ClickHouse reads a position only under `enable_positional_arguments`, on by default. With it off, `ORDER BY 2` sorts by a constant.

## Decision

`sql_syntax::sort_reference` names the column when the name is unique among the result's columns, case folded, and its select item is an unqualified column, an alias or part of a bare `*`. Otherwise it gives the column's position on PostgreSQL, SQLite, SQL Server and DuckDB. Otherwise it gives nothing, and the host sorts the rows the result holds with `value::order`, as it does for a statement that cannot run again. The FFI's `ResultSet::sorted` is that sort, as a view over the same store.

## Rationale

- A name stays the first choice: it is what macOS writes, and it reads well in the history.
- MySQL and ClickHouse get no positions. On a server that does not read the number as a position, the rows come back unsorted with no error, which is worse than sorting the rows held.
- A qualified `t.col` is named only on MySQL, which looks an ORDER BY name up in the select list first. SQLite looks it up in the FROM tables, where a join can hold two.
- One ordering for every app: Linux's `value_order` moved to `tablepro_core::value::order` with its tests, and Windows reads it through the FFI.

## Consequences

- The rows held, as `row_order` orders them:
  - NULL first, and last when descending, since descending is the comparison reversed. Equal values keep their arrival order.
  - Each value orders by its own kind. Numbers compare exactly across integer, float and decimal kinds, NaN after every number. Dates and timestamps compare by instant with the infinities at the ends, intervals by length, UUIDs, bits and bytes by content.
  - A column that can hold text orders by storage class first: NULL, numbers, text, blobs. Text compares by the head `sort_text` gives, 4,096 characters: digit runs by value, the rest by code point, case counting.
- How this differs from macOS:
  - macOS picks the comparison from the column's declared type: `Int64` for integers, `Double` for decimals, else the text with `.numeric`. The core is exact past `Int64` and `Double`, orders a SQLite column that mixes kinds, and orders timestamps with an offset by instant.
  - macOS compares bytes as hex text, and a NULL ties with an empty string. In the core a NULL comes first.
  - Foundation treats canonically equivalent text as equal. The core compares code points, so a precomposed and a decomposed é differ.
  - macOS runs SHOW and EXPLAIN again with an ORDER BY. `with_order_by` refuses them, so the core sorts their rows.
- Linux keeps `GtkStringSorter` for text, which collates in the user's locale. It takes everything else from `value::order`.
- The FFI store keeps display text, a kind and a `raw` per cell, not `Value`s. A sort rebuilds the column's values from those. Kinds kept only as text order by that text: arrays, network addresses, spatial values and `Other`.
- A sorted set reads the rows through its order. Rows that arrive after the sort follow in arrival order.

## Alternatives considered

- **Always a position.** It breaks no name, but MySQL deprecates it and ClickHouse can ignore it.
- **Wrap the statement, `SELECT * FROM (...) s ORDER BY ...`.** MySQL and SQL Server refuse a derived table with two columns of one name, the case this is for.
- **A locale collation for text in the core.** macOS sorts the rows it holds by code point with numeric runs, so Windows does too. Linux keeps GTK's collation.
