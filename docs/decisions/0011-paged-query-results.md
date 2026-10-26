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

## Alternatives considered

- **Re-run the statement with `LIMIT` and `OFFSET`.** Rejected; see Context. It rewrites user SQL, can repeat or miss rows, and re-evaluates the statement per page.
- **Append every page forever.** Rejected. Memory is still unbounded ([grid memory plan](../archive/grid-memory-and-fetch-action-plan-2026-10-07.md)).
- **A page-count cache limit.** Rejected for an estimated-byte limit (see the October 22 and 24 clarification). The earlier four-page cache admitted by count and could exceed any byte budget ([Linux peer review](../archive/linux-peer-review-2026-10-16.md), finding 4).
- **Strong, permanent row objects.** Rejected. Memory grew with scrolling. Row slots hold weak references plus a source index, and draft rows stay strong. Identity must not become a bare row position, because inserts, removals and sorting move positions.
- **ODBC columnar fetch.** Rejected; see [ADR 0001](0001-no-plugin-system.md).

## Consequences

- The stream cache bounds estimated retained row storage, except for the newest-page allowance. This is not a process-memory ceiling: pins, overlapping results, widgets, incoming buffers, metadata and allocator retention remain outside the estimate.
- Every page is a guarded, audited call. The audit journal grows with the number of pages, so the page size is fixed and a long scroll writes bounded events.
- A forward-only cursor cannot show earlier pages without keeping them. The retained-page budget decides what the user can scroll back to.
- Engines without a cursor keep the current caps and the truncated banner.

## Implementation status

Core and PostgreSQL cursor support and PostgreSQL read-only snapshot sessions have landed. `PolicyGuard` authorizes one read statement in a read-only snapshot, masks each fetched page, and records page and terminal audit outcomes. PostgreSQL is the only driver with cursor support; other drivers return `Unsupported`. The SQL editor uses this path for supported single-statement PostgreSQL `SELECT`s, retaining pages within the 64 MiB estimated-row budget and keeping the newest page even if it alone exceeds that estimate. PR #1660 adds a process-local encrypted spool, so pages accepted into the spool remain revisitable without rerunning the query. The spool has a shared 1 GiB quota and a 4,096-page per-result cap; when storage, quota or page limits prevent writing a page, the stream stops as incomplete and previously stored pages stay available while their owners remain open. The installed 100,000-row PostgreSQL GTK scenario traversed every page and reloaded earlier pages while keeping a transaction marker unchanged ([spool evidence](../evidence/stream-result-spool-2026-10-25.md)).

Historical Omarchy captures predate this spool: the installed package at source `d9b5aaca` retained rows 70,001–100,000 for a wide 100,000-row result ([installed profile](../evidence/native-wayland-profile-2026-10-24/README.md)), and the source-built profile at `58805ca17fcf4e450a43cde9207287741bbaa53d` retained rows 1,855,001–2,000,000 from a two-million-row result ([profile](../evidence/postgres-stream-native-wayland-2026-10-25/README.md)). A separate PR #1568 candidate capture is recorded [here](../evidence/built-head-2026-10-24/README.md#native-result-cache-capture-from-pr-commit-748c75c). These dated runs establish neither a process-memory ceiling nor general release acceptance. Other engines and unsupported query shapes keep the capped materialized path. Driver decoding also applies the result byte/cell budget per page. A historical synthetic profile reached 1,325 MiB RSS with four pinned results and one active stream ([evidence](../evidence/stream-retention-synthetic-2026-10-16/README.md)); it predates the current cache behavior and does not qualify current performance. Broader real-query memory profiling and lifecycle acceptance remain under [#1032](https://github.com/cozyGarage/BookiE/issues/1032).

## Open questions

- Whether MySQL and SQL Server can use their native streaming without holding a transaction open.

## Clarification, October 22 and 24, 2026

The maintainer selected an estimated-byte retention limit. The UI stream cache retains pages while their estimated row storage stays within the existing 64 MiB query-result budget. It has no separate page-count limit. The newest page is always kept, including a single oversized page. Older pages leave the forward-only RAM window without changing their values or received-row counts. ADR 0025 adds a separate encrypted spool for revisiting fetched PostgreSQL pages while the result owner remains open; its quota and page cap can stop the stream as incomplete.

The estimate reuses core row/value accounting and excludes column metadata, widgets, incoming driver buffers, overlapping result snapshots, other tabs, pins and allocator-retained pages. It is not a process-memory ceiling. The PostgreSQL spool preserves access to pages successfully written within its limits, but a quota, page-cap or storage refusal stops the stream as incomplete. Other engines and unsupported query shapes remain materialized. Broader ownership and profiling acceptance remain under [#1032](https://github.com/cozyGarage/BookiE/issues/1032); installed GTK and release-candidate acceptance remain separate.
