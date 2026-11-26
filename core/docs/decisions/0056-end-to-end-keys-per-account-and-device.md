# 0056: End-to-end keys: an account key pair, device key pairs, scope keys wrapped per member, the recovery key and pinned keys

- **Status**: Accepted; supersedes 0053; amends 0044 (Secrets, and its Consequences line that teammates confirm a person again after a device removal or recovery); amended by 0059 (Errors, Ed25519 validity, the HPKE buffers and one vector row); the first envelope row's destination amended by 0061; a team stop's cause and how each clears amended by 0062; team restarts and the lanes' readings amended by 0064
- **Date**: 2026-11-25

## Context

[0053](0053-end-to-end-keys-under-the-recovery-key.md) gave TablePro Sync end-to-end keys of its own design: hash-chained identity, device and team logs, fork detection and new generations, k-of-n team signers with time-locked removal, server time receipts and per-envelope counters. Six rounds of gate G0 each found new critical or high flaws, nearly all in those mechanisms. No deployed password manager needs them.

On 2026-11-25 the maintainer moved the design to the model 1Password and Bitwarden ship:

- one key pair per account and one per device;
- a required recovery key;
- a new device approved by another device or the recovery key;
- team keys wrapped to each member's public key, membership managed by admins on the server;
- members' keys pinned on first use, with key-change alerts and optional fingerprint words;
- keys rotated when a member or a device is removed.

Dropped: signed key logs, fork handling, k-of-n signers, time-locked signer removal, identity generations, `revoke_add`, the genesis `prior` and server time receipts. Accepted: a malicious server can substitute a key at first contact, which a fingerprint check or a pin alert catches, as 1Password and Bitwarden accept.

These decisions carry over in their simple form:

- **D6.** A recovery key exists before any personal sync.
- **D7.** A lost device is removed with the recovery key, and teammates see no change. A sign-out or an ended session rotates nothing.
- **D8.** Nothing personal reaches a device before another device or the recovery key approves it, and the server enforces it.
- **Linux without a keyring** syncs team records only.
- **Past grace,** key writes and sign-out stay allowed.
- **Accepted consequences:** team secrets need the account's keys, so the recovery key too; no device and no recovery key means a reset that deletes the personal and history records; changing the API origin loses history written under the old one.

What 0053 served and this ADR keeps: authenticated recovery (critique F1), rotation that excludes a removed device (F2), an envelope AAD of immutable ids with the destination sealed inside (F3), device keys that outlive a session (F5), D8 against a phished IdP sign-in (F12), no TablePro staff authority over team keys (F13), MLS ruled out with reasons (F16), and a threat model with a metadata list (F20).

The threat model is [`core/docs/security/sync-threat-model.md`](../security/sync-threat-model.md).

## Decision

Each account has an identity key derived from its recovery key, and an account key pair that the identity key certifies. Every approved device holds the account key pair; the identity key exists only while the person types the recovery key. Each device also has a key pair of its own, which receives the account keys and proves to the server which device is calling. Personal secrets, history and each team's secrets are sealed with AES-256-GCM under a versioned symmetric scope key. A scope key reaches its members only through HPKE wraps to their account public key, each signed by the member that wrapped it. Clients pin each other account's identity key on first use, follow key versions it certifies, and alert when it changes. A new device joins through a short authentication string behind a hash commitment. Removing a device, which needs the recovery key, rotates the account keys and every scope key the person holds.

This replaces 0044's Secrets section except its device stores, typed references and iCloud Keychain rules.

Every primitive is a published standard, and `tablepro-keys` composes calls into aws-lc-rs and rustls and holds no primitive of its own. Four parts are TablePro's own protocols built from those primitives, with no proof of their own: the holders rule for team key versions, the SAS transcript, the pin states, and republication after a server restore. The vault model around them is 1Password's and Bitwarden's, and each flow below names the published flow it follows.

## How it works

### Suite and encoding

**Suite `tp1`**, the only one a client accepts:

| Use | Construction | Source |
|---|---|---|
| Wraps | HPKE base mode, single shot: KEM 0x0020 DHKEM(X25519, HKDF-SHA256), KDF 0x0001 HKDF-SHA256, AEAD 0x0002 AES-256-GCM | RFC 9180 §5.1.1, §6.1, §7 |
| Data | AES-256-GCM, 96-bit random nonce, 128-bit tag | NIST SP 800-38D |
| Derivation | HKDF-SHA256, context in `info` | RFC 5869 §3.2 |
| Signatures | Ed25519, pure | RFC 8032 §5.1 |
| Hash | SHA-256 | FIPS 180-4 |

- A client refuses any other suite. The suite name is in every HPKE `info`, AAD and signed message, since RFC 9180 leaves algorithm agreement to the application (§9.7.2).
- `tp1` was 0053's name for a P-256 suite that never shipped. It names this suite from now on.

**Encoding.**

- `LP(x)` is a u32 big-endian length, then the bytes of `x`. `u32(n)` is big-endian and `u8(n)` one byte.
- Account, team, request and reset ids, and a device's key device id (Keys), are UUIDs as their 16 bytes. The origin is the API origin's ASCII serialization (RFC 6454 §6.2), as 0047 compares it. A record id is its UTF-8 wire text (0052).
- `scope` is `LP(type) || LP(owner)`: `personal` or `history` with the account id, or `team` with the team id. Every key object of the personal and history purposes lives in the personal scope and names it; history entries name the `history` scope.
- An X25519 key is its 32 bytes (RFC 7748). An Ed25519 public key is 32 bytes and its private key the 32-byte seed (RFC 8032 §5.1.5).
- JSON carries bytes as canonical base64url without padding (RFC 4648 §5): a decoder refuses non-zero pad bits and any length but the field's. A version or `av` is a JSON integer from 1 to 2^31-1, refused outside that range when parsed.
- Every signed message, HKDF `info`, HPKE `info`, AES-GCM AAD and hash input starts with `LP(label) || LP("tp1")`, and every one but `kid` and the recovery checksum then names the origin. 0054's table digests, which its state MAC frames, are the one exception. HPKE's own `aad` argument is empty, since a wrap's context is in its `info`. JSON is never a crypto input: a verifier rebuilds the signed bytes from the parsed fields, as 0051's key object bodies map them. A DPoP proof is a JWS (RFC 7515) and follows 0051's profile instead.
- **Ciphertext.** An AES-256-GCM ciphertext is two fields: `nonce`, 12 random bytes, and `ct`, the ciphertext followed by its 16-byte tag. An HPKE wrap is `enc`, the 32-byte encapsulated key, and `ct`, the ciphertext followed by its tag (RFC 9180 §6.1).
- **JSON plaintexts** (the `trust` wrap, envelopes and history entries) are UTF-8 JSON objects (RFC 8259) with a member `v`, the plaintext's format, 1 today. A reader refuses a duplicate member name, a missing or wrongly typed member and a `v` it does not know, and ignores a member it does not know. Member order is free, so the vectors give the exact bytes.
- **Base32** is Crockford's alphabet, `0123456789ABCDEFGHJKMNPQRSTVWXYZ`, with bits taken most significant first (RFC 4648 §6 order). Bytes that are not a whole number of symbols end with zero bits, and a decoder refuses non-zero final bits.
- **Words.** For a 32-byte digest `f`, `x` is `f` read as a big-endian integer and `digit[j] = floor(x / 7776^j) mod 7776`. Word `j` is entry `digit[j]` of the EFF large word list in the order of its dice numbers, `11111` at index 0 to `66666` at index 7775. `tablepro-keys` ships the list with its SHA-256 pinned.

**Labels**, one per use:

| Label | Use |
|---|---|
| `tablepro/v1/recovery-checksum` | The recovery key's checksum |
| `tablepro/v1/identity` | The identity key's seed |
| `tablepro/v1/recovery-wrap`, `tablepro/v1/recovery` | The recovery blob's key and AAD |
| `tablepro/v1/account` | An account certificate |
| `tablepro/v1/replace` | The old identity key's endorsement of a new one |
| `tablepro/v1/cancel` | Cancelling a reset with the recovery key |
| `tablepro/v1/device` | A device certificate |
| `tablepro/v1/key-id` | A scope key's commitment |
| `tablepro/v1/version` | A scope key version record |
| `tablepro/v1/wrap`, `tablepro/v1/wrap-sig` | A wrap's HPKE `info` and its signature |
| `tablepro/v1/ring-key`, `tablepro/v1/ring` | A ring's subkey and AAD |
| `tablepro/v1/envelope-key`, `tablepro/v1/envelope` | An envelope's subkey and AAD |
| `tablepro/v1/history-key`, `tablepro/v1/history` | A history entry's subkey and AAD |
| `tablepro/v1/sas-commit`, `tablepro/v1/sas` | Device approval's commitment and words |
| `tablepro/v1/fingerprint` | An account's fingerprint words and QR code |
| `tablepro/v1/state` | The state file's MAC (0054) |

**Padding.** A plaintext of `n` bytes in a `trust` wrap, an envelope or a history entry is padded with ISO/IEC 7816-4 padding, 0x80 then zeros, to `P(n)`: the smallest of 64, 128, 256, 512, 1,024, 2,048 and 4,096 that is at least `n + 1`, and above that `4,096 × ceil((n + 1) / 4,096)`. Fixed-size plaintexts are not padded: scope and account wraps, rings and the recovery blob. The padding is removed only after the AEAD opens (RFC 9180 §9.7.6), and a reader refuses a length not on that scale, a missing 0x80 or a non-zero byte after it.

### Keys

| Key | Type | Private half lives | Rotates |
|---|---|---|---|
| Recovery key R | 256 random bits | On paper or in a password manager. In memory only while a flow uses it | Replace, reset |
| Identity key IK | Ed25519, seed derived from R | Nowhere. Derived when R is typed, then zeroized | With R |
| Account keys, version `av`: signing key ASK (Ed25519) and encryption key AEK (X25519) | Random | Every approved device's store; under R in the recovery blob | Removing devices, recovery, replace, reset |
| Device keys: DSK (Ed25519, the device's DPoP key) and DEK (X25519), named by a key device id | Random | That device's store only, never synced | Never. A device that loses them, or signs out, makes new ones under a new key device id |
| Personal key PK, history key HK, versions `pv`, `hv` | 256-bit symmetric | Wrapped to the account's AEK | With the account keys |
| Team key TK, version `tv`, per team | 256-bit symmetric | Wrapped to each confirmed member's AEK | A member removed; a member's account keys rotated |

- **One identity per account and origin.** IK is the account's identity: teammates pin it, and it certifies each account key version. It never sits on a device, so a stolen device cannot certify keys of its own. This is Matrix's master key, kept off devices, with no stored copy at all.
- **Device stores.** Keychain items with `ThisDeviceOnly` that do not sync; Credential Manager with `CRED_PERSIST_LOCAL_MACHINE`; a Secret Service item. A device with no store, such as Linux without a keyring, holds no keys: it syncs team plaintext records, nothing personal, and reads no team secret.
- **Device keys belong to (origin, account, device row),** not to a session (F5). They survive session expiry, SAML's 10-hour cap, a lost token and a failed deprovisioning check, and resume without approval when the same account signs in on the same row.
- **The key device id** is a random UUIDv4 the device draws with its device keys, and every key object names the device by it. A device row holds at most one key device at a time (0051, Keys on the wire). Every approval takes new device keys and a new key device id: after Sign Out, and for a device approved again after a lock, a reset or a lost anchor alike, so its certificate and wraps never meet an earlier one's ids. The old keys stay until the approval applies. Matrix does the same: a logout deletes the device and its device keys, and the next login is a new device.
- **Erasing.** Device keys are erased on Sign Out and when another account signs in on that row. An approval replaces the device keys and account keys a device held, and merges its key tables (Approving a device). A sign-out the server causes, 0047's `refused` or `device removed`, is not Sign Out: it locks the device and erases nothing.
- **A hardware key later.** DSK sits behind a host trait. A Secure Enclave or TPM key is P-256, so it needs a later suite that defines its public key encoding, the device certificate, the wrap signature, the SAS input and DPoP's `ES256` together.
- **Versions** count from 1 and step by exactly one, which client and server both check. Secret bytes live in `secrecy` and `zeroize` types and are never logged.
- **Nonce budget.** Every AES-GCM key here stays far below SP 800-38D §8.3's 2^32 encryptions with random nonces: an envelope or history subkey encrypts one record under one scope key version, once per edit on any device; a ring key encrypts once; `K_rec` encrypts once per `av`, each a person's action. A retry after a timeout resends the ciphertext it built and never seals the same plaintext again.

### The recovery key

**R** is 32 bytes from the system RNG.

- **Text.** `B = R || SHA-256(LP("tablepro/v1/recovery-checksum") || LP("tp1") || LP(R))[0..3]`, 35 bytes, written as 56 Base32 symbols (Encoding) in 14 groups of 4 joined by `-`. Reading drops hyphens and spaces, upper-cases, reads `O` as `0` and `I` and `L` as `1`, and refuses any other length or a bad checksum.
- **Shown once.** Genesis, Replace and a reset show it and ask the person to type back two groups chosen at random before anything is pushed.
- **The identity key.** `seed = HKDF-SHA256(salt = none, IKM = R, info = LP("tablepro/v1/identity") || LP("tp1") || LP(origin) || LP(account), L = 32)`. IK is the Ed25519 key with that seed.
- **The recovery blob,** one per `av`: `K_rec = HKDF-SHA256(salt = none, IKM = R, info = LP("tablepro/v1/recovery-wrap") || LP("tp1") || LP(origin) || LP(account), L = 32)`, and `ct = AES-256-GCM(K_rec, nonce, ASK seed || AEK private key, AAD = LP("tablepro/v1/recovery") || LP("tp1") || LP(origin) || LP(account) || u32(av))`: a 12-byte `nonce` and an 80-byte `ct`, the 64-byte plaintext and the tag, unpadded.
- **Why recovery is authentic.** Only someone holding R can make a blob that opens or an IK signature that verifies. A recovering device derives IK from R, checks the account certificate under it, and checks that the keys in the blob are the ones the certificate names. A server can withhold or serve an older version, never forge one (F1). This is 1Password's recovery key, which wraps the key set's key under an HKDF subkey of a 256-bit secret, and it needs no `DeriveKeyPair`.

### Signed objects and wraps

**Account certificate**, one per `av`: `Sign(IK, LP("tablepro/v1/account") || LP("tp1") || LP(origin) || LP(account) || u32(av) || LP(IK pub) || LP(ASK pub) || LP(AEK pub) || u8(kind))`. `kind` is 0 for genesis or a rotation, 1 for a replace, 2 for a reset that keeps the scope keys and 3 for a reset that starts empty (Reset).

- A replace also carries `Sign(old IK, LP("tablepro/v1/replace") || LP("tp1") || LP(origin) || LP(account) || u32(av) || LP(new IK pub))`, where the old IK is the one the certificate at `av - 1` names.

**Device certificate**, one per (key device, `av`): `Sign(ASK at av, LP("tablepro/v1/device") || LP("tp1") || LP(origin) || LP(account) || u32(av) || LP(key device id) || LP(DEK pub) || LP(DSK pub))`.

**Key commitment.** `kid(K) = HKDF-SHA256(salt = none, IKM = K, info = LP("tablepro/v1/key-id") || LP("tp1"), L = 32)`. AES-GCM does not commit to its key (Albertini et al., USENIX Security 2022), so every reader checks an unwrapped key against the `kid` its version record names.

**Version record**, one per (scope, purpose, version), purpose `personal`, `history` or `team`: `Sign(signer's ASK, LP("tablepro/v1/version") || LP("tp1") || LP(origin) || scope || LP(purpose) || u32(version) || u8(start) || LP(kid) || LP(signer account) || u32(signer av))`.

- `start` is 0 for the next version of a key and 1 for a version that starts the key over: version 1, a team restart (Teams), and the first personal and history versions after a reset that starts empty. A version with `start` 1 needs no ring.
- It is created once, so two devices that rotate at once are serialized: the second gets `create_only`, pulls, and rotates again only if a rotation is still due.

**Wrap.** `(enc, ct) = SealBase(pkR, info, aad = "", pt)` (RFC 9180 §6.1), with `info = LP("tablepro/v1/wrap") || LP("tp1") || LP(origin) || scope || LP(purpose) || u32(version) || LP(recipient type) || LP(recipient id) || u32(recipient version) || LP(pkR)`:

| Purpose | Scope and version | Recipient | `pkR` | `pt` |
|---|---|---|---|---|
| `account` | The personal scope, the `av` | `device`: the key device id, at that `av` | That key device's DEK | `ASK seed || AEK private key`, 64 bytes |
| `trust` | The personal scope, the `av` | `device`: the key device id, at that `av` | That key device's DEK | The trust plaintext (Pins), padded |
| `personal`, `history` | The personal scope, the key's version | `account`: the account id, at its `av` | That account's AEK at that `av` | The 32-byte key |
| `team` | The team scope, the key's version | `account`: the account id, at its `av` | That account's AEK at that `av` | The 32-byte key |

The wrapper signs it: `Sign(key, LP("tablepro/v1/wrap-sig") || LP("tp1") || LP(info) || LP(enc) || LP(ct) || LP(wrapper account) || u32(wrapper av) || LP(wrapper key device id))`. The key is the writing device's DSK for `account` and `trust`, since every device holds ASK and a stolen one could sign as any of them, and the wrapper's ASK at `wrapper av` for a scope key. That is RFC 9180 §9.1.1's signature over `(enc, ct)`: base mode authenticates no sender, so without it a server could wrap a key of its choice to any public key, the attack ePrint 2026/058 found in deployed password managers. The recipient's public key is inside the signed `info`, so a wrap also tells every member which key its wrapper saw for that recipient.

**Opening a wrap,** the recipient checks:

- for `account` and `trust`, the signature under the writing device's DSK, which the recipient holds from a comparison of its own (Approving a device);
- for a scope key, the signature under the wrapper's ASK at the `av` the wrap names, whose certificate verifies under the IK the recipient pinned for that account or one that IK endorsed (Rollback, Verifying);
- for `account`, that the private keys give the public keys of the account certificate at that `av`;
- for a scope key, the `kid` of the version record, and that the record's signer may sign it (Teams).

**Ring.** A version v with `start` 0 has a ring, written in the same change set as its version record: `u32(v - 1) || K_(v-1)`, 36 bytes, under `HKDF-SHA256(salt = none, IKM = K_v, info = LP("tablepro/v1/ring-key") || LP("tp1") || LP(origin) || scope || LP(purpose) || u32(v), L = 32)` with `AAD = LP("tablepro/v1/ring") || LP("tp1") || LP(origin) || scope || LP(purpose) || u32(v)`. A version with `start` 1 has one only when its signer holds the version before it. A client reads the current version through a wrap and each older version by walking the rings down from it, checking each key against its version's `kid`. A member confirmed today reads secrets stored years ago, which is what a vault needs, and a ring stays 36 bytes however many versions a key has, so no record limit ends a key's rotations. Keybase chains its team keys the same way: each generation's secret encrypts the one before it.

### Envelopes and history

**Envelope**, one per (parent record, secret kind), with the id 0052 gives it.

| Parent kind | Secret kind | Sealed destination |
|---|---|---|
| `connection` (personal) and `library_connection` (team) | `password`, `ssl_key_passphrase` | Engine, host, port, user, database, TLS mode, CA and client certificate paths, and the SSH route |
| same | `ssh_password`, `ssh_key_passphrase`, `ssh_totp_secret` | SSH host, port, user and key path |
| same | `plugin.<field id>`, one per secure field a driver plugin declares; a field id holding `/` does not sync | As for `password` |
| `ssh_profile` | `ssh_password`, `ssh_key_passphrase`, `ssh_totp_secret` | SSH host, port, user and key path |
| `credential_profile` | `password` | The profile's user. At use, each (profile secret, connection destination) pair is approved once per device, as 0044 does for typed references |
| `<platform>_settings`, record `ai` | `ai_key.<provider id>` | The provider type and endpoint |

A new secret kind needs a row here first.

- **Subkey.** `HKDF-SHA256(salt = none, IKM = K_kv, info = LP("tablepro/v1/envelope-key") || LP("tp1") || LP(origin) || scope || LP(parent kind) || LP(record id) || LP(secret kind), L = 32)`, with K a PK version in the personal scope and a TK version in a team.
- **AAD, immutable ids only** (F3): `LP("tablepro/v1/envelope") || LP("tp1") || LP(origin) || scope || LP(parent kind) || LP(record id) || LP(secret kind) || u32(kv)`.
- **Plaintext:** `{"v": 1, "secret": <string>, "dest": <object>}`, padded. `secret` is the secret's text. `dest` is the destination the secret was sealed for: one member per destination field the row names, with the name and JSON type the parent kind's wire schema in `tablepro-records` gives that field, left out when the record has no value. An SSH route is an array of hops in order, each an object of the same SSH fields.
- **Fields:** `suite`, `kv`, `nonce`, `ct`. Removing a secret deletes its envelope.
- **At use,** the client builds `dest` from the record's current fields by the same rule and compares the two as JSON values. A difference is the approval case "saved for X, now points to Y", which 0044 requires for any destination change. A server that rewrites a host trips it, since it cannot change `dest`.

**History entry,** created once under a random UUIDv4 id (0052): subkey `HKDF-SHA256(salt = none, IKM = HK_kv, info = LP("tablepro/v1/history-key") || LP("tp1") || LP(origin) || scope || LP(record id), L = 32)` with the history scope, `AAD = LP("tablepro/v1/history") || LP("tp1") || LP(origin) || scope || LP(record id) || u32(kv)`, the plaintext `{"v": 1, "entry": <object>}`, padded, where `entry` holds the fields of the `history_entry` wire schema in `tablepro-records`, and the fields `suite`, `kv`, `nonce`, `ct`. An entry's ciphertext never changes while the server holds it. A device that pushes it again, over a policy tombstone or after a restore lost it, encrypts the same id and fields again under the newest HK version (0051, Policies and Restore); the HK rings open entries under older versions.

**Writing.** A client writes an envelope or a history entry only under the newest version of its scope key, after pulling key objects. The honest server refuses any other `kv`.

### Pins

A client keeps, per account it meets, its own included, a pin: the IK, the newest `av` it has verified, how it pinned (`first_use`, `compared`, `replaced`), whether an alert is open, and the IKs it saw replaced.

- **First use.** The first time a client meets an account, it pins that account's IK from its certificate, with no prompt.
- **Following.** A certificate with the pinned IK and a higher `av` is followed silently: the account rotated its keys, as after a device removal (D7). A lower `av` never becomes the newest; it still verifies the objects signed under it (Rollback, Verifying).
- **Replace.** A new IK endorsed by the pinned IK is followed with a notice ("Ana replaced her recovery key"), and the old IK joins the replaced list. The client never goes back to an IK it has seen replaced.
- **Any other change** is an alert, in every team the account is in: "Ana's keys changed. Compare her words before sharing team keys with her." Until the person re-confirms on that device, the client wraps nothing to the account and gives its version records and wraps no effect as a holder's. Re-confirming offers the words. Accepting without comparing is allowed and recorded as `first_use`.
- **The person's own account.** An unendorsed IK on its own account, as after a reset on another device, locks the device: it keeps its keys, syncs nothing personal and asks to be approved again from the device that reset.
- **Fingerprint words.** `f = HKDF-SHA256(salt = none, IKM = IK pub, info = LP("tablepro/v1/fingerprint") || LP("tp1") || LP(origin) || LP(account), L = 32)`. The words are words 0 to 5 of f (Encoding), about 77 bits. Both people read their own account's words on their own device and compare out of band. In person, one device shows a QR code of `TPF1:` and the 52 Base32 symbols of f, upper case and ungrouped, its last 4 bits zero, and the other scans it.
- **Own devices.** A device approved by another starts from the approver's trust plaintext, so for the pins the approver sends a server cannot show a new device a teammate the approver pinned otherwise, or without an alert the approver holds. First-use pins left out for size (below) are pinned on first use again. A device recovered with R starts with none. Own-device pins, the devices a device compared with, are kept beside the pins and never sent.
- **Where they live.** In the TablePro Sync state file's key tables, under 0054's anchor (Rollback).

**The trust plaintext:**

```json
{
  "v": 1,
  "pins": [
    { "account": "<UUID>", "ik": "<32 bytes>", "av": 4, "how": "compared", "alert": false, "replaced": ["<32 bytes>"] }
  ],
  "versions": [
    { "owner": "<UUID>", "purpose": "team", "version": 7, "record": "<32 bytes>" }
  ]
}
```

- `pins` holds one entry per account the approver pinned, its own included, and `versions` one per scope key it holds: the owner is the account for `personal` and `history` and the team for `team`, and `record` is the SHA-256 of that version record's signed bytes (Rollback). UUIDs are upper-case text as 0052 writes them.
- When the encoded `trust` wrap would pass 0051's record limit, the approver leaves out pins with `how` `first_use`, no alert and no replaced IK, which the new device pins on first use again. If it still does not fit, the approval fails with `too_large`; no alert, comparison or replaced IK is dropped.

Bitwarden's fingerprint phrase is five EFF words over the public key. The sixth word here adds margin, since a teammate's pin lasts and the words are compared remotely.

### Approving a device

The new device N and an approved device A, both online, with a commitment so an attacker that controls both views gets one guess. The exchange has Vaudenay's commit-then-reveal shape (CRYPTO 2005), which Apple's Contact Key Verification and Matrix SAS also use. Its session follows Matrix's key verification framework: one transaction per request, the first device that answers holds it and the others stop, a cancel with a reason ends it, and it times out after 10 minutes.

1. N signs in, makes DSK, DEK and a key device id, reads the account's newest certificate and fixes its view: IK, its key device id, DEK and DSK. It draws a 32-byte `r_N` and writes `key.request`: its key device id, DEK, DSK and `c = SHA-256(LP("tablepro/v1/sas-commit") || LP("tp1") || LP(origin) || LP(account) || LP(request id) || LP(N's key device id) || LP(IK pub) || LP(N's DEK pub) || LP(N's DSK pub) || LP(r_N))`. The server sets `expires_at`, 600 s after it took the request.
2. A shows the request with the device's name, platform and time. The person picks it. A writes the `nonce` step: its own key device id, DEK and DSK, and a random 32-byte `r_A`. The step is created once, so the first approver holds the session, and another approver's sheet closes on `create_only` ("being approved on Mac mini").
3. N writes the `reveal` step, `r_N`. A refuses an `r_N` that does not open `c` with the keys the request carries.
4. Each side computes `d = SHA-256(LP("tablepro/v1/sas") || LP("tp1") || LP(origin) || LP(account) || LP(request id) || LP(N's key device id) || LP(IK pub) || LP(N's DEK pub) || LP(N's DSK pub) || LP(r_N) || LP(A's key device id) || LP(A's DEK pub) || LP(A's DSK pub) || LP(r_A))` from its own view: A with its own account's IK, the request's fields and its own keys, N with the IK it read, its own keys and the `nonce` step it received. Five words: words 0 to 4 of d (Encoding), about 64 bits. Matching words authenticate both ways: N's key device id and keys to A, and the account's IK and A's keys to N.
5. The person compares the words and confirms on both devices. A side whose person says they differ, or cancels, writes the `cancel` step with its reason, `mismatch` or `user`, and the request ends.
6. Once its person confirmed, A pushes the approval change set: N's device certificate under ASK at the current `av`, the `account` wrap of the account keys to N's DEK, and a `trust` wrap of its trust plaintext, both wraps signed by its DSK.
7. N, once its own person confirmed, checks both wraps under the DSK it compared, opens them, checks the account keys against the certificate at the `av` they name under the IK it compared, and merges the trust plaintext into what it holds, the way pinning clients merge a peer's view:
   - **its own account** takes the approver's pin and alerts, which the comparison authenticated, when the approver's `av` is at or above its own, and that clears an own-account lock (Pins). Below its own, the approval is refused with `keys.stale`, and the device keeps its keys;
   - **another account** keeps the device's own pin and its `how`, and takes the approver's when it has none. It follows a higher `av` under the same IK and adds the approver's open alerts. The replaced lists merge, each IK once, in the order it was replaced, and an IK in the merged list is never current: where the device's pinned IK is in it, the device follows the replacing IK when it holds the endorsement, and otherwise opens the key-change alert. A pin under a different IK that no endorsement the device holds explains opens the key-change alert for that account too (Pins, Any other change);
   - **personal and history key versions** that are current are the ones signed under the merged current `av`, the device's own or the approver's (Rollback, Per scope key). One signed under an older own `av` is never current, however high its number. When neither side holds one signed under the current `av`, the approval is refused with `keys.stale` and the device keeps its prior state. A personal or history stop clears only this way;
   - **a team scope the device holds** keeps its version, record, holders and state. The approver's higher version is only a hint, which the device takes only through its own Advancing rules under the merged pins, and a stop clears only through re-confirmation (Teams, A stopped device);
   - **a team scope new to the device** takes the approver's version and record, as a new device does, and builds its holders from the wraps it then accepts under Advancing;
   - at an equal version a different `record` is `keys.conflict`, a scope that ended stays ended with its epoch, and a scope the trust plaintext leaves out stays as it was;
   - **own-device pins** are all dropped, and the approver becomes the only one, since the device's keys are new (Keys).

   A device with no key tables takes what A sent. It then reads the scope keys through their wraps to AEK. A stolen device that holds ASK cannot sign as A, so it can neither give N old keys nor pins of its choosing.
8. Each side keeps the other's key device id, DEK and DSK, as the words covered them and never from a certificate, as an **own-device pin**: a device whose keys it holds from a comparison of its own.

**The session,** as the server sees it from the request's records:

| State | Entered when | The server takes | Ends as |
|---|---|---|---|
| `open` | N's `key.request` applies | A's `nonce`; N's `cancel` | `chosen`, `cancelled` or `expired` |
| `chosen` | The first `nonce` step applies, from an approved device of the account | N's `reveal`; a `cancel` from N or A | `revealed`, `cancelled` or `expired` |
| `revealed` | N's `reveal` applies | A's approval change set; a `cancel` from N or A | `approved`, `cancelled` or `expired` |
| `approved` | A's approval change set applies before `expires_at` | nothing | final |
| `cancelled` | A `cancel` step applies | nothing | final |
| `expired` | `expires_at` passes before approval | nothing | final; purged |

- Every step is created once. A step out of this order, or for a request that has ended, is `request_closed` (0051).
- The approval change set comes from the device that wrote the `nonce` step. Its certificate names the request's key device id, DEK and DSK, at the account's current `av`, and its two wraps are to that key device at that `av`; the server finds the request by that key device. Once it applies, the device row that wrote the request holds that key device.
- **One comparison per session.** Each side keeps the session's fixed view in its state file (0054, `key_comparisons`): N from its request, A from its `nonce` step. A computes the words once, from the first `reveal` it reads, and never shows words for a session it already compared. An ended session never reopens: N asks again with a new request and a new `r_N`. The commitment fixes N's view before `r_A` exists, and create-only fixes `r_A` before `r_N` is revealed, so a server that controls both views gets one guess at 2^-64.6 per request.
- **Account changes during a session.** The approval change set is built at the account's current `av`. A rotation that keeps A and leaves IK as it was keeps the session, and A writes N's certificate at the new `av`. A replace or a reset changes IK, which the words covered, so the session ends and N asks again. A device that a rotation left out, or whose row was removed, can no longer approve: its change set is `device_not_approved`.

The request expires after 10 minutes, and both devices poll every 1 to 2 seconds while the sheet is open (0051's rate limits).

**Admin-assisted approval is not offered.** Bitwarden's admin approval works because the organization holds every member's user key through account recovery, which is admin escrow of personal secrets: 0044 rules it out, and ePrint 2026/058's key escrow attacks are that class. Team secrets come back after a reset through an owner or admin re-confirming the person (Teams), which is the help an admin can give without escrow.

### Account flows

**Genesis,** on the first device of an account with no certificate.

1. The device makes R and shows it, has two groups typed back, then derives IK and makes ASK, AEK, PK v1 and HK v1, both with `start` 1.
2. It pushes, as one change set the server applies whole: the certificate at `av` 1, the recovery blob, its own device certificate, and the PK and HK version records with their wraps to AEK.
3. If another device's genesis won, it discards its keys and asks for approval instead. The server takes a genesis from any interactive sign-in while the account has none: it is trust on first use.

**Rotation,** the one procedure behind removing devices, recovery and replace. A device X, with R typed, moves the account from `av` to `av + 1`, keeping a set D of devices: X itself, and only those of its own-device pins the person ticks. A device certificate alone does not qualify a device for D, since every certificate so far is signed by an ASK a stolen device may hold.

1. It makes ASK', AEK', PK and HK at their next versions, and with a replace a new R'.
2. It pushes, as one change set the server applies whole: the certificate at `av + 1` under IK (with a replace, under the new IK with the old IK's endorsement), the recovery blob under R (with a replace, under R'), for each device in D a device certificate under ASK' with the same key device id and keys and an `account` wrap signed by X's DSK, and the PK and HK version records, wraps to AEK' and rings.
3. It copies the new certificate into each team as `key.member`, and rotates each team's key (Teams).
4. It zeroizes R, R' and IK once the change set is built and R' has been typed back.

- The server then treats only the devices in D as approved. Each of them pulls, finds its new certificate and wrap, checks the wrap under X's DSK from its own-device pin and the keys under IK, and adopts them.
- **A device left out** finds a verified certificate at `av + 1` and no certificate of its own at that `av` once it has the whole change set (0051, a page never splits one). It locks, keeps its keys, and asks to be approved again from a device in D. The absence of a record is not signed, so it erases nothing (Erasing).
- A rotation that applies at `av + 1` ends a pending reset that proposed the same `av` (Reset): whoever rotated holds R.

**Removing a device** (D7).

1. From any approved device, the person picks the lost device. The app removes its device row first, which needs a step-up within 300 s (0051, Step-up): the server revokes its tokens, and the row no longer holds a key device.
2. The person types R. The sheet lists:
   - the account's devices with name, platform and when each was added. Those this device compared with can be kept, ticked by default except the lost one; every other device joins again by approval afterwards;
   - in each team, the members this account confirmed with a wrap it signed under an `av` the lost device held a certificate for. "Confirmed while MacBook Pro had your keys" covers the person's own confirmations too, since a scope-key wrap names the account, not the device. The person keeps or removes each, as a Bitwarden admin reviews the `Confirmed user` events of the organization's event log.
3. The app sends the person to the portal to remove the seats of the members marked for removal, since membership changes only there, behind the portal's step-up (0044).
4. The app runs a rotation, then rotates each team without the members marked for removal, whether or not the server still lists them. The choices stay in the state file until every team rotation is written (0054, `key_pending`).

- An install admin can remove a row from the portal, behind the portal's step-up (0044). The browser holds no keys, so this only locks the device: the server answers it `device_removed`. The person's next device asks for R to finish.
- Until R is typed nothing rotates. The device is cut off from the honest server at once, and a compromised server could still give it what is written meanwhile. The app keeps asking.
- Every device left sees the rotation when the server delivers it. Teammates see the same IK at a higher `av` and follow it silently.

**Recovery with R** on a device with no approved device at hand: the device reads the newest certificate and blob, which any signed-in device may read, takes R, derives IK, checks the certificate, opens the blob and checks its keys. It has compared with no device, so its rotation keeps only itself, and the person's other devices join again by approval from it. IK's signature on the new certificate authorizes the change set. A server that showed it an older certificate gets no old account or scope key from it: the rotation issues keys no removed device ever had, and on an honest server its `av` must be the next one. The device still starts with no pins and can be shown an older view of its teams (threat model). The rotation binds the device's row to its new key device (0051).

**Sign Out,** online, sends 0051's revoke for its own device row, so the row holds no key device and a reset it proposed ends, then erases its keys and its key device id. Nothing rotates (D7). Offline, it erases anyway, and the row keeps the old certificate until a new key device on that row is approved, a rotation leaves it out or the row is removed. Signing in again on the same row is a new device: new keys, a new key device id and an approval.

**Replace Recovery Key,** with the current R: a rotation with a new R' and a new IK', endorsed by the old IK. It takes effect at once. Own devices and teammates follow the endorsement with a notice. The honest server deletes the old blob, and a copy someone kept opens only keys older than the replace.

**Reset,** when R is lost. It follows Bitwarden's emergency access takeover: a request that waits, which the account's owner can reject during the wait, and which applies when the wait passes with no answer.

- **Who.** A reset of kind 2 starts from an approved device and keeps the scope keys it holds. A reset of kind 3 starts from a sign-in whose device is not approved, after a step-up within 300 s (0051, Step-up; `step_up_required` otherwise), and starts empty. It does not wait on the rows of lost devices: whatever devices are still certified at the current `av`, and R, can cancel it during the wait.
- **Proposal.** The device makes R' (shown and typed back), IK' and new account keys, and pushes a `key.reset` alone: the certificate it proposes at `av + 1` under IK' with its kind, its own device certificate under the new ASK, and the new blob. The honest server holds it 7 days from when it took it, and every device, the portal and, on the SaaS, an email show it. At most one reset is pending per account.
- **Cancel.** Any device certified at the current `av` cancels it, and so does R, through `Sign(IK, LP("tablepro/v1/cancel") || LP("tp1") || LP(origin) || LP(account) || u32(av + 1) || LP(the proposed IK pub))`, carried by any device of the account. Each reset has a new IK, so a cancel never applies to another attempt. A revoked or locked device cannot cancel, so a person who lost R first removes a stolen device's row from another device, which needs no R.
- **Activation.** After 7 days with no cancel, the proposing device pushes the activation change set: the proposed certificate, device certificate and blob as the proposal holds them, and the PK and HK version records at their next versions with their wraps to the new AEK. For kind 2 they have `start` 0 and rings, so old data stays readable. For kind 3 they have `start` 1 and no ring, and the server deletes, in the same transaction, every other record of the account's personal and history scopes except its account certificates and version records (decided). Either way the server removes every other device row of the account with its tokens, so only the proposing device is approved, and marks `rotation due` on every team where the account held a key just before.
- **After.** The device copies its certificate into each team as `key.member`. The person's other devices get `device_removed`, sign in again and join by approval from the resetting device, with new key device ids. Teammates see an alert, and no team key reaches the person until an owner or admin re-confirms them.

| State | Entered when | Ends as |
|---|---|---|
| `pending` | The proposal applies, with `held_until` 7 days after the server took it | `cancelled`, `superseded` or `active` |
| `cancelled` | A `key.cancel` for it applies | final |
| `superseded` | A `key.account` applies at its `av` (a rotation or replace by someone holding R), the device row that proposed it is removed or signs out with the reset's DSK, or 7 days pass after `held_until` with no activation | final |
| `active` | Its activation change set applies, at or after `held_until`, while `av + 1` is still the next `av` | final |

The server tombstones the `key.reset` record when it ends, and the sheet shows that it ended.

### Teams

Owners and admins manage membership on the server, behind the portal's step-up (0044). The app's keys follow it. The app reads the roster, with each member's role, from the scopes body's `members` (0051), a server assertion that never stands in for a holder check.

- **Certificates in the team.** An account copies its current certificate into each team it belongs to as `key.member`: when it joins, with every replace certificate it made, so a teammate who pinned an older IK elsewhere follows the endorsements; when its team key version is created; and after every change of its `av`. Every seat reads them, so a member checks a signer, a wrapper or a recipient under the certificate at the `av` the object names. The server refuses a team version record or wrap that names an account, as signer, wrapper or recipient, with no `key.member` at that `av` (`key_dependency`). An account with no keys yet shows as "waiting for this person to set up their keys".
- **Holders.** The holders of version v of a team key are the account and IK that signed v's version record, plus each account and IK that a wrap of v names, when a holder of v signed that wrap. An IK that replaced a holder's IK with its endorsement is the same holder; an unendorsed one, as after a reset, is not. A client works this out from the version records and wraps, which every member can read, under the rules of Rollback, Advancing.
- **Who signs a version.** A version with `start` 0 counts only when a holder of the version before it signs it. So a member the server makes up cannot bring in a key of its own: it holds nothing (ePrint 2026/058's organisation injection and overwrite). Version 1, with `start` 1, is signed by the team's creator and taken on first use. The honest server takes a next version from an owner or admin at any time, and from any other holder only while the team is `rotation due`, so a member cannot churn the key on its own.
- **Joining.** A member takes the version it was confirmed with on first use, from the wrap a person confirmed, and applies the rule from that version on.
- **A stopped device.** A device stopped by a catch-up it could not verify (Rollback, Advancing) keeps the last version it verified and that record's digest, marks the team stopped in its state file (0054), writes nothing under the team key and reports the version to the server, which lists the report to owners and admins (0051, Teams). An owner or admin whose account held that version confirms it again by rotating the team key, and the app offers this only to such an account. The device takes the new version from its wrap only when the wrap's signer is among the holders it had accepted for the version it stopped at, and signed the new wrap under its newest `av` the device knows. Those holders are the ones it counted when it verified that version: the version record's signer and each recipient of a wrap it accepted under Advancing, with their signatures under older `av`s still valid. A wrap of that version the device first sees after it stopped never makes its recipient a holder. That clears the stop, and the device withdraws its report. When no owner or admin in `members` (0051) held that version, the team ends on that device as after a restore (After a restore), the device withdraws its report, and owners create a new team and share again.
- **Creating a team** is one change set: the owner's `key.member`, TK v1 with `start` 1, and a wrap to its own AEK.
- **Confirming a member** is an owner's or admin's action in the app, as Bitwarden's Confirm step is. The app reads the member's `key.member`, pins it on first use, shows the words with Compare, and on Confirm wraps the current version to the member's AEK. That version's ring chain gives the older ones. A member added in the portal waits, shown as "waiting for confirmation", until an owner or admin opens the app. Nothing is wrapped automatically, so a member the server invents receives no key until a person confirms it. Any wrap to an account that does not hold the current version is a confirmation, a rotation's included, so a member left out of a version comes back only through an owner or admin. Two admins who confirm at once meet on one wrap id, and the second sees `create_only`.
- **Rotating a team key** is one change set the server applies whole: the next version record, its ring, and a wrap of it to each recipient at the recipient's current `av`. The recipients are every holder of the current version on the roster whose pin has no open alert, less the members a removal review marked (Removing a device). The server checks every wrap against the roster and each recipient's current `av` at the moment it applies, so a removal or a member's rotation that lands first makes the whole set fail, and the app pulls and builds it again. A member left out shows as "waiting for confirmation" until an owner or admin confirms it again.
- **Removing a member.** The server removes the seat and marks the team `rotation due`. The removing admin's app, or the first holder's app that sees the mark, rotates the team key.
- **A member's account keys rotate** after a device removal, a recovery, a replace or a reset. The server marks `rotation due` each team where that member holds a team key. The set of teams is the one where the member held a key just before the change. After a removal or a recovery the member's own app rotates each team in the same flow, after its review; after a replace the member's app or any holder does; after a reset another holder rotates, and the person waits for re-confirmation.
- **Rotation due.** While it is set, the honest server refuses new team envelopes with `rotation_due`, and apps hold them in their queue. It clears only when a whole team rotation change set applies, and every mark set before that moment is met by it, since its wraps were checked against the roster and `av`s of that moment.
- **Re-confirming** after an alert: an owner or admin compares or accepts, then wraps the current version to the new key.
- **No holder left.** When no member on the roster holds the current version, after a reset, a removal or the last holder leaving, an owner restarts the key: it signs the next version with `start` 1, a ring when its device still holds the current version's key, and wraps to the members it confirms. A client whose own account holds the current version under its current IK refuses a restart of it, so a server cannot use one to replace a key a member holds; every other member takes it on first use with a notice that the team key started over. An owner who reset is no longer a holder, so its own device takes its own restart.
- **Size.** A team rotation fits one push (0051, Limits), so at most 5,000 members of a team hold its key; past that a confirmation is `team_full`, and admins split the team.
- **A member checks what reaches it.** A member whose app sees a wrap or version addressed to one of its own superseded `av` raises an alarm and copies its newest certificate into that team again. A server that withheld the member's rotation from a teammate shows up this way once that wrap reaches the member. The alarm reports the split; it does not stop it.
- **Old data.** Envelopes stay under the version they were written with (lazy revocation): a removed party already read them. "Credentials to rotate" lists the database credentials it could read.

### What the server stores and checks

Key objects are records of reserved kinds under 0051's record rules, with 0052's ids and 0051's bodies. Every key kind is create-only. The server verifies the Ed25519 signatures it can, with Go's `crypto/ed25519`, as an honest-server control. Clients verify everything anyway.

| Kind | Scope | Id | Written by | Server checks |
|---|---|---|---|---|
| `key.account` | personal | `<account>/<av>` | A genesis, rotation or reset activation change set | Its signature: at genesis under its own IK while the account has none; for a rotation under the current IK; for a replace under the new IK with the current IK's endorsement; at a reset's activation, the fields of its pending `key.reset`. `av` is the current plus one |
| `key.device` | personal | `<account>/<key device>/<av>` | Inside a genesis, rotation, approval or reset activation change set | Its signature, under ASK at `av`; the device row it binds to is the account's |
| `key.recovery` | personal | `<account>/<av>` | With its `key.account` | A certificate at that `av` is in the same change set. Older blobs are deleted once a newer certificate applies |
| `key.reset` | personal | `<account>/<reset>` | The proposing device | Its proposed certificate under its own new IK at the current `av` plus one, kind 2 from an approved device or kind 3 from a sign-in whose device is not approved, stepped up within 300 s; its device certificate under its new ASK, whose DSK is the caller's DPoP key; none other pending. Held 7 days |
| `key.cancel` | personal | `<account>/<reset>` | A device certified at the current `av`, or any device carrying an IK signature | The reset is pending; the IK signature over its `av` and proposed IK, when present |
| `key.request` | personal | `<request>` | The requesting device, bound to its DPoP key | One open request per device row; `expires_at` set by the server; purged after it ends |
| `key.sas` | personal | `<request>/<step>` | `nonce`: an approved device; `reveal`: the request's device; `cancel`: either party | The session states (Approving a device); a `nonce` step's DSK is the caller's DPoP key; purged with its request |
| `key.version` | personal, team | `<owner>/<purpose>/<version>` | Personal: the account's approved device. Team: as Teams says | Its signature, under the signer's ASK at the `av` it names, which for a new record is the signer's current one; the version is the current plus one; `start` 1 only for version 1, a restart from an owner while no member on the roster holds the current version, or the first versions of a reset that starts empty. A `start` 0 version comes with its ring |
| `key.wrap` | personal, team | `<owner>/<purpose>/<version>/<recipient type>/<recipient id>/<recipient version>` | `account`, `trust`: an approval or rotation change set. A scope key: its signer, from an approved device | Its signature, under the writing device's DSK for `account` and `trust`, else under the wrapper's ASK at the `av` it names, the current one for a new record. The recipient is a key device certified at that `av` in the same change set, or, for a scope key, the scope's own account or a team member on the roster, at its current `av`. In a team, a wrap to an account that does not hold the current version, which confirms it, comes only from an owner or admin |
| `key.ring` | personal, team | `<owner>/<purpose>/<version>` | With its version record | Its form, in the same change set as its version |
| `key.member` | team | `<account>/<av>` | That account, any role | The same fields as the account's `key.account` at that `av` |
| `secret_envelope` | personal, team | 0052 | Personal: approved devices. Team: owner, admin, editor holding the current version, from an approved device | `kv` is the scope's current version (`key_version_stale`, `key_version_unknown`); not while the team is `rotation due`. In a team, the writer's account holds the current version, since a member not yet confirmed has no key to seal with (`role`) |
| `history_entry` | history | 0052 | Approved devices | `kv` is the current HK version |

- **Change sets.** Each of these goes up as one push that the server applies whole or not at all: a genesis, a rotation, an approval, a reset proposal, a reset activation, a team creation and a team rotation. Inside an account change set, the current `av` is the one the set introduces, and IK's signature on its `key.account` authorizes the rest. A page never splits one (0051).
- **After a restore.** Devices push back the exact key objects their own account signed, in 0051's order and under every ordinary check, and every refusal is final (0051, After a restore). A team version only another account signed stops the team on the device until its signer's device pushes it back. A refused push ends the scope on the device, as the maintainer decided for forks: a team takes no new version there, and owners create a new team and share again; an account's devices lock and ask the person to sign out, then recover with R or reset. An ended scope stays ended whatever another device puts back later. A lost approval is done again with a new key device, and a lost confirmation at the next team version, so neither meets an id a device holds.
- **Approved** means the DPoP key (RFC 9449, as 0051 profiles it) is the DSK of the key device that the token's device row holds, certified at the account's current `av`, and the row is not removed. In a team scope it is the writing member's own device.
- **Before approval** a signed-in device reads only the key kinds of the personal scope, which hold public keys and ciphertext and no plaintext record, so a recovery can open the scope keys it must carry forward. It writes only its request and that request's `reveal` and `cancel` steps, a genesis while the account has none, a rotation change set that IK signs, a reset proposal and activation as Reset says, and a cancel signed by IK. Anything else is `device_not_approved`.
- **A locked device** (`device_removed`, or left out of a rotation) keeps its keys, stops syncing and shows why. A server can send that signal, so it erases nothing.
- **Removing a device row** of an account with keys needs a DPoP proof from an approved device and a step-up (0051, Step-up), or an install admin in the portal. Either is audited, every device of the account is told, and a reset that row proposed ends.
- **Past grace and after a lapse,** key kinds stay writable and data kinds do not (0051, Gates), so a person can still remove a stolen device.
- **`personalSync` off** keeps the key kinds (0051, 0055). Key objects live in the personal scope on TablePro Sync even when the device's personal provider is iCloud or Off, since team secrets need the account keys.
- **The server reads** the key kinds' fields this table names, `kv`, and DPoP proofs. It holds no key that opens a secret or a history entry, unless it substituted one at first contact (Pins).

### Rollback

**Verifying and advancing.** A client uses a key object in two ways, and only the second depends on what it already holds.

- **Verifying** checks an object's signature under its signer's key at the `av` or version the object names, whose certificate verifies under the IK the client pinned or one that IK endorsed. Holding a newer `av` or version never makes an older object invalid, and verifying moves nothing back. Rings, older version records and certificates, and a wrap the client opens to read a key, are verified only.
- **Advancing** changes what the client holds as current: an account's newest `av`, a scope key's newest version, and the holders it wraps to. A version record above the client's newest counts only when a holder of the version before it signed it under that holder's newest `av` the client knows, and so does every version the client passes on its way to the newest. A wrap adds its recipient to the holders only when signed under its signer's newest `av` the client knows. So a stolen device holding an old ASK cannot advance a client that saw the rotation. A client that meets an older-`av` signature on its way stops at the version before it (`keys.stale`) and writes nothing under that key: for a team key an owner or admin confirms it again (Teams, A stopped device), and for the personal and history keys another device approves it again, or the person recovers with R or resets.
- An object whose signer's certificate or version record has not arrived yet is held until it does, never refused for that.

**What a client keeps.**

- **Per account,** the newest `av` and the IK it verified. A lower `av` never becomes the newest, and an IK it saw replaced never comes back.
- **Per scope key,** the newest version it verified and that version record's digest, the SHA-256 of its signed bytes. It never writes below that version, a version record below it is historical, and at that version it takes only the record with that digest, so a restored state file cannot be handed another record at a version it already passed (0054). The personal and history keys get a new version exactly when the account's `av` changes, at genesis, rotation, replace and reset activation, so the current one is the one signed under the account's current `av`: a client never writes under one signed under an older `av`.
- **Per envelope,** it never takes a copy under a lower `kv` than the copy it holds.
- **In order.** A pull serves a scope's changes in revision order, and the client applies key objects and envelopes in that order. A new or changed envelope counts only under the version in force at its place in the order, which is the newest version record applied at or before that place: the rule the honest server writes by. This replay position is apart from the newest version the client verified. A device that was offline while another wrote under v and then rotated to v + 1 meets the write before the rotation and takes it. A removed device's write that a server slips in after the rotation is refused.
- **Snapshots,** a device's first and every refill, carry no order. The client holds a snapshot's key objects until its pull is caught up (0051, Pull), then verifies them as one set, then its envelopes. A record the device does not hold may come under any version up to the newest, since old envelopes stay under old keys. A server can force a refill, so this is where a removed device with the server's help can still plant content under a key it held (threat model).
- **History** entries live in their own scope, apart from their key's version records, so they have no order against them: an entry under any HK version up to the newest is taken.
- These values, the pins and the open alerts live in the state file's key tables under 0054's MAC and anchor, so a restored file cannot forget a newer version or an alert.
- **Restore on the server.** Key objects are records, so 0051's refill pushes back the ones a device holds, and a scope whose objects cannot all go back ends (After a restore). Every key kind is create-only, so a key object at an id a client already holds with other fields is refused and raises an alarm.

### Libraries

- **Rust:** aws-lc-rs for AES-256-GCM, HKDF-SHA256, Ed25519, X25519, SHA-256 and the system RNG; the AWS-LC 3 module holds FIPS 140-3 certificate #5314. HPKE comes from rustls 0.23 `crypto::aws_lc_rs::hpke::DH_KEM_X25519_HKDF_SHA256_AES_256`, which runs the RFC 9180 vectors but has no audit of its own; G1 adds Wycheproof and the Go differential. rustls leaves X25519 suites out under its `fips` feature, which TablePro does not build. RustCrypto's `hpke` and `ed25519-dalek` are not used, and `ring` stays banned.
- **Go:** `crypto/ed25519` and `crypto/sha256` for the server's checks, and `encoding/base64` in strict mode. `crypto/hpke` (Go 1.26) seals and opens our wraps in differential tests only.
- **Ed25519 validity.** Before either library verifies, both sides refuse an A or R whose encoding is not canonical (y at or above p), an A that is one of the eight points of small order, and S at or above L. The libraries then verify cofactorless, as both do, so Rust and Go give the same answer on every edge case (Chalkias, Garillot and Nikolaenko, 2020).
- **Word list.** The EFF large word list, CC BY 3.0 US; `deny.toml` gains `CC-BY-3.0` and the notices credit it.

### Errors

`tablepro-keys` errors carry a stable `code()` (`core/AGENTS.md`); the server's codes are 0051's.

| Code | When |
|---|---|
| `keys.suite` | A suite other than `tp1` |
| `keys.encoding` | Non-canonical base64url, a wrong byte length, a nonce, tag or `ct` of the wrong length, a version or `av` out of range, a key object body with a duplicate, missing, unknown or wrongly typed member, a JSON plaintext with a duplicate, missing or wrongly typed member or an unknown `v`, bad padding, QR text that does not parse |
| `keys.recovery_key` | Recovery key text of the wrong length or with a bad checksum |
| `keys.signature` | A signature that does not verify, the Ed25519 refusals above included |
| `keys.public_key` | An X25519 key whose shared secret is all zero (RFC 9180 §7.1.4) |
| `keys.open` | A well-formed ciphertext whose AEAD or HPKE open fails: a changed label, AAD or `info` field, another origin, account, scope or version |
| `keys.mismatch` | Unwrapped account keys or blob keys that do not give the certificate's public keys; a wrap whose `pkR` is not the recipient's key at the version it names |
| `keys.kid` | An unwrapped or ring key that does not match its version's `kid` |
| `keys.ring` | A ring whose entry is not the version below its own |
| `keys.stale` | An `av`, version or `kv` below what the client holds or below the version in force at its place in the order; an object that would advance, signed under an older `av` than its signer's newest; account keys from an approver below the device's own newest `av` |
| `keys.step` | An `av` or version that skips |
| `keys.retired_ik` | A certificate under an IK the client saw replaced, offered as the account's newest. Older certificates under that IK still verify the objects signed under them |
| `keys.unendorsed` | An IK change with no endorsement. It opens an alert and fails nothing else |
| `keys.not_holder` | A team version from an account that is not a holder of the version before it (Teams); a restart shown to a client whose account holds the current version; a wrap offered to a stopped device by an account that did not hold the last version it verified |
| `keys.not_compared` | An `account` or `trust` wrap signed by any key but the DSK this side compared; a rotation that keeps a device that is not an own-device pin |
| `keys.commitment` | An `r_N` that does not open `c` |
| `keys.sas_mismatch` | The person says the words differ |
| `keys.session` | A step out of order, a second comparison, or an ended session |
| `keys.conflict` | A key object at an id the client holds, with other fields, or a version record whose digest differs from the one the client anchored or imported: an alarm |
| `keys.destination` | A sealed destination that differs from the record's: the approval case |

### Vectors that `tablepro-keys` ships

JSON in `core/crates/keys/vectors/`, one file per area, with every random input (R, keys, nonces, `r_N`, `r_A`) an input of the case. HPKE draws its own ephemeral key, so wrap cases run the open direction plus a seal-then-open round trip, and the Go side seals with `crypto/hpke` for Rust to open and opens what Rust's production path sealed.

- **Standard:** the RFC 9180 vectors for (0x0020, 0x0001, 0x0002), from the test-vectors JSON the RFC links at revision `5f503c564da00b0687b3de75f1dfbdfc4079ad31`; Wycheproof for AES-GCM, X25519, Ed25519 and HKDF-SHA256.
- **Known answers,** each with its framed bytes before hashing or signing:
  - recovery key text, checksum and parsing (lower case, `I`, `L`, `O`, hyphens, spaces), with a key that starts with zero bytes; IK seed and `K_rec`; the blob;
  - account certificates of each kind with the replace endorsement; device certificates; cancels; `kid`; version records with `start` 0 and 1; every wrap purpose and recipient type with its signature; rings, and a walk down three of them;
  - `LP` of an empty field, of a field with zero bytes inside, and at 65,535 and 65,536 bytes; UUIDs as 16 bytes against record ids as text; each scope and purpose; origins with a default and a non-default port;
  - envelopes for each secret kind and history entries on each side of every padding step: 63 and 64, 127 and 128, 255 and 256, 511 and 512, 1,023 and 1,024, 2,047 and 2,048, 4,095 and 4,096, 8,191 and 8,192 bytes; the trust plaintext with an open alert, a replaced IK and a version per purpose;
  - the SAS commitment and words, both directions; fingerprint words with indexes 0 and 7775, and QR text with its final bits;
  - the state MAC (0054); DPoP proofs (0051).
- **Negative.** Each case names the client's error above and, where the server checks it, the server's code from 0051.

| Case | Client | Server |
|---|---|---|
| A suite not listed | `keys.suite` | `bad_statement` |
| A wrong label, or each AAD or `info` field changed | `keys.open` | `bad_statement` for a signed object |
| Non-canonical base64url, a wrong length, a version of 0 or at or above 2^31; a key object body with a duplicate, missing, unknown or wrongly typed member; a plaintext with a duplicate, missing or wrongly typed member | `keys.encoding` | `bad_statement` |
| A plaintext with a member the reader does not know | taken | none |
| Padding with no 0x80, a non-zero byte after it, or a length off the scale | `keys.encoding` | none |
| A truncated nonce, tag or `ct`, a ring `ct` other than 52 bytes | `keys.encoding` | `bad_statement` for a blob or ring |
| A certificate under another IK | `keys.signature` | `bad_statement` |
| An `av` that goes back; one that skips | `keys.stale`; `keys.step` | `bad_statement` |
| A replace without the old IK's endorsement | `keys.unendorsed` | `bad_statement` |
| A certificate under an IK seen replaced, offered as the newest; the same certificate verifying an object signed before the replace | `keys.retired_ik`; taken | none |
| Account keys in a wrap or blob that do not match their certificate | `keys.mismatch` | none |
| A blob for another origin, account or `av` | `keys.open` | none |
| Recovery key text with a bad checksum or length | `keys.recovery_key` | none |
| A wrap whose signature fails, or whose `pkR` differs from the recipient's certificate | `keys.signature`; `keys.mismatch` | `bad_statement` |
| A `kid` mismatch, from a wrap or a ring | `keys.kid` | none |
| A ring entry other than the version below | `keys.ring` | none |
| A wrap signed under an older `av` than its signer's newest: opens, adds no holder | `keys.stale` for advancing | none |
| A team version signed by an account that is not a holder of the one before, or by a holder under an older `av` | `keys.not_holder`; `keys.stale` | `role`; `bad_statement` |
| A version signed under an older `av` than the client knows for its signer, on the way to a newer one | `keys.stale`; stops at the version before | none |
| Version 7 signed with a removed device's old account key and wrapping to account M, then version 8 signed by M under its current key, in one pull | `keys.stale` at version 7; M is no holder | none |
| A stopped device offered an owner's next rotation whose signer held the last version it verified; one from an account that did not | taken; `keys.not_holder` | `applied` |
| A stopped device whose qualifying admin rotated its account keys since, signing the new wrap under its newest `av` | taken | `applied` |
| A stopped device with no owner or admin on the roster that held its version | the team ends on the device | the device withdraws its report |
| While stopped at version 6, a new wrap of version 6 to account M signed under a removed device's old account key, then M's rotation wrapping to the device under M's current key | `keys.not_holder`; the device stays stopped | none |
| A device stopped on its personal or history key, with no device to approve it | recovery with R or a reset is offered | none |
| A rotation by a member that is not an owner or admin, while due, wrapping to several holders of the version before | taken | `applied` |
| A next team version from a member that is not an owner or admin while no rotation is due | none | `role` |
| A member the server added with no confirming wrap | gets no key | none |
| A team version or wrap naming an account with no `key.member` at that `av` | held until the certificate arrives | `key_dependency` |
| An IK change with no endorsement | `keys.unendorsed`, alert, no wraps until re-confirmed | none |
| An envelope below the version in force at its place in the order, or below the copy held; the same envelope before the rotation that follows it, taken | `keys.stale` | `key_version_stale` |
| An `r_N` that does not open `c`; a commitment over other keys | `keys.commitment` | none |
| Words that differ, with one field changed on one side, N's key device id included | `keys.sas_mismatch`, then a `cancel` step | none |
| An approval wrap signed by ASK, or by a DSK other than the compared one | `keys.not_compared` | `bad_statement` |
| A `nonce` step from a device that is not approved; a second `nonce` | none | `device_not_approved`; `create_only` |
| A `reveal` before the `nonce`, any step after a `cancel`, an approval or `expires_at`, or an approval change set after `expires_at` | `keys.session` | `request_closed` |
| A second open request from one device row | none | `request_pending` |
| An approval built at an `av` a rotation passed, then built again at the new `av`, taken; a replace during a session | `keys.session` after a replace | `bad_statement`, then `applied` |
| A rotation that keeps a device that is not an own-device pin; an own-device pin whose DEK came from a certificate | `keys.not_compared` | none |
| A genesis, rotation, approval, reset or team rotation change set with one bad object | that object's error | that object's code, `change_set` for the rest; nothing applies |
| Two genesis change sets; an identical retry after a timeout | none | `create_only` for the loser; `applied` for the retry |
| A device left out of a rotation, shown the certificate but not yet the whole change set; then all of it | waits; then locks, erases nothing | none |
| Recovery from zero devices that reads the old PK and HK versions and rings before approval and carries them into the new rings | succeeds | `applied` |
| A cancel signed for one reset, replayed against a later reset at the same `av` | `keys.signature` | `bad_statement` |
| A cancel from a removed row's device | none | `device_removed` |
| A reset proposal while one is pending; kind 2 from a sign-in, kind 3 from an approved device | none | `bad_statement` |
| A kind 3 proposal without a step-up | none | `step_up_required` |
| A kind 3 proposal while lost devices' rows remain; one of those devices cancels it | none | `applied`; the cancel ends it |
| The proposing device signs out while its reset is pending, under the reset's DSK; a proof under another key on that row | the reset ends; nothing changes | 204 both |
| A pending reset 7 days past `held_until` with no activation | the reset ends | tombstoned |
| An activation before `held_until`; after the reset ended; from another device | none | `reset_held`; `bad_statement`; `writer_bound` |
| A rotation while a reset is pending, which ends it | the reset ends | `applied` |
| Kind 3 activation with no old PK and HK; kind 2 activation with rings | `start` 1 and no ring; `start` 0 with rings | `applied`; every other device row removed, every team held just before marked `rotation_due`, the personal and history records gone only for kind 3 |
| A team rotation with a wrap to a removed member or to a member's superseded `av` | none | `bad_statement`, `change_set` for the rest; `rotation_due` stays |
| A rotation by a member that is not an owner or admin, with a wrap to a member left out of the version before | none | `role` |
| A restart shown to a client whose account holds the current version; a restart while a holder is on the roster | `keys.not_holder` | `role` |
| A sole owner who reset and restarts its team from the device that held the key | takes its own restart | `applied` |
| A history entry pushed again after an HK rotation, encrypted under the newest version | taken | `applied`; under an older version `key_version_stale` |
| After a restore that lost a team version, its signer's device pushes it back with the same fields, every ordinary check passing | verifies | `applied` |
| A version only another member signed, missing after a restore | the team stops on the device until that member's device pushes it back | none |
| A version one admin rotated and a member another admin confirmed, after a restore | both go back, each from its own signer's device | `applied` each |
| A refused push of the device's own version, then another device puts it back, then a restart | the scope stays ended | `applied` for the other device |
| After a restore that lost a confirmation, a member that is not an owner or admin pushes it back | none | `role`; an owner or admin confirms the member at the next team version |
| A completed reset a restore lost | the account's devices sign out; the person recovers or resets | `bad_statement` |
| A device whose approval a restore lost | locks; approved again with a new key device id | `device_not_approved` until then |
| A removed device's new key device, certified under the current ASK, offered from another row | none | `device_not_approved` |
| A key object pushed again or pulled at a held id with other fields | `keys.conflict` | `create_only` |
| After a state file restore, a version record at an anchored version whose digest differs | `keys.conflict` | none |
| An approver at `av` 1 approves a device that knows `av` 2 under the same IK, the words matching | `keys.stale`; the device keeps its keys | none |
| An approval whose trust pins another account under a different IK than the device's pin | an alert for that account | none |
| An approval whose trust lists the device's pinned IK as replaced, with and without the endorsement held | follows the new IK; an alert | none |
| An approver at the same `av` with a lower personal version, and one with another record at an equal version | keeps its own; `keys.conflict` | none |
| B saw A's rotation and holds team version 6, stopped or not. The person approves B from C, which took version 7 under A's old account key with a wrap to M, and version 8 signed by M, because the server withheld A's rotation from C | B keeps version 6 with its holders and state; version 8 stays a hint its own checks refuse (`keys.stale`) | none |
| C, kept on `av` 1 by the server, took personal versions 2 and 3 signed under the old account key and still holds its version 2. B, at `av` 2 with personal version 2 signed under it, approves C | `keys.conflict` at version 2; the approval fails, and no old-key version becomes current through it | none |
| The same C after an anchored rebuild that kept only its version 3, approved by B | C takes `av` 2 and B's version 2; its version 3 is never current | none |
| The same pair the other way: C, at `av` 2 but holding personal version 3 signed under `av` 1, approves B | B keeps its version 2; C's version 3 is never current | none |
| An approval where neither side holds a personal version signed under the merged current `av` | `keys.stale`; the device keeps its prior state | none |
| An approval over a stopped personal key that brings the version signed under the current `av`, over an ended scope, and a restart after each | clears; stays ended; the same after restart | none |
| A team scope new to the device, imported from the approver | takes its version and record, `ok`, holders from the wraps it accepts | none |
| A device locked by its own account's reset, approved by the resetting device | the lock clears | none |
| A device approved again: its own-device pins become the approver alone, and its next rotation can keep no other | as stated | none |
| A device approved again after a lock or a lost anchor | new key device id; old keys kept until it applies | `applied` |
| A recovery from a fresh row, then a call that needs approval | succeeds | `applied`, then approved |
| A trust record whose alerts, comparisons and replaced IKs alone pass the record limit; a first-use pin with a replaced IK, kept | the approval fails, nothing dropped | `too_large` |
| A sealed destination that differs from the record's | `keys.destination` | none |
| An Ed25519 A of small order, a non-canonical A or R, S at or above L | `keys.signature` | `bad_statement` |
| A rotation or a trust record at the record limit | succeeds | `applied`; over it `too_large` |

- **Go side.** The cloud repository copies the vectors and verifies every certificate, version record and wrap signature in Go, opens every wrap with `crypto/hpke`, and seals the round trips Rust opens.

### Review

- G0 reviews this ADR and the threat model before any key code: a Codex review and an independent security agent.
- G1 reviews `tablepro-keys` against the vectors, with at least an hour of cargo-fuzz per parser and the Go differential.
- G3 runs the hostile-server suite before any release: substituted keys at and after first contact, a made-up member, a server-made wrap, withholding, rollback, split view, a destination rewrite, a fake revocation, a stale version and a suite downgrade.
- 0053's Tamarin model does not carry over. The SAS transcript is TablePro's own, in Vaudenay's commit-then-reveal shape, and no proof covers it as written. The argument: N's commitment fixes its view before `r_A` exists, create-only fixes `r_A` before `r_N` is revealed, and each side hashes its own view, so an attacker who changes either view must match 64.6 bits of digest with one try per request. The rest is signatures and AEAD over fixed inputs.
- No text says a third party verified this design. Whether to commission an external audit is decided before end-to-end encryption leaves beta.

## Threat model summary

The full model is the threat model document. In short:

- **A malicious server alone** reads no secret, history entry or scope key wrapped to keys a client pinned. It cannot forge a certificate, a wrap, a version record or a recovery blob, and cannot change a pinned identity without an alert. It can substitute a key at first contact (a new member, a new teammate on a device recovered with R, a genesis), which the fingerprint words catch when someone compares them, and then gets what is wrapped to that key. It can withhold, delay, serve older state to a device that never saw newer, keep two groups of devices on different views, deny service, and read plaintext records and metadata.
- **Self-hosted,** the operator is the customer's own IT, usually also the IdP admin and the endpoint manager. End-to-end encryption protects secrets from database staff, dumps and backups, not from the organization that runs every endpoint.
- **A phished IdP sign-in** gets team plaintext records its seat allows, and nothing personal or secret. Without the step-up, a passkey the server holds or on the SaaS an emailed code, it cannot start a reset; with it, the honest server holds the reset 7 days in view of every device. Before a person's first passkey, a self-hosted step-up is only as strong as the IdP: whoever holds the IdP sign-in then binds the first passkey.
- **A stolen unlocked device** reads what the person can until it is removed. Removal with R rotates the account and every scope key it held, and the members it confirmed come up for review. On an honest server the device gets none of the new keys. A server that keeps a teammate on the account's old version can still get it a team key that teammate wraps to the old AEK. The person's app alarms if that wrap reaches it, which does not stop the split. Before R is typed, a compromised server can still give it new data.
- **A stolen device working with the server** cannot forge the identity key, which is not on the device. With the server it can still push a reset, which teammates see as an alert.
- **A member** reads every team secret by design, and with the server's help can write one. A removed member keeps what it read.

## Consequences

- **A recovery key comes first** (D6). Team secrets need the account keys, so they need it too. Team plaintext records need none.
- **Removing a lost device needs the recovery key** (D7). Cutting it off from the server does not. The person also reviews the members their account confirmed while that device had the keys.
- **Accepted residual risks.** On 2026-11-25 the maintainer accepted the server-assisted views the vault model leaves open, as 1Password and Bitwarden do: a split view after a removal that wraps the next team key to the old account key, a removed member signing the next team version for members who missed the removal, a member replacing a secret's value with the server's help, old-key records planted in snapshots and history, and a stale view under an exposed old recovery key (threat model, Residual risks 2, 3, 5, 6 and 9). Under risk 2 he also accepted that a member a stolen admin device confirmed can still be shown to other teammates after the person removed it. No step waits for every member to acknowledge a removal; the honest server's `rotation due` holds team envelopes only until the next team version. No text here promises more than those risks allow.
- **Teammates see no change** when a person removes a device or recovers, a notice when the person replaces the recovery key, and an alert after a reset.
- **Approving a device needs both devices online,** with five words to compare. After a device removal, the devices the removing device never compared with join again the same way, and after a recovery every other device does. Every approval is a new key device.
- **A new member waits** for an owner or admin to confirm them in the app. A team key rotation briefly holds new team secrets in the queue.
- **A team's key reaches at most 5,000 members,** so a rotation fits one push. A bigger team splits.
- **A server restore can end a team's or an account's keys.** Devices push the lost key objects back. When one cannot go back, the team is created again and shared again, or the account's devices sign out and the person recovers or resets.
- **A team catch-up a device cannot verify stops it.** An owner or admin who held its last version confirms it again, and with no such owner or admin the team ends on that device. A personal or history stop clears when another device approves it with the version signed under the current `av`, or when the person recovers with R or resets.
- **A reset waits 7 days** on an honest server, and removes the person's other device rows when it applies. A kind 3 reset, which runs whatever device rows remain, deletes the personal and history records (decided).
- **An API origin change** is a new identity, as for tokens and the license (0047). History written under the old origin is not readable (decided).
- **The server verifies Ed25519 signatures** on certificates, version records and wraps, and reads `kv`. It holds no key that opens a secret, except one it substitutes at first contact.
- **No FIPS build of the HPKE suite.** No customer has asked for one. A later suite can add hybrid ML-KEM once draft-ietf-hpke-pq is an RFC; it protects what is written after the move.
- **What other ADRs drop.** 0051, 0052 and 0054 lose the signed logs, member bundles of log statements, forks and generations, signer proposals and time locks, receipts and `taken_at` waits, writer signatures and envelope counters, and keep or adapt the rest, each in its own change. 0044's Secrets section points here.
- **Docs.** The cloud repository's `SECURITY.md` links the threat model.

## Alternatives considered

- **0053's own design.** Hash-chained logs, fork freezes, generations, k-of-n signers with time-locked removal and receipts aimed at split views and stolen signer devices. Each G0 round found new critical or high flaws in those mechanisms. 1Password and Bitwarden ship without them, and the maintainer accepted their trade-off.
- **Holding team writes after a removal until every teammate confirms the rotation.** It would close the split view of Residual risk 2 only for teammates who come back, and a server can keep one away. The maintainer accepted that risk instead.
- **Signing each account key version with the previous ASK instead of IK.** Every device holds ASK, so a stolen device with the server's help could sign a rotation to keys of its own, and teammates would follow it silently.
- **Rotating nothing on device removal,** as 1Password does. A stolen device keeps AEK and would read every later team key from any copy of the wraps.
- **Every key change as an alert,** as Signal shows a new safety number. Each device removal would alert the whole team, and alerts people see often get clicked through.
- **Wrapping team keys automatically on first use.** A server that invents a member, with a public key of its own, would receive the team key: the unauthenticated public key behind ePrint 2026/058's key escrow attacks. Bitwarden's Confirm step is the fix.
- **Revoking a member's confirmation with a signed statement** (`revoke_add`). It would let a removal stop teammates from wrapping to a member a stolen device confirmed even when the server keeps that member on the roster. The maintainer dropped it with the signed logs; the review list and the portal removal cover the honest server.
- **Admin-assisted device approval.** It needs admin escrow of personal keys (Approving a device).
- **A fingerprint over the new device's key only,** as Bitwarden's login with device. The new device could not check which account it joins. Covering both directions without a commitment leaves a birthday search: about 2^32 work at 64 bits.
- **Republishing key objects after a restore under relaxed checks** (round 2). Each relaxed check, of role, of current `av` or of approval, became a way around that check: a member confirming another, a removed device approving itself again. Ordinary writes leave lost approvals and confirmations for the person to redo, as the vault products do.
- **Rings that hold every older version.** A ring grows 36 bytes a version, and a member who churns the key can push it past the record limit, after which nobody can rotate. A chain of one-entry rings costs a reader a walk and has no limit.
- **A list of kept devices signed into the account certificate,** so a device left out could erase its keys on a signed fact. Locking and waiting gives the same safety without the field.
- **MLS** (RFC 9420). It gives forward secrecy for message streams, and "messages sent before they were added to the group will not be accessible" (§3.2), while a vault member must read old secrets. Its Authentication Service, the hard part here, is outside the protocol (§3), and its Commits need one sequencer (§14).
- **A Matrix-style device list that teammates verify,** with keys wrapped per device. Teammates would track every device of every member and wrap again on each change. Wrapping to the account, as a vault does, keeps device lists between the person's own devices and the server.
- **Pins synced between a person's devices.** A new device copies the approver's pins, which covers the gap that matters. Syncing adds a record kind and a merge rule.
- **Writer signatures and counters on envelopes** (0053). Members hold the team key and are trusted with its secrets, and an older envelope under the current version only rolls a value back, which a server can do by withholding anyway.
- **A password-derived key or SRP.** Sign-in is the IdP's, and a password brings back the KDF downgrade attacks of ePrint 2026/058.
- **P-256 for a FIPS build** (0053). No customer has asked for FIPS, and X25519 is the curve the maintainer's brief names.
- **Key transparency** (draft-ietf-keytrans-protocol). It would catch split views, and is still a draft.

## Sources

- 1Password Security Design: account password and Secret Key (§3), keys and enrolling a client (§8.2, §8.4), sharing vaults (§6), revoking access (§10), recovery keys and recovery groups (§12), verifying public keys (Appendix C): https://agilebits.github.io/security-design/
- Bitwarden Security Whitepaper, organizations, account recovery and key rotation: https://bitwarden.com/help/bitwarden-security-white-paper/ ; trusted devices: https://bitwarden.com/help/about-trusted-devices/ ; log in with device: https://bitwarden.com/help/log-in-with-device/ ; fingerprint phrase: https://bitwarden.com/help/fingerprint-phrase/ and https://sdk-api-docs.bitwarden.com/src/bitwarden_crypto/fingerprint.rs.html ; emergency access, the wait and the takeover: https://bitwarden.com/help/emergency-access/ ; event logs, `Confirmed user` and `Removed user`: https://bitwarden.com/help/event-logs/
- Apple Platform Security, secure keychain syncing: https://support.apple.com/guide/security/secure-keychain-syncing-sec0a319b35f/web ; Advanced Data Protection: https://support.apple.com/guide/security/advanced-data-protection-for-icloud-sec973254c5f/web ; iMessage Contact Key Verification: https://security.apple.com/blog/imessage-contact-key-verification/
- Matrix client-server API: the key verification framework, its `m.accepted` cancel to the other devices and its cancel codes, and SAS: https://spec.matrix.org/latest/client-server-api/#key-verification-framework ; logout, which deletes the device and its device keys: https://spec.matrix.org/latest/client-server-api/#post_matrixclientv3logout
- Keybase, per-team key rotation, each previous seed encrypted under the next generation: https://book.keybase.io/docs/teams/crypto
- RFC 9180, HPKE: https://www.rfc-editor.org/rfc/rfc9180.html and its vectors at https://github.com/cfrg/draft-irtf-cfrg-hpke/blob/5f503c564da00b0687b3de75f1dfbdfc4079ad31/test-vectors.json ; RFC 5869, HKDF: https://www.rfc-editor.org/rfc/rfc5869.html ; RFC 8032, EdDSA; RFC 7748, X25519; RFC 9449, DPoP; RFC 9420, MLS; RFC 4648; RFC 6454; RFC 8259, JSON; RFC 7515, JWS
- NIST SP 800-38D (GCM, §8.3), FIPS 180-4
- S. Vaudenay, "Secure Communications over Insecure Channels Based on Short Authenticated Strings", CRYPTO 2005
- Matrix cross-signing: https://matrix.org/docs/older/e2ee-cross-signing/
- Scarlata et al., "Zero Knowledge (About) Encryption", ePrint 2026/058: https://eprint.iacr.org/2026/058
- Albertini, Duong, Gueron, Kölbl, Luykx, Schmieg, "How to Abuse and Fix Authenticated Encryption Without Key Commitment", USENIX Security 2022
- Chalkias, Garillot, Nikolaenko, "Taming the many EdDSAs", SSR 2020
- Crockford Base32: https://www.crockford.com/base32.html ; EFF large word list: https://www.eff.org/deeplinks/2016/07/new-wordlists-random-passphrases
- draft-ietf-hpke-pq: https://datatracker.ietf.org/doc/draft-ietf-hpke-pq/ ; draft-ietf-keytrans-protocol: https://datatracker.ietf.org/doc/draft-ietf-keytrans-protocol/
