# Query result byte-budget profile, October 22

This is a historical measurement of the recorded source, not current acceptance. Later driver repairs and PostgreSQL measurements are recorded in [query row decoding budget](../../../evidence/query-row-budget-2026-10-22/README.md); later editor-scroll measurements are recorded in [editor scrolling resources](../../../evidence/editor-scroll-resources-2026-10-23/README.md).

Tracker: [#1382](https://github.com/cozyGarage/BookiE/issues/1382). Source: Linux `ad9bb1447163c848919616773ab0971c5a2d2135`, with the committed workspace `Cargo.lock`.

## Finding

`MAX_QUERY_RESULT_BYTES` is 64 MiB. The SQLite collector converts the whole row to `Value`s before calling `QueryResultBudget::admit`. The PostgreSQL collector and MySQL result collector use the same order. A row rejected by the retained-result budget can therefore allocate the raw cell and a decoded copy first.

## Measurement

A release-mode probe used the SQLite driver in a standalone process to query one generated text cell with `SELECT printf('%<size>s', 'x')`. Each size ran in a fresh process. `/usr/bin/time -v` reported maximum resident set size:

| Cell size | Returned rows | Truncated | Maximum RSS | Query time |
| ---: | ---: | --- | ---: | ---: |
| 8 MiB | 1 | no | 33,328 KiB | 9 ms |
| 64 MiB | 0 | yes | 205,424 KiB | 58 ms |
| 128 MiB | 0 | yes | 402,044 KiB | 113 ms |

The 128 MiB cell is refused and not retained, but the process reaches about 393 MiB RSS while decoding it. RSS includes the runtime and SQLite overhead. This is a driver-level reproduction, not a whole GTK app measurement. PostgreSQL production profiling remains unverified.

## Reproduction

Build a small release example inside `crates/drivers/sqlite/examples` with the root lockfile. Connect `SqliteDriver` to `:memory:`, run `connection.query(&format!("SELECT printf('%{payload_bytes}s', 'x') AS payload"))`, and print row count plus `truncated`. Run once per size so each measurement has a fresh process:

```sh
/usr/bin/time -v target/release/examples/resource_budget_probe 134217728
```

The result should contain zero rows and `truncated=true`; maximum RSS should substantially exceed the 64 MiB retained-result limit.

## Acceptance target

Check or reserve the row budget before conversions that copy or expand raw values, while preserving type decoding and the explicit truncation flag. Add a regression for a single row larger than the budget and cover PostgreSQL and the other affected driver collectors. Track implementation in [#1382](https://github.com/cozyGarage/BookiE/issues/1382).
