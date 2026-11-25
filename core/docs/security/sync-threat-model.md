# Sync threat model

This model covers TablePro Sync with end-to-end keys, on our SaaS and on a self-hosted install. The keys and their checks are in [ADR 0053](../decisions/0053-end-to-end-keys-under-the-recovery-key.md), cited below by section name.

The other ADRs:

- the protocol and the server's record rules: 0051;
- record ids: 0052;
- the sync engine: 0054;
- the service and its deploys: [0044](../decisions/0044-sync-through-one-service-run-by-us-or-on-premises.md).

iCloud sync and iCloud Keychain follow Apple's own model and are out of scope.

**Review status.**

- The design gets internal review only: gates G0 to G3, each a Codex review plus an independent security agent, and the formal model in `models/`.
- No third party has reviewed it, and no text may say otherwise.
- Whether to commission an external audit is decided before end-to-end encryption leaves beta.

## What is protected

| Asset | Protection |
|---|---|
| Secrets: database passwords, SSH passphrases and keys, AI provider keys, inside a `secret_envelope` | Confidential and authentic against the server. Bound to their record, secret kind and key version, and to the destination they were sealed for |
| Query history | Confidential and authentic against the server |
| Account and team keys | Reach only key holders and confirmed members, checked against signed logs |
| Which devices and members hold keys | Signed, hash-chained logs. The server cannot change them without being detected, within the limits under Rollback and split views |
| Plaintext records: connections, groups, tags, SSH profiles, credential profiles, saved queries and folders, favorites, table folders, settings | Protected from the network and from other accounts. **Readable by the operator.** Under D8, readable only by approved devices of the account |
| Team plaintext records | Readable by the operator and by every team member the server's roles allow |

## Assumptions

- **The app is genuine.** It is a signed release build, and the device's OS and key store work as documented.
- **Randomness.** The system RNG gives unpredictable bytes.
- **TLS** to the server uses the OS trust store, with no pinning (0044). The model does not need TLS for the secrets, only for availability and for plaintext records.
- **People compare.** A person compares the five words on both screens before confirming. A person who confirms without looking gives the comparison away.
- **Libraries.** aws-lc-rs, the rustls HPKE module and Go's standard library are correct. The vectors and the Go differential check this (0053, Vectors).

## Actors

| Actor | Protected | Not protected |
|---|---|---|
| Network attacker | Everything, through TLS on the OS trust store | Traffic timing and sizes |
| Honest-but-curious operator, database staff, backups, dumps, the cloud provider | Secrets, history, keys | Plaintext records, metadata (below) |
| Malicious operator with full control of the server | Secrets and history, as long as it never gets a key holder or a recovery key. The named attacks below are refused or detected | Withholding; full rollback for a device that never saw the newer head; split views until two sides compare; fake revocations, which deny service; plaintext records |
| A compromised IdP or a phished session | Personal data, plaintext included: nothing personal flows without an approved key holder or the recovery key (D8). Team secrets: they need a confirmed SK | Team plaintext records that the account's seat and role allow; genesis on an account with no identity yet; a reset on an account with no holder left |
| A lost or stolen device | After removal with the recovery key: every new secret and history write, and the new key versions | What the device already holds, and anything readable before the removal |
| A stolen device working with the server | Taking over the identity: IK is not on the device, and a reset needs a comparison with an own device or a teammate | Reading new data until the person removes the device; envelopes under old key versions shown to a device that never saw the earlier value |
| A removed member | Team key versions after the rotation. The floor stops writers on old keys | Secrets they could already read, which is why "Credentials to rotate" exists |
| A malicious current member, with the server's help | Other people's personal scopes | Writing a team secret under a valid writer signature |
| A malicious signer | Other people's personal scopes. With three signers or more, one signer cannot remove another alone | Every team secret. Confirming puppet accounts and sealing keys to them. Adding signers. All of it shows in every member's app |
| Self-hosted customer IT as operator, IdP admin, install admin and endpoint manager | Secrets against dumps, backups and database staff | Anything on endpoints it controls. It can install software, read device memory or sign in as anyone through its IdP. End-to-end encryption does not protect against the organization itself |

## A malicious server operator

**Who.**

- **On the SaaS:** anyone with write access to production: an attacker inside our infrastructure, or staff acting outside policy.
- **Self-hosted:** the customer's own IT, which usually also runs the IdP, holds the install admin role and manages the endpoints.

This is the case the end-to-end design exists for.

**What it can do.** It can:

- read and write every row;
- run a modified server binary;
- serve different answers to different devices;
- drop, delay, replay or reorder records;
- create accounts and assign roles, including owner;
- revoke sessions and device rows;
- lie about policies, floors and epochs.

**Named attacks.**

| Attack | What stops it | 0053 |
|---|---|---|
| Seal a key it knows to RK, an SK or a holder | The recipient checks the unwrapped key's `kid` or public key against a statement signed by IK or a signer. A server key does not match | Key commitment; Wraps and rings |
| Forge recovery: hand a recovering device its own identity | IK comes from the blob, which only S opens. The log must verify under that IK | The recovery key and the recovery blob |
| Swap a public key: a holder's, an SK or an RK | Public keys come only from signed statements. Device and member keys are pinned through a comparison | Logs; Comparing keys |
| Substitute keys during device approval or member confirmation | A commitment leaves it one guess at 2^-64.6 per session. The QR code carries 256 bits | Comparing keys |
| Replay an old statement, key version or device list | Hash chains, stored heads and highest versions; `dh` and `ih` compare-and-set; floors | Logs; Ordering rules |
| Add a holder after a removal, or keep one a stolen device planted before it | Approvals are signed by the approving holder, and a `rotate` takes out every holder the removed ones approved. The rules replay the same on every client | Ordering rules between the two account logs |
| Hand back a superseded envelope under the same key version | Each envelope carries a counter. Clients keep the highest they accepted and refuse a lower one | Envelopes, Replays |
| Squat a log position, a wrap or a ring through a phished session | Key-object writes need a DPoP proof from an approved holder. The server verifies team statements as it does account statements. A wrap or ring can be replaced by its writer | Key objects as records |
| Seal a new team key to a revoked SK | Signers seal only to current, unrevoked SKs, and `key` names its recipients | Team log; Rotation pending |
| Mint an envelope | Envelopes are AEAD under keys the server never has. Team envelopes also carry the writer's signature | Envelopes |
| Move an envelope to another record, kind, scope or version | The AAD binds them, and the subkey is per record | Envelopes |
| Rewrite a connection's host so a password goes elsewhere | The destination is sealed inside the envelope. A mismatch asks the person | Envelopes, At use |
| Downgrade the suite | Clients accept `tp1` only. The suite is inside every `info` and AAD | Suite, encoding and labels |
| Replay a blob or statement from another account or install | Origin and account are bound into K_rw, the blob's AAD and every statement | The recovery key and the recovery blob; Logs |
| Make up a reset | Own devices need the holder's endorsement and then a comparison. Teammates must confirm again | Flows, Reset |
| Make up a team genesis before the real owner | Trust on first use. The real signer's app sees a log it did not write, and members' comparisons with it fail | Team log; Comparing keys |
| Re-root a team through staff tools | No staff tool writes one. A re-root is visible, and every member must confirm again | Team log, `reroot` |
| Fake a revocation or a removal hint | Only denies service, and it shows: signers stop sealing to that SK, and the person's next device asks for the recovery key | Flows, Admin removal |
| Lower a floor or the version a client sees | Clients enforce the versions that signed removals require, whatever the server says | Envelopes, Ordering |

**What it still gets.**

- Every plaintext record in full, and the metadata below.
- It can withhold records or statements. A device sees stale data, and a missing statement looks the same as no change.
- It can show a device that never saw a newer head a full older state: a fresh device, or a recovery from zero devices.
- It can keep two groups of devices on two consistent histories (split view) until they compare.
- It can deny service at any time.

## A compromised IdP or session

**Who.**

- **On the SaaS:** a phished Google, GitHub or Apple sign-in, or a stolen refresh token.
- **Self-hosted:** also the IdP admin, who can sign in as anyone.

**What holds.**

- **Personal data.** A new session gets no personal record, plaintext or not, until a key holder is approved from another device or with the recovery key. The server enforces this through DPoP proofs checked against the signed device set (0053, Server enforcement). Before approval the session reads only the identity and device logs and the recovery blob, which is under a 256-bit seed.
- **Team secrets.** They need a sharing key that a signer confirmed through a comparison.
- **Writes.** The session writes no key object and no envelope in any scope, since those writes need a DPoP proof from an approved holder.
- **Social engineering.** A request from the attacker shows on the person's devices as a new device asking for approval. Approving it needs the five words on the attacker's screen.

**What does not hold.**

- Team plaintext records, as far as the account's seat and role allow.
- Genesis on an account with no identity yet is trust on first use. An attacker who gets there first owns that identity. The person's own genesis then fails, and the account is recovered by an admin removing the attacker's device row, then a reset.
- A reset on an account with no holder left is also trust on first use. The server first deletes the account's personal and history records, keeping only its logs, so it exposes nothing earlier.
- The logs, which an attacker can read before approval: public keys, device platforms and when the person removed devices.

## A lost or stolen device

**What the device holds.** Everything its holder holds:

- the AK ring, ASK, SK and the team key rings;
- the local plaintext stores, and the secrets in the device store.

It holds no IK and no recovery key.

**What the thief can do** until the device is removed, if it can unlock it or read its store:

- read everything the person can;
- write as the person;
- approve new holders in the stolen holder's name, which honest devices show in the device list. Removing the stolen device removes them too.

**After removal with the recovery key** (0053, Removing a lost device):

- new ASK, SK and AK versions reach only the remaining holders;
- each team rotates its key;
- the honest server refuses the device's DPoP key.

What the device already read stays read. "Credentials to rotate" lists the database credentials to change.

**With the server's help, after removal**, the thief can:

- show a device that never saw the newer head an older state;
- write envelopes under the old versions. A device that already saw the removal refuses them, and a device that never held the earlier value cannot tell.

It cannot take over the identity:

- IK is not on the device;
- a reset needs a holder endorsement, and then a comparison with each of the person's other devices;
- teammates confirm again.

**An admin removal without the recovery key** cuts the device's access on an honest server at once. Personal key versions do not change until the person enters the recovery key. Until then, new personal secret and history writes wait in the local queue.

## A malicious team member

- **A confirmed member** reads every team secret, by design. With the server's help, a member can write a team secret, since roles are server data and the writer signature proves only membership. A member cannot read other people's personal scopes.
- **A member who is not confirmed yet** reads team plaintext records and no team secret.
- **A malicious signer** is trusted with the team. It can confirm puppet accounts and seal the team key to them, and it can add signers. k = min(2, n-1) only stops one signer from removing another alone when there are three signers or more. Every statement it signs is in the team log, which every member's app verifies and shows.
- **A removed member** keeps what they read. The next team key version is sealed only to the members left. Until a signer's app rotates the key, the honest server's floor holds new team secret writes back, and clients refuse to write under old versions.
- **Collusion with the server** cannot get a new team key version to a revoked SK, since signers seal only to current SKs. The formal model checks this claim.

## Rollback and split views

ePrint 2026/058 calls rollback an open problem for clients that keep no state. Here, each client keeps every log it follows, with its head, under an HMAC keyed from the device store.

**What holds.**

- A device refuses any log that does not extend its stored head.
- A device refuses any statement at a position it already holds with a different hash, and raises a fork alarm.
- Key versions and floors only move forward.
- Every comparison, for device approval or member confirmation, covers the log heads, so two devices that compare also check that they see one history.

**What does not hold.**

- **A device with no state yet** has nothing to compare against: a new device, or a recovery from zero devices. The server can show it a consistent older state. Its approval comparison catches this against an existing device, and a recovery with S has no such partner.
- **Split view.** The server can keep two groups of devices on two consistent branches indefinitely. They notice only when a device of one group compares with a device of the other.
- **Withholding** a statement looks the same as no statement.
- **This is not key transparency.** draft-ietf-keytrans-protocol is still a draft. A transparency log, or devices gossiping heads, could detect split views later.

## Metadata the server sees

**Who and when.**

- Accounts, team membership, roles, and device rows with their names, platforms and app versions.
- The time of every push and pull, and the client IP address. Self-hosted installs keep it in their own logs.
- Device approval requests, comparison sessions and their timing.
- DPoP key thumbprints, which tie each request to a key holder.
- Device and roster changes: added and removed holders, members confirmed and removed, signers added and removed, re-roots.

**Shape of the data.**

- Which records carry which secret kinds, for example which connections have a password or an SSH passphrase.
- Key versions per envelope and history entry, and padded sizes.
- History entry counts, padded sizes and push timing. Record ids are random UUIDv4, so they leak no capture time, and pushes are batched.
- The number of key holders, and how many were removed in each rotation.
- When a person replaced or reset their recovery key.
- **The team log in clear:** who confirmed whom and when, the signer set, and the recipients of each team key version.
- **The identity and device logs in clear:** public keys, holder ids, device rows and the order of every change.

**Plaintext records in full:**

- connection hosts, ports, users and database names, which can be SQLite file paths;
- SSH profiles;
- credential profiles and typed references;
- settings;
- saved queries with their SQL text;
- favorites, table folders, groups and tags.

**Teammates** see each member's identity log through member bundles: when the person removed devices, and how many, and recovery key replacements and resets.

## Residual risks

1. **Trust on first use** at genesis, at a reset with no holder left, and at a team's genesis.
2. **Split views and withholding** go undetected until devices compare.
3. **Full rollback** works against a device with no state.
4. **A confirmed member** can write a team secret with the server's help.
5. **A thief working with the server** can show an old-version envelope to a device that never saw the earlier value.
6. **A malicious signer** can grant the team key to accounts of its choice.
7. **A person who confirms a comparison without reading it** approves whatever is on the other screen.
8. **Plaintext records and metadata** are readable by the operator.
9. **The organization running a self-hosted install** controls its endpoints and its IdP, which end-to-end encryption does not cover.
10. **P-256 and Ed25519 are not post-quantum.** Someone who archives `tp1` wraps today could open them on a future quantum computer, and with them every envelope and history entry written under those key versions, however strong AES-256 is. Moving to `tp2` issues new keys that reach anyone only through hybrid wraps, so it protects what is written after the move, not what was written before (0053, Suite).

## Out of scope

- Malware on an unlocked device, a modified app build, and side channels on the device.
- Coercion of a person.
- Denial of service by the operator.
- iCloud and iCloud Keychain.

## Formal model

`models/` holds Tamarin theories for the flows and claims 0053 lists under Formal model and review. The prover's version and how to run the theories are in the folder's README. A claim that fails changes the design before any key code ships. This follows the formal analysis of Apple's PQ3 (Linker, Sasse and Basin, USENIX Security 2025).

## Sources

- ADR 0053 and its Sources.
- Scarlata et al., ePrint 2026/058: https://eprint.iacr.org/2026/058
- RFC 9180 §9: https://www.rfc-editor.org/rfc/rfc9180.html#section-9
- RFC 9449 §11: https://www.rfc-editor.org/rfc/rfc9449.html#section-11
- RFC 6189 §4.4.1.1: https://www.rfc-editor.org/rfc/rfc6189.html
- draft-ietf-keytrans-protocol: https://datatracker.ietf.org/doc/draft-ietf-keytrans-protocol/
- Linker, Sasse, Basin, "A Formal Analysis of the iMessage PQ3 Messaging Protocol", USENIX Security 2025: https://security.apple.com/assets/files/A_Formal_Analysis_of_the_iMessage_PQ3_Messaging_Protocol_Basin_et_al.pdf
