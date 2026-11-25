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
| Secrets: database passwords, SSH passphrases and keys, AI provider keys, inside a `secret_envelope` | Confidential against the server. Bound to their record, secret kind, key version and scope, with the destination they were sealed for inside |
| Query history | Confidential against the server |
| Account, personal, history and team keys | Reach only the account's approved devices and confirmed members, through wraps the server cannot make |
| The account's identity | Derived from the recovery key, which never leaves the person. Pinned by teammates |
| Plaintext records: connections, groups, tags, SSH profiles, credential profiles, saved queries and folders, favorites, table folders, settings | Protected from the network and from other accounts. **Readable by the operator.** Under D8, readable only by the account's approved devices |
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
| Malicious operator with full control of the server | Secrets and history of every account and team whose keys the client pinned, unless a device or a recovery key is stolen too. The named attacks below | Substitution at first contact, withholding, older state shown to a device that never saw newer, split views, denial of service, plaintext records, metadata |
| A compromised IdP or a phished session | Personal data, plaintext included; team secrets; every key object | Team plaintext records its seat allows; a genesis on an account with no keys yet; a reset, which waits 7 days in view of every device |
| A lost or stolen device | After removal with the recovery key: every scope key and secret written after it | What the device already holds. Before the recovery key is typed, what a compromised server gives it |
| A stolen device working with the server | The identity: IK is not on the device, so it cannot certify keys or start a rotation | Reading everything until removal |
| A removed member | Team key versions after the rotation | What it already read, which "Credentials to rotate" covers |
| A malicious current member | Other people's personal data | Every secret of its teams. With the server's help, writing one |
| Self-hosted customer IT as operator, IdP admin, install admin and endpoint manager | Secrets against dumps, backups and database staff | Anything on endpoints it controls: it can install software, read memory and sign in as anyone through its IdP. End-to-end encryption does not protect against the organization itself |

## A malicious server operator

**Who.**

- **On the SaaS:** anyone with write access to production, an attacker inside our infrastructure or staff acting outside policy.
- **Self-hosted:** the customer's own IT, which usually also runs the IdP, holds the install admin role and manages the endpoints.

**What it can do.** Read and write every row, run a modified binary, answer devices differently, drop, delay or replay records, create accounts and assign any role, revoke sessions and device rows, and lie about policies and versions.

**Named attacks.**

| Attack | What stops it | 0056 |
|---|---|---|
| Wrap a key it knows to a member or a device | Every wrap is signed by the wrapper's account key, certified by an identity key the recipient pinned. The unwrapped key must match its version record's `kid`, or the account certificate's public keys | Signed objects and wraps |
| Forge a recovery: hand a recovering device keys of its own | IK is derived from the recovery key, and the blob opens only under a key derived from it. The certificate must verify under that IK and name the keys the blob holds | The recovery key |
| Show a recovering device an older certificate | Recovery always rotates, so it issues keys no removed device had. On an honest server its version must be the next one | Account flows, Recovery |
| Change a pinned account's keys | A certificate counts only under the pinned IK. A new IK counts only with the old IK's endorsement. Any other change alerts in every team and stops wraps to that account until a person re-confirms | Pins |
| Substitute a key at first contact | Not prevented. The fingerprint words or QR code catch it. Every wrap names its recipient's public key under the wrapper's signature, so a teammate's later wrap that shows another key raises an alert | Pins; Signed objects and wraps |
| Invent a member and wait for the team key | Nothing is wrapped automatically. An owner or admin confirms each member in the app, with the words shown | Teams |
| Invent a member or admin that rotates the team key to one the server knows | A version counts only when a holder of the previous version signs it, and a made-up account holds none | Teams |
| Substitute keys during device approval | The new device commits to its view before the approving device sends its random value, so the server gets one guess at 2^-64.6 per session | Approving a device |
| Show a new device other teammates than the person's other devices see | The approving device sends its pins and newest versions in a signed wrap | Approving a device; Pins |
| Replay an older certificate, version or key | Clients keep the newest account key version and scope key versions, under 0054's anchor, and refuse anything older. The honest server takes only the next version | Rollback |
| Slip in an envelope or history entry under an old key that a removed device still holds | A client refuses a new or changed one below the newest version it has seen | Rollback |
| Move an envelope to another record, secret kind, scope or version | The AAD binds them, and the subkey is per record | Envelopes and history |
| Rewrite a connection's host so a password goes elsewhere | The sealed destination differs from the record's, and a destination change waits for approval on each device | Envelopes and history |
| Downgrade the suite | Clients accept `tp1` only, and the suite is in every signed message, `info` and AAD | Suite and encoding |
| Replay an object from another account or install | Origin and account are in every derivation, signature and AAD | Suite and encoding |
| Re-encode a signature or a field | Verifiers rebuild the signed bytes from the parsed fields, base64url must be canonical, and both Go and Rust refuse a non-canonical Ed25519 signature | Suite and encoding; Libraries |
| Use up a key's versions | Versions step by one and stop below 2^31 | Keys |
| Make up a reset | The honest server holds it 7 days in view of every device and cancels it on a device's or the recovery key's word. A malicious server can apply one, and then the person's devices and every teammate see an identity that nothing endorsed | Account flows, Reset |
| Fake a revocation (`device_removed`) | The device locks and erases nothing. Only Sign Out, a verified rotation that leaves it out or another account's sign-in erase keys | Keys |
| Withhold a member's rotation so teammates wrap to its old key | The honest server refuses a wrap to a superseded key version. A malicious one can serve it; the member's app sees a wrap to its own superseded version and raises an alarm | Teams |
| Use a phished session to write key objects | Key-object and envelope writes need a DPoP proof from an approved device | What the server stores and checks |

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
- **Secrets and keys.** It reads only the newest account certificate and the recovery blob, which is under a 256-bit key. It writes no key object or envelope.
- **Social engineering.** A request from the attacker shows on the person's devices as a new device. Approving it needs the five words on the attacker's screen.

**What does not hold.**

- Team plaintext records, as far as the account's seat and role allow.
- **Genesis** on an account with no keys yet is trust on first use. An attacker who gets there first owns that identity. The person's own genesis fails, and the account comes back through a reset.
- **A reset.** After a fresh IdP sign-in the attacker can start one. It waits 7 days, every device and the portal show it, the SaaS emails, and any certified device or the recovery key cancels it. A person away for 7 days with no recovery key loses the identity, and teammates see an alert. With no device left, the reset also deletes the personal and history records.

## A lost or stolen device

**What the device holds:** the account keys, the personal, history and team keys, its own device keys, the local stores and the secrets in its device store. No identity key and no recovery key.

**What the thief can do** until the device is removed, if it can unlock it or read its store:

- read and write everything the person can;
- approve new devices, which show in the person's device list with the device that approved them;
- as an owner or admin, confirm members and rotate team keys;
- start a reset, which waits 7 days and which any of the person's devices or the recovery key cancels.

**After removal with the recovery key** (0056, Removing a device):

- the device's row, tokens and certificate are revoked, so the honest server refuses it;
- new account, personal and history keys reach only the devices the person kept, and every team key rotates;
- devices the person did not keep, including those the thief approved, lose their certificates.

**Before the recovery key is typed,** the device is cut off from the honest server, but a compromised server can still give it new data written under the keys it holds.

**With the server's help, after removal,** the thief can show a device's first snapshot, or a device recovered with the recovery key, older envelopes it wrote under old keys. It cannot take the identity: IK is not on the device.

What the device already read stays read. "Credentials to rotate" lists the database credentials to change.

## A malicious team member

- **A confirmed member** reads every team secret, by design. Team envelopes carry no writer signature, so a member with the server's help can replace a secret's value. The sealed destination still catches a redirected host.
- **An owner or admin** confirms members and so decides who receives the team key. Every confirmation names the confirming member in a signed wrap that every member can read.
- **A member who is not confirmed yet** reads team plaintext records and no team secret.
- **A removed member** keeps what it read. The next version reaches only the members left, and while a rotation is due the honest server holds new team secrets back.
- **A removed member with the server's help** still holds the old version, so it can sign a new version and show it to members the server picks. The honest server refuses it, and members' apps show who rotated.

## Rollback and split views

ePrint 2026/058 calls rollback an open problem for clients that keep no state. Here each device keeps, under 0054's MAC and anchor, the newest account key version and identity key per pinned account, the newest version per scope key, and its pins and open alerts.

**What holds.**

- A device refuses an older certificate, version record or identity key, and a new or changed envelope or history entry below the newest version it has seen.
- A restored state file cannot forget a newer version or an alert while its anchor survives.
- A device approved by another starts from that device's pins and versions.

**What does not hold.**

- **Rollback within a version.** A server can serve an older envelope under the current version, or withhold a deletion.
- **A first snapshot** accepts every version up to the newest, since old envelopes stay under old keys. A removed device with the server's help can plant content there under a version it held.
- **A device recovered with the recovery key** pins teammates on first use and can be shown an older view of its teams.
- **A restore of the state file together with its anchor,** such as a whole-machine image, cannot be told apart locally from the moment it came from (0054). Deleted history ids live in the file only.
- **Split views** last until devices or people compare.
- **This is not key transparency.** draft-ietf-keytrans-protocol is still a draft.

## Metadata the server sees

**Who and when.**

- Accounts, team membership, roles, and device rows with their names, platforms and app versions.
- The time of every push and pull, and the client IP address. Self-hosted installs keep it in their own logs.
- Device approval requests with their platform and timing, pending resets and cancels.
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

1. **Trust on first use** at a genesis, for a team's creator, for each member an admin confirms without comparing, for teammates on a device recovered with the recovery key, and for a re-confirmation after a reset.
2. **Withholding and split views** go undetected until devices or people compare. A server that withholds a member's rotation from a teammate gets the next team key wrapped to the member's old key, which a stolen device of that member opens, until the member's app sees the wrap and raises its alarm.
3. **A removed member with the server's help** can sign a new team key version, since it holds the previous one, and show it to members the server picks.
4. **A stolen device before the recovery key is typed** can be given new data by a compromised server.
5. **A confirmed member with the server's help** can replace a team secret's value.
6. **Rollback within a version,** and old-version content planted in a first snapshot by a removed device with the server's help.
7. **Full rollback** for a state file restored with its anchor, which can also bring back history the person deleted.
8. **A reset** by someone with the person's IdP sign-in succeeds if nobody cancels it for 7 days. Teammates see an alert.
9. **An exposed recovery key after a replace.** With the server's help, its holder can keep a device or a teammate that never saw the replace on the old identity, a split view.
10. **A person who confirms without reading** approves whatever is on the other screen.
11. **Plaintext records and metadata** are readable by the operator.
12. **The organization running a self-hosted install** controls its endpoints and its IdP, which end-to-end encryption does not cover.
13. **X25519 is not post-quantum.** Someone who archives wraps today could open them on a future quantum computer, and with them every envelope and history entry under those versions. A later hybrid suite protects what is written after the move, not before.

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
