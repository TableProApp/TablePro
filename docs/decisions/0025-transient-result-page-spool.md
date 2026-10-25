# 0025: Keep fetched result pages in a transient spool

- **Status**: Proposed
- **Date**: 2026-10-25

## Context

ADR 0011 streams supported PostgreSQL editor queries through a forward-only cursor and bounds retained row data in memory. A 64 MiB estimated-row budget evicts old pages. Native acceptance under #554 showed that users can receive 100,000 rows but cannot revisit earlier pages when a wide result exceeds that budget. Re-running SQL can observe different data and is not an equivalent way to revisit the same result.

The query result values already have a typed Serde representation. The GTK-free `app-services` crate can own temporary page storage and loading, while Relm4 messages keep controller and view updates on the main context. PolicyGuard already classifies, audits and masks each database page before the editor receives it.

## Decision

For streamed PostgreSQL editor results, retain the existing 64 MiB in-memory page cache and add a bounded, process-local spool for every page already accepted by the editor.

1. The editor acknowledges a fetched page only after the service has stored it in the spool or retained it as the one current in-memory page when storage fails. A storage failure stops further cursor fetches and is shown as a failed, incomplete result.
2. The spool is an anonymous temporary file. Pages are encoded incrementally with a versioned typed Serde format and encrypted in fixed-size chunks using an ephemeral AES-256-GCM key held in `SecretBox`; the app does not build a second full-page encoded buffer. Each chunk uses a unique counter-derived nonce and authenticates the format version, page index and chunk index. No query rows or keys are written to named files or logs. A JSON cell is encoded as JSON text to preserve arbitrary-precision numbers, so that individual cell may have a temporary text copy while it is encoded.
3. A process-wide 1 GiB quota covers all live result spools, with at most 4,096 pages in one spool so page-index metadata and pager widgets stay bounded. Quota reservation is shared across streams and returned when the last result, pin or load operation releases its owner. A quota or filesystem error stops the active stream without discarding pages already stored.
4. `app-services` owns append, indexed reload, quota accounting and spool lifetime. Blocking serialization, encryption and file I/O run away from the GTK main context. Outcomes return through Relm4 input messages carrying the result generation and page index; stale loads cannot replace a newer result.
5. The spool holds only pages already returned by the existing guarded cursor path. Reloading a local page does not run SQL or create a new database audit event. Existing per-page policy, masking, cancellation and terminal audit behavior remain unchanged.
6. The store is not persisted or recovered across application restart. It is deleted by the operating system when its final file handle closes, including after process termination. Pins share the same spool owner as their result.
7. Full-result export remains governed by ADR 0014. This decision does not extend streaming to other engines or unsupported statement shapes.

## Rationale

This preserves same-execution result semantics while keeping the row cache bounded in memory. A private anonymous file avoids persistent application state and a pathname that other processes can discover. Per-chunk authenticated encryption limits exposure of database values in temporary storage. The application service keeps storage logic testable without GTK, and generation-tagged messages preserve the existing Relm4 ownership model.

The 1 GiB process quota allows the observed 100,000-row result with 2 KiB text values to remain navigable while placing a hard bound on aggregate spool storage. The page cap bounds per-page navigation metadata. The user sees an explicit incomplete-result state if a limit or filesystem is reached.

## Consequences

- Query results may consume temporary disk space up to the process-wide quota in addition to the existing memory cache.
- A loaded page temporarily occupies memory while it is decoded and displayed. The existing byte estimate remains a cache bound, not a process-memory ceiling.
- During append, the original page remains alive until the editor acknowledges it. Additional encoding memory is bounded to one encryption chunk plus any temporary JSON text for the current JSON cell.
- AES-GCM and the Serde wire format become implementation dependencies of the service and require license, advisory and exact-value review.
- Tests must cover every `Value` variant, NaN payloads and signed zero, page ordering, repeated reads, tampering, quota exhaustion, filesystem refusal, stale generation results, and release after result replacement, close, cancellation, timeout and application exit.
- Installed PostgreSQL acceptance must prove navigation from first through last page on a result wider than the RAM cache, unchanged SQL execution count, bounded spool usage, and cleanup after all owners close.

## Alternatives considered

- **Change the PostgreSQL cursor to `SCROLL`.** Rejected as a direct fix. PostgreSQL documents possible plan costs and repeated evaluation hazards for volatile functions. `SCROLL WITH HOLD` can materialize the full result on the server and moves the resource problem rather than bounding application storage.
- **Re-run the query for an evicted page.** Rejected. It can observe changed data, repeats work, and is not navigation within the original execution.
- **Keep every row in RAM.** Rejected by ADR 0011 because memory grows with result size.
- **Keep the current bounded window and disable Previous.** Rejected as the completed large-result behavior requested in #554; it leaves already-received rows inaccessible.

## Acceptance evidence

The implementation and test expectations were tracked in [#554](https://github.com/cozyGarage/BookiE/issues/554), which was closed after [PR #1660](https://github.com/cozyGarage/BookiE/pull/1660) merged as `f0ee2e104a3ab5f01ef51ecf2eb1b4f8ea473699`. Local preflight, GTK widgets and the installed 100,000-row PostgreSQL scenario pass; the scenario report is in [stream result spool evidence](../evidence/stream-result-spool-2026-10-25.md). At merge time the exact-head hosted checks were incomplete; the hosted preflight later passed. See PR #1660 for later GitHub results. Forgejo acceptance and maintainer review remain unrecorded, so this ADR stays proposed until the remaining review and acceptance are complete.
