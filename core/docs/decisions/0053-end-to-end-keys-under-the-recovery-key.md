# 0053: End-to-end keys: the identity under the recovery key, signed logs, envelopes, removal and recovery

- **Status**: Accepted; amends 0044 (Secrets)
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
- **D15.** Any owner or admin signs team trust. Removing a signer needs k = min(2, n-1) signers, and a signer may always remove itself. A team re-root happens only when no signer is left, is visible to every member, and support can never perform it.
- **Linux without a keyring** gets team records only.
- **Review.** No external audit now. Whether to commission one is decided before end-to-end encryption leaves beta.
- **Consequences accepted the same day:** team secrets need the recovery key; an account with no holder and no recovery key left resets after the server deletes its personal and history records; changing the API origin loses the history written under the old one.

The threat model is [`core/docs/security/sync-threat-model.md`](../security/sync-threat-model.md). The formal model is in `core/docs/security/models/`.

## Decision

Secrets and history are encrypted with AES-256-GCM under per-record HKDF subkeys of symmetric account and team keys. Those keys reach devices and members only through HPKE wraps, and a recipient checks each unwrapped key against a hash-chained, Ed25519-signed log. The account's logs are anchored in an identity key that lives only inside a blob sealed under the person's recovery key. Devices join through a short authenticated string compared with a hash commitment, and the server refuses personal data to any device key outside the signed device set. This replaces 0044's Secrets section except its device stores, typed references and iCloud Keychain rules, and its end-to-end Tests line.

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
  - A record id is the UTF-8 of its canonical wire text (0052).
  - The origin is the API origin as 0047 compares it, in its ASCII serialization (RFC 6454 §6.2).
- **Scope.** `scope` in a crypto input is `LP(type) || LP(owner)`: `personal` or `history` with the account id, or `team` with the team id. It names ids that signed statements carry, never the server's row id for the scope.
- **Keys.** An Ed25519 public key is its 32 bytes and its private key is the 32-byte seed (RFC 8032 §5.1.5). A P-256 public key is the 65-byte uncompressed point and its private key the 32-byte scalar (RFC 9180 §7.1.1, §7.1.2).
- **Text.** JSON and JWS use base64url without padding (RFC 4648 §5). A head is `head = u64(seq) || LP(hash)`.
- **No JSON in crypto inputs.** Every AAD, HKDF `info`, HPKE `info` and hash input is a concatenation of `LP` fields and fixed-width integers that starts with `LP(label)`. JSON is never one of them. The one exception is a signed statement, whose JWS bytes are signed and hashed exactly as received.

**Labels.** Each use has its own label, so no two uses share an input.

| Label | Use |
|---|---|
| `tablepro/v1/key-id` | Key commitment |
| `tablepro/v1/recovery-checksum` | Checksum of the recovery key's text |
| `tablepro/v1/recovery-wrap` | The recovery blob's key |
| `tablepro/v1/recovery` | The recovery blob's AAD |
| `tablepro/v1/recovery-blob` | The recovery blob's hash |
| `tablepro/v1/wrap` | HPKE `info` of every wrap |
| `tablepro/v1/ring-key`, `tablepro/v1/ring` | A key ring's subkey and AAD |
| `tablepro/v1/envelope-key`, `tablepro/v1/envelope` | An envelope's subkey and AAD |
| `tablepro/v1/envelope-writer` | A team envelope's writer signature |
| `tablepro/v1/history-key`, `tablepro/v1/history` | A history entry's subkey and AAD |
| `tablepro/v1/sas-commit` | A comparison's commitment |
| `tablepro/v1/device-approval` | Device approval words |
| `tablepro/v1/member`, `tablepro/v1/member-qr` | Member confirmation words and QR code |
| `tablepro/v1/state` | The state file's MAC |

**Key commitment.** For any symmetric key K, `kid(K) = HKDF-SHA256(salt = none, IKM = K, info = LP("tablepro/v1/key-id"), L = 32)`.

- Every signed statement that introduces a symmetric key names its `kid`. A recipient recomputes it after unwrapping and refuses a mismatch.
- AES-GCM does not commit to its key (Albertini et al., USENIX Security 2022; Len, Grubbs and Ristenpart, USENIX Security 2021), so without this a server could hand out a wrap that opens to a key of its choice.
- The `kid` is 32 bytes, not 16. A signer who generates a key could otherwise search for two keys with one `kid` at about 2^64 work.
- Asymmetric keys are committed by their public keys, which statements carry in full.

**Padding.** Every plaintext under AES-256-GCM, except the fixed-size recovery blob, is padded with ISO/IEC 7816-4 padding: 0x80, then zero bytes. That is method 2 of ISO/IEC 9797-1, the bit padding of NIST SP 800-38A Appendix A.

- The padded length is the smallest of 64, 128, 256, 512, 1,024, 2,048 and 4,096 that holds the plaintext plus one byte. Past 4,096 bytes it is the next multiple of 4,096.
- A reader removes the padding only after the AEAD opens, so no padding check runs on unauthenticated data. RFC 9180 §9.7.6 asks applications to pad.

**Signed statements.**

- They are JWS compact (RFC 7515 §7.1). The protected header is exactly `{"alg":"Ed25519","typ":<type>}` (RFC 9864 §2.2).
  - A verifier requires exactly that `alg` (RFC 8725 §3.1) and the expected `typ` (RFC 8725 §3.11).
  - It refuses any other header member, and duplicate member names in the header or the payload. Go's and Rust's JSON parsers treat duplicates differently, so both refuse them, and the server and the apps never read one statement two ways.
- Licenses keep `EdDSA`. RFC 9864 deprecates it for new uses.
- **Bytes.** A signature covers the exact signing input received. Nothing is signed after being serialized again. A statement's hash is SHA-256 over its JWS compact bytes as received.
- **Payload.**
  - Every payload carries `v: 1`. A client refuses a `v` or an `op` it does not know, and refuses an unknown member within a known one. A statement that a client cannot read stops that log for the client, which then asks for an update.
  - Integers are JSON numbers below 2^53.
- **Types** are `tablepro-identity+jws`, `tablepro-device+jws`, `tablepro-team+jws`, `tablepro-request+jws` and `tablepro-reset+jws`.

### Keys

| Key | Type | Private half lives | Certified by | Rotates when |
|---|---|---|---|---|
| Recovery seed S | 256-bit random | On paper or in a password manager only | n/a | Replace Recovery Key, reset |
| Identity key IK | Ed25519 | Only inside the recovery blob. In memory during genesis, removal, recovery or replacement, then zeroized | Itself, through the blob; pinned by own devices at approval and by signers at confirmation | Reset only |
| Recovery wrap key RK, `rk_v` | HPKE P-256, random | Only inside the recovery blob | IK, identity log | Replace Recovery Key, reset |
| Account signing key ASK, `ask_v` | Ed25519 | Wrapped to each holder and to RK | IK, identity log | Device removal, reset |
| Sharing key SK, `sk_v` | HPKE P-256 | Wrapped to each holder and to RK | IK, identity log | Device removal, reset |
| Account key AK, `ak_v` | 256-bit symmetric, versioned ring | Wrapped to each holder and to RK. Older versions sit in the ring under the newest | IK names each version's `kid` | Device removal, reset |
| Holder keys | HPKE P-256, plus a signing key | The device store only, never synced | The device log | Never. A new holder is a new key set |
| Team key TK, `tk_v` | 256-bit symmetric, versioned ring per team | Wrapped to each confirmed member's current SK | A signer's ASK, team log | Member removal, SK revocation, a member's rotation |

- **Key holders.** A key holder is one key store under one server device row. A Linux host build and its Flatpak, two Windows data folders, or a cloned image are separate holders under one row, and the device cap counts rows. A holder belongs to (origin, account, device row).
- **Device stores.**
  - Keychain items with `ThisDeviceOnly` that do not sync.
  - Credential Manager with `CRED_PERSIST_LOCAL_MACHINE`.
  - A Secret Service item.
  - A Linux device without a keyring cannot hold a key holder. It syncs team plaintext records and nothing personal, and it reads no team secret.
- **Host trait.** The holder's signing key sits behind a host trait and is published as a JWK (RFC 7517) in the device log: `{"kty":"OKP","crv":"Ed25519","x":...}` (RFC 8037). A hardware P-256 key in the Secure Enclave or a TPM can later sign as ES256 with no change to the log format. Its thumbprint is the RFC 7638 thumbprint over the members RFC 8037 §2 names.
- **Where key objects live.** An account's key objects sit in its personal scope on the service even when the device's personal provider is iCloud or Off. Team secrets need an identity, and the identity lives there.
- **Versions** count from 1 and only grow, across resets too.
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

**Why it is an anchor.**

- Only someone holding S can produce a blob that opens, since AES-GCM is an authenticated cipher and K_rw comes from S. So the IK inside an opened blob is the person's.
- A recovering device trusts no other key until it has checked it against a statement that IK signs.
- AK, ASK and SK are HPKE-wrapped to RK's public half, which any device can seal to without the seed. A server that seals a key of its own to RK gains nothing: the key's `kid` or public key does not match the IK-signed log. That closes the gap in 0044's recovery.
- This is the wrapped-private-key pattern of 1Password's recovery and Matrix's secret storage, and needs no `DeriveKeyPair`.

**Opening.** A client opens only the blob whose `rk_v` the newest RK statement names, and only one whose hash matches. It then checks three things:

- the IK in it equals the IK of the newest `genesis` or `reset`;
- its RK equals the RK of the newest RK statement;
- the whole identity log verifies under it.

A replaced recovery key no longer opens the account in an honest client.

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

**Identity log.** Kind `key.identity`, type `tablepro-identity+jws`. Teams read it through member bundles.

| `op` | Members | Signed by |
|---|---|---|
| `genesis` | `ik`, `rk`, `rk_v`, `blob`, `ask`, `ask_v`, `sk`, `sk_v`, `ak_v`, `ak_kid`, `holder` | The `ik` it names |
| `rotate` | `removed` (holder ids), `ask`, `ask_v`, `sk`, `sk_v`, `ak_v`, `ak_kid`, `dh` | The current IK |
| `recovery` | `rk`, `rk_v`, `blob` | The current IK |
| `reset` | `ik`, `rk`, `rk_v`, `blob`, `ask`, `ask_v`, `sk`, `sk_v`, `ak_v`, `ak_kid`, `holder` with its `row`, `platform`, `hpke` and `sig`, `dh` | The new `ik` it names |

- `dh` is the device log's head (`seq`, `hash`) when the statement was made.
- Each version in a statement is the previous one plus 1.
- `genesis` appears only at `seq` 0.
- A `rotate` names only holders in the device set at its `dh`, and it must name every holder in that set that a named holder approved, directly or through other approvals. A `reset` names a holder in that set, or any holder when the set is empty (Flows, Reset).
- A `reset` record also carries an `endorsement`: a `tablepro-reset+jws` signed by the named holder's signing key, whose payload names the reset's hash. Own devices can then tell a reset made on one of the person's devices from one the server made up.

**Device log.** Kind `key.device`, type `tablepro-device+jws`. It stays in the personal scope. Each statement also carries `ih`, the identity log's head when it was made.

| `op` | Members | Signed by |
|---|---|---|
| `add`, method `genesis` | `holder`, `row`, `platform`, `hpke`, `sig` (JWK) | IK; only at `seq` 0, for the holder `genesis` names |
| `add`, method `approval` | As above, plus `request` and `by`, the approving holder | The `by` holder's own signing key, never ASK, so every approval traces to one holder |
| `add`, method `recovery` | As for genesis | The current IK |
| `leave` | `holder` | That holder's own signing key. This is Sign Out |

**The device set** is replayed in order:

- an `add` puts a holder in and a `leave` takes it out;
- each `rotate` takes out the holders it names, once the device log passes its `dh`;
- each `reset` leaves only the holder it names, from the same point.

The server also leaves out holders whose device row an admin removed, and the holders those approved, as a hint the logs do not carry.

**Ordering rules between the two account logs.** These rules stop a removed device from adding a holder after the removal, and stop a holder it planted before the removal from surviving it, which counters alone do not (Tailscale TKA, SYN C3):

- A device statement's `ih` never goes back, and is at or after every `rotate` or `reset` whose `dh.seq` is below the statement's `seq`.
- An `add` by approval verifies under the signing key of its `by` holder, which is in the device set at `seq - 1`. A thief holding a stolen device can therefore approve holders only in the stolen holder's name.
- A `rotate` takes out the holders it names together with every holder they approved, directly or not, and the identity log's rules make it name them. Holders added by `genesis` or `recovery` are signed by IK and descend from nobody. An honest device that a stolen device approved before the theft joins again by approval or with S.
- A holder id is never added twice.
- The server takes `rotate`, `recovery` and `reset` only with `dh` equal to the current device head, and device statements only with `ih` equal to the current identity head. That is compare-and-set both ways, and a client whose append is refused pulls, then signs again.

**Team log.** Kind `key.team`, type `tablepro-team+jws`. Each statement carries `by`: the signer's `acct`, `ask_v` and `ih`. A verifier finds the signer's IK in the team log and the signer's identity statements in its member bundle. `ask_v` must be the ASK in force at `ih`, the one the newest `genesis`, `rotate` or `reset` at or before `ih` introduced, and `ih` never goes back for that signer. So a removed device that still holds an old ASK can neither claim the newest head nor, at any client that has seen the rotation, an older one.

| `op` | Members | Rule |
|---|---|---|
| `genesis` | `root`: `acct`, `ik`, `ih` | The first signer, an owner or admin in the server's roles. Signed by the root's ASK. The root counts as confirmed |
| `signer_add` | `who`: `acct`, `ik`, `ih` | The account is a confirmed member with that IK |
| `signer_remove` | `target` | Takes effect at once when `target` is `by`. Otherwise it opens a proposal named by its own hash |
| `signer_remove_approval` | `proposal` | The removal takes effect at the statement where the distinct signers other than the target, counting the proposer, reach `k = min(2, n - 1)`, with n the signers at that statement. A signer that is no longer one does not count |
| `confirm` | `member`: `acct`, `ik`, `ih` | After a comparison (below). Confirming a member again after a reset is allowed |
| `remove_member` | `acct` | Refused while the account is a signer. A signer leaves the signer set first, under k |
| `revoke_sk` | `acct`, `sk_v` | After a server hint that the person's device was removed, or a reset |
| `key` | `tk_v`, `kid`, `recipients`: a list of (`acct`, `sk_v`) | `tk_v` is the previous plus 1. Each recipient is a confirmed member, and `sk_v` is that member's current SK, not revoked |
| `grant` | `tk_v`, `recipients` | Adds recipients to an existing version under the same rules |
| `reroot` | `root`: `acct`, `ik`, `ih` | Only when the signer set is empty at that point. Signed by the root's ASK. Every member's app shows it, and trusts nothing after it until that member confirms again with the new root |

- **The signer set** starts as the root and changes only through `signer_add`, a removal that takes effect, and `reroot`.
- **Confirmed members** come from `confirm`, less those named by `remove_member`. A member whose identity log shows a `reset` is unconfirmed until a new `confirm` names the new IK.
- **A revoked SK** is one that `revoke_sk` names or that the member's own `rotate` or `reset` replaced.
- **What a signer can do.** One signer can confirm members and add signers, and k only limits removals. A malicious signer is therefore trusted with the team, and every statement it signs shows in every member's app. The threat model covers this.

**Member bundle.** Kind `key.member` in the team scope, writer-bound to the member's account, one record per statement. Each holds a verbatim copy of one identity statement, and the member's client copies each new statement into every team it is in. Teammates verify the chain under the IK their `confirm` pinned. A `rotate` signed by that IK gives them the person's new SK without a comparison (D7).

**What a client keeps.** Each holder keeps a state file with:

- every statement of the logs it follows;
- each log's head;
- its pins: its own identity head, and per team the team head and confirmed members;
- open comparisons and floors.

The file carries `HMAC-SHA256(key, LP("tablepro/v1/state") || LP(origin) || LP(account) || state)`, keyed by 32 random bytes in the device store, so a local writer without the device store cannot swap a pin.

**Rollback and forks.**

- A log the server presents must contain the stored head at its `seq` with the same hash. Otherwise it is refused as a rollback.
- Two valid statements at one `seq` of one log raise a fork alarm. Secret writes for that account or team stop. The app shows both branches and who signed them, and writes resume once the person removes the devices behind the other branch with S, or signers remove the member or signer behind it.
- **Observing a removal.** Team statements by a signer whose identity log has rotated or reset are refused when they name an `ih` older than one the client had already verified before it received them. Writers pull before they push and sign again any statement made under a key they have since rotated away from.
- **The limit.** This is not key transparency (draft-ietf-keytrans-protocol). A server can show two devices two consistent histories. They notice only when they compare, and every comparison below covers the log heads.

### Key objects as records

Key objects are records of reserved kinds under 0051's record rules. Ids are writer-bound where the table says, and follow 0052's key-object grammar.

- **Create-only.** Every key kind except `key.wrap` and `key.ring` is create-only: a second create of one id is refused with `create_only`, which serializes two devices or two signers appending at once.
- **Replaceable.** The writer the table names may replace a wrap or a ring. A recipient checks every wrap anyway, so a wrap that a stolen holder squatted can be replaced after its removal.
- **Who may write.** Every write of a key kind carries a DPoP proof from a holder in the writing account's device set (Server enforcement), except the personal-scope writes allowed before approval. A phished session with no approved holder therefore writes no key object anywhere, and cannot squat a log position.

| Kind | Scope | Id parts | Writer-bound | What the server verifies |
|---|---|---|---|---|
| `key.identity` | personal | account, `seq` | account | The JWS framing, the chain, the signatures and every rule above. `genesis` only when the account has none. `reset` only from a holder in the device set, or any signed-in holder when the set is empty (below), with an endorsement that verifies under the named holder's key. Answers `bad_statement` |
| `key.device` | personal | account, `seq` | account | As for `key.identity`, and the holder's row is one of the account's device rows |
| `key.recovery` | personal | account, `rk_v` | account | Its hash is the `blob` an identity statement names for that `rk_v` |
| `key.request` | personal | request id | holder | Signed by the request's own signing key, which is the DPoP key. `exp` is in the future and at most 600 s after `iat`. One open request per holder |
| `key.sas` | personal, team | session id, step | the step's party | Its form. The request or the commit names the two parties, and each step comes from its party |
| `key.wrap` | personal, team | owner, purpose, version, recipient | the owner's account; in a team, the signer whose `key` or `grant` names the recipient | Its form, and the writer |
| `key.ring` | personal, team | owner, version | the owner's account; in a team, the signer of the `key` for that version | Its form, and the writer |
| `key.team` | team | team, `seq` | no | As for `key.identity`: the framing, the chain, that `by` is a signer at that point, the signature under the ASK in force at `ih` (read from `by`'s verified identity log), and every rule above. The writer's role is owner or admin. Answers `bad_statement` |
| `key.member` | team | account, `seq` | account | It equals, byte for byte, the account's `key.identity` record at that `seq` |

- The server reads key-object fields only as this table says, plus `kv` on `secret_envelope` and `history_entry` for floors (0051).
- `key.request` and `key.sas` records are purged after they expire. Every other key object stays until the scope is deleted.

### Comparing keys

Device approval and member confirmation compare a short authenticated string. The two devices exchange it through records, with a hash commitment that leaves an attacker one guess. Without the commitment, a server that controls both sides' views can search for two views with equal words: about 2^32 work for 64-bit words and 2^52 for 103-bit words. RFC 6189 §4.4.1.1 describes that birthday attack, and the commitment closes it (Vaudenay, CRYPTO 2005; Matrix's SAS verification; Apple's contact key verification).

**The exchange.** The initiator I and the responder R are both online, and both poll every 1-2 s while the sheet is open. Each step is a `key.sas` record named `commit`, `nonce` or `reveal` and written by its party's account, except that a device approval's commitment sits in its request, whose id is the session id. The steps need no signature, since the commitment and the comparison authenticate them.

1. `commit`: I picks a random 32-byte `r_I` and publishes `c = SHA-256(LP("tablepro/v1/sas-commit") || LP(session) || LP(r_I))`.
2. `nonce`: R, after it has `c`, publishes a random 32-byte `r_R`.
3. `reveal`: I, after it has `r_R`, publishes `r_I`. R refuses an `r_I` that does not open `c`.
4. Each side computes `d = SHA-256(LP(label) || ctx || LP(r_I) || LP(r_R))` from its own view of `ctx`. The words are the first five base-7776 digits of d read as a big-endian integer, least significant first, each picking a word of the EFF large word list.

- The person compares the five words on both screens and confirms on both.
- A session allows one comparison and expires 10 minutes after `c`. A mismatch ends it and is shown as a possible interception.
- An attacker who changes either side's view must commit before it sees the other side's random value, so it succeeds with a probability of 7776^-5, about 2^-64.6, per session.

**Device approval**, label `tablepro/v1/device-approval`. I is the new holder N, R the approving holder A, and the session is N's request.

`ctx = LP(origin) || LP(account) || LP(request) || LP(N's HPKE key) || LP(thumbprint of N's signing key) || head(identity) || head(device)`.

**Member confirmation**, label `tablepro/v1/member`. I is the signer G, R the member M.

`ctx = LP(origin) || LP(team) || LP(M's account) || LP(M's IK) || head(M's identity log) || head(team log)`.

- The comparison checks both directions at once: G's view of M's IK, and M's view of the team log. This is the star of SYN 1.3. Members never compare with each other.
- In person, M's device can instead show a QR code of `TPM1:` followed by the 52 Crockford Base32 symbols of `SHA-256(LP("tablepro/v1/member-qr") || ctx)`.
  - G's device scans it and shows whether it matches its own.
  - The full 256-bit digest leaves only a 2^128 collision search, so this path needs no commitment.
  - M confirms on M's device after seeing G's result.

### Flows

**Genesis**, on the first device of an account with no identity log.

1. The holder generates S, IK, RK, ASK, SK and AK v1 from the system RNG.
2. It shows the recovery key and asks the person to type back two groups chosen at random. Nothing is pushed before that, so a crash never leaves a blob that nobody can open.
3. It signs the identity `genesis` and the device `add` (method `genesis`) with IK, seals the blob, and seals AK, ASK and SK to RK.
4. It keeps the signed records in the state file. Records hold no secret. It then zeroizes S, IK and RK.
5. It pushes `genesis` first, then the blob, the `add` and the wraps, each after the one before applies.
   - The server takes `genesis` from any signed-in session with a DPoP proof while the account has none. That first enrollment is trust on first use.
   - If another device's `genesis` won, this one discards everything and asks for approval instead.

**Approving a device.** A new holder N and an approved holder A.

1. N writes `key.request`:
   - its holder id, device row and platform;
   - its HPKE key and its signing JWK;
   - the commitment, `iat`, and `exp` 600 s later;
   - signed by its signing key.
2. The person picks the request on A, and A writes the `nonce` step.
3. N writes the `reveal` step. Both show the words, and the person confirms on both.
4. A signs the `add` (method `approval`) with its own signing key and pushes it. Once it applies, A seals the current AK, ASK and SK to N's HPKE key.
5. N pins the heads it compared and accepts the `add` only if it extends them and verifies under A's signing key, as the pinned device log lists it.
6. N unwraps, checks every `kid` and public key, and reads the AK ring.

**Recovery with the recovery key**, on a holder with no approved device at hand.

1. The holder reads `key.identity`, `key.device` and `key.recovery`, which a holder outside the set may read.
2. The person types S. The holder opens the newest blob and makes the checks in Opening.
3. It signs its own `add` (method `recovery`) with IK, and pushes it. The server checks it under IK.
4. Now in the device set, it reads the wraps to RK and the rings. It unwraps, and checks every `kid` and public key against the IK-signed log.
5. It zeroizes S, IK and RK.

**Sign Out.** The holder pushes its `leave` when online, then erases its keys with a verified delete. Nothing rotates (SYN C4). Offline, it erases anyway. The holder then stays in the set until a removal names it, and nobody holds its keys.

**Removing a lost device** needs the recovery key (D7).

1. On any approved holder, the person picks the devices and enters S. The holder opens the blob.
2. It generates ASK, SK and AK v+1, and signs a `rotate` with IK. The `rotate` names the current device head and the removed holders, with every holder they approved. The app lists those before the person confirms, so a holder planted by a stolen device goes with it.
3. Once the `rotate` applies, it seals the new keys to every remaining holder and to RK, and writes AK ring v+1. It zeroizes IK and RK.
4. The app also removes the device row through the account (0016), which revokes its tokens.
5. The person's client copies the `rotate` into every team's member bundle.
   - Teammates see a new SK certified by the IK they pinned and accept it with no comparison (D7).
   - Each team enters rotation pending.

**Admin removal from the portal.** The browser has no keys.

1. The server revokes the device row's refresh family and marks its holders revoked. It raises the person's personal floor to the current AK version plus 1.
2. Envelope and history pushes wait in the local queue, and nothing is lost.
3. The person's next device asks: "Your admin removed device X. Enter your recovery key to finish." Finishing is the removal above.
4. Signer clients treat the server's hint as untrusted but safe. They sign `revoke_sk` and stop sealing to that SK. A false hint only denies team keys, and it shows.

**Replace Recovery Key**, when the old key is lost or the person wants a new one.

1. The person enters the current S. The holder opens the blob and makes a new S' and RK'.
2. It shows S' and has two groups typed back. It writes the blob for `rk_v + 1`, signs `recovery` with IK, and seals the current AK, ASK and SK to RK'.
3. The old S still opens the old blob wherever a copy survives, and that gives IK. So when the old key may have been seen, the app runs a reset instead.

**Reset**, when the recovery key is lost or may have been seen.

1. An approved holder H generates IK', S', RK', ASK', SK' and AK v+1, shows S' and has it typed back.
2. It signs a `reset` with IK', naming itself and the current device head, endorses it with its own signing key, and pushes it.
3. Then it pushes the blob, the wraps to RK' and AK ring v+1. The ring holds every older AK version, so history stays readable.
4. The device set becomes H alone.
   - The person's other devices see a reset made on one of their holders. They stop personal sync and join again by device approval from H. That comparison is the only way an own device accepts a reset.
   - Signers sign `revoke_sk` for the old SK. The person is unconfirmed until a signer confirms the new IK.
   - A stolen device plus the server therefore cannot take the identity over silently.
5. **No holder left.** On an account with no holder left in the device set and no recovery key, nothing tells the person from someone who took over the sign-in.
   - The server then takes a `reset` from any signed-in holder, as at genesis.
   - It first deletes every record in the account's personal and history scopes except the identity and device logs, as account deletion would. The reset still extends the logs, so teammates see it as a reset.
   - Devices that kept local data push it again after they join.

**Confirming a member.** A signer and the member compare (above). The signer then signs `confirm`, seals the current TK to the member's SK, and signs `grant`, or `key` when rotation is pending.

**Removing a member.**

1. The server raises the team floor to the current TK version plus 1.
2. The first signer client to open signs `remove_member`, then a `key` for TK v+1 sealed to every confirmed member with an unrevoked SK, then TK ring v+1.
3. "Credentials to rotate" lists the database credentials the removed party could read.

**Rotation pending.** A team is pending after:

- a `remove_member` or a `revoke_sk`;
- a member's `rotate` or `reset`;
- the server raising its floor.

The first signer client that sees it signs the next `key` and seals it to current, unrevoked SKs only. Two signers racing are serialized by `create_only`, and the loser discards its key. A client pushes a statement alone and waits for it to apply before it pushes the wraps and the ring that depend on it.

### Server enforcement (D8)

This is an honest-server control against account takeover. A malicious server is covered by the client checks above.

**Every call on a personal or history scope, and every write of a key kind or a `secret_envelope` in any scope, carries a DPoP proof** (RFC 9449 §4.2):

- `typ` `dpop+jwt`, `alg` `Ed25519`, and `jwk` with the holder's signing key;
- `jti`, `htm`, `htu` (no query or fragment), `iat`;
- `ath`, the base64url SHA-256 of the access token;
- `nonce` once the server has sent one.

The server checks it as RFC 9449 §4.3 lists. Check 12's key binding becomes one rule: the key's thumbprint is a holder in the account's current device set, on the device row of the token's refresh family. In a team scope that is the writing member's own device set. In detail:

- `iat` is at most 300 s old and at most 60 s ahead.
- Each `jti` is kept, hashed, for 360 s in a Postgres table, since several tasks serve (RFC 9449 §11.1).
- On clock skew the server answers `use_dpop_nonce` with a `DPoP-Nonce` (RFC 9449 §9).
- A refusal is 403 `device_not_approved`.

**Tokens stay bearer tokens.** Binding them at the token endpoint with `cnf.jkt` (RFC 9449 §6) is later hardening, and RFC 9449 §7.2's rule for bound tokens does not apply yet.

**The device set** is what the server derives by verifying the identity and device logs on every append with Go's `crypto/ed25519`, less the holders of device rows an admin removed and every holder those approved. An append that does not verify is refused.

**Before approval**, a holder outside the set may only:

- read `key.identity`, `key.device` and `key.recovery`, its own `key.request`, and the `key.sas` steps of its own request;
- write its `key.request` and the `reveal` step of that request;
- write an `add` (method `recovery`) that verifies under the current IK and names its own DPoP key;
- while the account has no identity log, or has one with an empty device set, write the genesis or reset records naming itself.

**Floors.** Each personal and team scope has a floor: the lowest key version a new envelope or history entry may use. Flows says when it rises. An honest server refuses a `kv` below it with `key_version_stale`. After a removal raises it from v to v+1, a write under v is refused, one under v+1 is taken, and the writes queued meanwhile go out once the rotation lands.

### Key holders and sessions

A key holder belongs to (origin, account id, device row id), not to a session (F5).

- **It survives:**
  - session expiry, including the 10 h cap with SAML;
  - a lost or refused token;
  - a failed deprovisioning revalidation.
- **It resumes without approval** when the same account signs in again on the same device row, since its key is still in the device set.
- **Its keys are erased**, with a verified delete, on exactly four events:
  - Sign Out;
  - a verified `rotate` that names it;
  - a server revocation of its device row, which fails closed;
  - a different account signing in on that device row (DEC:127).
- A reset that leaves it out stops its personal sync until it is approved again, but erases nothing.
- **Tests:** one test per erase event, and one per event it survives.

### Wraps and rings

**A wrap** is a `key.wrap` record: `(enc, ct) = SealBase(pkR, info, aad = "", pt)` (RFC 9180 §6.1), where:

- `info = LP("tablepro/v1/wrap") || LP("tp1") || scope || LP(purpose) || u32(version) || LP(recipient type) || LP(recipient id) || u32(recipient version)`;
- `purpose` is `account-key`, `account-signing-key`, `sharing-key` or `team-key`;
- the recipient type is `holder` (the holder's id, version 0), `recovery` (the account, `rk_v`) or `member` (the account, `sk_v`), spelled as in the record id (0052);
- `pt` is the 32-byte key, seed or scalar;
- the fields are `suite`, `purpose`, `version`, `recipient`, `enc` and `ct`.

Context goes in `info`, as RFC 9180 §8.1 advises. After `Open`, the recipient checks:

- a symmetric key's `kid`;
- that the ASK seed's Ed25519 public key, or the SK scalar's P-256 public key computed with aws-lc-rs, equals the key the signed statement names.

The wrap itself is not signed. Base mode does not authenticate a sender, and a server can seal anything to a public key. The signed commitment is what makes a substituted key fail, and it binds the key itself rather than the ciphertext.

**A ring** is a `key.ring` record for version v ≥ 2 of AK or TK. It holds every older version:

- plaintext `u32(1) || K_1 || ... || u32(v-1) || K_{v-1}`, padded;
- the subkey `HKDF-SHA256(salt = none, IKM = K_v, info = LP("tablepro/v1/ring-key") || scope || u32(v), L = 32)`;
- `AAD = LP("tablepro/v1/ring") || LP("tp1") || scope || u32(v)`.

A reader checks each `K_i` against the `kid` the log names for version i. A device joining later gets the newest wrap and the ring, and so reads every secret stored before it joined. That is the vault behavior.

### Envelopes

**One record per (record, secret kind).** A `secret_envelope` exists for each parent record and secret kind, and is conditional on its change tag like every record (0051).

- **Subkey.** `k = HKDF-SHA256(salt = none, IKM = K_v, info = LP("tablepro/v1/envelope-key") || scope || LP(record id) || LP(secret kind), L = 32)`.
  - K_v is an AK version in the personal scope and a TK version in a team scope.
  - A subkey per record keeps random nonces far below the 2^32 messages per key that NIST SP 800-38D §8.3 allows.
- **AAD, immutable ids only.** `LP("tablepro/v1/envelope") || LP("tp1") || scope || LP(parent kind) || LP(record id) || LP(secret kind) || u32(kv)`.
- **Plaintext.** A UTF-8 JSON object (RFC 8259), then padded:
  - `v`: 1;
  - `secret`;
  - `dest`: the sealed destination;
  - `n`: the envelope's counter, one more than the counter of the envelope it replaces, from 1;
  - `writer`: account and holder;
  - `sealed_at`;
  - `cleared`, true when the secret was removed. A secret is cleared with the next counter, never by deleting its envelope.

  A reader refuses an unknown `v`. The sealed destination is the destination fields the K3 wire schema names per secret kind: engine, host, port, user, database, SSH route, TLS mode, CA and certificate paths, and the AI provider type and endpoint.
- **Fields:** `suite`, `kv`, `nonce`, `ct`. In a team scope there are also `writer`, `ask_v` and `sig`.
- **At use.** The client compares the sealed destination with the record's current destination (F3).
  - A mismatch is the approval case: "saved for X, now points to Y". A server that rewrites a host still trips it, since it cannot change the sealed destination.
  - A teammate's new seal carries an authenticated new destination and applies without a prompt.
  - A device that edits a destination but cannot seal again leaves the old seal in place, and nobody else's secret breaks.
- **Writer signature, team scope (F20).**
  - `sig = Ed25519(ASK at ask_v, LP("tablepro/v1/envelope-writer") || LP(writer) || u32(ask_v) || LP(SHA-256(LP(AAD) || nonce || ct)))`.
  - A client accepts it only from a member the team log confirms and has not removed, and only if the plaintext `writer` matches.
  - Residual risk: a confirmed member with the server's help can write a team secret, since roles are server data, not signed data.
- **Ordering.**
  - Clients pull key objects before they push envelopes.
  - They never encrypt under a version below the highest one seen, below a floor, or below the version that a signed removal requires.
  - A client refuses an envelope or history change under such a version when its pull order puts the change after that removal.
- **Replays.** A client keeps, per envelope, the highest `n` it accepted and the hash of that ciphertext, in the state file. It refuses a lower `n`, and the same `n` with another ciphertext, whatever the key version, the change tag or the epoch. So a server cannot hand back a superseded password under the same key version, during a refill included. Two writers on one base are already serialized by the change tag.

### History entries

- Each entry is created once, under a random UUIDv4 record id (0052), so its id leaks no capture time. A client keeps the ids of entries it saw deleted and refuses them if they come back.
- **Subkey.** `HKDF-SHA256(salt = none, IKM = AK_kv, info = LP("tablepro/v1/history-key") || scope || LP(record id), L = 32)`, with the history scope.
- **AAD.** `LP("tablepro/v1/history") || LP("tp1") || scope || LP(record id) || u32(kv)`.
- **Plaintext.** The entry's fields as a JSON object, padded.
- **When.** Entries are encrypted at push time, not at capture, so a rotation never strands queued entries. Pushes are batched.
- **Old versions.** The AK ring opens them. History is never encrypted again (SYN C5).

### Restore

- **On the server.** Key kinds are records, so a new epoch's refill covers them (0051). Refilled statements are verified like any append.
- **On the client.**
  - A refilled log shorter than a client's stored head is refused.
  - Clients publish the statements they hold above the server's head again.
  - A holder that holds a key version whose wraps or ring the server lost seals them again.

### Libraries

- **Rust: aws-lc-rs.**
  - It provides AES-256-GCM, HKDF-SHA256, Ed25519, SHA-256, HMAC, P-256 key import and the system RNG.
  - The AWS-LC 3 Cryptographic Module holds FIPS 140-3 certificate #5314.
- **Rust: HPKE.**
  - It comes from rustls 0.23.46 `crypto::aws_lc_rs::hpke::DH_KEM_P256_HKDF_SHA256_AES_256` on AWS-LC.
  - That module runs the RFC 9180 vectors but has no audit of its own, and G1 makes up for it with Wycheproof and the Go differential.
  - Its API has no `DeriveKeyPair`, which nothing here needs.
- **Rust: encoding.** `base64` and `serde_json` encode, and signed bytes are kept verbatim. The JWS compact framing, `LP`, Crockford Base32 and the word mapping are encodings, written in `tablepro-keys`.
- **Rust: not used.** RustCrypto's `hpke` (no audit), and `ed25519-dalek`, `p256` and `aes-gcm`, which reach the lock file only through russh. `ring` stays banned.
- **Go.**
  - The standard library's `crypto/ed25519` and `crypto/sha256`. Trail of Bits audited Go's cryptography in 2025, and the Go Cryptographic Module holds CMVP certificate #5247.
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
  - envelopes at each padding boundary (63, 64 and 4,096 bytes, and 4,097);
  - team writer signatures;
  - history entries;
  - every statement type of every log, with its hash, chains, and the device set at each step;
  - commitments, the words for both comparisons, and the QR text;
  - DPoP proofs and their thumbprints;
  - the state file MAC.
- **Negative vectors**, each with the error code it must produce:
  - an unsigned statement, a wrong `typ` or `alg`, an extra header member, and duplicate JSON members;
  - a statement that is badly chained, or out of order with `dh` or `ih`;
  - an `add` not signed by its `by` holder, an `add` by a holder a `rotate` removed, and a `rotate` that leaves in a holder its removed holders approved;
  - a team statement signed with an old `ask_v` while it names the newest `ih`;
  - a floor raised from v to v+1: a write under v refused, and one under v+1 taken;
  - a `reset` without an endorsement, and one by a holder outside the set;
  - a swapped SK, and a `kid` mismatch after unwrap;
  - a recovery blob with the wrong origin, account or `rk_v`, and a recovery key with a bad checksum or the wrong length;
  - an `r_I` that does not open its commitment, and words that do not match;
  - a fork and a rollback;
  - a stale key version and an unknown suite;
  - a wrong AAD for each AAD field;
  - a sealed destination mismatch;
  - an envelope replayed with a lower `n`, or with the same `n` and another ciphertext, under the same key version;
  - a team envelope from an unconfirmed or removed member;
  - a `key` sealed to a revoked SK;
  - removing a signer with fewer than k approvals, `remove_member` of a signer, and `reroot` while a signer is left;
  - Ed25519 edge cases: small-order points, a non-canonical R or A, and S at or above L.
- **Go side.** The cloud repository copies the vectors through its update script (S3K). It verifies every statement, device set and DPoP vector in Go, and opens every wrap with Go's `crypto/hpke`.

### Formal model and review

**Formal model.** `core/docs/security/models/` holds Tamarin theories for these flows:

- genesis with S;
- approval from a device, with the commitment, and with S;
- removal with rotation;
- recovery from zero devices;
- reset;
- a TK seal and member confirmation;
- member removal with the floor.

**Claims the model must pass:**

- the secrecy of AK and TK versions after a removal, against a removed holder working with the server;
- the authenticity of IK on recovery;
- that no TK version is sealed to a revoked SK;
- injective agreement on device approval and member confirmation;
- refusal of rollback through chained heads;
- that no holder a removed holder approved, directly or not, receives a later key version.

**Gates.** G0 reviews this ADR, the threat model and the model's results before any key code. G1 reviews the crate against the vectors, with at least an hour of cargo-fuzz per parser. G3 runs a hostile-server suite before any release. No text says a third party verified this design.

## Rationale

- **The identity under the recovery key.**
  - The identity key never sits on a device, so a stolen device cannot sign a successor identity. That closes the fork instead of raising an alarm on it.
  - Recovery gets an anchor the server cannot forge, and teammates see nothing when a device goes.
  - The cost is entering the recovery key to remove a device, and D6 already makes everyone hold one.
  - This follows Matrix's master and self-signing split and Apple's Advanced Data Protection recovery key.
- **Symmetric scope keys with HPKE wraps.**
  - Envelopes are AEAD under keys only holders and members have, so a server that knows every public key still cannot mint one.
  - This is the 1Password and Bitwarden composition with the fixes ePrint 2026/058 proposes: authenticated encryption only, key separation, all plaintext authenticated, and public keys authenticated.
- **Committed key ids instead of signing each wrap.** A recipient checks the unwrapped key against a signed commitment. That binds the key itself, so a wrap needs no signature of its own and a server-made wrap only fails.
- **Hash chains and heads in every comparison.** One comparison checks both the keys and that both sides see one history (Tailnet Lock, Keybase). Key transparency would also catch split views, but it is still a draft.
- **A commitment in the comparison.** Without it, a server that controls both views wins with a birthday search. With it, five words leave one guess at 2^-64.6.
- **DPoP proofs checked against the signed set.** This uses the standard proof format and its checks rather than a header of our own. Binding the tokens is a later, separate step.
- **Lazy revocation.** A removed party already read what it could. New writes move to a new version, and only rotating database credentials revokes what it read. 1Password rotates nothing, and Apple's ADP protects what is written after a rotation.

### Why not MLS

- **Wrong shape.** MLS gives forward secrecy and post-compromise security for message streams. RFC 9420 §3.2 states that for a new member, "messages sent before they were added to the group will not be accessible". A vault needs the opposite: a member added today reads secrets stored years ago.
- **Identity stays ours.** MLS assumes an Authentication Service outside the protocol (RFC 9420 §3), and the application decides which identities are acceptable (§5.3.1). That is the hard part here, and MLS would not do it.
- **Ordering.** Each Commit is premised on one epoch, and two Commits on one state conflict (RFC 9420 §14). That needs a sequencing service or online agreement our polling model does not have. Our create-only appends serialize only key statements.
- **No library has this shape.** We would still keep a key ring under an MLS epoch secret. So we reuse designs, not code: the 1Password, Bitwarden and ADP composition, Matrix's cross-signing split, and Tailnet Lock and Keybase sigchains for the logs.

## Consequences

- **A recovery key comes first** (decided). It is needed before any personal sync and before any team secret, since both need an identity. Team plaintext records need none.
- **Device approval and member confirmation need both devices online at once,** or in the same room for the QR code. An asynchronous member compare is not offered: it would need about 200 bits to resist the birthday search.
- **A lost device is removed only with the recovery key.** An admin's portal removal stops the device at once. The person's personal floor holds new secret and history writes in the local queue until they enter the key.
- **Losing every holder and the recovery key loses the personal and history scopes on the server** (decided). The account starts again with a reset, which first deletes those records.
- **Team secrets wait during rotation pending** until a signer's app opens. Members keep reading under the versions they hold.
- **The server reads more than versions.** It reads the key-object fields its table lists, DPoP proofs and `kv`, and verifies the account and team logs. It reads no secret and no history.
- **An install that changes its API origin** (decided) is a new server for keys too, as it already is for tokens and the license (0047). People enroll again and devices seal the secrets they hold again. History written under the old origin is not readable there.
- **Teammates see each other's identity logs** through member bundles: when a person removed devices, how many, and when they replaced or reset their recovery key.
- **The threat model's residual risks hold:** trust on first use at genesis and at a reset with no holder left, split views, withholding, a full rollback for a device that never saw the newer head, a confirmed member writing a team secret with the server's help, and data under `tp1` key versions against a future quantum computer.
- **Docs.** The cloud repository's `SECURITY.md` links the threat model. No text claims third-party verification. Whether to commission an external audit is decided before end-to-end encryption leaves beta.

## Alternatives considered

- **`DeriveKeyPair` from the seed for the recovery pair** (0044, SYN C10). The pair is public, and base mode authenticates no sender, so the server can seal its own key to it. Writing `DeriveKeyPair` ourselves is also primitive code the library lacks.
- **The identity key on every device, with signed successors** (D7 option A). A stolen device plus the server can sign a competing successor, and the fix is only an alarm.
- **A sigchain signed by devices, with no identity key** (Keybase, Tailnet Lock). It is heavier, and needs signature weights to settle forks.
- **Signing `(enc, ct)` on each wrap** (SYN C2). Checking the unwrapped key against a signed commitment gives the same protection, and the recipient list stays in the `key` statement.
- **Five or eight words with no commitment** (0044, SYN C8). A server that controls both views finds matching words by a birthday search: 2^32 work at 64 bits and 2^52 at 103 bits.
- **Signal-style fingerprints per party, compared without a session.** Each side is then a second-preimage search, but 103 bits per side means 16 words to read.
- **Re-encrypting every envelope and all history on a removal** (0044). It protects nothing the removed party had not already read, and it is O(history) work.
- **Members pinning each other** (0044). Only signers seal team keys, so a star is enough, and pairwise pins cost O(n²) comparisons.
- **One owner, with a support re-root** (SYN C9). That makes TablePro staff an authority over team trust (D15).
- **Endpoints of their own for key objects.** A second cursor and a second restore story, where records reuse the one log.
- **A password-derived key.** It brings back the KDF downgrade attacks of ePrint 2026/058, and sign-in already happens through the IdP.
- **X25519 for the KEM.** It is fine cryptographically, but rustls drops X25519 HPKE suites under its `fips` feature, while P-256 stays.

## Sources

- RFC 9180, HPKE: https://www.rfc-editor.org/rfc/rfc9180.html
- RFC 5869, HKDF: https://www.rfc-editor.org/rfc/rfc5869.html
- RFC 8032, EdDSA: https://www.rfc-editor.org/rfc/rfc8032.html
- RFC 7515, JWS; RFC 7517, JWK; RFC 7638, thumbprints; RFC 8037, OKP keys: https://www.rfc-editor.org/rfc/rfc7515.html, https://www.rfc-editor.org/rfc/rfc7517.html, https://www.rfc-editor.org/rfc/rfc7638.html, https://www.rfc-editor.org/rfc/rfc8037.html
- RFC 9864, fully specified JOSE algorithms: https://www.rfc-editor.org/rfc/rfc9864.html
- RFC 8725, JWT best current practices: https://www.rfc-editor.org/rfc/rfc8725.html
- RFC 9449, DPoP: https://www.rfc-editor.org/rfc/rfc9449.html
- RFC 9420, MLS: https://www.rfc-editor.org/rfc/rfc9420.html
- RFC 6189, ZRTP, §4.4.1.1 hash commitment: https://www.rfc-editor.org/rfc/rfc6189.html
- RFC 4648, RFC 6454, RFC 9562, RFC 8259, RFC 2104
- NIST SP 800-38D (GCM, §8.3), SP 800-38A (Appendix A), FIPS 180-4
- S. Vaudenay, "Secure Communications over Insecure Channels Based on Short Authenticated Strings", CRYPTO 2005
- Matrix SAS verification: https://spec.matrix.org/latest/client-server-api/#short-authentication-string-sas-verification
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
