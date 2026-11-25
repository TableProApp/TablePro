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
| A compromised IdP or a phished session | Personal data, plaintext included: nothing personal flows without an approved key holder or the recovery key (D8). Team secrets: they need a confirmed SK. Key objects and envelopes: it writes none | Team plaintext records that the account's seat and role allow; genesis on an account with no identity yet; a reset on an account with no holder left, after a step-up and 7 days that S can cancel |
| A lost or stolen device | After removal with the recovery key, even after the thief signed it out: every new secret and history write, the new key versions, and what it approved, confirmed or added | What the device already holds, and anything readable before the removal |
| A stolen device working with the server | Taking over the identity: IK is not on the device, a reset waits 7 days that any other device or S can cancel, and following it needs a comparison | Reading new data until the person removes the device; an older view shown to a holder that pins again with S; a new team key sealed by a signer from whom the server withheld the member's `rotate` |
| A removed member | Team key versions after the rotation. The floor stops writers on old keys | Secrets they could already read, which is why "Credentials to rotate" exists |
| A malicious current member, with the server's help | Other people's personal scopes | Writing a team secret under a valid writer signature |
| A malicious signer | Other people's personal scopes | Every team secret. Confirming puppet accounts and sealing keys to them. All of it shows in every member's app |
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
| Seal a key it knows to RK, an SK or a holder | The recipient checks the unwrapped key's `kid` or public key against a statement signed by IK or a signer's holder. A server key does not match | Key commitment; Wraps and rings |
| Forge recovery: hand a recovering device its own identity | IK comes from the blob, which only S opens. The log must verify under that IK | The recovery key and the recovery blob |
| Show a recovering device a log cut before a removal | Recovery ends with a `rotate` that removes every other holder and issues keys the removed holder never had | Flows, Recovery |
| Swap a public key: a holder's, an SK or an RK | Public keys come only from signed statements. Device and member keys are pinned through a comparison | Logs; Comparing keys |
| Substitute keys or heads during device approval or member confirmation | The commitment covers the initiator's message and random value. Each side fixes its view before it publishes its random value, so the server gets one guess at 2^-64.6 per session. The QR code carries 256 bits | Comparing keys |
| Show a new device an older team log or member bundle | Device approval compares the approving device's team checkpoints, and the new device pins them | Comparing keys, Device approval |
| Replay an old statement, key version or device list | Hash chains, stored heads and highest versions; `dh` and `ih` only move forward, with compare-and-set on the server; floors | Logs; Ordering rules |
| Re-encode a signature so one statement gets two hashes and raises a fork | A statement's hash covers its signing input, and base64url must be canonical | Suite, encoding and labels |
| Add a holder after a removal, or keep one a stolen device planted, even one that then signed out | Approvals are signed by the approving holder. A `rotate` takes effect at its `dh` and takes out every holder the removed ones approved | Logs, Ordering rules |
| Keep a puppet that a stolen signer's device confirmed or added as a signer | Team statements are signed by one holder. Those of a holder the account later removes are voided, and the team rotates its key | Logs, Team log |
| Seal a new team key to a revoked SK by hiding a member's `rotate` from the signers | Not prevented against a malicious server: the signer seals to the SK it last verified. The honest server refuses a `key` naming a stale SK. `key` names the member log head each recipient was checked at. The member's own app refuses the version, raises an alarm and publishes its `rotate` again | Flows, Rotation pending |
| Mint an envelope | Envelopes are AEAD under keys the server never has, and every envelope carries its writer holder's signature | Envelopes |
| Slip in an envelope a removed holder wrote under an old key version | A client refuses envelopes from a removed holder unless it held them before it saw the removal. The removing client seals the removed holder's envelopes again under the new version | Envelopes |
| Hand back a superseded envelope | Each envelope carries (`kv`, `n`). Clients keep the highest they accepted and refuse anything not above it | Envelopes |
| Pin an envelope counter so honest writes are refused | The honest server takes only the next counter and answers `bad_counter` otherwise. `n` starts again under each key version, so a removal clears a counter a stolen holder pushed up | Envelopes |
| Move an envelope to another record, kind, scope or version | The AAD binds them, and the subkey is per record | Envelopes |
| Rewrite a connection's host so a password goes elsewhere | A destination change waits for approval on each device. A sealed destination that differs from the record's asks too | Envelopes, At use |
| Downgrade the suite | Clients accept `tp1` only. The suite is inside every `info` and AAD | Suite, encoding and labels |
| Replay a blob or statement from another account or install | Origin and account are bound into K_rw, the blob's AAD and every statement | The recovery key and the recovery blob; Logs |
| Make up a reset, or have a stolen device reset the identity | A reset waits 7 days, and any of the person's devices or S cancels it. Own devices follow a reset only through a comparison, and teammates confirm again | Logs, Identity log; Flows, Reset |
| Reset an account with no holder left and delete its data | The reset needs a sign-in at the IdP within the last 300 s, and waits 7 days with notice. S cancels it. The server takes the `activate` only after the delay and only if no cancel came, and deletes nothing before it, the key logs never | Flows, No holder left |
| Make up a team genesis before the real owner | Nothing stops the first one: it is trust on first use. The real owner's app sees a log it did not write. A member's comparison checks that both sides see one team log, and shows its root and signers, but it cannot prove the root is the right person | Team log; Comparing keys |
| Re-root a team through staff tools, or make a signer look gone | No staff tool writes one. A signer counts as gone only through its own logs, never a server hint. A re-root is visible, and every member must confirm again | Team log, `reroot` |
| Fake a revocation or a removal hint | Only denies service, and it shows. A holder that gets `device_removed` locks and erases nothing. Signers stop sealing to that SK, and the person's next device asks for the recovery key | Flows, Admin removal |
| Ignore an admin's portal removal | Signer apps show members the team log confirms but the roster no longer lists, and the portal shows the removal pending until the team log has it | Flows, Removing a member |
| Squat a log position, a wrap or a ring through a phished session | Key-object writes need a DPoP proof from an approved holder. The server verifies team statements as it does account statements. A wrap or ring can be replaced by its writer | Key objects as records |
| Lower a floor or the version a client sees | Clients enforce the versions that signed removals require, whatever the server says | Envelopes, Writing |

**What it still gets.**

- Every plaintext record in full, and the metadata below.
- It can withhold records or statements. A device sees stale data, and a missing statement looks the same as no change.
- It can show a holder that pins again with S, with no device to compare with, a consistent older view.
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
- **Genesis** on an account with no identity yet is trust on first use. An attacker who gets there first owns that identity. The person's own genesis then fails, and the account is recovered by an admin removing the attacker's device row, then a no-holder reset.
- **A reset on an account with no holder left** is also trust on first use once it takes effect. The server takes it only after a step-up at the IdP, it waits 7 days with notice in the portal and, on the SaaS, by email, and a person who still holds S cancels it. The server deletes the account's personal and history records only when it takes effect, keeping its logs, so it exposes nothing earlier. On self-hosted, the operator who also runs the IdP and the portal can suppress the notice, which falls under the organization row above.
- **The logs,** which an attacker can read before approval: public keys, device platforms and when the person removed devices.

## A lost or stolen device

**What the device holds.** Everything its holder holds:

- the AK ring, SK, its own holder keys and the team key rings;
- the local plaintext stores, and the secrets in the device store.

It holds no IK and no recovery key.

**What the thief can do** until the device is removed, if it can unlock it or read its store:

- read everything the person can;
- write as the person, every write signed by the stolen holder;
- approve new holders in the stolen holder's name, which honest devices show in the device list;
- if the person is a signer, confirm members and add signers in that holder's name;
- start a reset, which waits 7 days, shows on every device, and any other device or S cancels.

**After removal with the recovery key** (0053, Removing a lost device). This holds even if the thief signed the device out first:

- new SK and AK versions reach only the remaining holders, and every holder the stolen one approved is removed with it;
- team statements the stolen holder signed are voided, and each team rotates its key;
- envelopes it wrote are sealed again under the new version, and clients refuse any new one from it;
- the honest server refuses the device's DPoP key, since its row went first.

What the device already read stays read. "Credentials to rotate" lists the database credentials to change.

**With the server's help, after removal**, the thief can:

- show a holder that pins again with S an older view, which its closing `rotate` makes worthless to the thief;
- show a device paging back through history an entry it backdated, which that device marks as written on a removed device.

It cannot take over the identity:

- IK is not on the device;
- a reset needs 7 days without a cancel, and then a comparison with each of the person's other devices;
- teammates confirm again.

**An admin removal without the recovery key** locks the device on an honest server at once. Personal key versions do not change until the person enters the recovery key. Until then, new personal secret and history writes wait in the local queue.

## A malicious team member

- **A confirmed member** reads every team secret, by design. With the server's help, a member can write a team secret, since roles are server data and the writer signature proves only membership. A member cannot read other people's personal scopes.
- **A member who is not confirmed yet** reads team plaintext records and no team secret.
- **A malicious signer** is trusted with the team:
  - it can confirm puppet accounts and seal the team key to them;
  - once a team has two signers, it can neither add a signer nor remove another alone, since both need k = min(2, n) approvals;
  - owners' apps warn while a team has one signer.

  Every statement it signs is in the team log, which every member's app verifies and shows.
- **A team whose last signer is gone,** having reset, removed itself or lost every device, can be re-rooted by an owner the server lists. Every member's app shows it, and every member confirms the new root before trusting it. A thief who resets the last signer's identity waits 7 days first, and any of that signer's devices or its recovery key can cancel.
- **A removed member** keeps what they read. The next team key version is sealed only to the members left, and the envelopes their holders wrote are sealed again. Until a signer's app rotates the key, the honest server's floor holds new team secret writes back, and clients refuse to write under old versions.
- **Collusion with the server.** No signer seals a new team key version to an SK it has verified as revoked, and the formal model verifies that claim. A server that withholds a member's `rotate` from a signer can still get the next version sealed to the member's old SK, which a stolen device of that member opens. The honest server refuses such a `key`. The member's own app refuses it, writes nothing under it, raises an alarm and publishes its `rotate` again, so the withholding shows.

## Rollback and split views

ePrint 2026/058 calls rollback an open problem for clients that keep no state. Here, each holder keeps every log it follows in the key tables of its state file, and 0054 keeps a key checkpoint in an anchor in the device store: each log's head, each floor, and each envelope's highest counter (0053, Security state).

**What holds.**

- A device refuses any log that does not extend its stored head.
- A device refuses a second statement at a position it already holds with a different signing input, and raises a fork alarm. A fork ends only through a statement the key in force at the fork signs, or k signers for a team.
- Key versions, envelope counters and floors only move forward.
- A stale state file, edited or older than its anchor, is not trusted, and neither is an anchor with no file. The key tables are rebuilt from the server's logs, taking only what extends the anchored checkpoint, or the pending one a crash left, and no secret is written until a log extends the anchored heads. No comparison pins a head older than one the holder has anchored.
- Every comparison covers the log heads, so two devices that compare also check that they see one history. A device approval also compares the team logs and member bundles, and the new device starts from the approving device's checkpoints.

**What does not hold.**

- **A holder that pins again with S,** after a recovery from zero devices or with a file that has no anchor, has no device to compare with. The server can show it a consistent older view of the account's logs. That pin ends with a `rotate` that issues fresh keys and removes every other holder, so an older view gives a removed holder nothing new. The holder can still see an older view of the person's teams until it compares with a teammate or another of its own devices.
- **A file with no anchor** pins again through a comparison with another holder, or with S as above.
- **A restore of the state file together with its anchor,** such as a whole-machine image, cannot be told apart locally from the moment it came from (0054). Freshness across it needs a hardware monotonic counter.
- **Deleted history ids** live in the file only, so a restore can let the server bring back history entries the person deleted.
- **Split view.** The server can keep two groups of devices on two consistent branches indefinitely. They notice only when a device of one group compares with a device of the other.
- **Withholding** a statement looks the same as no statement.
- **This is not key transparency.** draft-ietf-keytrans-protocol is still a draft. A transparency log, or devices gossiping heads, could detect split views later.

## Metadata the server sees

**Who and when.**

- Accounts, team membership, roles, and device rows with their names, platforms and app versions.
- The time of every push and pull, and the client IP address. Self-hosted installs keep it in their own logs.
- Device approval requests with the requesting platform, comparison sessions and their timing, and pending resets.
- DPoP key thumbprints, which tie each request to a key holder.
- The writer, account and holder, in clear on every envelope and history entry, and `updated_device` on every record (0051). So the server learns which device last set each secret and wrote each history entry.
- Device and roster changes: added and removed holders, members confirmed and removed, signers added and removed, re-roots.

**Shape of the data.**

- Which records carry which secret kinds, for example which connections have a password or an SSH passphrase.
- Key versions and counters per envelope, key versions per history entry, and padded sizes.
- History entry counts, padded sizes and push timing. Record ids are random UUIDv4, so they leak no capture time, and pushes are batched.
- The number of key holders, and how many were removed in each rotation.
- Ring sizes, which give the number of key versions.
- When a person replaced or reset their recovery key.
- **The team log in clear:** who confirmed whom and when, from which holder, the signer set, and the recipients of each team key version.
- **The identity and device logs in clear:** public keys, holder ids, device rows, platforms and the order of every change.

**Plaintext records in full:**

- connection hosts, ports, users and database names, which can be SQLite file paths;
- SSH profiles;
- credential profiles and typed references;
- settings;
- saved queries with their SQL text;
- favorites, table folders, groups and tags.

**Teammates** see each member's identity and device logs through member bundles: device platforms and rows, when the person removed devices and how many, and recovery key replacements and resets.

## Residual risks

1. **Trust on first use** at genesis, at a team's genesis, and once a no-holder reset takes effect.
2. **Split views and withholding** go undetected until devices compare.
3. **Full rollback** works against a holder that pins again with S, against a file with no anchor that pins with S, and against a restore of the state file together with its anchor. Such a restore can also bring back history the person deleted.
4. **A confirmed member** can write a team secret with the server's help.
5. **A signer from whom the server withholds a member's `rotate`** seals the next team key to that member's old SK, which a stolen device of the member opens, until the member's app sees the `key` and raises its alarm.
6. **History paged back on a new device** can show an entry a removed holder backdated with the server's help, marked as written on a removed device.
7. **A malicious signer** can grant the team key to accounts of its choice.
8. **A re-root after the last signer is gone** trusts the owner the server lists, as at a team's genesis, until members confirm it.
9. **A person who confirms a comparison without reading it** approves whatever is on the other screen.
10. **Plaintext records and metadata** are readable by the operator.
11. **The organization running a self-hosted install** controls its endpoints and its IdP, which end-to-end encryption does not cover.
12. **P-256 and Ed25519 are not post-quantum.** Someone who archives `tp1` wraps today could open them on a future quantum computer, and with them every envelope and history entry written under those key versions, however strong AES-256 is. Moving to `tp2` issues new keys that reach anyone only through hybrid wraps, so it protects what is written after the move, not what was written before (0053, Suite).

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
