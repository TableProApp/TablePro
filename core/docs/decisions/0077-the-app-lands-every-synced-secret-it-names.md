# 0077: The app lands every synced secret it names

- **Status**: Accepted; amends 0076
- **Date**: 2026-11-28

## Context

[0076](0076-personal-envelopes-go-up-from-the-device-secret-store-and-land-on-the-record-they-were-sealed-for.md) sends a connection's password, SSH password and key passphrase through the Core's `SecretVault`, which on the Apple apps is `HostSecrets`, and only the other rows of 0056's envelope table through `HostSyncedSecrets`. `HostSecrets` writes each item into the scope the app's own rules pick. On the Mac those follow the iCloud Keychain switch until the Keychain has followed the provider to TablePro Sync, so a password pulled during a move from iCloud could become a synchronizable item, against [0044](0044-sync-through-one-service-run-by-us-or-on-premises.md)'s iCloud Keychain rule.

## Decision

- A kind the app names in `HostSyncedSecrets::kinds` goes through `HostSyncedSecrets`, a connection's password, SSH password and key passphrase included. The app writes and removes those as this device's own items, whatever its iCloud Keychain switch says.
- A connection's password, SSH password or key passphrase the app does not name goes through the Core's `SecretVault`, as 0076 says. Windows passes no host, so its Credential Manager items stay the path there.

## Consequences

- The Mac names every kind it syncs, its connections' three included, and its host writes each with `deviceOnly`, so no pulled secret reaches iCloud Keychain during a move.
- A removal the app refuses fails the store write, so the engine holds the envelope's deletion and tries again on the next pull.
