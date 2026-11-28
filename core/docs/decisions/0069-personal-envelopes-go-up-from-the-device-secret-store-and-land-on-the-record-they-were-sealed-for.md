# 0069: Personal envelopes go up from the device's secret store and land on the record they were sealed for

- **Status**: Accepted; amends 0054 and 0066
- **Date**: 2026-11-28

## Context

[0044](0044-sync-through-one-service-run-by-us-or-on-premises.md) syncs passwords end to end encrypted, [0056](0056-end-to-end-keys-per-account-and-device.md) defines the envelope and its sealed destination, and [0054](0054-one-sync-engine-in-the-core-for-tablepro-sync-and-icloud.md) gives each kind an adapter. The engine judged pulled envelopes and sealed history entries, but no adapter held `secret_envelope`, so no password ever left a device (E2E finding F10). Building it left open where the sealed copy lives between passes, when a pulled secret may land, what a rotation does to envelopes already on the server, and how the app reaches secrets the connection calls do not.

## Decision

### The adapter (0054, Adapters)

- `secret_envelope` in the personal scope sits over the device's own secret store, through `DeviceSecrets`: a connection's password, SSH password and key passphrase through the Core's secret store, and the other rows of 0056's envelope table the app keeps through the FFI's `HostSyncedSecrets`, which the app passes to `open_sync` and which names the kinds it keeps. The Mac keeps its SSH and credential profiles' secrets there.
- A team's envelopes are its library's secrets. This adapter does not serve team scopes, and `RecordAdapter::serves` leaves a scope to the store that serves it.
- The copy the server and the device last agreed on is the record's base. A secret that still opens from its base, for the same destination and under the version written now, reads as that base, so nothing is sealed again. A changed secret is sealed once and kept in memory until it goes up. Nothing plaintext reaches the state file.
- The account's key moving on, as after a device removal or a new recovery key, seals every secret again under the new version on each device that holds it (0044, Removing a device). Old envelopes stay readable through the rings meanwhile.
- A secret the device no longer holds, or whose record is gone, deletes its envelope. A kind the device does not keep, a record it cannot read and an id it does not read are kept and sent back unchanged, never deleted.
- A journal pass that names a connection or profile also reads its envelopes, since a library write that saved a secret names its record.

### Landing a pulled envelope (0056, At use)

- A pulled envelope lands only while the device holds its record, syncing, with the destination the secret was sealed for. A record new to the device waits for the person (0044), and a destination changed since is the approval case, so its envelope waits with it.
- An envelope the keys took that its store did not is held as `awaiting_store`, a new value of `held.reason` (0066, The state file). Each pull offers it to the store again without a second judgement, since the keys judged it at its place in the order before the store saw it. One the keys refused stays `unreadable` and waits for the server to serve it again, as before.
- Within a page, records apply before envelopes, so a record and its secret pulled together land together.
- A record the device keeps to itself takes nothing a pull brings, as on iCloud.
- The app keeps a pulled secret on the device only (0044, iCloud Keychain).

### Policies (0051, Policies)

A `policy` refusal stands only while the switch that refused it is off. Once the scopes body says it is on again, the change goes up again, as a device pushes its copies back when an admin turns a switch on. 0066's `refused` rule holds for every other code.

## Consequences

- Passwords sync on TablePro Sync from the first upload, after the recovery key is confirmed (D6): before that the keys write no personal secret, and the move plan counts the secrets it will seal.
- An older build reading a state file that holds `awaiting_store` refuses the file. No build that runs TablePro Sync's personal scope has shipped.
- A driver's own secure fields (`plugin.<field id>`) and a settings record's AI keys do not sync yet: no store here reads them. Their envelopes from another device are kept and sent back unchanged.
- Each device holding a secret seals it again after a rotation, so the later pusher wins on equal plaintext.

## Alternatives considered

- **Seal at push time, as history does.** A history entry is created once, so its base holds no fields. An envelope is patched, and a base of sealed fields never equals a plaintext local copy, so every pass would push again.
- **A file of sealed copies beside the state file.** It holds what the bases already hold, and it would need its own identity and restore rules.
- **Land a pulled secret whatever its record says and check the destination at connect.** The connect paths of four apps would each need the sealed destination, and a secret would sit in the store for a host the person never approved.
