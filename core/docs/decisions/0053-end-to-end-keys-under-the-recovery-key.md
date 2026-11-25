# 0053: End-to-end keys: the identity under the recovery key, signed logs, envelopes, removal and recovery

- **Status**: Accepted; amends 0044 (Secrets, and its Consequences line that teammates confirm a person again after a device removal or recovery)
- **Date**: 2026-11-25

## Context

[0044](0044-sync-through-one-service-run-by-us-or-on-premises.md) syncs secrets and query history end to end encrypted through TablePro Sync, run by us or on a customer's servers. Its Secrets section names the algorithms and a trust chain but leaves holes that an internal review found:

- **Recovery is not authenticated.** The recovery key's HPKE pair comes from `DeriveKeyPair`, and HPKE base mode does not authenticate a sender (RFC 9180 §9.1), so a server can seal a key of its own to the recovery public key and a recovering device pins it.
- **Removal re-keys to the removed party.** An admin's device removal seals the new team key to a sharing key the removed device still holds, and nothing stops a writer from sealing under an old team key after a member leaves.
- **The envelope binds mutable fields.** Its associated data covers the destination, which the field merge combines, so ordinary edits on two devices make a secret undecryptable.
- **Ending a session is not signing out.** A SAML session ends after 10 hours, and a rule that drops keys with the session asks for approval every working day.
- **Signed lists have counters but no chain,** so a server can show different devices different views without anyone noticing.
- **One owner and a support re-root** make TablePro staff an authority over team trust.
- **Other gaps:** no byte encoding, no key separation, no suite allowlist, no home for key objects, no metadata list, no threat model for a malicious operator, and no reason given for leaving out MLS.

On 2026-11-25 the maintainer decided:

- **D6.** A recovery key is required before any personal sync, and it anchors the identity through a seed-derived, AEAD-wrapped identity key.
- **D7.** A lost device is removed with the recovery key. The identity key lives only under the recovery key, so teammates see no change. Neither a sign-out nor the end of a session rotates any key.
- **D8.** A device gets nothing personal until it is approved, and the server enforces it through the signed device list.
- **D15.** Any owner or admin signs team trust. Removing a signer needs k signers, and a signer may always remove itself. A team re-root happens only when no signer is left, is visible to every member, and support can never perform it. k is a technical choice, set below.
- **Linux without a keyring** gets team records only.
- **Review.** No external audit now. Whether to commission one is decided before end-to-end encryption leaves beta.
- **Past grace,** key-object writes and `leave` stay allowed.
- **Signers, refined later that day.** Adding a signer needs the same k approvals as removing another, so a lone signer still adds the first co-signer. To hold that, k = min(2, n), as the orchestrator corrected the earlier min(2, n-1) the same day. A team's only signer that removed itself leaves at once. One that lost its keys or reset leaves through the 7-day time-locked removal an owner starts, as the maintainer confirmed, and D15's visible re-root comes only after that. Owners' apps warn while a team has fewer than three signers.
- **Time-locked signer removal.** The signers left, even fewer than k, may start removing a signer. It takes effect after 7 days, every member sees it, and the targeted signer cancels it by signing from any of its devices.
- **Sign Out** never removes the devices it approved. Removing a device with S catches a planted one.
- **Consequences accepted the same day:** team secrets need the recovery key; an account with no holder and no recovery key left resets after the server deletes its personal and history records; changing the API origin loses the history written under the old one.

The threat model is [`core/docs/security/sync-threat-model.md`](../security/sync-threat-model.md). The formal model is in `core/docs/security/models/`.

## Decision

Secrets and history are encrypted with AES-256-GCM under per-record HKDF subkeys of symmetric account and team keys. Those keys reach key holders and members only through HPKE wraps, and a recipient checks each unwrapped key against a hash-chained, signed log.

- **The anchor.** The account's logs are anchored in an identity key that lives only inside a blob sealed under the person's recovery key.
- **Holder keys.** Every other signature comes from one key holder's own signing key, and the device log certifies each one: approving a device, a team statement, an envelope, a history entry. So removing a device removes the devices it approved and the grants it signed, while the removals it signed stay.
- **Joining.** Devices and members join through a short authenticated string behind a hash commitment.
- **The server's part.** The server refuses personal data to any key outside the signed device set.

This replaces 0044's Secrets section except its device stores, typed references and iCloud Keychain rules, and its end-to-end Tests line.

Every construction is a standard one from an audited library. `tablepro-keys` composes calls into aws-lc-rs and rustls and holds no primitive of its own.

### Suite, encoding and labels

**Suite `tp1`**, the only one a client accepts today:

| Use | Construction | Source |
|---|---|---|
| Key wraps only | HPKE base mode, single shot, KEM 0x0010 DHKEM(P-256, HKDF-SHA256), KDF 0x0001 HKDF-SHA256, AEAD 0x0002 AES-256-GCM | RFC 9180 §5.1.1, §6.1, §7 |
| Data | AES-256-GCM, 96-bit random nonce, 128-bit tag | NIST SP 800-38D |
| Derivation | HKDF-SHA256 | RFC 5869 |
| Hash | SHA-256 | FIPS 180-4 |
| Signatures | Ed25519, pure | RFC 8032 §5.1 |
| Local MAC | HMAC-SHA256 | RFC 2104 |

- **Allowlist.** Every wrap, envelope, history entry, ring and blob names its suite. A client refuses a suite it does not list, since RFC 9180 §9.7.2 leaves downgrade prevention to the application. The suite is also inside each HPKE `info` and each AAD, so a ciphertext cannot be relabeled.
- **Post-quantum path.** A later suite `tp2` replaces the KEM with the hybrid MLKEM768-P256 once draft-ietf-hpke-pq is an RFC and a vetted Rust implementation runs on AWS-LC.
  - The move issues new RK, SK and holder HPKE keys, then new AK and TK versions that reach anyone only through `tp2` wraps. New writes go under those versions.
  - Wrapping the old versions again would protect nothing. A `tp1` wrap someone archived today still opens to the old key on a future quantum computer, since HPKE gives no forward secrecy against the recipient's key (RFC 9180 §9.7.4). Everything written under a `tp1`-wrapped version stays exposed to that attacker, history included, and the threat model says so.
  - A client that has seen a signed `tp2` key for a recipient refuses `tp1` wraps to it.

**Encoding.**

- `LP(x)` is a u16 big-endian length followed by the bytes of `x`. An input longer than 65,535 bytes is refused. `u32(n)` and `u64(n)` are big-endian.
- **Ids.**
  - Account, team, holder, device row, request and session ids are UUIDs, encoded as their 16 bytes (RFC 9562 §4).
  - A record id is the UTF-8 of its canonical wire text (0052). In an envelope it is the parent record's id.
  - The origin is the API origin as 0047 compares it, in its ASCII serialization (RFC 6454 §6.2).
  - A writer is `writer = LP(account) || LP(holder)`, both as 16 bytes. In JSON it is `{"acct": <UUID text>, "holder": <UUID text>}`.
- **Scope.** `scope` in a crypto input is `LP(type) || LP(owner)`: `personal` or `history` with the account id, or `team` with the team id. It names ids that signed statements carry, never the server's row id for the scope.
- **Keys.** An Ed25519 public key is its 32 bytes and its private key is the 32-byte seed (RFC 8032 §5.1.5). A P-256 public key is the 65-byte uncompressed point and its private key the 32-byte scalar (RFC 9180 §7.1.1, §7.1.2).
- **Text.**
  - JSON and JWS use base64url without padding (RFC 4648 §5), in its canonical form: a decoder refuses non-zero pad bits, as RFC 4648 §3.5 allows, so one value has one encoding.
  - A JSON integer matches `0|[1-9][0-9]*` and is below 2^53, with no sign, fraction or exponent. Go and Rust then read the same numbers.
  - A head is `head = u64(seq) || LP(hash)`.
- **No JSON in crypto inputs.** Every AAD, HKDF `info`, HPKE `info` and hash input is a concatenation of `LP` fields and fixed-width integers that starts with `LP(label)`. JSON is never one of them. The one exception is a signed statement, whose JWS signing input is signed and hashed exactly as received.

**Labels.** Each use has its own label, so no two uses share an input.

| Label | Use |
|---|---|
| `tablepro/v1/key-id` | Key commitment |
| `tablepro/v1/statement` | A signed statement's hash |
| `tablepro/v1/recovery-checksum` | Checksum of the recovery key's text |
| `tablepro/v1/recovery-wrap` | The recovery blob's key |
| `tablepro/v1/recovery` | The recovery blob's AAD |
| `tablepro/v1/recovery-blob` | The recovery blob's hash |
| `tablepro/v1/wrap` | HPKE `info` of every wrap |
| `tablepro/v1/ring-key`, `tablepro/v1/ring` | A key ring's subkey and AAD |
| `tablepro/v1/envelope-key`, `tablepro/v1/envelope` | An envelope's subkey and AAD |
| `tablepro/v1/history-key`, `tablepro/v1/history` | A history entry's subkey and AAD |
| `tablepro/v1/writer` | The writer signature on an envelope or history entry |
| `tablepro/v1/sas-commit` | A comparison's commitment |
| `tablepro/v1/device-approval` | Device approval words |
| `tablepro/v1/member`, `tablepro/v1/member-qr` | Member confirmation words and QR code |
| `tablepro/v1/state` | The state file's MAC (0054) |
| `tablepro/v1/receipt` | The server's time receipt on a key statement |
| `tablepro/v1/receipt-key` | An old receipt key's signature on its successor |

**Key commitment.** For any symmetric key K, `kid(K) = HKDF-SHA256(salt = none, IKM = K, info = LP("tablepro/v1/key-id"), L = 32)`.

- Every signed statement that introduces a symmetric key names its `kid`. A recipient recomputes it after unwrapping and refuses a mismatch.
- AES-GCM does not commit to its key (Albertini et al., USENIX Security 2022; Len, Grubbs and Ristenpart, USENIX Security 2021), so without this a server could hand out a wrap that opens to a key of its choice.
- The `kid` is 32 bytes, not 16. A signer who generates a key could otherwise search for two keys with one `kid` at about 2^64 work.
- Asymmetric keys are committed by their public keys, which statements carry in full.

**Padding.** Every plaintext under AES-256-GCM, except the fixed-size recovery blob, is padded with ISO/IEC 7816-4 padding: 0x80, then zero bytes. That is method 2 of ISO/IEC 9797-1, the bit padding of NIST SP 800-38A Appendix A.

- The padded length is the smallest of 64, 128, 256, 512, 1,024, 2,048 and 4,096 that holds the plaintext plus one byte. Past 4,096 bytes it is the next multiple of 4,096.
- A reader removes the padding only after the AEAD opens, so no padding check runs on unauthenticated data. RFC 9180 §9.7.6 asks applications to pad.

**Signed statements.**

- **Format.** They are JWS compact (RFC 7515 §7.1). The protected header is exactly `{"alg":<alg>,"typ":<type>}`.
  - `alg` is `Ed25519` (RFC 9864 §2.2) for IK and for software holder keys. A hardware holder key would later use `ES256` (RFC 7518 §3.4) with low-S signatures only.
  - A verifier requires the `alg` its key is bound to (RFC 8725 §3.1) and the expected `typ` (RFC 8725 §3.11).
  - It refuses any other header member, and duplicate member names in the header or the payload. Go's and Rust's JSON parsers treat duplicates differently, so both refuse them, and the server and the apps never read one statement two ways.
- Licenses keep `EdDSA`. RFC 9864 deprecates it for new uses.
- **Hash.** A signature covers the exact signing input received. Nothing is signed after being serialized again. A statement's hash is `SHA-256(LP("tablepro/v1/statement") || signing input)`, so two encodings of one signature never make two hashes.
- **Payload.**
  - Every payload carries `v: 1`, `origin`, `acct` or `team`, and `op` or the object's kind.
  - A client refuses a `v` or an `op` it does not know, and refuses an unknown member within a known one. A statement that a client cannot read stops that log for the client, which then asks for an update.
- **Types** are:
  - `tablepro-identity+jws`, `tablepro-device+jws` and `tablepro-team+jws` for the logs;
  - `tablepro-request+jws` for a device approval request;
  - `tablepro-endorse+jws` for an endorsement: a second signature over another statement's hash.

### Keys

| Key | Type | Private half lives | Certified by | Rotates when |
|---|---|---|---|---|
| Recovery seed S | 256-bit random | On paper or in a password manager only | n/a | Replace Recovery Key, reset |
| Identity key IK | Ed25519 | Only inside the recovery blob. In memory during genesis, removal, recovery or replacement, then zeroized | Itself, through the blob; pinned by own devices at approval and by signers at confirmation | Replace Recovery Key, reset |
| Recovery wrap key RK, `rk_v` | HPKE P-256, random | Only inside the recovery blob | IK, identity log | Replace Recovery Key, reset |
| Sharing key SK, `sk_v` | HPKE P-256 | Wrapped to each holder and to RK | IK, identity log | Device removal, recovery, Replace Recovery Key, reset |
| Account key AK, `ak_v` | 256-bit symmetric, versioned ring | Wrapped to each holder and to RK. Older versions sit in the ring under the newest | IK names each version's `kid` | Device removal, recovery, Replace Recovery Key, reset |
| Holder keys | HPKE P-256, plus a signing key | The device store only, never synced | The device log | Never. A new holder is a new key set |
| Team key TK, `tk_v` | 256-bit symmetric, versioned ring per team | Wrapped to each confirmed member's current SK | A signer's holder key, team log | Member removal, SK revocation, a member's rotation, a voided statement |

- **No account-wide signing key.** Every signature other than IK's comes from one holder. A removal then takes away exactly what that holder vouched for: the holders it approved, the grants it signed in teams, and the standing of the envelopes and history it wrote. Removals and revocations it signed stay in force.
- **Key holders.** A key holder is one key store under one server device row, and belongs to (origin, account, device row). The device cap counts rows.
  - A Linux host build and its Flatpak, or two Windows data folders, are separate holders under one row.
  - A cloned image copies the device store and its holder. Its device row differs, so the server refuses that holder there and the clone enrolls one of its own. A clone that keeps the machine id shares the holder, which nothing can tell apart.
- **Device stores.**
  - Keychain items with `ThisDeviceOnly` that do not sync.
  - Credential Manager with `CRED_PERSIST_LOCAL_MACHINE`.
  - A Secret Service item.
  - A Linux device without a keyring cannot hold a key holder. It syncs team plaintext records and nothing personal, and it reads no team secret.
- **Host trait.** The holder's signing key sits behind a host trait and is published as a JWK (RFC 7517) in the device log: `{"kty":"OKP","crv":"Ed25519","x":...}` (RFC 8037). Its thumbprint is the RFC 7638 thumbprint over the members RFC 8037 §2 names. A hardware P-256 key in the Secure Enclave or a TPM can later sign with ES256 under an EC JWK, with no other change to the log format.
- **Where key objects live.** An account's key objects sit in its personal scope on the service even when the device's personal provider is iCloud or Off. Team secrets need an identity, and the identity lives there.
- **Versions** count from 1 and only grow, across resets too. A new version is one more than the highest of that key seen on any branch, a dropped one included, so a fork's dropped versions are burned and gaps are allowed.
- **Hygiene.** Secret bytes are held in `secrecy` and `zeroize` types, never logged, and zeroized once used.

### The recovery key and the recovery blob

**The recovery key** is S, 32 bytes from the system RNG.

- **Text.**
  - `B = S || SHA-256(LP("tablepro/v1/recovery-checksum") || LP(S))[0..3]`, 35 bytes.
  - B is written as 56 Crockford Base32 symbols (alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`), with RFC 4648 §6's bit order: 5-bit groups, most significant first. The symbols are shown in 14 groups of 4 joined by `-`.
- **Reading it back.**
  - Hyphens and spaces are dropped, letters are upper-cased, `O` reads as `0` and `I` and `L` read as `1`, as Crockford's decoding rules say. `U` or any other character is refused.
  - Exactly 56 symbols are required, and the 24-bit checksum must match. A random typo passes with a probability of 2^-24.
  - The checksum's label also carries the format version.

**The blob key.** `K_rw = HKDF-SHA256(salt = none, IKM = S, info = LP("tablepro/v1/recovery-wrap") || LP(origin) || LP(account), L = 32)`. The context goes in `info`, as RFC 5869 §3.2 advises.

**The blob**, a `key.recovery` record per `rk_v`:

- Plaintext: the IK seed, then the RK scalar, 64 bytes.
- `ct = AES-256-GCM(K_rw, nonce, plaintext, AAD)`, with `AAD = LP("tablepro/v1/recovery") || LP("tp1") || LP(origin) || LP(account) || u32(rk_v)` and a random 12-byte nonce.
- Fields: `suite`, `rk_v`, `nonce`, `ct`.
- Its hash is `SHA-256(LP("tablepro/v1/recovery-blob") || u32(rk_v) || LP(nonce) || LP(ct))`. The identity statement that introduces `rk_v` names it as `blob`.
- Every holder keeps a copy of the newest blob's ciphertext in its security state, which holds no secret. It publishes the blob again whenever the server lacks it, after an interrupted push or a restore.

**Why it is an anchor.**

- Only someone holding S can produce a blob that opens, since AES-GCM is an authenticated cipher and K_rw comes from S. So the IK inside an opened blob is the person's.
- A recovering device trusts no other key until it has checked it against a statement that IK signs.
- AK and SK are HPKE-wrapped to RK's public half, which any device can seal to without the seed. A server that seals a key of its own to RK gains nothing: the key's `kid` or public key does not match the IK-signed log. That closes the gap in 0044's recovery.
- This is the wrapped-private-key pattern of 1Password's recovery and Matrix's secret storage, and needs no `DeriveKeyPair`.

**Opening.** A client opens only the blob of the RK in force, the one the newest `genesis`, `replace` or activated `reset` names, and only one whose hash matches. It then checks three things:

- the IK in it equals the IK in force (Identity log);
- its RK equals the RK in force;
- the whole identity log verifies under it.

A replaced recovery key opens nothing in force: Replace Recovery Key changes IK too.

**Required.** Genesis needs IK, and IK exists only under S, so a recovery key exists before any personal record or any secret syncs (D6). That covers team secrets too, since they need SK and a confirmed IK.

### Logs

Each account has an identity log and a device log, and each team has a team log. Each is hash-chained and signed, after Keybase sigchains and Tailscale's Tailnet Lock (`tka/aum.go`). Every statement's payload carries these members:

- `v`;
- `origin`;
- `acct` or `team`;
- `seq`, counting from 0;
- `prev`, the hash of the statement at `seq - 1`, or 32 zero bytes at 0;
- `op`;
- `iat`, which is informational and never orders anything.

A statement's place in its log orders it. Neither `iat` nor the server's revision orders anything a client decides.

**Waits run on the server's clock, as the log records it.** Three rules wait on time: a reset's `activate` (7 days), a time-locked removal's `signer_remove_complete` (7 days), and a proposal's lapse (30 days). A client's own clock alone never decides them.

- Each statement record carries `taken_at`, the RFC 3339 UTC time the server first took it, which never changes (0051). Along one log, `taken_at` never goes back, and a restore can lengthen a wait but never shorten one. A client refuses one more than 300 s ahead of its own clock when it first receives it.
- A statement that ends a wait or approves a proposal names, in its signed payload, `after`: the `taken_at` of the statement it follows. `activate` names the reset's, `signer_remove_complete` the start's, and `approve` the proposal's.
  - It is valid when its own `taken_at` is at least 7 days after `after`, or for an `approve` at most 30 days after, and `after` equals the record the client holds.
  - So every client that holds the same head reaches the same state, and a comparison of heads covers the times. A client whose record differs from a signed `after` raises a fork alarm.
- **The hold.** A client that saw a reset or a time-locked start while it was still open also holds the log at a statement that ends the wait, until its own clock is 7 days past when it first saw the start, less the 300 s bound. It holds and never refuses: when the wait ends it evaluates the statement again.
- **Time receipts.** When the server takes a key statement, it signs a receipt: `Ed25519(receipt key, LP("tablepro/v1/receipt") || LP(origin) || LP(statement hash) || u64(taken_at))`. This is the pattern of Certificate Transparency's signed certificate timestamp (RFC 6962 §3.2) and of an RFC 3161 time-stamp token.
  - The receipt key is an Ed25519 key used only for receipts, and lives outside the database, so a restore cannot lose it. The server lists its receipt keys newest first and keeps old ones so their receipts still verify (0051). Each client pins the newest per origin when it first sees it.
  - **Rotating the receipt key.** The old key signs the new one: `Ed25519(old receipt key, LP("tablepro/v1/receipt-key") || LP(origin) || LP(new public key))`, published beside the new key. A client adds a new key only through a chain of these from a key it pinned. This is The Update Framework's root rotation, where a client trusts a new root only when the root it holds signs it.
  - **A receipt under a key the client cannot link** to a pinned one counts as no evidence. The client keeps the statement, and waits still run on the record's `taken_at` and the signed `after`. It asks for the cross-certification. If none links the key, the app shows a changed server time key, as an SSH client shows a changed host key, and pins the new key only when the person accepts. An install that lost its old key ends up there.
  - Clients keep each receipt with its statement in `key_statements`, and send it back when they republish.
  - An `after` must equal the `taken_at` in the start's receipt.
- **Restore.** After a restore, the server verifies its own signature on a republished receipt and checks every wait against the original `taken_at` it carries. A statement republished without its receipt gets a new `taken_at`, so its wait starts again: a restore lengthens a wait and never shortens one. A client-supplied time never counts, since a resetting holder mints its own IK and could backdate it.
- **What receipts do against a malicious server.** It holds the receipt key, so it can sign any time it likes, and receipts give no time check against it, as none of the honest-server time checks do. What they add is evidence: two receipts for one statement with different times, or a time that goes back along a log, prove the server lied, and a client that holds both raises a fork alarm.
- **Joining later.** A device that joins later has no first-seen time. It takes a past `activate`, completion or `reroot` as the log records it, and then confirms with a new root as every member must.

**Identity log.** Kind `key.identity`, type `tablepro-identity+jws`. Teams read it through member bundles.

| `op` | Members | Signed by |
|---|---|---|
| `genesis` | `ik`, `rk`, `rk_v`, `blob`, `sk`, `sk_v`, `ak_v`, `ak_kid`, `holder` | The `ik` it names |
| `rotate` | `removed` (holder ids, which may be empty), `sk`, `sk_v`, `ak_v`, `ak_kid`, `dh`, and `fork` when it resolves a fork | IK in force |
| `replace` | `ik`, `rk`, `rk_v`, `blob`, `sk`, `sk_v`, `ak_v`, `ak_kid`, `dh` | IK in force, endorsed by the new `ik` |
| `reset` | `ik`, `rk`, `rk_v`, `blob`, `sk`, `sk_v`, `ak_v`, `ak_kid`, `holder` with its `row`, `platform`, `hpke` and `sig`, `dh`, and `fresh`, true when the holder is outside the device set | The new `ik`, endorsed by the named holder |
| `cancel` | `reset`, the hash of a pending reset, and `holder` when a holder signs it | IK in force, or the holder it names, which the logs list at the reset's `dh` |
| `activate` | `reset`, the reset's hash, `after`, and `dh` | The reset's new `ik`, from the holder the reset names |

- **IK in force** is the `ik` of the newest `genesis`, `replace` or activated `reset`.
- **Versions.** Each version in a statement is above the previous one on its chain and above every version a fork resolution burned. Its writer takes the highest version of that key it has seen on any branch, plus 1.
- **`genesis`** appears only at `seq` 0. The holder it names is in the device set from then on, so no window opens in which the set is empty.
- **`dh`** is the device log's head (`seq`, `hash`) when the statement was made. It is at or after the `dh` of every earlier identity statement, and the server takes the statement only when `dh` is its current device head.
- **`rotate`.**
  - It may name holders in the device set and holders that left it.
  - It must also name every holder in the set at `dh` that a named holder approved, directly or through other approvals.
  - An empty `removed` gives fresh SK and AK, for example after a false revocation hint.
- **`replace`** carries the new IK with an endorsement by it, so the new key proves it is held. Own devices and teammates follow a `replace` without a comparison, since the IK they pinned signed it.
- **A pending `reset`.** A `reset` stays pending until an `activate`.
  - Only these may come between them: statements the old IK signs, in either account log, and `cancel`.
  - Any statement the old IK signs after a pending reset cancels it, a recovery `add` included, and so does a `cancel`.
  - `activate` is taken only 7 days after the server took the `reset`, under the waits above.
  - The server takes a `reset` only from the holder it names, in the device set at the reset's `dh`, or from any signed-in holder after a step-up when the set it derives is empty (Flows, No holder left).
  - A client verifies a reset's chain, signature and endorsement, but follows it only after a comparison: an own device through approval from the reset's holder, a teammate through a new `confirm`. The endorsement tells own devices which device made it.
- **An endorsement** is a `tablepro-endorse+jws` in the same record. Its payload is `v`, `origin`, `acct`, `op` (`endorse`), `statement` (the endorsed statement's hash) and `role` (`holder` or `identity`).

**Device log.** Kind `key.device`, type `tablepro-device+jws`. It stays in the personal scope and in the account's member bundles. Each statement also carries `ih`, the identity log's head when it was made.

| `op` | Members | Signed by |
|---|---|---|
| `add`, method `genesis` | `holder`, `row`, `platform`, `hpke`, `sig` (JWK) | IK; only at `seq` 0, for the holder `genesis` names |
| `add`, method `approval` | As above, plus `request` and `by`, the approving holder | The `by` holder's own signing key |
| `add`, method `recovery` | As for genesis | IK in force |
| `leave` | `holder` | That holder's own signing key. This is Sign Out |

**The device set** is replayed in log order:

- an `add` puts a holder in and a `leave` takes it out;
- a `rotate` takes effect at its `dh`. The set after device statement `dh.seq` already leaves out the holders it names and everything they approved, with no further device statement needed. Statement `dh.seq + 1` is checked against that set, and new keys are wrapped only to it;
- an activated `reset` leaves only the holder it names, at the `activate`'s `dh`.

The server also leaves out holders whose device row an admin removed, and the holders those approved, as a hint the logs do not carry.

**Ordering rules between the two account logs.** These rules stop a removed device from adding a holder after the removal, and stop a holder it planted before the removal from surviving it, which counters alone do not (Tailscale TKA):

- A device statement's `ih` never goes back. It is at or after every identity statement whose `dh.seq` is below the statement's `seq`.
- A `dh` or `ih` names a head by `seq` and hash. A hash that differs from the other log's statement at that `seq` is a fork.
- An `add` by approval verifies under the signing key of its `by` holder, which is in the device set at `seq - 1`. A thief holding a stolen device can therefore approve holders only in the stolen holder's name.
- **Descendants.** A holder approved, directly or not, by a holder that a `rotate` names leaves with it. That holds even when the named holder signed out first. Holders added by `genesis` or `recovery` are signed by IK and descend from nobody. An honest device that a stolen device approved before the theft joins again by approval or with S.
- A holder id is never added twice.
- **Compare-and-set.** The server takes `rotate`, `replace`, `reset` and `activate` only with `dh` equal to the current device head, and device statements only with `ih` equal to the current identity head. That is compare-and-set both ways, and a client whose append is refused pulls, then signs again.

**Team log.** Kind `key.team`, type `tablepro-team+jws`.

Each statement carries `by`: the signer's `acct`, its `holder`, and its `ih` and `dh`. It is signed by that holder's own signing key. A verifier checks that:

- the signer's identity and device logs come from its member bundle;
- they verify under the IK the team log pinned for that signer, in its `genesis`, `signer_add` or `reroot`;
- the holder is in the signer's device set at `dh`;
- `ih` and `dh` never go back for that signer.

| `op` | Members | Rule |
|---|---|---|
| `genesis` | `root`: `acct`, `ik` | The first signer, an owner or admin in the server's roles. The root counts as confirmed |
| `signer_add` | `who`: `acct`, `ik` | The account is a confirmed member with that IK. A proposal, named by its own hash |
| `signer_remove` | `target`, `timelock` | Takes effect at once when `target` is `by.acct`. Otherwise a proposal. With `timelock`, it starts a time-locked removal (below) |
| `approve` | `proposal`, `after` | A proposal takes effect at the statement where the distinct signers other than its target, counting the proposer, reach `k = min(2, n)`, with n the signers at that statement. So a lone signer adds the first co-signer alone, and with two signers or more nobody adds a signer or removes another alone without the time lock |
| `withdraw` | `proposal` | Its proposer ends a proposal |
| `signer_remove_cancel` | `proposal` | Ends a time-locked removal. Signed by any holder that the targeted signer's logs list at the cancel's `dh`, whatever its row, server role or team seat (Rows and the veto). It is a grant: a `rotate` that names its holder voids its cancels, pending and later, and the removal is pending again |
| `signer_remove_complete` | `proposal`, `after` | Completes a time-locked removal, 7 days after the start under the waits above, and never after a cancel in force |
| `confirm` | `member`: `acct`, `ik`, `ih`, `dh` | After a comparison (below). Confirming a member again after a reset is allowed |
| `remove_member` | `acct` | Refused while the account is a signer. A signer leaves the signer set first |
| `revoke_sk` | `acct`, `sk_v` | After a server hint that the person's device was removed, or a reset |
| `key` | `tk_v`, `kid`, `recipients`: a list of (`acct`, `sk_v`, `ih`) | `tk_v` is one more than the highest TK version the signer has seen on any branch, a dropped one included. Each recipient is a confirmed member, `sk_v` is the SK in force at `ih` of that member's identity log, and the signer has verified that log to `ih` and seen no later SK |
| `grant` | `tk_v`, `recipients` | Adds recipients to an existing version under the same rules |
| `reroot` | `root`: `acct`, `ik` | Only when the signer set is empty at that point. Every member's app shows it, and trusts nothing after it until that member confirms again with the new root. No TablePro staff tool writes one |
| `resolve` | `seq`, `kept`, `dropped`, `burned` | A proposal that ends a fork (Rollback and forks) |

**Rules over the team log.**

- **The signer set** starts as the root and changes only through a `signer_add` or a `signer_remove` that takes effect, and `reroot`. n counts every signer in the set, a suspended one included. Nothing the server says, and no reset, lowers n or k on its own.
- **Proposals.** Every condition of a proposal is checked again at the statement where it takes effect, and only signers at that statement count. A proposal lapses when its proposer withdraws it or leaves the signer set, and for any `approve` taken more than 30 days after it, under the waits above.
- **Time-locked removal**, as the maintainer decided. The signers left, even fewer than k, may remove a signer that will not or cannot act.
  - Any one other signer starts it with `signer_remove` and `timelock`. When the target is the last signer, an owner in the server's roles who is a confirmed member starts it. When that signer's own account is the only owner and has reset, that account starts it after its `activate`: its statement verifies through its identity log, which extends the chain the team pinned, though its new IK is not confirmed. Either way the 7-day wait, the visible `reroot` and every member's comparison with the new root follow, as D15 asks.
  - Every member's app shows it from the start.
  - The targeted signer cancels it by signing `signer_remove_cancel` from any of its holders. A wiped or lost signer cannot, and one that reset cannot either, since its new IK is not the one the team pinned.
  - 7 days on, with no cancel, any signer or the starter signs `signer_remove_complete`, and the target leaves the set.
  - This is the same time lock with a veto as a reset. A thief holding one signer's device cannot act fast, and the honest signer can stop it. It also ends the two-signer freeze, and a last signer that lost its keys or reset leaves through it, which opens D15's re-root.
- **Self-removal** takes effect at once (D15). So a thief holding the only signer's device can remove that signer and open a visible re-root at once. The threat model lists it.
- **One or two signers.** While a team has fewer than three signers, the apps of its owners warn them to add more. With one, losing it leaves only a re-root. With two, a removal needs the time lock, and a signer that keeps cancelling it leaves only by its own action, or once its IdP account ends and it can sign in nowhere.
- **Confirmed members** come from `confirm`, less those named by `remove_member`.
- **After a reset.** A member whose identity log shows an activated `reset` is unconfirmed until a new `confirm` names the new IK. If it is a signer, it is suspended: its statements made under the new IK have no effect until other signers add the new IK through `signer_add` after a comparison. It still counts in n until it is removed.
- **A revoked SK** is one that `revoke_sk` names or that the member's own `rotate`, `replace` or `reset` replaced.
- **Voided grants.** When a `rotate` of a signer's account names a holder, or one it descends from, the grants that holder signed have no effect. A grant here is a `confirm`, a `signer_add`, an `approve` of an addition, a `signer_remove_cancel`, or a `key` or `grant` as far as its recipients go. Revocations stay in force whoever signed them: `remove_member`, `revoke_sk`, `signer_remove` and its `approve`, `signer_remove_complete`, `withdraw`, and a `resolve`'s drop. The team's `genesis` and a `reroot` are never voided.
  - Clients replay the team log skipping voided grants. A grant that is not valid on the replayed state has no effect either.
  - Voiding never undoes a revocation. A revocation, removal or cancel is checked once, on the chain as the client first verified it, and stays in force even when a later voiding takes away the grant that made its signer a signer. Clients keep that first verification with the statement.
  - Voided statements keep their place for the chain and for version numbering.
  - A TK version that a voided `key` introduced counts as known to the attacker, so the team enters rotation pending. It stays readable for envelopes a client already held under it, and nothing is written under it again.
  - With IK in hand during the removal, the app lists the voided grants, and beside them the revocations the removed holder signed, which stay. For each it shows the account id, the IK fingerprint, the signing holder and the `seq`, and preselects none.
  - The person signs again the grants they recognize. A flow that signs account and team statements pushes the account chain first, then the team chain: a `confirm` again, and their own `approve` of an addition, which counts with the approvals still in force.
  - A grant may be signed again without a new comparison only if a remaining holder of the account verified it before the time the person gives for the loss. That holder's own first-seen time is one a thief cannot set. A later grant needs a new comparison, since a thief may have made it.
  - Teammates compare again only for the grants the person does not sign again, so honest history keeps D7's "teammates see no change".
- **What a signer can do.** One signer can confirm members, seal team keys to them and remove members. Once a team has two signers, it can neither add a signer nor remove another without either k approvals or the time lock the target can cancel. A malicious signer is still trusted with the team's secrets, and every statement it signs shows in every member's app. The threat model covers this.

**Member bundle.** Kind `key.member` in the team scope, writer-bound to the member's account, one record per statement.

- Each holds a verbatim copy of one statement of the member's identity log or device log. The member's client copies each new statement into every team it is in.
- Teammates verify both chains under the IK their `confirm` pinned.
- A `rotate` or `replace` signed by that IK gives them the person's new SK, and a `replace` its new IK, without a comparison (D7).

**Rollback and forks.**

- A log the server presents must contain the stored head at its `seq` with the same hash. Otherwise it is refused as a rollback.
- **A fork** is two valid statements at one `seq` of one log with different signing inputs. It raises a fork alarm, and secret writes for that account or team stop. The app shows both branches and who signed them.
- **Ending an account fork.**
  - **A replaced key never decides.** A client never follows a statement signed by an IK that a `replace` or activated `reset` it has verified, on any branch, replaced. That holds for fork resolutions too. This is The Update Framework's rule for its root role, where a client trusts a new root only through the root it holds and never goes back to one it saw replaced, and Keybase's rule that a client never accepts a sigchain without a link it has seen.
  - **A fork with no identity change** on either branch ends with a `rotate` carrying `fork`, signed by the IK in force on both. `fork` names the `seq`, the kept hash, the dropped hash, and `burned`: the highest AK, SK and RK versions on the dropped branch. The `rotate`'s new versions are above them, and its `removed` names every holder that signed a statement on the dropped branch, and their descendants.
  - **A fork where either branch holds a `replace`, `reset` or `activate`** ends by no `rotate` alone, since the key that would sign it may be the one an attacker holds through an old S. The comparison decides: each own device pins again on the kept branch through a fork re-pin with a holder on it (Comparing keys), and teammates confirm the person again through a member comparison that covers the fork the same way.
  - Before writes resume on that account, the person signs, with the IK in force on the kept branch, a `rotate` carrying `fork` and `burned` as above. Its new versions are above every version of each key seen on any branch. A client takes that `rotate` only after its own fork re-pin chose the kept branch.
  - A client whose pin is on the dropped branch moves it back to the fork point and onto the kept branch, after the `rotate` or the comparison. 0054's anchor heads move with it. This is the one exception to the stored-head rule and to anchored heads only moving forward. A fork ending moves heads and pins, never a floor or an envelope counter, since new versions are allocated above every branch. Floors limit writes only: older versions on the kept chain still open their envelopes, and burned versions open nothing.
  - Holders, keys and records that exist only on the dropped branch are gone, and their versions are burned. Queued edits stay queued and are sealed under the new versions.
- **Ending a team fork.**
  - A `resolve` on the kept branch does the same for a team. It names `burned`, the highest TK version on the dropped branch.
  - It takes effect with k = min(2, n) approvals, with n the signer count at the fork point. Only signers that both branches have at the fork point, and that neither branch, as the client has verified, removes, may approve. A removal on either branch never lowers n or k.
  - **A `resolve` never drops a cancel.** A client refuses a `resolve` whose dropped branch holds a `signer_remove_cancel` or a `withdraw` it verified, unless the kept branch holds it too.
  - **It never drops a revocation.** That covers `remove_member`, `revoke_sk`, a signer removal or its completion. The signers sign it again on the kept branch, under the rules there, before the `resolve`. A completion whose removal the kept branch cancels is the exception, since the target's cancel wins.
  - When no `resolve` meets these, the fork stays, and secret writes for the team stay stopped.
  - The team enters rotation pending, and the next `key` is above `burned`.
- **Observing a rotation.** A client refuses a team statement by a signer whose identity log has rotated or reset when the statement names an `ih` older than one the client had already verified before it received it. Writers pull before they push, and sign again any statement made under a holder or IK that has since left.
- **The limit.** This is not key transparency (draft-ietf-keytrans-protocol). A server can show two devices two consistent histories. They notice only when they compare, and every comparison below covers the log heads.

### Key objects as records

Key objects are records of reserved kinds under 0051's record rules. Ids are writer-bound where the table says, and follow 0052's key-object grammar.

- **Create-only.** Every key kind except `key.wrap` and `key.ring` is create-only: a second create of one id is refused with `create_only`, which serializes two devices or two signers appending at once.
- **Replaceable.** The writer the table names may replace a wrap or a ring. A recipient checks every wrap anyway, so a wrap that a stolen holder squatted can be replaced after its removal.
- **Who may write.** Every write of a key kind carries a DPoP proof from a holder in the writing account's device set (Server enforcement), except the personal-scope writes allowed before approval. A phished session with no approved holder therefore writes no key object anywhere, and cannot squat a log position.
- **Which license.** Key-object writes in the personal scope need the feature `service_sync` or `team_library`, and the first one creates the scope (0051). A license that grants Team Library only still lets a member build an identity and read team secrets.
- **Past grace.** Key-object writes and `leave` stay open past a license's grace, as the maintainer decided and 0051 carries, since they are how a person removes a stolen device.

| Kind | Scope | Id parts | Writer-bound | What the server verifies |
|---|---|---|---|---|
| `key.identity` | personal | account, `seq` | account | The JWS framing, the chain, the signatures, the endorsements and every rule above. `genesis` only while the account has no `key.identity` record (0051). `reset` only from the holder it names. `activate` only 7 days after the `reset`, and only while it is not cancelled. Answers `bad_statement` |
| `key.device` | personal | account, `seq` | account | As for `key.identity`, and the holder's row is one of the account's device rows |
| `key.recovery` | personal | account, `rk_v` | account | Its hash is the `blob` an identity statement names for that `rk_v`. A superseded blob is deleted once a `replace` or an activated `reset` applies |
| `key.request` | personal | request id | the request's holder | Signed by the request's own signing key, which is the DPoP key. `exp` is in the future and at most 600 s after `iat`. One open request per holder |
| `key.sas` | personal, team | session id, step | the step's party | Its form. The request or the commit names the two parties, and each step comes from its party |
| `key.wrap` | personal, team | owner, purpose, version, recipient | the owner's account; in a team, the signer whose `key` or `grant` names the recipient | Its form, and the writer. A wrap to a superseded `rk_v` is deleted with its blob |
| `key.ring` | personal, team | owner, version | the owner's account; in a team, the signer of the `key` for that version | Its form, and the writer |
| `key.team` | team | team, `seq` | no | As for `key.identity`, using each signer's verified identity and device logs, and every rule over the team log. The writer's role is owner or admin |
| `key.member` | team | account, log (`identity` or `device`), `seq` | account | It equals, byte for byte, the account's `key.identity` or `key.device` record at that `seq` |

- The server reads key-object fields only as this table says, plus `kv` and `n` on `secret_envelope` and `kv` on `history_entry` (Envelopes; 0051).
- **Retention.**
  - `key.request` and `key.sas` records are purged after they expire.
  - Superseded blobs and their RK wraps are deleted.
  - Identity and device logs are never tombstoned or purged, under a policy or a member removal alike: they hold no secret, and a gap would let a new `genesis` in.
  - Every other key object stays until the account or team is deleted.

### Comparing keys

Device approval and member confirmation compare a short authenticated string. The two devices exchange it through records, with a hash commitment that leaves an attacker one guess. Without the commitment, a server that controls both sides' views can search for two views with equal words: about 2^32 work for 64-bit words and 2^52 for 103-bit words. RFC 6189 §4.4.1.1 describes that birthday attack, and the commitment closes it.

The exchange is Vaudenay's SAS-based message cross-authentication (CRYPTO 2005; Pasini and Vaudenay, PKC 2006). The commitment covers the committer's message and random value, as ZRTP's `hvi` and Matrix's SAS commitment do.

**The exchange.** The initiator I and the responder R are both online, and both poll every 1-2 s while the sheet is open. Each step is a `key.sas` record named `commit`, `nonce` or `reveal` and written by its party's account, except that a device approval's commitment sits in its request, whose id is the session id. The steps need no signature, since the commitment and the comparison authenticate them.

1. `commit`: I picks a random 32-byte `r_I` and publishes `c = SHA-256(LP("tablepro/v1/sas-commit") || LP(session) || LP(m_I) || LP(r_I))`, where `m_I` is I's own message below.
2. `nonce`: R, after it has `c`, publishes a random 32-byte `r_R`.
3. `reveal`: I, after it has `r_R`, publishes `r_I`. R refuses an `r_I` that does not open `c` with `m_I` as R received it.
4. Each side computes `d = SHA-256(LP(label) || ctx || LP(r_I) || LP(r_R))` from its own view of `ctx`. The words are the first five base-7776 digits of d read as a big-endian integer, least significant first, each picking a word of the EFF large word list.

- **Never backwards.** A holder never pins, from a comparison, a head older than one it has anchored (0054). Such a session ends as a mismatch.
- **A fork re-pin** is the one exception. When a holder's pin, or a teammate's pin of the person, sits on a fork's dropped branch, its `ctx` ends with `u64(fork seq) || LP(kept hash) || LP(dropped hash)`, so the words cover both branches. Once they match, the holder or teammate moves that pin, and 0054's anchor, to the kept branch.
- **When each side fixes its view.** Each side fixes its `ctx` (the request bytes and the heads it compares) before it publishes its own random value: I before step 1, R before step 2. A session ends if one of the account's own logs moves before the person confirms. A team log that moves between the two sides' views gives a mismatch, and they start again. The formal model found that a side reading its heads later lets the server pick heads after `r_I` is public.
- The person compares the five words on both screens and confirms on both.
- A session allows one comparison and expires 10 minutes after `c`. Words that differ end it and are shown as a possible interception. A followed log that moved ends it with its own message, "something changed, start again", since in a large team that is common.
- An attacker who changes either side's view must commit before it sees the other side's random value, so it succeeds with a probability of 7776^-5, about 2^-64.6, per session.

**Device approval**, label `tablepro/v1/device-approval`. I is the new holder N, R the approving holder A, and the session is N's request.

- `m_N = LP(holder) || LP(row) || LP(platform) || LP(N's HPKE key) || LP(thumbprint of N's signing key)`.
- `ctx = LP(origin) || LP(account) || LP(session) || LP(m_N) || head(identity) || head(device) || u32(personal floor) || LP(SHA-256(teams))`, so a large team list costs one hash.
- `teams` is `u32(count)`, then for each team the account is in, sorted by id: `LP(team) || head(team log) || u32(team floor)`, then for each confirmed member sorted by account: `LP(account) || head(that member's identity log) || head(that member's device log)`.
- A floor in `ctx` is the version the signed removals in those logs require, so both sides compute it from the heads they compare, never from a server hint.
- Each side lists the teams it follows. A lists them from its pinned state, N from what the server shows it, so a team the server hides from N shows as a mismatch. N reads the team logs and member bundles before step 1, as it may as the account's seat (0051), and pins every head it compared once the words match. So a new device starts with the approving device's team checkpoints, and a server that shows it an older team log or member bundle fails the comparison.

**Member confirmation**, label `tablepro/v1/member`. I is the signer G, R the member M.

- `m_G = LP(team) || head(team log)`.
- `ctx = LP(origin) || LP(m_G) || LP(M's account) || LP(M's IK) || head(M's identity log) || head(M's device log)`.
- The comparison checks both directions at once: G's view of M's IK and logs, and M's view of the team log. This is the star of SYN 1.3. Members never compare with each other. The sheet shows the team's root and signers, since the member trusts whoever signed the head it compares.
- In person, M's device can instead show a QR code of `TPM1:` followed by the 52 Crockford Base32 symbols of `SHA-256(LP("tablepro/v1/member-qr") || ctx)`.
  - G's device scans it and shows whether it matches its own.
  - The full 256-bit digest leaves only a 2^128 collision search, so this path needs no commitment.
  - M confirms on M's device after seeing G's result.

### Flows

**Genesis**, on the first device of an account with no identity log.

1. The holder generates S, IK, RK, SK and AK v1 from the system RNG.
2. It shows the recovery key and asks the person to type back two groups chosen at random. Nothing is pushed before that, so a crash never leaves a blob that nobody can open.
3. It signs the identity `genesis` and the device `add` (method `genesis`) with IK, seals the blob, and seals AK and SK to RK.
4. It keeps the signed records and the blob ciphertext in its security state, which then holds no secret. It zeroizes S, IK and RK.
5. It pushes `genesis` first, then the blob, the `add` and the wraps, each after the one before applies.
   - The server takes `genesis` from any signed-in session with a DPoP proof while the account has none. That first enrollment is trust on first use.
   - If another device's `genesis` won, this one discards everything and asks for approval instead.

**Approving a device.** A new holder N and an approved holder A.

1. N reads the account's logs, its team logs and member bundles, fixes its `ctx`, and writes `key.request`:
   - its holder id, device row and platform;
   - its HPKE key and its signing JWK;
   - the commitment, `iat`, and `exp` 600 s later;
   - signed by its signing key.
2. The person picks the request on A. A fixes its `ctx` and writes the `nonce` step.
3. N writes the `reveal` step. Both show the words, and the person confirms on both.
4. A signs the `add` (method `approval`) with its own signing key and pushes it. Once it applies, A seals the current AK and SK to N's HPKE key.
5. N pins the heads it compared. It accepts the `add` only if it extends them and verifies under A's signing key, as the pinned device log lists it.
6. N unwraps, checks every `kid` and public key, and reads the AK ring.

**Recovery with the recovery key**, on a holder with no approved device at hand.

1. The holder reads `key.identity`, `key.device` and `key.recovery`, which a holder outside the set may read.
2. The person types S. The holder opens the newest blob and makes the checks in Opening.
3. It signs its own `add` (method `recovery`) with IK, and pushes it. The server checks it under IK.
4. Now in the device set, it reads the wraps to RK and the rings. It unwraps, and checks every `kid` and public key against the IK-signed log.
5. It signs a `rotate` with IK that names every other holder in the set, with fresh SK and AK v+1 sealed to itself and RK.
   - A server that showed it a log cut before an earlier removal then gives it keys the removed holder never had.
   - The person's other devices join again by approval, and the app says so before it starts.
6. It zeroizes S, IK and RK.

**Sign Out.**

- The holder pushes its `leave` when online, then erases its keys with a verified delete. Nothing rotates (D7). Offline, it erases anyway. The holder then stays in the set until a removal names it, and nobody holds its keys.
- Holders it approved stay. If it was a stolen device that signed out, removing it with S still takes them out (Descendants).

**Removing a lost device** needs the recovery key (D7).

1. The app first removes the device row through the account (0016), with the proof and step-up Server enforcement asks for. That revokes its tokens, so the honest server refuses it before it can append anything.
2. The person picks the device and enters S. The device may still be in the set or may have signed out. The app lists every holder and preselects only the one the person picked. The holder opens the blob.
3. It signs a `rotate` with IK that names the current device head, the lost holder and every holder it approved. When the acting device's own holder descends from a named one, the device first makes a fresh holder. In one log chain it signs that holder's `add` (method `recovery`) with IK, then the `rotate`, which also names the old holder, and the fresh holder pushes the chain. Otherwise the acting device keeps its holder and pushes the `rotate` alone.
4. It generates SK and AK v+1 for that `rotate`. Once the chain applies, it seals the new keys only to the set the `rotate` leaves, and to RK, and writes AK ring v+1. It zeroizes IK and RK.
5. It lists the personal envelopes a removed holder wrote, asks before sealing each again under AK v+1, and clears the ones the person does not keep (Envelopes).
6. The app tells the person to end every IdP session of the account, since a thief that can still sign in keeps a reset cancel until the `rotate` names its holder.
7. The person's client copies the chain into every team's member bundle.
   - Teammates see a new SK certified by the IK they pinned and accept it with no comparison (D7).
   - Each team enters rotation pending. Grants the removed holders signed are voided, and the app lists them. The person signs again the ones they recognize (Voided grants).

**Admin removal from the portal.** The browser has no keys, so the admin removes the row behind the portal's step-up, and nothing about keys or the reset veto changes (Rows and the veto).

1. The server revokes the device row's refresh family and marks its holders revoked. It answers them with `device_removed`, and raises the person's personal floor to the current AK version plus 1.
2. A holder that gets `device_removed` locks: it stops syncing and keeps its keys (Key holders and sessions).
3. Envelope and history pushes wait in the local queue, and nothing is lost.
4. The person's next device asks: "Your admin removed device X. Enter your recovery key to finish." Finishing is the removal above. It lists every holder and preselects none, since a server's hint names the device.
5. Signer clients treat the server's hint as untrusted but safe. They sign `revoke_sk` and stop sealing to that SK. A false hint only denies team keys, and it shows.

**Replace Recovery Key** needs the current recovery key. It is the step when that key may have been seen, since it takes effect at once and wins the race to the next identity statement on an honest server. A lost key is a Reset.

1. The person enters the current S. The holder opens the blob.
2. It makes IK', S', RK', SK' and AK v+1, shows S', and has two groups typed back.
3. It signs `replace` with IK, naming IK' and the current device head, endorses it with IK', and pushes the statement first.
4. Then it pushes the blob for `rk_v + 1`, the wraps of the new keys to every holder and to RK', and AK ring v+1. It keeps the blob ciphertext until it lands.
5. The old S stays in force until the `replace` applies. Once it does:
   - the old S opens nothing in force, since IK changed;
   - the honest server deletes the old blob and the wraps to the old RK;
   - an old blob someone kept gives only the old IK and keys that were current before the replace. A client that has verified the replace never follows the old IK again, fork resolutions included. A device or teammate that a malicious server keeps from seeing the replace can be shown a competing one, which is a split view until a comparison.

**Reset** when the recovery key is lost. A key that may have been seen goes to Replace instead, since whoever saw it can cancel a reset. Against a malicious server, a seen key is recoverable only through comparisons. A reset is time-locked recovery with a veto, as Bitwarden's emergency access uses.

1. An approved holder H generates IK', S', RK', SK' and AK v+1, shows S' and has it typed back.
2. It signs a `reset` with IK', naming itself and the current device head, endorses it with its own signing key, and pushes it. Then it pushes the blob.
3. The reset is pending for 7 days.
   - Every holder of the account shows that a reset from H is pending, and the portal shows it. The SaaS also sends an email.
   - Any holder the logs list at the reset's `dh` can sign a `cancel`, on any session of the account, whatever the server says of its row. S can too, through any statement the old IK signs.
   - A stolen holder alone therefore cannot take the identity while the person holds S or another device.
4. After 7 days H signs `activate` with IK', naming the current device head. Then it pushes the wraps to RK' and AK ring v+1, which holds every older AK version, so history stays readable.
5. The device set becomes H alone.
   - The person's other devices stop personal sync and join again by device approval from H. That comparison is the only way an own device accepts a reset.
   - Signers sign `revoke_sk` for the old SK. The person is unconfirmed, and suspended if a signer, until a signer confirms the new IK.

**No holder left.** An account whose device set is empty and whose person has no recovery key can only start again. Empty means every holder has left by the logs, or every one is on a row that has stayed removed for 7 days.

- The server takes a `reset` from a signed-in holder outside the set only on a session that authenticated again at the IdP within the last 300 s, through `max_age=0` (step-up, S5). Otherwise it answers `step_up_required` (0051).
- The holder pushes the `reset`, marked `fresh`, and its blob, and stays pending (Server enforcement).
- The reset is pending for 7 days. The portal shows it, and the SaaS sends an email. An `add` (method `recovery`) under the IK in force cancels it, so a person who still holds S keeps the account.
- The server takes the `activate` only 7 days after the `reset`, from the holder it names, and only while it is not cancelled. The holder then pushes the wraps of the new keys to itself and RK', and no ring, since it holds no older key (Wraps and rings). At `activate`, and not before, the server deletes every record in the account's personal and history scopes except the key logs, which stay intact (0051). The reset still extends the logs, so teammates see it as a reset.
- A device that signs in to an account that has an identity and an empty set asks for the recovery key first.
- Devices that kept local data push it again after they join.

**Confirming a member.** A signer and the member compare (above). The signer then signs `confirm`, seals the current TK to the member's SK, and signs `grant`, or `key` when rotation is pending.

**Removing a member.**

1. The server raises the team floor to the current TK version plus 1.
2. The first signer client to open signs `remove_member`, then a `key` for TK v+1 sealed to every confirmed member with an unrevoked SK, then TK ring v+1. It lists the team envelopes the removed member's holders wrote and asks before sealing each again under TK v+1. One it does not keep is cleared.
3. "Credentials to rotate" lists the database credentials the removed party could read.
4. **Reconciling.** Signer apps compare the team log's confirmed members with the server's roster. A member confirmed in the log but no longer on the roster shows as removed but not yet rotated. The portal shows a removal as pending until `remove_member` and the next `key` are in the team log. So an operator that ignores a removal is seen.

**Rotation pending.** A team is pending after:

- a `remove_member` or a `revoke_sk`;
- a member's `rotate`, `replace` or `reset`;
- a voided statement;
- the server raising its floor.

The first signer client that sees it signs the next `key` and seals it to current, unrevoked SKs only.

- Two signers racing are serialized by `create_only`, and the loser discards its key.
- A client pushes a statement alone and waits for it to apply before it pushes the wraps and the ring that depend on it.
- The honest server refuses a `key` or `grant` whose recipient `sk_v` is not that member's current SK.
- **A member checks what is sealed to it.** A member's client refuses a `key` or `grant` that names one of its own SK versions that its `rotate`, `replace` or `reset` replaced. It writes nothing under that TK version, raises an alarm, and publishes the replacing statement into that team's member bundle again. That is how a server that hid the member's bundle from the signers is noticed, as signer apps notice an ignored portal removal (Removing a member).

### Server enforcement (D8)

This is an honest-server control against account takeover. A malicious server is covered by the client checks above.

**Every call on a personal or history scope, and every write of a key kind or a `secret_envelope` in any scope, carries a DPoP proof** (RFC 9449 §4.2):

- `typ` `dpop+jwt`, the holder key's `alg`, and `jwk` with the holder's signing key;
- `jti`, `htm`, `htu` (no query or fragment), `iat`;
- `ath`, the base64url SHA-256 of the access token;
- `nonce` once the server has sent one.

**This is a profile of RFC 9449.** The proof format and its checks are the RFC's, but the access token stays an unbound bearer token. The server checks the proof as RFC 9449 §4.3 lists, and check 12's key binding becomes one rule: the key's thumbprint is a holder in the account's current device set, on the device row of the token's refresh family. In a team scope that is the writing member's own device set. In detail:

- `iat` is at most 300 s old and at most 60 s ahead.
- Each `jti` is kept, hashed, for 360 s in a Postgres table, since several tasks serve (RFC 9449 §11.1).
- On clock skew the server answers `use_dpop_nonce` with a `DPoP-Nonce` (RFC 9449 §9).
- A refusal is 403 `device_not_approved`. A holder whose device row an admin removed gets `device_removed` instead, distinct from a refused or expired token.
- G2 tests the Go verifier against this profile.

**Tokens stay bearer tokens.** Binding them at the token endpoint with `cnf.jkt` (RFC 9449 §6) is later hardening.

**The device set** is what the server derives by verifying the identity and device logs on every append with Go's `crypto/ed25519`, less the holders of device rows an admin removed and every holder those approved. An append that does not verify is refused.

**Before approval**, a holder outside the set may:

- read `key.identity`, `key.device` and `key.recovery`, its own `key.request`, and the `key.sas` steps of its own request;
- write its `key.request` and the `reveal` step of that request;
- push any personal log chain whose statements all verify under this ADR's rules, such as an `add` (method `recovery`) under the IK in force, or the statements that once approved it (0051);
- write a `cancel` of a pending reset, when the logs list it at that reset's `dh`, whatever its row (Reset).

The only things a signed-in holder may start alone are these two:

- the genesis records naming itself, while the account has no `key.identity` record;
- while the device set is empty, a `reset` naming itself, after a step-up within the last 300 s (else `step_up_required`), and the blob that reset names (Flows, No holder left).

**A pending reset.** The holder that wrote a no-holder `reset` is pending, not approved. It reads only what a holder outside the set reads, plus its own reset and blob, and writes nothing else. 7 days after the server took the reset, and only if no cancel came, it writes that reset's `activate` from the same DPoP key. That chain is the one whose result puts it in the device set (0051). Only then does it write wraps.

**Rows and the veto.**

- **From the apps,** removing a device row of an account that has an identity needs a DPoP proof from an approved holder and a fresh IdP sign-in within 300 s.
- **From the portal,** an install admin can still remove a row, behind the portal's step-up (0044, S5). The browser holds no keys, so this is the admin removal in Flows.
- Either kind is audited, and every holder of the account is told.
- **Neither kind changes keys or either veto.** It only locks the row: its holders, and the holders those approved, get `device_removed`, and the server refuses them everything but what follows.
  - **The reset veto.** The server takes a `cancel` from any holder the logs list at a pending reset's `dh`, and that cancel voids the reset, whatever the holder's row. It answers that holder's reads of `key.identity`.
  - **The signer veto.** The server takes a `signer_remove_cancel` from any holder that the targeted signer's logs list at the cancel's `dh`, whatever its row, server role or team seat, and passes it through every request-wide gate. It answers that holder's reads of `key.team` and the member bundles in each team where a removal targets it.
  - For both cancels, the server checks the DPoP key against the holder the logs list, not against its current device set.
- `device_removed` names any pending reset and every pending time-locked removal that targets the account, with its team. A locked device shows them and offers the recovery key and the cancel.
- For a `fresh` reset, a removed row counts as empty only after it has stayed removed for 7 days.

**Floors.** Each personal and team scope has a floor: the lowest key version a new envelope or history entry may use. Flows says when it rises. An honest server refuses a `kv` below it with `key_version_stale`. After a removal raises it from v to v+1, a write under v is refused, one under v+1 is taken, and the writes queued meanwhile go out once the rotation lands.

### Key holders and sessions

A key holder belongs to (origin, account id, device row id), not to a session (F5).

- **It survives:**
  - session expiry, including the 10 h cap with SAML;
  - a lost or refused token;
  - a failed deprovisioning revalidation.
- **It resumes without approval** when the same account signs in again on the same device row, since its key is still in the device set.
- **Its keys are erased**, with a verified delete, on exactly three events:
  - Sign Out;
  - a verified `rotate` that names it;
  - a different account signing in on that device row (DEC:127).
- **It locks** on `device_removed`: it stops syncing, keeps its keys and shows that an admin removed the device. A malicious server can send that signal, so it erases nothing. The person can erase the keys there, or a `rotate` that names the holder does.
- A reset that leaves it out stops its personal sync until it is approved again, but erases nothing.
- **Tests:** one test per erase event, one for the lock, and one per event it survives.

### Security state

A holder's security state is what it has verified, apart from its keys. It lives in the account's TablePro Sync state file. 0054 owns the file's format, its MAC, its freshness, and the key checkpoint it keeps in an anchor in the device store, after ROTE. The MAC covers two digests, one over the key tables and one over every other table, so a local writer can swap in neither older pins nor older bases, approvals or cursors (0054). Both frame each value with 0054's `W`, an 8-byte length, since key objects can pass 65,535 bytes. This ADR's `LP` stays for its own crypto inputs. The checkpoint holds every followed log's head, every key version floor, and each envelope's highest counter with that ciphertext's hash. This ADR fixes what each key table holds and the rules on it. 0054 holds the one column list:

| Table | Holds |
|---|---|
| `key_statements` | Every key object the holder keeps verbatim: the statements of the logs it follows (its account's two logs, and each team's log and member bundles), each with its time receipt and the first verification of a revocation, both branches of a fork it has seen, the newest blob's ciphertext, and key objects not yet pushed. A holder's own statement moves a head, in `key_heads` and in 0054's anchor, only once the server reports it `applied` |
| `key_heads` | Each followed log's head |
| `key_pins` | Its pins: the account's heads it compared or verified under IK, and per team the team head, the confirmed members, and each member's two chain heads, identity and device (0054's `member:<account>:identity` and `member:<account>:device`). One shared head would let a server replay a member's device chain from before a `leave` |
| `key_comparisons` | Open comparison sessions, with the view this side fixed |
| `key_floors` | Per scope, the lowest key version it may write: the higher of the server's floor and the version the signed removals require. Versions seen on any branch, a dropped one included, also count, so a new version is above them. It also marks rotation pending |
| `envelope_counters` | Per envelope, the highest (`kv`, `n`) it accepted and that ciphertext's hash |
| `deleted_history` | The ids of history entries with a `user` tombstone |

**Stale state, or an anchor with no file.** 0054 rebuilds the key tables from the server's logs, with no comparison. The holder keeps its keys and accepts only what extends the anchored checkpoint, or the pending one when 0054's two-step anchor write left one. A log extends a head when it contains that head at its `seq`. The holder writes no secret until every followed log extends its anchored head. No comparison makes it pin a head older than one it has anchored.

**A file with no anchor** pins again, in one of two ways:

- **With another holder of the account.**
  - It runs the device approval comparison as N, with its existing keys. The request is marked as a re-pin, and the flow ends with no `add` and no wraps.
  - The context carries the account's identity and device heads and floor, and every team's head and floor with each member's identity and device heads (Comparing keys).
  - Once the words match, the holder pins what it compared and rebuilds its key tables from the logs it verifies from there.
- **With S.** The holder runs Recovery's steps 2 to 6 with a fresh holder of its own. It opens the blob and verifies the account logs under IK. Then, in one chain, it signs the fresh holder's `add` (method `recovery`) and the `rotate` that removes every other holder, its old one included. The team logs and member bundles it then reads are pinned uncompared, as after a recovery, until a device approval or member confirmation compares them.

**The limits** (0054):

- a file with no anchor, which pins as above;
- a restore that brings back the file together with its anchor, which cannot be told apart locally from the moment it came from;
- `deleted_history`, which lives in the file only, so a restore can bring back history the person deleted.

The threat model lists all three.

### Wraps and rings

**A wrap** is a `key.wrap` record: `(enc, ct) = SealBase(pkR, info, aad = "", pt)` (RFC 9180 §6.1), where:

- `info = LP("tablepro/v1/wrap") || LP("tp1") || scope || LP(purpose) || u32(version) || LP(recipient type) || LP(recipient id) || u32(recipient version)`;
- `purpose` is `account-key`, `sharing-key` or `team-key`;
- the recipient type is `holder` (the holder's id, version 0), `recovery` (the account, `rk_v`) or `member` (the account, `sk_v`), spelled as in the record id (0052);
- `pt` is the 32-byte key or scalar;
- the fields are `suite`, `purpose`, `version`, `recipient`, `enc` and `ct`.

Context goes in `info`, as RFC 9180 §8.1 advises. After `Open`, the recipient checks:

- a symmetric key's `kid`;
- that the SK scalar's P-256 public key, computed with aws-lc-rs, equals the key the signed statement names.

The wrap itself is not signed. Base mode does not authenticate a sender, and a server can seal anything to a public key. The signed commitment is what makes a substituted key fail, and it binds the key itself rather than the ciphertext.

**A ring** is a `key.ring` record for a version v of AK or TK that has older versions to hold. It holds every older version that exists on its chain, back to the newest `fresh` reset:

- plaintext: `u32(i) || K_i` for each such version i, ascending, padded;
- the subkey `HKDF-SHA256(salt = none, IKM = K_v, info = LP("tablepro/v1/ring-key") || scope || u32(v), L = 32)`;
- `AAD = LP("tablepro/v1/ring") || LP("tp1") || scope || u32(v)`.

A reader checks each `K_i` against the `kid` the log names for version i. Versions a fork burned have no key and are absent. Versions below a `fresh` reset were given up with the data the server deleted at its `activate`, and no reader asks for them. The AK version a `fresh` reset introduces has no ring. A device joining later gets the newest wrap and the ring, and so reads every secret stored before it joined. That is the vault behavior.

### Envelopes

**One record per (parent record, secret kind).** A `secret_envelope` exists for each parent record and secret kind, and is conditional on its change tag like every record (0051). Its id is the parent's kind, the parent's record id and the secret kind (0052).

**Secret kinds.**

| Parent kind | Secret kind | Sealed destination |
|---|---|---|
| `connection` (personal) and `library_connection` (team) | `password` | Engine, host, port, user, database, TLS mode, CA and client certificate paths, and the SSH route |
| same | `ssl_key_passphrase` | As for `password` |
| same | `ssh_password`, `ssh_key_passphrase`, `ssh_totp_secret` | SSH host, port, user and key path |
| same | `plugin.<field id>`, one per secure field a driver plugin declares; a field id holding `/` does not sync | As for `password` |
| `ssh_profile` | `ssh_password`, `ssh_key_passphrase`, `ssh_totp_secret` | SSH host, port, user and key path |
| `credential_profile` | `password` | The profile's user. At use, each (profile secret, connection destination) pair is approved once per device, as 0044 does for typed references |
| `<platform>_settings`, record `ai` | `ai_key.<provider id>` | The provider type and endpoint |

The K3 wire schema spells each destination field. A new secret kind needs a row here first.

**The ciphertext.**

- **Subkey.** `k = HKDF-SHA256(salt = none, IKM = K_v, info = LP("tablepro/v1/envelope-key") || scope || LP(parent kind) || LP(record id) || LP(secret kind), L = 32)`.
  - K_v is an AK version in the personal scope and a TK version in a team scope.
  - A subkey per record keeps random nonces far below the 2^32 messages per key that NIST SP 800-38D §8.3 allows.
- **AAD, immutable ids only.** `LP("tablepro/v1/envelope") || LP("tp1") || scope || LP(parent kind) || LP(record id) || LP(secret kind) || u32(kv) || u64(n)`.
- **Plaintext.** A UTF-8 JSON object (RFC 8259), then padded:
  - `v`: 1;
  - `secret`;
  - `dest`: the sealed destination;
  - `writer`;
  - `sealed_at`;
  - `cleared`, true when the secret was removed. A secret is cleared with the next counter, never by deleting its envelope.

  A reader refuses an unknown `v`.
- **Fields:** `suite`, `kv`, `n`, `nonce`, `ct`, `writer` and `sig`.
- **The counter `n`.** It is 1 for the first envelope under each key version and grows by one per write under that version. `n` is in the AAD and in the clear fields. The honest server takes a write only with (`kv`, `n`) exactly one step after what it stores: the same `kv` with `n + 1`, or a higher `kv` with `n` = 1. Any other pair answers `bad_counter` (0051). An envelope sealed again when a policy comes back follows the same rule. Since `kv` and `n` are not secret, 0051 sends them on a `secret_envelope` tombstone, and a `bad_counter` answer carries the stored pair. So a device that missed the last write still finds the next pair. It still refuses to write a pair that is not above the one it holds.
- **Writer signature.** `sig = Sign(writer's holder key, LP("tablepro/v1/writer") || writer || LP(SHA-256(LP(AAD) || nonce || ct)))`. Personal and team envelopes alike.

**Accepting an envelope.** A client accepts an envelope only when:

- the signature verifies under the writer holder's key, and the writer's device log lists that holder (its own, or the member bundle's copy);
- in a team, the writer is a member the team log confirms and has not removed;
- the plaintext `writer` matches the clear one;
- (`kv`, `n`) is above the pair it holds for that envelope in `envelope_counters`, compared as a pair;
- the writer holder has not been removed, or the client already held this exact envelope before it verified that removal.

So a removed holder cannot slip a forged envelope under an old key version past a client that knows of the removal, whatever order the server uses. A superseded envelope under the same version also fails the counter. A counter a stolen holder pushed high is cleared by the next version, where `n` starts again.

**Sealing again after a removal.** The client that makes the new version lists every envelope whose writer the removal took out, and asks before sealing each again under it and its own signature. One the person does not keep is cleared, so a secret a thief planted never loses its mark silently. It keeps the sealed destination from the old plaintext, never the record's current one. If it stops halfway, any holder of the account, or for a team any signer, finishes. A device that already holds the secret keeps using it meanwhile. Other envelopes stay under the version they were written with (lazy revocation).

**At use.** The client compares the sealed destination with the record's current destination (F3).

- A destination change waits for approval on each device, as 0044 decides for any destination of a stored secret, whoever made it.
- A new seal for the new destination clears only the "saved for X, now points to Y" mismatch. It never approves the change.
- A server that rewrites a host trips the mismatch, since it cannot change the sealed destination.
- A device that edits a destination but cannot seal again leaves the old seal in place, and nobody else's secret breaks.

**Writing.**

- Clients pull key objects before they push envelopes.
- They never encrypt under a version below the highest one seen, below a floor, or below the version that a signed removal requires.
- Residual risk: a confirmed member with the server's help can write a team secret, since roles are server data, not signed data.

### History entries

- Each entry is created once, under a random UUIDv4 record id (0052), so its id leaks no capture time.
- **Subkey.** `HKDF-SHA256(salt = none, IKM = AK_kv, info = LP("tablepro/v1/history-key") || scope || LP(record id), L = 32)`, with the history scope.
- **AAD.** `LP("tablepro/v1/history") || LP("tp1") || scope || LP(record id) || u32(kv)`.
- **Plaintext.** The entry's fields and its `writer`, as a JSON object, padded.
- **Fields:** `suite`, `kv`, `nonce`, `ct`, `writer` and `sig`, with the signature as for envelopes.
- **Accepting.** Accepting an entry follows the envelope rules, except one case.
  - A client refuses an entry from a removed holder when it reaches it among new changes after it verified the removal.
  - One it reaches by paging back through older history, such as on a new device, it shows as written on a removed device.
  - History has no counter, since entries never change.
- **Deletions.** A client keeps the ids of entries with a `user` tombstone in `deleted_history` and refuses them if they come back. A policy tombstone does not count, so history comes back when the policy does (0051).
- **When.** Entries are encrypted at push time, not at capture, so a rotation never strands queued entries. Pushes are batched.
- **Old versions.** The AK ring opens them. History is never encrypted again (SYN C5), with one exception: an entry that comes back over a policy tombstone is pushed again, encrypted under the newest version, so a floor raised meanwhile holds (0051).

### Restore

- **On the server.** Key kinds are records, so a new epoch's refill covers them (0051). Refilled statements are verified like any append.
- **On the client.**
  - A refilled log shorter than a client's stored head is refused.
  - Clients publish the statements they hold above the server's head again, through 0051's restore path.
  - A holder that holds a key version whose wraps, ring or blob the server lost publishes them again or seals them again.

### Libraries

- **Rust: aws-lc-rs.**
  - It provides AES-256-GCM, HKDF-SHA256, Ed25519, SHA-256, HMAC, P-256 key import and the system RNG.
  - The AWS-LC 3 Cryptographic Module holds FIPS 140-3 certificate #5314.
- **Rust: HPKE.**
  - It comes from rustls 0.23.46 `crypto::aws_lc_rs::hpke::DH_KEM_P256_HKDF_SHA256_AES_256` on AWS-LC.
  - That module runs the RFC 9180 vectors but has no audit of its own, and G1 makes up for it with Wycheproof and the Go differential.
  - Its API has no `DeriveKeyPair`, which nothing here needs.
- **Rust: encoding.** `base64` in its strict mode and `serde_json` encode, and signed bytes are kept verbatim. The JWS compact framing, `LP`, Crockford Base32 and the word mapping are encodings, written in `tablepro-keys`.
- **Rust: not used.** RustCrypto's `hpke` (no audit), and `ed25519-dalek`, `p256` and `aes-gcm`, which reach the lock file only through russh. `ring` stays banned.
- **Go.**
  - The standard library's `crypto/ed25519` and `crypto/sha256`. Trail of Bits audited Go's cryptography in 2025, and the Go Cryptographic Module holds CMVP certificate #5247.
  - `encoding/base64` with `Strict()`, so it refuses non-zero pad bits as the Rust side does.
  - `crypto/hpke` (Go 1.26) is used only in differential tests. go-jose stays for licenses. The server decrypts nothing.
- **Ed25519 validity.** aws-lc-rs and Go both refuse a non-canonical S. Validity rules still differ between Ed25519 libraries (Chalkias, Garillot and Nikolaenko, 2020), so the edge-case vectors below must get the same answer from both.
- **Word list.** The EFF large word list, 7,776 words, CC BY 3.0 US. `deny.toml` gains `CC-BY-3.0`, and the notices credit it.

### Vectors that `tablepro-keys` ships

They are JSON in `core/crates/keys/vectors/`, one file per area. Every random input (keys, nonces, `r_I`, `r_R`, S) is an input of the case, so each output is fixed. HPKE encapsulation draws its own ephemeral key, so our wrap cases run the open direction plus a seal-then-open round trip.

- **Standard vectors:**
  - the CFRG HPKE vector set that rustls runs (`rfc-9180-test-vectors.json`), for suite (0x0010, 0x0001, 0x0002);
  - Wycheproof for AES-GCM, Ed25519, ECDH P-256 and HKDF-SHA256.
- **Our known answers:**
  - recovery key text, checksum and parsing: lower case, `I`, `L` and `O`, hyphens, spaces;
  - `K_rw` and the blob, with its hash;
  - `kid`;
  - every wrap purpose and recipient type;
  - rings;
  - envelopes for each secret kind and at each padding boundary (63, 64 and 4,096 bytes, and 4,097), with their counters;
  - writer signatures on envelopes and history entries;
  - history entries;
  - every statement type of every log, with its hash, chains, endorsements, and the device set, signer set and confirmed members at each step;
  - commitments, the words for both comparisons, and the QR text;
  - DPoP proofs and their thumbprints;
  - the state file MAC over the key tables, in 0054's layout.
- **Negative vectors**, each with the error code it must produce:
  - **Framing:** an unsigned statement, a wrong `typ` or `alg`, an extra header member, duplicate JSON members, a non-canonical base64url character, and an integer with a sign, fraction or exponent.
  - **Chains:** a statement badly chained, or out of order with `dh` or `ih`; a `dh` that goes back; a fork and a rollback; a fork resolution by a key that is not in force or by a replaced IK; a `rotate` that tries to end a fork where either branch holds a `replace`, `reset` or `activate`; a version that reuses one a fork burned; a `dh` or `ih` whose hash differs from the other log's statement at that `seq`.
  - **Device log:**
    - an `add` not signed by its `by` holder, and an `add` by a holder a `rotate` removed;
    - an `add` at `dh.seq + 1` by a holder the `rotate` at `dh` names;
    - a `rotate` that leaves in a holder its named holders approved, including one whose approver signed out first;
    - removing the first device from a device it approved, through a fresh holder in the same chain, which must be taken.
  - **Resets:** a `reset` without an endorsement; one by a holder outside a non-empty set; an `activate` before 7 days, after a `cancel`, or from another holder; a pending holder writing anything but its blob and `activate`; a `cancel` from a holder on a removed row that the logs list, which must be taken; a statement by the old IK after a pending reset, which must cancel it; and a ring that reaches below a `fresh` reset.
  - **Replace:** a `replace` without the new IK's endorsement, and a statement by the replaced IK after it.
  - **Team log:**
    - a team statement signed by a holder outside the signer's device set, or with an old holder and the newest `ih`;
    - a statement by a signer after its own reset, before a new `signer_add`;
    - a `confirm` and a `key` by a holder a later `rotate` names, which must be voided;
    - a `key` sealed to a revoked SK, and one naming a stale `ih` for a member;
    - adding a signer or removing another with fewer than k = min(2, n) approvals, and, at n = 2, one signer adding a third or removing the other alone without the time lock;
    - a reset or a server hint that lowers n or k;
    - an `approve` of a lapsed or withdrawn proposal, and one whose conditions no longer hold where it reaches k;
    - a `signer_remove_complete` before 7 days or after a `signer_remove_cancel`, a cancel from a holder outside the target's device set, and a time-locked removal of the last signer started by someone not an owner or admin;
    - `remove_member` of a signer, and `reroot` while a signer is left;
    - a `remove_member` and a team `genesis` signed by a holder a later `rotate` names, which stay in force, and a `confirm` by that holder, which is voided;
    - a `reroot` once the last signer removed itself, which must be taken, and one after the last signer reset or has an empty device set, which must be refused until a time-locked removal of it completes;
    - a `signer_remove_cancel` from a holder on a removed row, and from a target with no team seat, both taken;
    - one log replayed by two clients with different first-seen times, which gives one signer set; a completion whose `after` differs from the record; and a grant signed again without a comparison although first seen after the stated loss;
    - a thief's self-removal of one of two signers, and its `approve` of a removal among three, which stay after the device is removed;
    - a fork re-pin that moves an anchored device from a dropped `replace` branch, and the `rotate` after it with versions above every branch;
    - a team `resolve` whose branch removed a signer and counts k there, one that drops a cancel, and one that drops a revocation not signed again;
    - a revocation whose signer's admission a later voiding takes away, which stays;
    - a restored `reset` and `activate` taken under the reset's original receipt, a restored start without its receipt, whose wait starts again, a receipt under a key no cross-certification links to a pinned one, a cross-certification by a key that was not pinned, and two receipts for one statement with different times;
    - the last signer's own account starting its removal after its `activate`;
  - **Keys:** a swapped SK, and a `kid` mismatch after unwrap.
  - **Recovery:** a blob with the wrong origin, account or `rk_v`, and a recovery key with a bad checksum or the wrong length.
  - **Comparisons:** an `r_I` that does not open its commitment, a commitment over another `m_I`, and words that do not match.
  - **Envelopes:**
    - a stale key version and an unknown suite;
    - a wrong AAD for each AAD field;
    - a sealed destination mismatch;
    - an envelope replayed with a lower or equal (`kv`, `n`), or with another ciphertext;
    - an envelope by a removed holder that the client did not already hold;
    - a team envelope from an unconfirmed or removed member;
    - a counter pushed high, then cleared by the next version.
  - **Floors:** a floor raised from v to v+1, with a write under v refused and one under v+1 taken.
  - **State:** a stale file whose anchor is intact, which rebuilds from the logs without a comparison and takes only what extends the anchor or the pending checkpoint; and a file with no anchor, which accepts no log, wrap or envelope until a re-pin (0054).
  - **Ed25519 edge cases:** small-order points, a non-canonical R or A, and S at or above L.
- **Go side.** The cloud repository copies the vectors through its update script (S3K). It verifies every statement, device set, team log and DPoP vector in Go, and opens every wrap with Go's `crypto/hpke`.

### Formal model and review

**Formal model.** `core/docs/security/models/` holds Tamarin theories for these flows:

- genesis with S;
- approval from a device, with the commitment, and with S;
- removal with rotation, including a holder that signed out;
- recovery from zero devices, ending with its `rotate`;
- Replace Recovery Key;
- a reset with a holder, and with no holder left, each with its delay and cancel;
- a TK seal and member confirmation;
- member removal with the floor;
- a signer's own removal and reset, and a time-locked removal with its cancel;
- removing device rows during a pending reset;
- ending an account fork, with and without an identity change on a branch, and a team fork;
- a restore that loses the tail of a log.

**Claims the model must pass:**

- the secrecy of AK and TK versions after a removal, against a removed holder working with the server;
- the authenticity of IK on recovery;
- that no TK version is sealed to an SK the sealing signer has verified as revoked. The model shows the stronger claim fails: a server that withholds a member's `rotate` from a signer gets the next TK sealed to the old SK. The threat model lists it;
- injective agreement on device approval and member confirmation, with each side's view fixed before its random value;
- refusal of rollback through chained heads;
- that no holder a removed holder approved, directly or not, receives a later key version;
- that no account a removed holder confirmed, and no signer it added, receives a later TK version;
- that no reset takes effect without S, or without the full delay with no cancel, and that removing device rows never takes the cancel away from a holder the logs list;
- that no time-locked removal completes after the server refused a cancel from a holder the target's logs list, or within 7 days of its start by the log's recorded times;
- that no signer is added, and no signer removed by another, with fewer than k = min(2, n) approvals unless a time-locked removal ran 7 days without its target's cancel, so one signer never takes a team of two or more alone, and no re-root takes effect while a signer is left;
- that no removed member receives a TK version after the device that removed it is removed, and that voiding never undoes a revocation;
- that no team `resolve` drops a cancel or a revocation, or counts k lower than at the fork point;
- that an old S after a `replace` can extend no log a client that verified the `replace` follows, nor end a fork against it;
- that no reset a server made up lowers k or opens a `reroot`;
- that a removed holder cannot pin an envelope counter past the next version.

**Gates.** G0 reviews this ADR, the threat model and the model's results before any key code, and gates 0051's kind table and its OpenAPI with them (F15). G1 reviews the crate against the vectors, with at least an hour of cargo-fuzz per parser. G3 runs a hostile-server suite before any release. No text says a third party verified this design.

## Rationale

- **The identity under the recovery key.**
  - The identity key never sits on a device, so a stolen device cannot sign a successor identity. A reset made without S waits 7 days, and any device or S can stop it.
  - Recovery gets an anchor the server cannot forge, and teammates see nothing when a device goes.
  - The cost is entering the recovery key to remove a device, and D6 already makes everyone hold one.
  - This follows Matrix's master and self-signing split and Apple's Advanced Data Protection recovery key.
- **Holder keys instead of an account-wide signing key.** A key that every device holds cannot say which device signed. With holder keys, a removal takes away exactly what the removed device approved, granted and wrote, as the device log already does for approvals. A removal it signed stays, since revoking that would let a thief undo it. The cost is that teammates read each member's device log.
- **Symmetric scope keys with HPKE wraps.**
  - Envelopes are AEAD under keys only holders and members have, so a server that knows every public key still cannot mint one.
  - This is the 1Password and Bitwarden composition with the fixes ePrint 2026/058 proposes: authenticated encryption only, key separation, all plaintext authenticated, and public keys authenticated.
- **Committed key ids instead of signing each wrap.** A recipient checks the unwrapped key against a signed commitment. That binds the key itself, so a wrap needs no signature of its own and a server-made wrap only fails.
- **Hash chains and heads in every comparison.** One comparison checks both the keys and that both sides see one history (Tailnet Lock, Keybase), and device approval carries the team checkpoints too. Key transparency would also catch split views, but it is still a draft.
- **A commitment in the comparison.** Without it, a server that controls both views wins with a birthday search. With it, five words leave one guess at 2^-64.6.
- **DPoP proofs checked against the signed set.** This uses the standard proof format and its checks rather than a header of our own. Binding the tokens is a later, separate step.
- **Lazy revocation, except for what a removed holder wrote.** A removed party already read what it could. New writes move to a new version, and only rotating database credentials revokes what it read. 1Password rotates nothing, and Apple's ADP protects what is written after a rotation. Envelopes a removed holder wrote are sealed again, since no client can tell when it wrote them. NIST SP 800-57 Part 1 asks for new keys and re-protected data after a compromise.

### Why not MLS

- **Wrong shape.** MLS gives forward secrecy and post-compromise security for message streams. RFC 9420 §3.2 states that for a new member, "messages sent before they were added to the group will not be accessible". A vault needs the opposite: a member added today reads secrets stored years ago.
- **Identity stays ours.** MLS assumes an Authentication Service outside the protocol (RFC 9420 §3), and the application decides which identities are acceptable (§5.3.1). That is the hard part here, and MLS would not do it.
- **Ordering.** Each Commit is premised on one epoch, and two Commits on one state conflict (RFC 9420 §14). That needs a sequencing service or online agreement our polling model does not have. Our create-only appends serialize only key statements.
- **No library has this shape.** We would still keep a key ring under an MLS epoch secret. So we reuse designs, not code: the 1Password, Bitwarden and ADP composition, Matrix's cross-signing split, and Tailnet Lock and Keybase sigchains for the logs.

## Consequences

- **A recovery key comes first** (decided). It is needed before any personal sync and before any team secret, since both need an identity. Team plaintext records need none.
- **Device approval and member confirmation need both devices online at once,** or in the same room for the QR code. An asynchronous member compare is not offered: it would need about 200 bits to resist the birthday search.
- **A lost device is removed only with the recovery key.** An admin's portal removal locks the device at once. The person's personal floor holds new secret and history writes in the local queue until they enter the key.
- **Removing a device also removes what it vouched for.** That covers the devices it approved and the grants it signed: members it confirmed, signers it added, keys it sealed. The app lists them, the person signs again the grants they recognize, and teammates compare again only for the rest. Removals it signed stay.
- **Recovery with S on a new device removes every other device,** which then joins again by approval.
- **A reset takes 7 days,** and any of the person's devices or S can cancel it. A replace takes effect at once, since S signs it.
- **Losing every holder and the recovery key loses the personal and history scopes on the server** (decided). The account starts again with a reset, which deletes those records when it takes effect, 7 days on.
- **A team whose last signer lost its keys or reset** loses it through a time-locked removal an owner starts, then is re-rooted by an owner, visibly, and every member confirms the new root. Owners' apps warn while a team has fewer than three signers.
- **Removing a signer that will not act** takes 7 days, and the signer can cancel it.
- **Team secrets wait during rotation pending** until a signer's app opens. Members keep reading under the versions they hold.
- **The server reads more than versions.** It reads the key-object fields its table lists, DPoP proofs, `kv` and `n`, and verifies the account and team logs. It reads no secret and no history.
- **An install that changes its API origin** (decided) is a new server for keys too, as it already is for tokens and the license (0047). People enroll again and devices seal the secrets they hold again. History written under the old origin is not readable there.
- **Teammates see each other's identity and device logs** through member bundles: device platforms and rows, when a person removed devices, and when they replaced or reset their recovery key.
- **The threat model's residual risks hold,** among them:
  - trust on first use at genesis, at a team's genesis, and after a no-holder reset;
  - split views and withholding;
  - a full rollback for a holder that pins again with S, or a restore of the state file together with its anchor;
  - a confirmed member writing a team secret with the server's help;
  - a new team key sealed to a member's old SK by a signer from whom the server withheld the member's `rotate`, until the member's app raises its alarm;
  - a malicious signer;
  - data under `tp1` key versions against a future quantum computer.
- **Docs.** The cloud repository's `SECURITY.md` links the threat model. No text claims third-party verification. Whether to commission an external audit is decided before end-to-end encryption leaves beta.

## Alternatives considered

- **`DeriveKeyPair` from the seed for the recovery pair** (0044, SYN C10). The pair is public, and base mode authenticates no sender, so the server can seal its own key to it. Writing `DeriveKeyPair` ourselves is also primitive code the library lacks.
- **The identity key on every device, with signed successors** (D7 option A). A stolen device plus the server can sign a competing successor, and the fix is only an alarm.
- **A sigchain signed by devices, with no identity key** (Keybase, Tailnet Lock). It is heavier, and needs signature weights to settle forks.
- **An account-wide signing key held by every device.** A removal cannot tell which statements the removed device signed, so a stolen signer's device could leave a confirmed puppet behind.
- **A reset that takes effect at once.** A stolen device alone would take the identity and lock out the person and their recovery key.
- **Sign Out removing the devices it approved.** The maintainer chose against it on 2026-11-25. An honest sign-out of an old laptop would drop the new laptop it approved, and it would still not revoke the shared SK, which D7 keeps from rotating at sign-out. Removal with S takes a planted device out instead.
- **One signer adding signers alone, or k = min(2, n - 1).** One signer could add accounts of its own and then remove every other signer. Under min(2, n - 1) a team of two falls to one signer in two steps: it adds a puppet alone, and the two remove the honest signer. The maintainer chose the same k for additions as for removals, and k = min(2, n) enforces it.
- **Replace Recovery Key keeping IK.** The old S would stay a master key wherever the old blob survives.
- **Signing `(enc, ct)` on each wrap** (SYN C2). Checking the unwrapped key against a signed commitment gives the same protection, and the recipient list stays in the `key` statement.
- **Five or eight words with no commitment** (0044, SYN C8). A server that controls both views finds matching words by a birthday search: 2^32 work at 64 bits and 2^52 at 103 bits.
- **Signal-style fingerprints per party, compared without a session.** Each side is then a second-preimage search, but 103 bits per side means 16 words to read.
- **Re-encrypting every envelope and all history on a removal** (0044). It protects nothing the removed party had not already read, and it is O(history) work. Only envelopes the removed holder wrote are sealed again.
- **A manifest of every old envelope in each rotation.** It would also protect a holder that pins again with S, but it grows with every secret and with history, and needs the rotating device to hold all of it.
- **Members pinning each other** (0044). Only signers seal team keys, so a star is enough, and pairwise pins cost O(n²) comparisons.
- **One owner, with a support re-root** (SYN C9). That makes TablePro staff an authority over team trust (D15).
- **Endpoints of their own for key objects.** A second cursor and a second restore story, where records reuse the one log.
- **A password-derived key.** It brings back the KDF downgrade attacks of ePrint 2026/058, and sign-in already happens through the IdP.
- **X25519 for the KEM.** It is fine cryptographically, but rustls drops X25519 HPKE suites under its `fips` feature, while P-256 stays.

## Sources

- RFC 9180, HPKE: https://www.rfc-editor.org/rfc/rfc9180.html
- RFC 5869, HKDF: https://www.rfc-editor.org/rfc/rfc5869.html
- RFC 8032, EdDSA: https://www.rfc-editor.org/rfc/rfc8032.html
- RFC 7515, JWS; RFC 7517, JWK; RFC 7518, JWA; RFC 7638, thumbprints; RFC 8037, OKP keys: https://www.rfc-editor.org/rfc/rfc7515.html, https://www.rfc-editor.org/rfc/rfc7517.html, https://www.rfc-editor.org/rfc/rfc7518.html, https://www.rfc-editor.org/rfc/rfc7638.html, https://www.rfc-editor.org/rfc/rfc8037.html
- RFC 9864, fully specified JOSE algorithms: https://www.rfc-editor.org/rfc/rfc9864.html
- RFC 8725, JWT best current practices: https://www.rfc-editor.org/rfc/rfc8725.html
- RFC 9449, DPoP: https://www.rfc-editor.org/rfc/rfc9449.html
- RFC 9420, MLS: https://www.rfc-editor.org/rfc/rfc9420.html
- RFC 6189, ZRTP, §4.4.1.1 hash commitment: https://www.rfc-editor.org/rfc/rfc6189.html
- RFC 6962, Certificate Transparency, §3.2 signed certificate timestamp: https://www.rfc-editor.org/rfc/rfc6962.html ; RFC 3161, time-stamp protocol: https://www.rfc-editor.org/rfc/rfc3161.html
- RFC 4648 (§3.5, §5, §6), RFC 6454, RFC 9562, RFC 8259, RFC 2104
- NIST SP 800-38D (GCM, §8.3), SP 800-38A (Appendix A), SP 800-57 Part 1 Rev. 5 (key management), FIPS 180-4
- S. Vaudenay, "Secure Communications over Insecure Channels Based on Short Authenticated Strings", CRYPTO 2005; S. Pasini and S. Vaudenay, "SAS-Based Authenticated Key Agreement", PKC 2006
- Matrix SAS verification: https://spec.matrix.org/latest/client-server-api/#short-authentication-string-sas-verification
- Bitwarden emergency access, wait time and rejection: https://bitwarden.com/help/emergency-access/
- Matetic et al., "ROTE: Rollback Protection for Trusted Execution", USENIX Security 2017, as 0054 applies it
- Albertini, Duong, Gueron, Kölbl, Luykx, Schmieg, "How to Abuse and Fix Authenticated Encryption Without Key Commitment", USENIX Security 2022
- Len, Grubbs, Ristenpart, "Partitioning Oracle Attacks", USENIX Security 2021
- Chalkias, Garillot, Nikolaenko, "Taming the many EdDSAs", SSR 2020
- Scarlata et al., ePrint 2026/058: https://eprint.iacr.org/2026/058
- Crockford Base32: https://www.crockford.com/base32.html
- EFF large word list: https://www.eff.org/deeplinks/2016/07/new-wordlists-random-passphrases
- draft-ietf-hpke-pq: https://datatracker.ietf.org/doc/draft-ietf-hpke-pq/ ; draft-ietf-keytrans-protocol: https://datatracker.ietf.org/doc/draft-ietf-keytrans-protocol/ ; NIST IR 8547: https://csrc.nist.gov/pubs/ir/8547/final
- Tailscale TKA: https://github.com/tailscale/tailscale/blob/main/tka/aum.go ; Matrix cross-signing: https://matrix.org/docs/older/e2ee-cross-signing/ ; Apple Advanced Data Protection: https://support.apple.com/guide/security/advanced-data-protection-for-icloud-sec973254c5f/web ; 1Password: https://agilebits.github.io/security-design/ ; Bitwarden trusted devices: https://bitwarden.com/help/about-trusted-devices/
- CMVP #5314 (AWS-LC 3) and #5247 (Go): https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/5314 , https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/5247 ; Go audit: https://go.dev/blog/tob-crypto-audit
- Tamarin prover: https://tamarin-prover.com
