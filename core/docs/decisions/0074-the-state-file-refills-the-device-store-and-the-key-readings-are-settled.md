# 0074: The state file, refills, the device store and the key readings are settled

- **Status**: Accepted; amends 0054, 0056 and 0066
- **Date**: 2026-11-28

## Context

The core-engine integration rounds 3, 3b and 4, the key lanes and the history split ([0069](0069-the-query-history-is-a-store-of-its-own-and-saved-queries-move-to-their-own-file.md)) met places where [0054](0054-one-sync-engine-in-the-core-for-tablepro-sync-and-icloud.md), [0056](0056-end-to-end-keys-per-account-and-device.md) and [0066](0066-the-state-file-keeps-refused-changes-and-per-kind-refills-and-the-engine-rulings-are-settled.md) leave a gap. Each ruling below is the orchestrator's, or a lane's fail-closed reading the orchestrator confirmed, checked against the merged engine. 0054, 0056 and 0066 are Accepted, so the rulings go here, and those ADRs change only their Status lines.

## Decision

### The state file (0054, The state file; 0066)

- **Table order.** The sync tables, in the order the sync digest takes them: `binding`, `scopes`, `stores`, `stores_kinds`, `bases`, `pending_bases`, `standing`, `held`, `deferred`, `outbox`, `refused`, `approvals`, `conflicts`, `legacy_mirror`, `moves`, `left_behind` ([0073](0073-moves-the-account-choice-and-the-policy-gate-are-settled.md) adds the last two). The key tables keep 0054's order.
- **Two held reasons.** `held` gains `refused_in_refill` (Per-kind refills, below) and `collides` ([0075](0075-the-downgrade-mirror-record-rules-and-team-library-readings-are-settled.md), Team Library).
- **Deleted bytes go.** The file runs with `secure_delete` on. `StateStore::purge` then rebuilds it with `VACUUM` and empties the WAL with `wal_checkpoint(TRUNCATE)`, failing when the checkpoint cannot finish, since a page freed before `secure_delete` was on can still hold older copies. Team Library's verified delete runs it after its row deletes commit and before it reads the tables back, and so does dropping a team the account lost its seat in.

### Per-kind refills (0066, Per-kind refills)

- **A refused record takes the next pull.** A record a refill's store refused takes the pull on whatever page next brings it: a snapshot, a delta, an older history page or iCloud's recovery, deletions included, not only on the held retry. A refusal while its kind refills is held as `refused_in_refill`.
- **A new device refills every kind.** Its first service pull finds no `stores` rows, so every kind of every store refills, and a refusal there holds as `refused_in_refill`.
- **A store split out of one the file saw** keeps its kinds' bases and moves any refill the old store's name owed. This is `saved_queries.db` out of `history.db` (0069). A new or stale file refills as before. On iCloud, an owed mark moves to the store its kind lives in now, for any change of store.

### The device store (0054, Integrity and freshness; 0066, Integrity readings 4)

- `HostDeviceStore::present` says whether the host keeps a device store at all. The FFI asks it once, as sync opens. It defaults to true, and Windows' Credential Manager store answers true.
- A host with a store that answers `Locked` or `Unavailable` never gets a new state file: the open answers `sync.state.anchor_unsettled` until the store answers, then runs the normal checks. Only a host that declares no store opens a new file unsealed.

### Approvals, conflicts, errors and settings (0066, Rules)

- **Stale answers.** A decision on an approval, or a Keep Mine or Keep Theirs on a team conflict, whose digest no longer matches answers `sync.changed`. `SyncControl::resolve_conflict` carries the digest of the conflict the person saw, its base, mine and theirs, as `decide_approval` carries the approval's.
- **A rebuild in progress.** `AccountFlows::rebuilding` tells a pull that a stale file's key tables still rebuild, so envelopes held meanwhile are read again once it ends.
- **Step-up.** `sync.step_up_required` fills `ErrorInfo.step_up` as `account.step_up_required` does, and `ErrorInfo.sync` carries `SyncFailureInfo::StepUp` too.
- **Settings.** `HostSettings` is an async foreign trait, like `CloudKitTransport`. Its `apply` returns once the write is on disk, since the engine commits the base after it.

### Keys (0054, `key_comparisons`; 0056, Pins; 0066, Replace points)

- **Comparison rows.** A comparison row goes when its request is purged, except in two cases. An approver that took its step keeps its row, ended. The new device keeps its row while a merge it owes is pending. A request served again over a row held this way opens nothing, so an ended session never reopens. 0054 said a row stays until its request is purged.
- **A key-change alert's replace point.** Accepting an alert (`accept_key_change`) adds the pinned IK to the replaced list with the pin's `av` + 1 as its replace point, unless the list already holds that IK. An alert has no replace certificate to take the point from.
- **QR and words.** `compare_fingerprint_qr` compares against the pinned IK only, and marks that pin `compared` only while no alert is open. Under an alert or a held restart the person compares words and accepts: `accept_key_change` with `compared`, or `accept_team_restart`, pins the offered IK or the restart's signer as `compared`. No call marks a pin compared from words alone.

## Consequences

- The sync digest follows the table order above.
- A state file holds no bytes of rows Team Library deleted once its verified delete ends.
- A host that keeps a store but cannot reach it waits; it never starts an unsealed file.
- A stale approval or conflict asks the person again instead of applying to the wrong value.
- A word comparison outside an alert or a held restart leaves the pin as it was.
