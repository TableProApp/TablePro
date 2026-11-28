# 0079: Team connection secrets go up sealed with a publish and open at use

- **Status**: Accepted; amends 0054, 0066 and 0076
- **Date**: 2026-11-28

## Context

[0044](0044-sync-through-one-service-run-by-us-or-on-premises.md) puts a team's `secret_envelope` in its scope, [0051](0051-sync-protocol-and-record-rules.md) lets owners, admins and editors write it under the team's `password_sync`, and [0056](0056-end-to-end-keys-per-account-and-device.md) defines the envelope, its sealed destination and the team key it is sealed under. [0076](0076-personal-envelopes-go-up-from-the-device-secret-store-and-land-on-the-record-they-were-sealed-for.md) gave the personal envelopes a store and left a team's to "the store that serves it", and none did: a publish wrote no envelope, and a teammate connecting to a Team Library connection had to know the password (E2E finding F24). A team connection is never saved on a teammate's device, so the device's secret store has no record for its secret to land on.

## Decision

### The store (0054, Adapters)

- A team's envelopes live in the Team Library store, `team_library.json`, beside the team's copies: each team keeps a list of sealed envelopes, the ciphertext the server holds, by record id. Nothing plaintext is written there or anywhere else.
- `secret_envelope` in a team scope has an adapter of its own over that list, which serves team scopes only. A pull lands the copies the keys already judged, and the engine sends a copy written here as it sends any change, after the team's library writes. A team's deletions send a connection's envelopes before the connection.

### Publishing (0051, Roles in a team scope)

- A publish names a connection's secrets as the full set it signs in with, or leaves them as the team has them. Each secret in the set is sealed under the team key's current version for the destination the published copy names; a sealed copy that still opens to the same secret for the same destination under that version is kept, so publishing twice sends nothing the second time. A kind left out of the set loses its envelope, and a removed connection loses all of its.
- A secret goes up only when the copy uses it: the SSH ones through a tunnel that is on, a key passphrase for a key file the copy names, the TOTP secret when the copy asks for a code. A driver's own fields have no store yet, as 0076 says of the personal ones.
- A saved connection publishes the secrets it signs in with: a linked credential profile's password and a linked SSH profile's secrets in place of its own, since the team copy carries the profile's values. They are read under the hold that keeps the app's saves out, and only while the library still holds the connection going where the published copy goes; a copy the app read before a save moved the connection keeps the team's secrets as they are. An editor's edit of a team copy passes the secrets the person saw, or none to leave the team's as they are.
- When the team's `password_sync` or this device's password sync is off, or this device cannot seal (its account not confirmed, the team key stopped or a restart waiting, the team due a rotation, or a role that writes no envelope), the connection still publishes, no envelope of any connection in that publish changes, and the publish reports why: `sync.team_library.passwords_off`, `.not_confirmed`, `.rotation_due` or `.passwords_role`.
- A discard of a team's unsent edits puts its envelopes back as the server last agreed on them.
- A `rotation_due` refusal stands only while the team is due a rotation, as 0076 has a `policy` refusal stand only while its switch is off: an envelope the server held back goes up once the next team version applies (0056, Teams, Rotation due). A publish whose envelopes wait reports the server's code.
- An envelope written here that has not gone up yet is sealed again under the current version before a push once the team key moved on, so a rotation between a publish and its push strands nothing; a device never writes under a version below the highest it took (0056, Writing).

### At use (0056, At use)

- A team connection's secrets are opened when the app asks for them, for a connect or the edit form, and only for the destination the store's copy of the connection names then. One sealed for another destination, one this device cannot open, and a kind with no envelope are left out, and the app asks the person as for any connection without a stored password. A team copy held for the person's approval is not in the store, so its secrets wait with it.
- Every member who holds the team key reads them, viewers included (0044, a confirmed member reads every team secret).
- A copy the device's own store holds opens with no rollback floor and records nothing: a pulled one was judged when it arrived and one sealed here has not gone up, so reading or comparing it never moves the floor a later pull is judged against (0056, Rollback).

### What 0056 already settled

- Team envelopes carry no writer signature: 0056 dropped writer signatures and envelope counters, and its threat model accepts that a member with the server's help can replace a secret's value (Residual risks 5). The F20 wording of the full-sync plan predates 0056 and does not apply.
- Envelopes stay under the version they were written with after a rotation (lazy revocation); a publish after it seals what it publishes under the new version.

## Consequences

- A teammate connects to a published connection without typing its password once the owner or an editor publishes it with the team's password sync on.
- An editor's edit that moves a connection seals its secrets again for the new destination; an edit from a device that cannot seal leaves the old seal, which members then do not use, as 0056's F3 case 5 has it.
- A password changed and published while offline waits with the publish's other edits, but Sign Out lists only the library items.
- An older build reading a `team_library.json` that holds envelopes ignores the list and writes it back without it; no build that runs Team Library on the engine has shipped.

## Alternatives considered

- **Land a pulled team secret in the device's secret store, as personal envelopes do.** A team copy has no saved record on the device to land on, so the secret would need keys of its own there, a cleanup on every team change and sign-out, and plaintext at rest for a connection the person may never open.
- **Read the publisher's secrets in each app.** Every platform would repeat which profile's secret a connection signs in with; the core already reads them for the personal envelopes.
