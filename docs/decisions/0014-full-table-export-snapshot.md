# 0014: Full table exports use one read snapshot

- **Status**: Accepted
- **Date**: 2026-10-07

## Context

Browse exports fetch successive pages with separate `fetch_rows` or SQL
requests. Concurrent inserts, deletes or updates between requests can make an
offset export omit or repeat rows, or combine values from different database
states. The current export path does not hold a read transaction across pages.

## Decision

A full table export represents one read snapshot captured when export starts.

1. Every page is read through one guarded, read-only session whose transaction
   provides a stable snapshot for that engine. A cursor over one statement is
   also valid when it preserves that statement's snapshot through exhaustion.
2. Independent autocommit page requests, keyset restarts and best-effort pages
   do not satisfy this contract. The implementation must use a stable order
   where the engine needs one; keyless tables must use one cursor or statement
   execution rather than restart an unordered scan.
3. A driver without a tested snapshot-capable export path refuses full export
   before publishing a file. It must not silently fall back to a mixed-time
   result. Existing single-statement query-result exports remain unchanged.
4. Cancellation or failure closes the session and discards the temporary
   output. The read is classified and audited under the existing guard; page
   events remain attached to the export operation.

## Rationale

An exported file is a data result users may save or share. Silently mixing
multiple database states is misleading. A clear refusal preserves that
contract until an engine has a verified implementation.

## Consequences

- Long exports hold a read transaction or cursor open. The user can cancel;
  completion and every error path must close it promptly.
- Snapshot guarantees are engine-specific and require native mutation-between-
  pages tests. A driver is not enabled for full export until those pass.
- The guarded read-snapshot start in the B4 plan is a prerequisite, not an
  exception to the export contract. Cursor paging in [ADR 0011](0011-paged-query-results.md)
  must use the same guarded snapshot rules.

## Alternatives considered

- Keep offset paging and describe the result as best-effort: users cannot tell
  that rows may be missing, repeated or taken from different times.
- Buffer every row before writing: does not fix a database that changes while
  pages are being fetched and defeats bounded-memory export.
