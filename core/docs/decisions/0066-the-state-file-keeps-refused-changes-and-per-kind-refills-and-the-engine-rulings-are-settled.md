# 0066: The state file keeps refused changes and per-kind refills, and the engine rulings are settled

- **Status**: Accepted; amends 0054, 0056, 0060 and 0064; schema 2's `moves` and `left_behind` and a zone made again amended by 0073; per-kind refills, stale answers and an alert's replace point amended by 0074; a `policy` refusal and the `awaiting_store` held reason amended by 0076
- **Date**: 2026-11-26

## Context

The engine lanes (C0, K6a-1, K6a-2, K6b-2, K6d, K7-1, K7-2 and the core-engine integration) met places where [0054](0054-one-sync-engine-in-the-core-for-tablepro-sync-and-icloud.md)'s state file and engine, and the readings [0060](0060-the-change-journal-names-the-records-each-write-changed-and-a-store-is-one-file.md) and [0064](0064-a-team-restart-waits-for-a-word-comparison-and-the-sync-lanes-readings-are-settled.md) settled, leave a gap. Each ruling below is the orchestrator's, or a lane's fail-closed reading that the orchestrator confirmed. 0054, 0056, 0060 and 0064 are Accepted, so the rulings go here, and those ADRs change only their Status lines.

## Decision

### The state file (0054, The state file)

| Table | Change |
|---|---|
| `refused`, new, after `outbox` | Per (scope, kind, record id): the SHA-256 of the change the server refused and its code. A pass sends that change again only once what it would send differs, after a restart too. 0054 fixes the table set, so K6a-1 kept these in memory and sent each once more after a restart |
| `stores_kinds`, new, after `stores` | Per (store, kind): a refill the kind still owes. `stores` keeps one row per file for its generation and write sequence (0060, 0064) |
| `scopes` | On iCloud, also what the zone's push waits for: the person's Move my data or Start empty after an account switch, or this device's person after another device made the zone again (Rules, below) |
| `deferred` | Deletions for a category that is off, and the copy a store refill found for a record while its kind was off |
| `key_objects` | `served`, after `applied`: the server's `taken_at` and, on a `key.reset`, `held_until` (0051, Pull), each 8 bytes big-endian, null until the server serves the record. Other devices' resets live here (0064, Reset). Without stored times they read 0 after a restart, and none ends as overdue before its tombstone |
| `key_pins` | Each `replaced` entry is the IK's 32 bytes, then the `av` of the replace certificate that retired it as a `u32` big-endian, in the order replaced |

The sync digest takes `stores_kinds` after `stores`, `pending_bases` after `bases` and `refused` after `outbox`.

### Per-kind refills (0060, What one store is)

A new generation or a lower write sequence marks every kind of the file in `stores_kinds`, as 0060 says. A kind refills once its category is on, and its mark then clears. Without the mark, a kind whose category is off when its file is restored would either refill its siblings on every pass, losing their local edits, or merge stale copies.

### Replace points (0054, `key_pins`; 0056, Pins; 0064, Pins)

- A certificate under a replaced IK verifies as history only below that IK's replace `av`. At or above it, it is `keys.retired_ik`. The replace point comes from the replace certificate itself, not from the certificates held on either side of it.
- The trust plaintext's `replaced` entries carry the same point: `{"ik": "<32 bytes>", "av": <n>}`. A merge that meets one IK at two `av`s keeps the lower.
- Without the point, a device that learned of a replace from an approver can be tricked. The server withholds the real replace certificate and serves certificates signed under an old IK it kept from an exposed recovery key, and the device would take them as older history. This affects verification only: the rings still anchor the keys.

### Rules (0054, The engine)

- **An iCloud account switch** starts the new account's file from a full fetch and pushes nothing until the person picks Move my data or Start empty. The engine does not upload the whole library to another Apple ID unasked. This matches the Swift engine, which sent only unsent edits.
- **A zone another device made again** through Upload Again leaves this device download-only until its own person acts, as the Swift engine did.
- **Approvals.** `SyncControl::decide_approval` carries a digest of the value the person saw. If the pulled value changed since the prompt, the decision applies to nothing and the person is asked again.
- **Settings.** `HostSettings` keeps a category its platform's registry does not name, such as a newer build's, and returns it from `categories` unchanged. The diff then never reads its absence as a deletion.
- **The DPoP key.** `AccountFlows::dpop_key` gives the engine the DSK of the device keys in force, or none while the device holds no keys. The service transport takes its proofs from it, with no proof source of its own.

### Integrity readings (0054, Integrity and freshness; K6d)

Each is confirmed, and each fails closed:

1. An iCloud file's state MAC has an empty origin and the iCloud user record name as its account. Nothing of the key tables applies to it.
2. What an open found, stale or with no anchor, is kept in the anchor's root, so a restart before the rebuild ends opens the same way.
3. The rebuild ends without waiting for a `key_versions` row that ended, one stopped as `restore_wait`, or a team or account the device no longer reads.
4. **When the device store cannot be read:**
   - A file never sealed goes on unsealed: its sync tables are trusted and its key tables are not anchored.
   - A sealed file waits with `sync.state.anchor_unsettled`.

   **When a file's MAC does not verify under its MAC key:**
   - If the anchor does not name the file, it starts over.
   - Only a file the anchor names is refused, with `sync.state.integrity`. This narrows 0054's "a file whose MAC does not verify is refused".
5. A stale file's refill on the service clears each scope's cursor, so its pull starts from a snapshot.
6. A device-store error is `sync.state.anchor_unsettled`, never a failure the pass retries.

**The limit gains a keyring-only restore.** An anchor restored without its file is older than the file: a restore of the Linux keyring or of Windows Credential Manager alone does this. The file then opens stale and rebuilds on the older checkpoint. Until the device meets the newer state, it faces the rollback 0054's limit describes.

## Consequences

- The state file gains `refused` and `stores_kinds` and two key table columns, and the trust plaintext's `replaced` entries change shape. The key digest, the checkpoint and the vectors follow.
- A refused change costs one request until it changes, not one per restart.
- A restored store refills each kind once, when its category is on.
- An iCloud account switch or a zone made again elsewhere waits for the person before anything goes up.
- `decide_approval`, `HostSettings` and `AccountFlows` change shape. The proof source seam goes.
- A keyring-only restore is a limit of local state, as a restore of the file with its anchor is.
