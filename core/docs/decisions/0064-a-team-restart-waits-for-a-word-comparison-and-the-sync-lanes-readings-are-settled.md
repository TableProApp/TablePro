# 0064: A team restart waits for a word comparison, and the sync lanes' readings are settled

- **Status**: Accepted; amends 0051, 0054, 0056 and 0059; the kind 3 reset's notice amended by 0065; `stores` rows' per-kind refills, other devices' reset times and the Pins reading amended by 0066
- **Date**: 2026-11-26

## Context

- **A restart taken on first use.** [0056](0056-end-to-end-keys-per-account-and-device.md), Teams, No holder left, lets a member that does not hold the current version take a restart on first use. A malicious server can withhold that member's wrap, then serve a `start` 1 version signed by an account it made up, and the device seals new team secrets under the server's key. The threat model's row on inventing a member that rotates the key rules that out. The maintainer decided on 2026-11-26 that a restart is never taken on first use.
- **Readings.** The lanes building on 0051, 0054 and 0056 met places the text does not settle. Each took the reading that fails closed. This ADR confirms or rules otherwise.

0051, 0054, 0056 and 0059 are Accepted, so these go here, and those ADRs change only their Status lines.

## Decision

### A restart is held until the person compares words

- A device that holds a version of a team key and meets a restart of it, a version with `start` 1 that its own account did not sign, holds it: `keys.restart_held`. It raises a key-change notice ("The team key was started over by Ana. Compare her words before using it.") and does not take the version as current.
- While held, the device writes nothing under that team's key, no envelope, wrap or key object, and opens only what the versions it already holds open. Plaintext team records still sync.
- It applies the restart only once the person compares the restarting owner's six fingerprint words (Pins) and accepts, as Signal and 1Password handle a key change. Accepting without comparing is not offered. The restart's signer then is its holder, and its pin is `compared`.
- The hold is `key_versions.state` `stopped` with [0062](0062-a-stopped-scope-records-why-it-stopped.md)'s `stopped_cause` `restart_held`, so the anchor keeps it. It is not reported, since no rotation clears it.
- A client whose account holds the current version still refuses a restart (`keys.not_holder`). A device that holds no version of the team joins as before. The owner's device that made the restart takes its own.
- **Vectors:** a restart shown to a device that held an earlier version: `keys.restart_held`, nothing written under the team key; the person compares and accepts: applied, its signer the holder; a restart by an account the server made up, words that differ: stays held.
- **Threat model:** a restart reaches a member's device only after a comparison of the restarting owner's words (the named attacks row on restarts).

### Readings

| Lane | Reading | Ruling |
|---|---|---|
| Pins | A higher `av` under the pinned IK is followed across a gap, to the highest certificate held under that IK. A certificate under a replaced IK at or above the pin is `keys.retired_ik` | Confirmed: each certificate is signed by the pinned IK. `keys.step` for an `av` stays where the next one is required: the server's check, and a change set a device verifies as its own account's next |
| Push-back | Only the newest recovery blob goes back | Confirmed: the server deleted the older ones. The server does not require a blob in an account change set; a new rotation still sends one |
| Push-back | An approval made at an `av` stays out of that `av`'s set | Confirmed. The set holds the device certificates and `account` wraps of the devices with no `trust` wrap at that `av`; an approval is redone with a new key device |
| Push-back | No wait for a member's own certificate before a set | Confirmed: the device pushes its own `key.member` first. A wrap whose recipient's `key.member` the server lacks goes back later on its own, and `key_dependency` never ends a scope |
| Push-back | A pending `key.reset` is not in the push-back order | Confirmed. The proposing device pushes it back afterwards as a new proposal under its checks, a fresh step-up for kind 3 included, and the 7 days start again |
| Approval | A trust plaintext whose own pin is missing or not the compared IK is `keys.mismatch` | Confirmed |
| Approval | N, refusing an approval the server applied, ends the session locally with no cancel step | Confirmed, and N revokes the new key device with 0051's Sign Out call, so its row holds none |
| Reset | Other devices' resets go in `key_pending` | Ruled otherwise: they live in `key_objects` as served. `key_pending` holds only this device's own proposal and its private keys |
| Approval | The trust plaintext carries every `key_versions` row, ended and stopped included | Confirmed. The receiver takes no state from it: its own checks stop or end the scope again, and the record digest makes a conflict end it again |
| Account | The own pin made at genesis or replace is `compared` | Confirmed: the device derived the IK itself |
| Account | Accepting an unendorsed change puts the old IK in `replaced` | Confirmed: the client never goes back to it |
| Account | A conflicting personal key object is refused with a notice and the scope does not end | Confirmed |
| Account | A device left out moves its pin and personal rows to the `av` it verified | Confirmed: it cannot open those keys, so it never writes under the old ones again |
| Account | No writes while a newer own `av` waits for the device's own certificate | Confirmed |
| Account | `start` is not checked for personal versions | Confirmed: only the account's own current ASK signs them, and the server checks `start` |
| CloudKit | One `stores` row per kind, keyed `<store>/<kind>` | Ruled otherwise: one row per store file, as [0060](0060-the-change-journal-names-the-records-each-write-changed-and-a-store-is-one-file.md) defines a store; each kind maps to its file |
| CloudKit | A crash between the store write and the state commit, then a zone change, is not a no-op | Ruled: add `pending_bases`. A pull writes the bases it will apply there first, then the store, then the bases and the token. At a restart a pending base whose store copy matches becomes the base; one that does not stays a local edit. 0054's "a crash replays it with no effect" holds then |
| Server | `/v1` keeps stored nulls, every other path drops them | Confirmed: the facade and `/v1` keep what their fixtures show; every `/v2/sync` write drops a null |
| Server | `sync_records.batch_end` and `sync_scopes.purged_revision` | Confirmed. `batch_end` is the last revision of the write that wrote a record, so no page ends inside a change set; `purged_revision` is the highest revision a delete removed, so the horizon never falls below it and a purge reads as no lost write |
| Server | A bad key id is `bad_statement`, not `bad_record_id` | Confirmed for key kinds, as the vectors and 0059 have it; `bad_record_id` stays for the general syntax and other kinds |
| Server | Envelope `nonce` and `ct` lengths are the client's check | Confirmed: the server reads only `kv` of envelopes and history entries |
| 0059 | A kind 1 `key.account` with no `replace_sig` | `keys.encoding`, a missing member. `keys.unendorsed`'s "or that has none" means an IK change that is not a replace |

## Consequences

- A team restart costs each member one comparison with the restarting owner. With no comparison, the device keeps the team's older data and writes no new secret there.
- `stopped_cause` gains `restart_held`, the state file gains `pending_bases`, and 0056's Errors gain `keys.restart_held`.
- The lanes' fail-closed readings stand except the two ruled otherwise, others' resets and `stores` rows.
