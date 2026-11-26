# 0062: A stopped scope records why it stopped

- **Status**: Accepted; amends 0054 and 0056
- **Date**: 2026-11-26

## Context

[0054](0054-one-sync-engine-in-the-core-for-tablepro-sync-and-icloud.md)'s `key_versions.state` has one value, `stopped`, "while a catch-up or a restore leaves the device waiting". The two waits end differently:

- **A catch-up stop** clears only through re-confirmation by an owner or admin the device had counted as a holder ([0056](0056-end-to-end-keys-per-account-and-device.md), Teams, A stopped device).
- **A restore stop** waits for a team version another account signed and the server lost, and the device "waits for the signer's device to push the version back, then resumes its own push-back from there" ([0051](0051-sync-protocol-and-record-rules.md), What cannot go back).

0056 also says that at approval a held team scope's stop "clears only through re-confirmation". With no record of the cause, a device either never clears a restore stop or clears a catch-up stop when the server shows a version it already held, which would undo S3-C1's fix. 0054 and 0056 are Accepted, so the fix goes here.

## Decision

- **`key_versions` gains `stopped_cause`,** after `state`: `catch_up` or `restore_wait` while `state` is `stopped`, else null. It is text in the key digest, like the other columns. A personal or history row only ever stops as `catch_up`.
- **A catch-up stop** clears only through re-confirmation, as 0056 says. The device reports it (0051, A stopped device).
- **A restore stop** clears only when the server again holds every version the device waits for with the same fields as the copy the device holds, each passing the device's own checks as in any pull (0056, Rollback). The device then resumes its push-back. A different record at such a version ends the scope (`keys.conflict`). A restore stop is not reported, since no owner's rotation can fill it.
- **Both at once:** a scope that meets a catch-up failure while it waits on a restore keeps `catch_up`, the stricter rule.
- **Approval** keeps a held team scope's `state` and `stopped_cause` (0056, Approving a device, step 7).

**Why a column, not a `key_pending` flow.** 0054 already holds both waits in `key_versions.state`, so the cause belongs beside it. `key_versions` rows are in the anchor's checkpoint, and `key_pending` stays in the file alone. The cause must survive a file restore unchanged: read as `restore_wait`, a catch-up stop would clear at once, because the server holds the version the device stopped at.

## Consequences

- The state file gains one column; the key digest and the checkpoint carry it.
- The engine and the key-flow lanes branch on the cause, never on the server's view alone.
- A restore stop clears with no admin action once the signer's device pushes back.
