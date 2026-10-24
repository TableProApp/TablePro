# 0011: Page large editor results through a cursor

- **Status**: Accepted
- **Date**: 2026-10-07
- **Clarified**: 2026-10-24 for implementation status. The Decision describes the target design; the Implementation status section records shipped PostgreSQL editor integration and remaining resource acceptance.

## Context

A SQL editor result is materialized in one pass up to three caps: 1,000,000 rows, 10,000,000 cells and 64 MiB of estimated value bytes. The byte cap binds first. GUI memory is about 2.5 times the driver result (PERF-2, PERF-8). At the time of this decision, full-table export paged 5,000 rows through the guard and the grid read shared rows lazily. [ADR 0014](0014-full-table-export-snapshot.md) later required snapshot-safe paging; the current export path refuses full-table export until a driver proves that contract. The remaining editor cost is the single large fetch of an arbitrary query.

Re-running the user's statement with `LIMIT` and `OFFSET` is not an option. It rewrites SQL the user wrote, can repeat or miss rows when data changes, and re-evaluates the whole statement per page. SEC-6 also requires that the cap never appends a `LIMIT`.

## Decision

Add an optional driver capability that opens a forward-only cursor over a single read statement and returns pages of at most 5,000 rows.

1. Only a statement that `PolicyGuard` classifies as a read, run in a `Session`, may open a cursor. Other statements keep the capped, materialized path.
2. PostgreSQL implements it with a server cursor inside the session's transaction. Other engines report the capability as unsupported and keep the capped path until each has a tested cursor.
3. The statement is classified, ruled and audited once. Each page fetch writes a page event under the same operation identifier. Masking applies to every page. A denied, failed, cancelled or timed-out fetch writes the terminal state and closes the cursor.
4. The grid keeps a fixed number of pages resident. A forward-only cursor cannot re-read an earlier page, so pages outside the retained budget are gone from the grid. An export can preserve every row only when it drains the cursor to exhaustion under the snapshot rules in ADR 0014.
5. Cancel and timeout reach the server through the existing server-side cancellation. Closing the tab, switching connection or running a new statement closes the cursor.

## Consequences

- Memory is bounded by the page budget, not the result size, for PostgreSQL.
- Every page is a guarded, audited call. The audit journal grows with the number of pages, so the page size is fixed and a long scroll writes bounded events.
- A forward-only cursor cannot show earlier pages without keeping them. The retained-page budget decides what the user can scroll back to.
- Engines without a cursor keep the current caps and the truncated banner.

## Implementation status

Core and PostgreSQL cursor support and PostgreSQL read-only snapshot sessions have landed. `PolicyGuard` now authorizes one read statement in a read-only snapshot, masks each fetched page, and records page and terminal audit outcomes. PostgreSQL is the only driver with cursor support; other drivers return `Unsupported`. The SQL editor uses this path for supported single-statement PostgreSQL `SELECT`s. Other engines and unsupported query shapes keep the capped materialized path. A synthetic maximum-page profile reached 1,325 MiB RSS with four pinned results and one active stream ([evidence](../evidence/stream-retention-synthetic-2026-10-16/README.md)). Broader real-query memory profiling and lifecycle acceptance remain under [#554](https://github.com/cozyGarage/BookiE/issues/554). This status update does not qualify installed GTK or a release candidate.

## Open questions

- Whether MySQL and SQL Server can use their native streaming without holding a transaction open.
- Whether the retained budget should be rows, bytes or both.

## Clarification, October 24, 2026

The UI stream cache retains pages until its estimated row storage exceeds the existing 64 MiB query-result budget. It does not apply a separate page-count limit. The newest page is always kept, including a single oversized page. If older pages leave the cache because the byte budget is exceeded, their values remain unavailable in the grid while received-row counts stay unchanged; the pager reports the remaining range. A native 100,000-row PostgreSQL query returned 20 pages and all 20 remained navigable within the estimate. The first page showed rows 1–5,000 after navigating back from the newest page ([native evidence](../evidence/built-head-2026-10-24/README.md)).

The estimate reuses core row/value accounting and excludes column metadata, widgets, incoming driver buffers, overlapping result snapshots, other tabs, pins and allocator-retained pages. It is not a process-memory ceiling. A result larger than the cache budget can still lose access to earlier pages. Broader ownership and profiling acceptance remain under [#1032](https://github.com/cozyGarage/BookiE/issues/1032); design work for revisiting rows beyond the in-memory budget remains under [#554](https://github.com/cozyGarage/BookiE/issues/554). The native profile is source-build evidence, not installed GTK or release qualification.
