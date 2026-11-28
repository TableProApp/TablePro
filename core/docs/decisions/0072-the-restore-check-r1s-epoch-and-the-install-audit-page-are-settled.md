# 0072: The restore check's functions, R1's epoch and the install audit page are settled on the server

- **Status**: Accepted; amends 0051 and 0065
- **Date**: 2026-11-28

## Context

The server's second review round (G2) and its move onto tablepro-cloud's main (#73 there, R1 renumbered from 00043 to 00047) met places where [0051](0051-sync-protocol-and-record-rules.md) and [0065](0065-the-restore-check-reads-the-wal-timeline-and-the-server-and-key-rulings-are-settled.md) say less than the server does. Each ruling below is the orchestrator's, checked against tablepro-cloud's main. 0051 and 0065 are Accepted, so the rulings go here, and those ADRs change only their Status lines.

## Decision

### Restore detection (0051, Restore, Detection; 0065)

- **The timeline is the WAL insert position's,** as 0065 has it: the first 8 hex digits of `pg_walfile_name(pg_current_wal_insert_lsn())`.
- **The role needs three functions:** `pg_control_system()`, `pg_current_wal_insert_lsn()` and `pg_walfile_name(pg_lsn)`. PostgreSQL lets every role run them. Where they were revoked, `serve` logs the grant to run, and `/v2/sync` answers 503 `restore_check_unavailable` (tablepro-cloud `docs/design/operations.md`, Backups, Restore). The check also reads `pg_is_in_recovery()` for a standby (0065).

### R1's epoch (0051, The library moves in, step 2)

R1 always ends `/v2/sync`'s lineage on an epoch it draws, with a random id:

- without library epochs, the first epoch, with `start_revision` 1, as 0051 says;
- with them, R1 copies them, then adds a new epoch past the copied revisions, with each scope's highest revision as its cut. The copied records keep the newest library epoch as their written epoch.

A database restored from a backup taken before R1 and migrated again then serves an epoch no device has seen, and every device refills. 0051 added an epoch only when there was none, so such a restore kept the lineage devices knew.

### The install audit page (0065)

- **Server events:** a new epoch (`sync.epoch_started`) and a detected restore (`sync.restore_detected`) are install events.
- **`sync.restore_suspected` stays out.** It names a scope's reader, which may be a team's.
- **A passkeys reset stays out.** It is a member's own sign-in event, and 0065's list does not name it.
- **A policy tombstone run** (`sync.policy_tombstoned`) on a team names the team as its target, so it shows in that team's audit and not on the install page. A run across the install has no target and shows there.

### Rulings that add no mechanism

- **A member removal clears its stop reports.** In the removal's transaction the server deletes the member's stop reports ([0062](0062-a-stopped-scope-records-why-it-stopped.md)) in each team it left, so a member that rejoins lists none.
- **A reset's hold has one clock.** A new `key.reset`'s `held_until` is set from the same clock read as the `taken_at` the server stamps on it (0051, Resets).
- **A push can race a device removal.** A push reads its device's standing under its own scope's lock. A device removal holds the account and the personal scope. So a team or history push that read the device as approved just before its removal committed can still land. It writes only what that device could write a moment earlier, and the removal still ends its tokens and every later push. A member removal takes the team row a team push holds, so a removed member's team push lands before the removal or is refused. This is accepted, and the threat model lists it (Residual risks 16).

## Consequences

- An install that revoked the three functions serves no `/v2/sync` until an operator grants them.
- A backup taken before R1 and restored later costs every device one refill.
- Install admins see epochs and detected restores, and see no team's tombstone runs.
- The threat model gains Residual risks 16.
