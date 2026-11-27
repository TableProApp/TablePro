# Sync threat model

This model covers TablePro Sync with end-to-end keys, on our SaaS and on a self-hosted install. The keys and their checks are in [ADR 0056](../decisions/0056-end-to-end-keys-per-account-and-device.md), cited below by section name.

The other ADRs:

- the protocol and the server's record rules: 0051;
- record ids: 0052;
- the sync engine and its state file: 0054;
- the service and its deploys: [0044](../decisions/0044-sync-through-one-service-run-by-us-or-on-premises.md).

iCloud sync and iCloud Keychain follow Apple's own model and are out of scope.

**Review status.**

- The design gets internal review only: gates G0 to G3, each a Codex review plus an independent security agent.
- No third party has reviewed it, and no text may say otherwise.
- Whether to commission an external audit is decided before end-to-end encryption leaves beta.

**The trade-off.** This is the model 1Password and Bitwarden ship. A server can substitute a public key the first time a client meets an account, and the fingerprint words or a later key-change alert catch it. Neither product prevents it, and 1Password's design document says so (Appendix C). Once a client has pinned an account, the server cannot change that account's keys without an alert.

## What is protected

| Asset | Protection |
|---|---|
| Secrets: database passwords, SSH passwords, key passphrases and TOTP secrets, AI provider keys, inside a `secret_envelope`. An SSH private key file stays on the device; its path syncs as a plaintext field | Confidential against the server, except what is wrapped to a key it substituted at first contact (The trade-off). Bound to their record, secret kind, key version and scope, with the destination they were sealed for inside |
| Query history | Confidential against the server, with the same first-contact exception |
| Account, personal, history and team keys | On an honest server, reach only the account's approved devices and confirmed members, through wraps the server cannot make. A server's split view can also bring a later team key to a removed device or member (Residual risks 2 and 3) |
| The account's identity | Derived from the recovery key, which never leaves the person. Pinned by teammates |
| Plaintext records: connections, groups, tags, SSH profiles, credential profiles, saved queries and folders, favorites, table folders, settings | Protected from the network. **Readable by the operator.** On an honest server, kept from other accounts and, under D8, readable only by the account's approved devices |
| Team plaintext records | Readable by the operator and by every member the server's roles allow |

## Assumptions

- **The app is genuine.** It is a signed release build, and the device's OS and key store work as documented.
- **Randomness.** The system RNG gives unpredictable bytes.
- **TLS** uses the OS trust store, with no pinning (0044). Secrets do not depend on it; availability and plaintext records do.
- **People compare.** A person compares the five words before approving a device, and compares fingerprint words when the app asks. A person who confirms without reading gives the check away.
- **Libraries.** aws-lc-rs, the rustls HPKE module and Go's standard library are correct. The vectors and the Go differential check this (0056, Vectors).

## Actors

| Actor | Protected | Not protected |
|---|---|---|
| Network attacker | Everything, through TLS | Traffic timing and sizes |
| Honest-but-curious operator, database staff, backups, dumps, the cloud provider | Secrets, history, keys | Plaintext records, metadata |
| Malicious operator with full control of the server | Secrets and history of every account and team whose keys the client pinned, unless a device or a recovery key is stolen too, or a current or removed member helps it (Residual risks 2, 3 and 5). The named attacks below | Substitution at first contact, withholding, older state shown to a device that never saw newer, split views, denial of service, plaintext records, metadata |
| A compromised IdP or a phished session | Personal data, plaintext included; team secrets; every key object | Team plaintext records its seat allows; a genesis on an account with no keys yet; with the step-up too, a reset, which the honest server holds 7 days in view of every device |
| A lost or stolen device | After removal with the recovery key and the review of the members it confirmed, on an honest server: every scope key and secret written after it | What the device already holds. Before the recovery key is typed, what a compromised server gives it |
| A stolen device working with the server | The identity key: IK is not on the device, so it cannot certify keys or start a rotation | Reading everything until removal. After it, a team key that a teammate the server kept on the account's old version wraps to the old account key (Residual risks 2). A reset it pushes with the server's help, which shows as an alert |
| A removed member | Team key versions after the rotation, on an honest server | What it already read, which "Credentials to rotate" covers. With the server's help, a next version it signs for members who missed the removal (Residual risks 3) |
| A malicious current member | Other people's personal data | Every secret of its teams. With the server's help, writing one |
| Self-hosted customer IT as operator, IdP admin, install admin and endpoint manager | Secrets against dumps, backups and database staff | Anything on endpoints it controls: it can install software and read memory there. As operator and IdP admin alone it is the malicious operator and the compromised IdP above, against genuine clients |

## A malicious server operator

**Who.**

- **On the SaaS:** anyone with write access to production, an attacker inside our infrastructure or staff acting outside policy.
- **Self-hosted:** the customer's own IT, which usually also runs the IdP, holds the install admin role and manages the endpoints.

**What it can do.** Read and write every row, run a modified binary, answer devices differently, drop, delay or replay records, create accounts and assign any role, revoke sessions and device rows, and lie about policies and versions.

**Named attacks.**

| Attack | What stops it | 0056 |
|---|---|---|
| Wrap a key it knows to a member or a device | A scope key's wrap is signed by the wrapper's account key (ASK), certified by an identity key the recipient pinned. An account or trust wrap is signed by the approving device's DSK, which the new device compared. The unwrapped key must match its version record's `kid`, or the account certificate's public keys | Signed objects and wraps |
| Forge a recovery: hand a recovering device keys of its own | IK is derived from the recovery key, and the blob opens only under a key derived from it. The certificate must verify under that IK and name the keys the blob holds | The recovery key |
| Show a recovering device an older certificate | Recovery always rotates, so it issues keys no removed device had. On an honest server its version must be the next one | Account flows, Recovery |
| Change a pinned account's keys | A certificate counts only under the pinned IK. A new IK counts only with the old IK's endorsement. Any other change alerts in every team and stops wraps to that account until a person re-confirms | Pins |
| Substitute a key at first contact | Not prevented. The fingerprint words or QR code catch it. Every wrap names its recipient's public key under the wrapper's signature, so a teammate's later wrap that shows another key raises an alert | Pins; Signed objects and wraps |
| Invent a member and wait for the team key | Nothing is wrapped automatically. An owner or admin confirms each member in the app, with the words shown | Teams |
| Invent a member or admin that rotates the team key to one the server knows | A version counts only when a holder of the previous version signs it, and a made-up account holds none | Teams |
| Restart a team with a key of its own, signed by an account it made up | A member's device that held the team holds a restart until the person compares the restarting owner's six fingerprint words and accepts, and a member that holds the current version refuses it (0064) | Teams |
| Substitute keys during device approval | The words cover both devices' key device ids and keys and the account's IK, and each side pins the other's keys only from them, never from a certificate. The new device commits to its view before the approving device sends its random value, so the server gets one guess at 2^-64.6 per session. The account keys and pins the new device receives are signed by that DSK, so a stolen device holding the account keys cannot stand in for the approver | Approving a device |
| Show a new device other teammates than its approver sees, or a teammate without the alert the approver holds | The approving device sends its pins, with their open alerts and replaced IKs, and its newest versions in a wrap signed by its DSK, which the words cover. First-use pins it leaves out for size are pinned on first use again | Approving a device; Pins |
| Have a rotation send new account keys to a device that a stolen account key certified | A rotation keeps only the devices the rotating device compared with itself. Every other device joins again by approval | Account flows, Rotation |
| Replay an older certificate, version or key | Clients keep the newest account key version and scope key versions, under 0054's anchor, and refuse an older one as current; older objects still verify history. At an anchored scope key version they take only the record whose digest the anchor holds. The honest server takes only the next version | Rollback |
| Slip in an envelope under an old key that a removed device still holds | In a pull, an envelope counts only under the newest version at its place in the revision order, and never below the copy a client holds. A forced refill is the gap left (Residual risks) | Rollback |
| Move an envelope to another record, secret kind, scope or version | The AAD binds them, and the subkey is per record | Envelopes and history |
| Rewrite a connection's host so a password goes elsewhere | The sealed destination differs from the record's, and a destination change waits for approval on each device | Envelopes and history |
| Downgrade the suite | Clients accept `tp1` only, and the suite is in every signed message, `info` and AAD | Suite and encoding |
| Replay an object from another account or install | The origin is in every derivation, signature and AAD but `kid` and the recovery checksum, and each one that belongs to an account or a team names it | Suite and encoding |
| Re-encode a signature or a field | Verifiers rebuild the signed bytes from the parsed fields, base64url must be canonical, and both Go and Rust refuse a non-canonical Ed25519 signature | Suite and encoding; Libraries |
| Use up a key's versions, or grow its ring past the record limit | Versions step by one and stop below 2^31. A ring holds one older key, so it never grows, and a member that is not an owner or admin rotates a team key only while a rotation is due | Keys; Signed objects and wraps; Teams |
| Make up a reset | The honest server holds it 7 days in view of every device and cancels it on a device's or the recovery key's word. A malicious server can apply one, and then the person's devices and every teammate see an identity that nothing endorsed | Account flows, Reset |
| Fake a revocation (`device_removed`), or hide a device's new certificate from a rotation that kept it | The device locks and erases nothing. Only Sign Out and another account's sign-in on its row erase its keys, and only an approval the person runs replaces them | Keys; Account flows, Rotation |
| Withhold a member's rotation so teammates wrap to its old key | The honest server refuses a wrap to a superseded key version. A malicious one can serve it. The member's app raises an alarm if that wrap reaches it, which does not stop the split | Teams |
| Use a phished session to write key objects | Key-object and envelope writes need a DPoP proof from an approved device, except what a device writes before approval: its request and its steps, a genesis on an account with none, a rotation or a cancel the recovery key signs, and a reset proposal after a step-up with its activation | What the server stores and checks |

**What it still gets.**

- Every plaintext record in full, and the metadata below.
- Substitution at first contact, until someone compares words.
- Withholding: a missing record looks the same as no change.
- Split views: two groups of devices on two consistent views until they compare.
- Denial of service at any time.
- `user` tombstones for any plaintext record, which carry no signature. A device that then moves back to iCloud deletes the iCloud copies after the person confirms the count (0054).

## A compromised IdP or session

**Who.** On the SaaS, a phished Google, GitHub or Apple sign-in or a stolen refresh token. Self-hosted, also the IdP admin, who can sign in as anyone.

**What holds.**

- **Personal data.** A new sign-in gets no personal record, plaintext or not, until another device approves it or the recovery key is typed. The server enforces this through DPoP proofs checked against the device certificates (0056, What the server stores and checks).
- **Secrets and keys.** It reads the personal scope's key objects, which hold public keys and ciphertext: wraps to keys it does not hold, and the recovery blob under a 256-bit key. It writes no envelope, and no key object but what a device writes before approval (0056, What the server stores and checks): its own request and its steps, a genesis on an account with none, and a reset proposal after a step-up, with its activation 7 days later. A rotation or a cancel before approval needs the recovery key.
- **Social engineering.** A request from the attacker shows on the person's devices as a new device. Approving it needs the five words on the attacker's screen.

**What does not hold.**

- Team plaintext records, as far as the account's seat and role allow.
- **Genesis** on an account with no keys yet is trust on first use. An attacker who gets there first owns that identity. The person's own genesis fails, and the account comes back through a reset.
- **A reset.** An attacker who also passes the step-up, a passkey the server holds or on the SaaS a code it emails, can start one. Before a person's first passkey, a self-hosted step-up is only as strong as the IdP: an attacker with the IdP sign-in binds the first passkey, then steps up with it, since the binding alone stamps none (0065). The honest server holds it 7 days, every device and the portal show it, the SaaS emails, and any certified device or the recovery key cancels it. If nobody cancels it in that time, its proposing device can activate it within the next 7 days, whether or not the person still has the recovery key. Once activated, the person's other devices are removed, and teammates see an alert. A kind 3 reset, which runs whatever device rows remain, also deletes the personal and history records.
- **A device row.** The machine id a device reports is self-reported and never a trust anchor. The attacker can register on the person's machine id and confuse or block that row's requests and resets. It cannot get the row approved or reach any key, and the same session already acts in the portal (0065).

## A lost or stolen device

**What the device holds:** the account keys, the personal, history and team keys, its own device keys, the local stores and the secrets in its device store. No identity key and no recovery key.

**What the thief can do** until the device is removed, if it can unlock it or read its store:

- read and write everything the person can;
- approve new devices, which show in the person's device list with the device that approved them;
- as an owner or admin, confirm members and rotate team keys;
- start a reset, which the honest server holds 7 days and which any of the person's devices or the recovery key cancels.

**After removal with the recovery key** (0056, Removing a device):

- the device's row and tokens are revoked and the row holds no key device, so the honest server refuses it;
- new account, personal and history keys reach only the devices the person kept, and every team key rotates;
- the new account keys reach only devices the removing device compared with itself and the person kept. Every other device, including any the thief approved, is no longer approved, and the person's own join again by approval;
- the sheet lists the members the account confirmed while the device held its keys. The person removes the ones they do not recognize, and the team rotations leave them out. Until their seats are gone, a teammate's app that rotates the key still counts them.

**Before the recovery key is typed,** the device is cut off from the honest server, but a compromised server can still give it new data written under the keys it holds.

**With the server's help, after removal,** the thief can show a device's first snapshot, or a device recovered with the recovery key, older envelopes it wrote under old keys. The server can also keep a teammate on the account's old version, so that teammate's next team key is wrapped to the old account key, which the device opens. The person's app raises an alarm if that wrap reaches it, which does not stop the split. A member the thief confirmed stays a holder for teammates the server keeps showing it to. It cannot forge the identity key, which is not on the device.

What the device already read stays read. "Credentials to rotate" lists the database credentials to change.

## A malicious team member

- **A confirmed member** reads every team secret, by design. Team envelopes carry no writer signature, so a member with the server's help can replace a secret's value. A server alone cannot redirect a host past the sealed destination, but a member with its help can seal a new value and destination together.
- **An owner or admin** confirms members and so decides who receives the team key. Every confirmation names the confirming member in a signed wrap that every member can read, and a device removal lists those its account made while the device held its keys.
- **A member who is not confirmed yet** reads team plaintext records and no team secret.
- **A removed member** keeps what it read. On an honest server the next version reaches only the members left, and while a rotation is due the honest server holds new team secrets back.
- **A removed member with the server's help** still holds the old version, so it can sign a new version and show it to members whose view missed the removal. The honest server refuses it, and members' apps show who rotated.

## Rollback and split views

ePrint 2026/058 calls rollback an open problem for clients that keep no state. Here each device keeps, under 0054's MAC and anchor, the newest account key version and identity key per pinned account, the newest version per scope key, and its pins and open alerts.

**What holds.**

- A device refuses an older certificate, version record or identity key as current, and an envelope below the copy it holds; older objects still verify history. At an anchored scope key version it takes only the record the anchor names.
- In a pull, which serves changes in revision order, a new or changed envelope counts only under the scope's newest version at its place in that order, the rule the honest server writes by. An offline device catches up on writes made before a rotation and refuses ones slipped in after it.
- A restored state file cannot forget a newer version or an alert while its anchor survives.
- A device approved by another starts from that device's pins, open alerts and versions for what it does not hold yet. A team key version it holds moves only through its own checks, never through an approver's view, and its current personal and history keys are the versions signed under the account's current key version, so a higher one signed under an older account key never comes back through an approval.

**What does not hold.**

- **Rollback within a version.** A server can serve an older envelope under the current version, or withhold a deletion.
- **A snapshot,** a device's first or a refill a server can force, accepts every version up to the newest for a record the device does not hold, since old envelopes stay under old keys. A removed device with the server's help can plant such a record under a version it held. History entries are taken under any version for the same reason.
- **A device recovered with the recovery key** pins teammates on first use and can be shown an older view of its teams.
- **A restore of the state file together with its anchor,** such as a whole-machine image, cannot be told apart locally from the moment it came from (0054). Deleted history ids live in the file only.
- **An anchor restored without its file,** such as a Linux keyring or Windows Credential Manager restore, is older than the file. The file opens stale and rebuilds on the older checkpoint (0066).
- **Split views** last until devices or people compare.
- **This is not key transparency.** draft-ietf-keytrans-protocol is still a draft.

## Metadata the server sees

**Who and when.**

- Accounts, team membership, roles, and device rows with their names, platforms and app versions.
- The time of every push and pull, and the client IP address. Self-hosted installs keep it in their own logs.
- Device approval requests with their platform and timing, pending resets and cancels. A signed-in session that is not approved sees the same key metadata, since recovery reads it before approval.
- DPoP key thumbprints, which tie each request to a device.
- `updated_by` and `updated_device` on every record (0051).

**Keys.**

- Each account's public keys and when its key version changed: when it removed devices, recovered, replaced its recovery key or reset.
- Which devices each certificate version keeps.
- Each wrap's wrapper and recipient: who confirmed whom and when, and who rotated each team key.

**Shape of the data.**

- Which records carry which secret kinds, such as which connections have a password.
- Key versions per envelope and history entry, and padded sizes.
- History entry counts, sizes and push timing. Record ids are random UUIDv4 and pushes are batched, so ids leak no capture time.

**Plaintext records in full:** connection hosts, ports, users and database names, which can be SQLite file paths; SSH profiles; credential profiles and typed references; settings; saved queries with their SQL; favorites, table folders, groups and tags.

**Teammates** see each member's certificates, so when a member's key version or identity changed, and every wrap in the team.

## Residual risks

On 2026-11-25 the maintainer accepted risks 2, 3, 5, 6 and 9, which the vault model leaves open as 1Password and Bitwarden do. No step waits for every member to acknowledge a removal; the honest server's `rotation_due` holds team envelopes only until the next team version. The same day he accepted, under risk 2, that a member a stolen admin device confirmed can still be shown to other teammates. 0065 accepts risks 14 and 15, which give no key and only deny service.

1. **Trust on first use** at a genesis, for a team's creator, for each member an admin confirms without comparing, for teammates on a device recovered with the recovery key, and for a re-confirmation after a reset.
2. **Withholding and split views** go undetected until devices or people compare. A server that withholds a member's rotation from a teammate gets the next team key wrapped to the member's old key, which a stolen device of that member opens. The member's app raises an alarm if that wrap reaches it, which does not stop the split. The same server can keep showing teammates a member that a stolen device confirmed and the person removed. Its own-account form: before any approval, a device of the person that the server keeps on the old account key version writes personal secrets and history under keys the removed device holds.
3. **A removed member with the server's help** can sign a new team key version, since it holds the previous one, and show it to members whose view missed the removal.
4. **A stolen device before the recovery key is typed** can be given new data by a compromised server.
5. **A confirmed member with the server's help** can replace a team secret's value.
6. **Rollback within a version,** and records a removed device with the server's help plants under a version it held: in a snapshot, which the server can force, and in history.
7. **Full rollback** for a state file restored with its anchor, and back to the anchor's checkpoint for an anchor restored without its file (0066). A restored state file, with its anchor or without it, can also bring back history the person deleted, since deleted history ids live in the file and not in the anchor (0054). These are limits of local state, not among the risks accepted above.
8. **A reset** by someone who passes the person's sign-in and step-up can be activated by its proposing device if nobody cancels it for 7 days. On a self-hosted install, before the person's first passkey, the IdP sign-in alone is enough to bind one. Teammates see an alert.
9. **An exposed recovery key after a replace.** With the server's help, its holder can keep a device or a teammate that never saw the replace on the old identity, a split view.
10. **A person who confirms without reading** approves whatever is on the other screen.
11. **Plaintext records and metadata** are readable by the operator.
12. **The organization running a self-hosted install** controls its endpoints, which end-to-end encryption does not cover. As operator and IdP admin alone it is this model's malicious operator and compromised IdP.
13. **X25519 is not post-quantum.** Someone who archives wraps today could open them on a future quantum computer, and with them every envelope and history entry under those versions. A later hybrid suite protects what is written after the move, not before.
14. **A device row taken by machine id.** A phished IdP session can register on a person's self-reported machine id and confuse or block that row's requests and resets.
15. **A team ended on a made-up record.** After a restore, a server can serve a different record at a version a device waits for, signed by an account it made up, and the team ends on that device (`keys.conflict`). Refusing the push-back already ends a team the same way.

## Out of scope

- Malware on an unlocked device, a modified app build, and side channels on the device.
- Coercion of a person.
- Denial of service by the operator.
- iCloud and iCloud Keychain.

## Sources

- ADR 0056 and its Sources.
- 1Password Security Design, Appendix C, verifying public keys: https://agilebits.github.io/security-design/mitm.html
- Scarlata, Torrisi, Backendal, Paterson, "Zero Knowledge (About) Encryption", ePrint 2026/058: https://eprint.iacr.org/2026/058
- RFC 9180 §9: https://www.rfc-editor.org/rfc/rfc9180.html#section-9
- RFC 9449 §11: https://www.rfc-editor.org/rfc/rfc9449.html#section-11
- draft-ietf-keytrans-protocol: https://datatracker.ietf.org/doc/draft-ietf-keytrans-protocol/
