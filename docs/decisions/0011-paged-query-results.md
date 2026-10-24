# 0011: Page large editor results through a cursor

- **Status**: Accepted
- **Date**: 2026-10-07
- **Clarified**: 2026-10-16, 2026-10-22 and 2026-10-24 for implementation status, retained-byte limits and shipped cache behavior.

## Context

A SQL editor result is materialized in one pass up to three caps: 1,000,000 rows, 10,000,000 cells and 64 MiB of estimated value bytes. The byte cap binds first. A historical grid profile measured about 2.5 times the driver result; it predates #518’s shared-row path, and no comparable post-change profile establishes a current ratio (PERF-2, PERF-8). At the time of this decision, full-table export paged 5,000 rows through the guard and the grid read shared rows lazily. [ADR 0014](0014-full-table-export-snapshot.md) later required snapshot-safe paging; the current export path refuses full-table export until a driver proves that contract. The remaining editor cost at that point was the single large fetch of an arbitrary query.

Re-running the user's statement with `LIMIT` and `OFFSET` is not an option. It rewrites SQL the user wrote, can repeat or miss rows when data changes, and re-evaluates the whole statement per page. SEC-6 also requires that the cap never appends a `LIMIT`.

## Decision

Add an optional driver capability that opens a forward-only cursor over a single read statement and returns pages of at most 5,000 rows.

1. Only a statement that `PolicyGuard` classifies as a read, run in a `Session`, may open a cursor. Other statements keep the capped, materialized path.
2. PostgreSQL implements it with a server cursor inside the session's transaction. Other engines report the capability as unsupported and keep the capped path until each has a tested cursor.
3. The statement is classified, ruled and audited once. Each page fetch writes a page event under the same operation identifier. Masking applies to every page. A denied, failed, cancelled or timed-out fetch writes the terminal state and closes the cursor.
4. The grid retains pages within the 64 MiB estimated-row budget and keeps the newest page even when that page alone exceeds it. A forward-only cursor cannot re-read evicted pages. An export can preserve every row only when it drains the cursor to exhaustion under the snapshot rules in ADR 0014.
5. Cancel and timeout reach the server through the existing server-side cancellation. Closing the tab, switching connection or running a new statement closes the cursor.

## Consequences

- The stream cache bounds estimated retained row storage, except for the newest-page allowance. This is not a process-memory ceiling: pins, overlapping results, widgets, incoming buffers, metadata and allocator retention remain outside the estimate.
- Every page is a guarded, audited call. The audit journal grows with the number of pages, so the page size is fixed and a long scroll writes bounded events.
- A forward-only cursor cannot show earlier pages without keeping them. The retained-page budget decides what the user can scroll back to.
- Engines without a cursor keep the current caps and the truncated banner.

## Implementation status

Core and PostgreSQL cursor support and PostgreSQL read-only snapshot sessions have landed. `PolicyGuard` authorizes one read statement in a read-only snapshot, masks each fetched page, and records page and terminal audit outcomes. PostgreSQL is the only driver with cursor support; other drivers return `Unsupported`. The SQL editor uses this path for supported single-statement PostgreSQL `SELECT`s, retaining pages within the 64 MiB estimated-row budget and keeping the newest page even if it alone exceeds that estimate. Pages evicted from this forward-only cache cannot be revisited in the grid. A native Omarchy profile of the installed package built from source `d9b5aaca` confirmed that a narrow 100,000-row query could return to rows 1–5,000, while a result with 2,048 text characters per row retained only rows 70,001–100,000 ([installed profile](../evidence/native-wayland-profile-2026-10-24/README.md)). A separate PR #1568 candidate capture is recorded [here](../evidence/built-head-2026-10-24/README.md#native-result-cache-capture-from-pr-commit-748c75c). These runs establish neither a process-memory ceiling nor general release acceptance. Other engines and unsupported query shapes keep the capped materialized path. Driver decoding also applies the result byte/cell budget per page. A historical synthetic profile reached 1,325 MiB RSS with four pinned results and one active stream ([evidence](../evidence/stream-retention-synthetic-2026-10-16/README.md)); it predates the current cache behavior and does not qualify current performance. Broader real-query memory profiling and lifecycle acceptance remain under [#554](https://github.com/cozyGarage/BookiE/issues/554) and [#1032](https://github.com/cozyGarage/BookiE/issues/1032).

## Open questions

- Whether MySQL and SQL Server can use their native streaming without holding a transaction open.

## Clarification, October 22 and 24, 2026

The maintainer selected an estimated-byte retention limit. The UI stream cache retains pages while their estimated row storage stays within the existing 64 MiB query-result budget. It has no separate page-count limit. The newest page is always kept, including a single oversized page. Older pages leave the forward-only window without changing their values or received-row counts; the existing pager reports the remaining range.

The estimate reuses core row/value accounting and excludes column metadata, widgets, incoming driver buffers, overlapping result snapshots, other tabs, pins and allocator-retained pages. It is not a process-memory ceiling. A result larger than the cache budget can still lose access to earlier pages; retrieval beyond that budget remains open under [#554](https://github.com/cozyGarage/BookiE/issues/554). Broader ownership and profiling acceptance remain under [#1032](https://github.com/cozyGarage/BookiE/issues/1032); installed GTK and release-candidate acceptance remain separate.
