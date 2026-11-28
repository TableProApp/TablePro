# 0065: The restore check reads the WAL's timeline, and the server and key rulings are settled

- **Status**: Accepted; amends 0051, 0056 and 0064; the restore check's functions and the install audit page amended by 0072
- **Date**: 2026-11-26

## Context

The server lanes (S3, S3K-b, S4, S8) and the key lanes (K7-2, core-fixes) met places where [0051](0051-sync-protocol-and-record-rules.md) and [0056](0056-end-to-end-keys-per-account-and-device.md) are wrong or say nothing. The orchestrator ruled on each, and the maintainer decided the install audit page on 2026-11-26. 0051, 0056 and 0064 are Accepted, so the rulings go here, and those ADRs change only their Status lines.

## Decision

### Restore detection (0051, Restore)

- **The timeline is the WAL's.** `sync_install` holds `pg_control_system().system_identifier` and the first 8 hex digits of `pg_walfile_name(pg_current_wal_insert_lsn())`, the timeline the server writes on now. `pg_control_checkpoint().timeline_id` keeps the old timeline until the next checkpoint ends, which a promotion (`pg_ctl promote`, `pg_promote()`, Patroni, an RDS replica promotion) spreads over minutes.
- **A database still recovering,** a standby included, has no such timeline. `/v2/sync` answers 503 `restore_check_unavailable` until a connection finds it promoted.
- **No `sync_install` row while a record `/v2/sync` wrote exists** fails closed. Only a lost row leaves that state, so the check stores nothing, and `/v2/sync` answers 503 `restore_check_unavailable` until an operator runs `sync new-epoch`. Storing the identity then would take a restored database for the original. An upgrade's first start, which finds only the library rows R1 copied, stores the values as before.

### Step-up (0051, Keys on the wire, Step-up)

- **Binding the first passkey stamps no step-up.** On a self-hosted install the IdP signs the person in again, the server binds the passkey, and the person then confirms with it, which is the step-up. This follows tablepro-cloud's `step-up-passkeys.md` (#62): an IdP may answer from its session with whatever time it gives.
- **On the SaaS,** a step-up by an emailed link counts as `urn:tablepro:acr:email-code`, as the emailed code does.
- **Tests:** binding a first passkey credits no step-up, and confirming with it does. This holds when an attacker holds the person's IdP sign-in too.

### Team envelopes while `rotation_due` (0051, Teams; 0056, Teams)

`rotation_due` refuses a team `secret_envelope` create or patch, a revival included. A delete applies: a tombstone seals nothing under the old key, and an admin who removes a credential right after a member leaves is not blocked. Apps queue creates and edits only.

### The install audit page (0051, Lifecycle and audit)

The install's owner and admins see install-level events only: server settings, licenses, policy switches, members added and removed, device removals, and reset and rotation metadata. The page never shows a member's personal sync events, and team events stay in each team's audit.

### Rulings that add no mechanism

- **Device rows (S3K-b).** 0056's and 0051's same-row rule stands. The machine id a device reports is self-reported and is never a trust anchor. A phished IdP session can register on a victim's machine id and confuse or block that row's requests and resets. It cannot get the row approved or reach any key, and the same session already acts in the portal. The threat model lists it as an accepted residual risk.
- **A team ended on a different record** (core-fixes item 5). After a restore, a server can end a team on a device by serving a different record at a version the device waits for, signed by an account the server made up (0051, What cannot go back; [0062](0062-a-stopped-scope-records-why-it-stopped.md)). Refusing the push-back already ends a team the same way. Proving more would need the versions the device advanced through. This is accepted as the operator's denial of service, listed in the threat model's residual risks.
- **A restart with no ring** (0056, Teams, No holder left; core-fixes item 1). A member that reset and kept its keys still holds the old version. After it accepts a restart with no ring, it reads no envelope sealed before the restart, since older team keys are read only down the ring chain. Keeping them would need the device to record, at acceptance, the version and record digest it held, anchored with the key tables. A ringless restart means the team lost every holder, so the loss is accepted, and owners share those secrets again.

### A kind 3 reset proposed again (0064, Push-back)

When a restore lost a pending kind 3 reset, its proposing device proposes it again only after a fresh step-up. A new `KeyNoticeKind` tells the person that the reset waits for one.

## Consequences

- A promoted standby opens its epoch on the first connection after the promotion, not minutes later.
- An install that lost its `sync_install` row serves no `/v2/sync` until an operator opens an epoch.
- An attacker with a self-hosted person's IdP sign-in and no passkey on the account still steps up: it binds the passkey, then confirms with it (threat model, Residual risks 8).
- Install admins read no personal activity of members.
- The threat model gains two residual risks: a device row taken by machine id, and a team ended on a made-up record.
