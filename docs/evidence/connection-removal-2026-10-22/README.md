# Saved connection removal confirmation, 2026-10-22

Tracks [#1337](https://github.com/cozyGarage/BookiE/issues/1337). This change follows the connection-row layout work in [#1338](https://github.com/cozyGarage/BookiE/pull/1338).

## Regression

The installed test selects Remove connection, expects the single application-level Delete confirmation, cancels and compares every saved record. It then confirms deletion and compares the remaining records. The selected database file must remain byte-for-byte unchanged.

After correcting an initial test setup that toggled the saved-connection popover closed, the test failed on the unchanged candidate because the application-level Delete confirmation did not appear. The row-level Remove confirmation was still visible instead. The unchanged candidate binary checksum is recorded in the [connection-row manifest](../connection-row-2026-10-22/manifest.json).

## Fix

The shared row now emits the deletion request directly. Both welcome and workspace consumers still route it through the existing unconditional application confirmation. No credential deletion, storage operation or database operation moved into the row. The redundant row confirmation and its cached widget reference were removed.

## Evidence

- Connected-workspace installed regression passed: cancel preserves records, confirmation removes only the selected record, and the database file is unchanged.
- Welcome-list installed regression passed with the same record and database preservation assertions.
- Full local preflight and application all-target Clippy passed.
- Secret Service credential deletion is not independently verified by the SQLite fixture. The existing storage and application deletion paths remain unchanged.
- At this evidence checkpoint, native Wayland and Forgejo acceptance remained pending.

Raw local results are outside the repository. All application interaction uses isolated Xvfb displays and session buses.

## Subsequent status

GitHub PR [#1340](https://github.com/cozyGarage/BookiE/pull/1340) merged on 2026-10-22 at head `48b2d08e1b5f0bcb37c6dd4527b649ee644b9625`, and issue [#1337](https://github.com/cozyGarage/BookiE/issues/1337) closed. Its merge commit is in the current Linux tree. This evidence does not record the exact-head Forgejo run; [#1543](https://github.com/cozyGarage/BookiE/issues/1543) tracks the merge-order and gate-evidence audit. Native Wayland and independent Secret Service deletion verification remain unproven.
