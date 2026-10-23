# Performance review and first phases, October 22–23

A source review of the workspace for performance and maintainability, followed by the first two delivery phases. Source context: `linux` at `28730f745` (review) and `248735cc3` (revalidation). Findings below were confirmed by reading the code; measured numbers name their benchmark. Open items live on [Project #3](https://github.com/users/cozyGarage/projects/3) and the issues linked here.

## Delivered

| Change | Pull request | Measured result |
| --- | --- | --- |
| Store `Value::Json` out of line; budget counts the boxed allocation | [#1452](https://github.com/cozyGarage/BookiE/pull/1452) | `size_of::<Value>()` 72 to 32 bytes. `materialize_profile` (6-column SQLite): 100,000 rows use 37.8 MB instead of 60.7 MB; the 64 MiB result budget admits 209,754 rows instead of 120,019. The installed app loaded 215,804 of 300,000 rows. |
| Compile mask patterns once per guard; skip projection analysis when results are not masked | [#1453](https://github.com/cozyGarage/BookiE/pull/1453) | Not benchmarked. Masking decisions unchanged. |
| Relm4 runtime uses 2 to 4 workers instead of 1 | [#1455](https://github.com/cozyGarage/BookiE/pull/1455) | Not benchmarked. |
| `dist` Cargo profile (thin LTO, one codegen unit, `panic = "unwind"`) for released packages; `BOOKIE_BUILD_PROFILE=release` for test builds | [#1458](https://github.com/cozyGarage/BookiE/pull/1458) | Stripped `bookie` 53.7 to 41.3 MB, `bookie-agentd` 42.2 to 32.2 MB. Cold build 248 to 362 s (16 cores). No runtime difference beyond noise. |
| PostgreSQL GTK e2e keeps the caller's Cargo and rustup homes | [#1459](https://github.com/cozyGarage/BookiE/pull/1459) | `e2e (postgres)` had reinstalled Rust and compiled 519 crates on every Forgejo run. |
| `ci` profile for GUI scenario binaries; CI build-speed proposal | [#1464](https://github.com/cozyGarage/BookiE/pull/1464), [proposal](../proposals/ci-build-speed.md) | App rebuild after a `crates/core` edit: 76–96 s (`release`) to 63–64 s (`ci`). |
| Audit journal appends verify only records written since the last check; the full chain is verified at open, by `verify_chain()` and by `recent()` | [#1467](https://github.com/cozyGarage/BookiE/pull/1467) | Per append: 14.3 ms to 0.046 ms at 5,000 records, 163.9 ms to 0.047 ms at 50,000 records. Maintainer decision recorded in [storage](../storage.md). |

## Remaining plan

The phases continue in this order. Each item needs its lane and a failing test first.

1. **UI freezes (UX).** Defer the first fetch of restored hidden table tabs. Batch change-tracker events per user action and add a row-key index to `RowStore` (paste, discard and undo scan every row per cell). Search loaded rows by reference. Iterate the selection bitset in editor results. Compute the bind key once per cell. Pass `Arc<QueryResult>` to export. Browse row lookup by key is in [#1481](https://github.com/cozyGarage/BookiE/pull/1481).
2. **I/O.** Write only changed workspace drafts. Cache one Secret Service handle per process, never the secrets. Give agentd's session cache a cheap fingerprint. History `synchronous=NORMAL` needs a maintainer decision.
3. **Drivers (B3).** Add `ColumnInfo::result` and a capped-collection helper first, then pick decoders per column, execute PostgreSQL's prepared statement instead of re-sending it, stream DuckDB to the cap, pipeline Redis per-key commands, and send MySQL session setup in one round trip. SQL Server reconnect-instead-of-drain needs a maintainer decision.
4. **Maintainability.** Extract the repeated authorize, audit, execute, mask and audit sequence in `policy/src/guard/connection.rs`. Tokenize each statement once in the classifier. Split files at the 1,200-line ceiling when they are next edited (`ssh/lib.rs`, `transport/lib.rs`, `policy/rules.rs`, `browse_tab/row_ops.rs`, `editor/mod.rs`, `editor/session_mode.rs`). Merge the four atomic-write helpers.
5. **CI.** Shard the `debian:testing` floor scenarios after the runner upgrade; the workflow change needs the app-side session's agreement ([proposal](../proposals/ci-build-speed.md)).

## Follow-ups found during the work

- The SSH key decoding and other blocking calls on the async runtime are B4 work and were left out of #1455.
- `json_heap_size` does not count `arbitrary_precision` number digits or the `IndexMap` index table; both predate #1452.
- Defects from the [native Wayland run](../evidence/installed-wayland-0.2.0-2026-10-23/README.md): fixes in [#1485](https://github.com/cozyGarage/BookiE/pull/1485) and [#1492](https://github.com/cozyGarage/BookiE/pull/1492); open issues [#1486](https://github.com/cozyGarage/BookiE/issues/1486) to [#1491](https://github.com/cozyGarage/BookiE/issues/1491).
