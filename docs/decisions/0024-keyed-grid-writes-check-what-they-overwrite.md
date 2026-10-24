# 0024: Keyed grid writes check what they overwrite

- **Status**: Accepted
- **Date**: 2026-10-25
- **Origin**: The R1 finding of the [external client review](../archive/external-audit-client-review-2026-10-06.md), the MongoDB checkpoints of 2026-10-04 in the [value contract history](../archive/value-contract-history.md), and the code at the extraction date.

## Context

The grid saves edits and deletes as keyed statements. A statement that matches only the primary key silently overwrites a value another writer changed between fetch and save. An affected-row count after the fact cannot tell a stale overwrite from a legitimate update, because both affect one row. A native SQLite probe showed `other writer` replaced by `stale grid edit` with one affected row.

## Decision

1. **Relational updates compare the original value.** For PostgreSQL, MySQL, SQL Server and SQLite, an UPDATE matches the primary key and each edited column's original value, using the dialect's NULL-safe equality (`IS NOT DISTINCT FROM`, `<=>`). `build_optimistic_keyed_update` builds it; the change tracker uses it for those engines.
2. **A checked write must affect exactly one row.** For those engines the save passes the update and delete indexes to `execute_in_transaction_checked`. A statement that affects any other count fails the transaction, which is rolled back with `ConcurrentModification`. A driver that cannot check returns `Unsupported`, so the checked path is never silently skipped.
3. **MongoDB guards by field and by row.** An update puts each edited field's original value in the same `update_one` filter. A delete compares every materialized non-key value. A NULL guard requires an existing, non-array NULL field; the missing-field marker becomes `$exists: false`. This keeps explicit NULL, a missing field and an array containing NULL distinct.
4. **Other engines keep the key-only path and a post-commit warning.** An engine without checked writes saves by key. When the driver reports affected rows, the app warns after commit if an UPDATE or DELETE matched zero rows.

## Limits

- **Relational deletes match the key only.** A DELETE on PostgreSQL, MySQL, SQL Server or SQLite checks that exactly one row matched, but not that the row is unchanged since the grid read it. Only MongoDB deletes compare the row.
- **This is compare-and-set on the edited fields, not version tracking.** A value changed and changed back (ABA) is not detected, and a field added after the result's column set was built is not guarded. Closing that needs a server version token, which engines do not offer uniformly.
- **It is not snapshot isolation.** Browse consistency stays per cursor ([ADR 0011](0011-paged-query-results.md)).

## Rationale

Comparing the value a user saw with the value being overwritten is the only check that distinguishes a stale write from a normal one, and it needs no engine-specific version column. Running it inside the save's transaction and requiring exactly one row keeps a conflict from partially applying.

## Consequences

- A save that loses a race fails and rolls back. The user re-fetches and reapplies.
- The edit materializer must keep each edited cell's previous value. Dropping it reintroduces the lost update.
- Adding a driver to the checked list means a real-engine test that changes the row between fetch and save.

## Alternatives considered

- **Match the primary key only and report zero-row counts after commit (the earlier behaviour).** Rejected for engines that can check: one affected row cannot tell a stale overwrite from a legitimate update. It remains the fallback in point 4.
- **A version or timestamp column.** Not adopted. Tables do not have one, and engines expose no uniform row version. It is the way to close the ABA limit if a safe design appears.
- **Guard every column of the row on UPDATE.** Not adopted. It would reject a save because an unrelated column changed. The decision guards the columns the user edited.
