# 0056: End-to-end keys: an account key pair, device key pairs, scope keys wrapped per member, the recovery key and pinned keys

- **Status**: Accepted; supersedes 0053; amends 0044 (Secrets)
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

Every construction is a published standard. `tablepro-keys` composes calls into aws-lc-rs and rustls and holds no primitive of its own.

## How it works

### Suite and encoding

**Suite `tp1`**, the only one a client accepts:

| Use | Construction | Source |
|---|---|---|
| Wraps | HPKE base mode, single shot: KEM 0x0020 DHKEM(X25519, HKDF-SHA256), KDF 0x0001 HKDF-SHA256, AEAD 0x0002 AES-256-GCM | RFC 9180 §5.1.1, §6.1, §7 |
| Data | AES-256-GCM, 96-bit random nonce | NIST SP 800-38D |
| Derivation | HKDF-SHA256, context in `info` | RFC 5869 §3.2 |
| Signatures | Ed25519, pure | RFC 8032 §5.1 |
| Hash | SHA-256 | FIPS 180-4 |

- A client refuses any other suite. The suite name is in every HPKE `info`, AAD and signed message, since RFC 9180 leaves algorithm agreement to the application (§9.7.2).
- `tp1` was 0053's name for a P-256 suite that never shipped. It names this suite from now on.

**Encoding.**

- `LP(x)` is a u32 big-endian length, then the bytes of `x`. `u32(n)` is big-endian and `u8(n)` one byte.
- Account, team, device and request ids are UUIDs as their 16 bytes. The origin is the API origin's ASCII serialization (RFC 6454 §6.2), as 0047 compares it. A record id is its UTF-8 wire text (0052).
- `scope` is `LP(type) || LP(owner)`: `personal` or `history` with the account id, or `team` with the team id. The history key's version records and wraps live in the personal scope and name it; history entries name the `history` scope.
- An X25519 key is its 32 bytes (RFC 7748). An Ed25519 public key is 32 bytes and its private key the 32-byte seed (RFC 8032 §5.1.5).
- JSON carries bytes as canonical base64url without padding (RFC 4648 §5): a decoder refuses non-zero pad bits. A version is a JSON integer from 1 to 2^31-1, refused outside that range when parsed.
- Every signed message, HKDF `info`, HPKE `info`, AAD and hash input starts with `LP(label) || LP("tp1")`, and every one but `kid` and the recovery checksum then names the origin. JSON is never a crypto input. A verifier rebuilds the signed bytes from the parsed fields.

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

**Padding.** Every plaintext under AES-256-GCM except the fixed-size ones, the recovery blob and key wraps, is padded with ISO/IEC 7816-4 padding (0x80, then zeros) to the smallest of 64, 128, 256, 512, 1,024, 2,048 and 4,096 bytes that holds it plus one byte, then to a multiple of 4,096. The padding is removed only after the AEAD opens (RFC 9180 §9.7.6).

### Keys

| Key | Type | Private half lives | Rotates |
|---|---|---|---|
| Recovery key R | 256 random bits | On paper or in a password manager. In memory only while a flow uses it | Replace, reset |
| Identity key IK | Ed25519, seed derived from R | Nowhere. Derived when R is typed, then zeroized | With R |
| Account keys, version `av`: signing key ASK (Ed25519) and encryption key AEK (X25519) | Random | Every approved device's store; under R in the recovery blob | Removing devices, recovery, replace, reset |
| Device keys: DSK (Ed25519, the device's DPoP key) and DEK (X25519) | Random | That device's store only, never synced | Never. A device that loses them is a new device |
| Personal key PK, history key HK, versions `pv`, `hv` | 256-bit symmetric | Wrapped to the account's AEK | With the account keys |
| Team key TK, version `tv`, per team | 256-bit symmetric | Wrapped to each confirmed member's AEK | A member removed; a member's account keys rotated |

- **One identity per account and origin.** IK is the account's identity: teammates pin it, and it certifies each account key version. It never sits on a device, so a stolen device cannot certify keys of its own. This is Matrix's master key, kept off devices, with no stored copy at all.
- **Device stores.** Keychain items with `ThisDeviceOnly` that do not sync; Credential Manager with `CRED_PERSIST_LOCAL_MACHINE`; a Secret Service item. A device with no store, such as Linux without a keyring, holds no keys: it syncs team plaintext records, nothing personal, and reads no team secret.
- **Device keys belong to (origin, account, device row),** not to a session (F5). They survive session expiry, SAML's 10-hour cap, a lost token and a failed deprovisioning check, and resume without approval when the same account signs in on the same row. They are erased on Sign Out, on a verified rotation that leaves the device out, and when another account signs in on that row.
- **A hardware key later.** DSK sits behind a host trait, so a Secure Enclave or TPM P-256 key can replace it with ES256 DPoP proofs and no other change.
- **Versions** count from 1 and step by exactly one, which client and server both check. Secret bytes live in `secrecy` and `zeroize` types and are never logged.

### The recovery key

**R** is 32 bytes from the system RNG.

- **Text.** `B = R || SHA-256(LP("tablepro/v1/recovery-checksum") || LP("tp1") || LP(R))[0..3]`, 35 bytes, written as 56 Crockford Base32 symbols (RFC 4648 §6 bit order) in 14 groups of 4 joined by `-`. Reading drops hyphens and spaces, upper-cases, reads `O` as `0` and `I` and `L` as `1`, and refuses any other length or a bad checksum.
- **Shown once.** Genesis and Replace show it and ask the person to type back two groups chosen at random before anything is pushed.
- **The identity key.** `seed = HKDF-SHA256(salt = none, IKM = R, info = LP("tablepro/v1/identity") || LP("tp1") || LP(origin) || LP(account), L = 32)`. IK is the Ed25519 key with that seed.
- **The recovery blob,** one per `av`: `K_rec = HKDF-SHA256(salt = none, IKM = R, info = LP("tablepro/v1/recovery-wrap") || LP("tp1") || LP(origin) || LP(account), L = 32)`, and `ct = AES-256-GCM(K_rec, nonce, ASK seed || AEK private key, AAD = LP("tablepro/v1/recovery") || LP("tp1") || LP(origin) || LP(account) || u32(av))`.
- **Why recovery is authentic.** Only someone holding R can make a blob that opens or an IK signature that verifies. A recovering device derives IK from R, checks the account certificate under it, and checks that the keys in the blob are the ones the certificate names. A server can withhold or serve an older version, never forge one (F1). This is 1Password's recovery key, which wraps the key set's key under an HKDF subkey of a 256-bit secret, and it needs no `DeriveKeyPair`.

### Signed objects and wraps

**Account certificate**, one per `av`: `Sign(IK, LP("tablepro/v1/account") || LP("tp1") || LP(origin) || LP(account) || u32(av) || LP(IK pub) || LP(ASK pub) || LP(AEK pub) || u8(kind))`, where `kind` is 0 for genesis or a rotation, 1 for a replace and 2 for a reset.

- A replace also carries `Sign(old IK, LP("tablepro/v1/replace") || LP("tp1") || LP(origin) || LP(account) || u32(av) || LP(new IK pub))`.

**Device certificate**, one per (device, `av`): `Sign(ASK at av, LP("tablepro/v1/device") || LP("tp1") || LP(origin) || LP(account) || u32(av) || LP(device id) || LP(DEK pub) || LP(DSK pub))`.

**Key commitment.** `kid(K) = HKDF-SHA256(salt = none, IKM = K, info = LP("tablepro/v1/key-id") || LP("tp1"), L = 32)`. AES-GCM does not commit to its key (Albertini et al., USENIX Security 2022), so every reader checks an unwrapped key against the `kid` its version record names.

**Version record**, one per (scope, purpose, version), purpose `personal`, `history` or `team`: `Sign(signer's ASK, LP("tablepro/v1/version") || LP("tp1") || LP(origin) || scope || LP(purpose) || u32(version) || LP(kid) || LP(signer account) || u32(signer av))`. It is created once, so two devices that rotate at once are serialized: the second gets `create_only`, pulls, and rotates again only if a rotation is still due.

**Wrap.** `(enc, ct) = SealBase(pkR, info, aad = "", pt)` (RFC 9180 §6.1), with:

- `info = LP("tablepro/v1/wrap") || LP("tp1") || LP(origin) || scope || LP(purpose) || u32(version) || LP(recipient type) || LP(recipient id) || u32(recipient version) || LP(pkR)`;
- purpose `account` with recipient type `device` (the device id and `av`), `pkR` the device's DEK, and `pt` the ASK seed and AEK private key, 64 bytes;
- purpose `personal`, `history` or `team` with recipient type `account` (the account id and its `av`), `pkR` that account's AEK, and `pt` the 32-byte key;
- purpose `trust` with recipient type `device`, the approving device's pins and newest versions (Pins), padded JSON.

The wrapper signs it: `Sign(key, LP("tablepro/v1/wrap-sig") || LP("tp1") || LP(info) || LP(enc) || LP(ct) || LP(wrapper account) || u32(wrapper av) || LP(wrapper device))`. The key is the writing device's DSK for `account` and `trust`, since every device holds ASK and a stolen one could sign as any of them, and the wrapper's ASK for a scope key. That is RFC 9180 §9.1.1's signature over `(enc, ct)`: base mode authenticates no sender, so without it a server could wrap a key of its choice to any public key, the attack ePrint 2026/058 found in deployed password managers. The recipient's public key is inside the signed `info`, so a wrap also tells every member which key its wrapper saw for that recipient.

**Opening a wrap,** the recipient checks:

- for `account` and `trust`, the signature under the writing device's DSK, which the recipient holds from a comparison of its own (Approving a device);
- for a scope key, the signature under the wrapper's ASK at the `av` the wrap names, which must be the newest `av` the recipient knows for that account, certified by the IK it pinned;
- for `account`, that the private keys give the public keys of the account certificate at that `av`;
- for a scope key, the `kid` of the version record, and that the record's signer may sign it (Teams).

A client opens only the current version's wraps. Older versions come from that version's ring.

**Ring.** A version v above 1 has a ring: every older version of that key, `u32(i) || K_i` ascending, padded, under `HKDF-SHA256(salt = none, IKM = K_v, info = LP("tablepro/v1/ring-key") || LP("tp1") || LP(origin) || scope || LP(purpose) || u32(v), L = 32)` with `AAD = LP("tablepro/v1/ring") || LP("tp1") || LP(origin) || scope || LP(purpose) || u32(v)`. A reader checks each `K_i` against version i's `kid`. A member confirmed today reads secrets stored years ago, which is what a vault needs. The signer of v writes it.

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


- **Subkey.** `HKDF-SHA256(salt = none, IKM = K_kv, info = LP("tablepro/v1/envelope-key") || LP("tp1") || LP(origin) || scope || LP(parent kind) || LP(record id) || LP(secret kind), L = 32)`, with K a PK version in the personal scope and a TK version in a team. A subkey per record keeps random nonces far below SP 800-38D §8.3's limit.
- **AAD, immutable ids only** (F3): `LP("tablepro/v1/envelope") || LP("tp1") || LP(origin) || scope || LP(parent kind) || LP(record id) || LP(secret kind) || u32(kv)`.
- **Plaintext:** a JSON object `{"v": 1, "secret": ..., "dest": ...}`, padded. `dest` is the destination the secret was sealed for.
- **Fields:** `suite`, `kv`, `nonce`, `ct`. Removing a secret deletes its envelope.
- **At use,** the client compares `dest` with the record's current destination. A difference is the approval case "saved for X, now points to Y", which 0044 requires for any destination change. A server that rewrites a host trips it, since it cannot change `dest`.

**History entry,** created once under a random UUIDv4 id (0052): subkey `HKDF-SHA256(salt = none, IKM = HK_kv, info = LP("tablepro/v1/history-key") || LP("tp1") || LP(origin) || scope || LP(record id), L = 32)` with the history scope, `AAD = LP("tablepro/v1/history") || LP("tp1") || LP(origin) || scope || LP(record id) || u32(kv)`, the entry's fields as padded JSON, and the fields `suite`, `kv`, `nonce`, `ct`. Entries are encrypted at push time and never encrypted again; the HK ring opens old ones.

**Writing.** A client writes an envelope or a history entry only under the newest version of its scope key, after pulling key objects. The honest server refuses any other `kv`.

### Pins

A client keeps, per account it meets, its own included, a pin: the IK, the newest `av` it has verified, and how it pinned (`first use`, `compared`, `replaced`).

- **First use.** The first time a client meets an account, it pins that account's IK from its certificate, with no prompt.
- **Following.** A certificate with the pinned IK and a higher `av` is followed silently: the account rotated its keys, as after a device removal (D7). A lower `av` is refused.
- **Replace.** A new IK endorsed by the pinned IK is followed with a notice ("Ana replaced her recovery key"). The client never goes back to an IK it has seen replaced.
- **Any other change** is an alert, in every team the account is in: "Ana's keys changed. Compare her words before sharing team keys with her." Until the person re-confirms on that device, the client wraps nothing to the account and gives its version records no effect. Re-confirming offers the words. Accepting without comparing is allowed and recorded as `first use`.
- **Fingerprint words.** `f = HKDF-SHA256(salt = none, IKM = IK pub, info = LP("tablepro/v1/fingerprint") || LP("tp1") || LP(origin) || LP(account), L = 32)`. The words are the first six base-7776 digits of f read as a big-endian integer, least significant first, each picking a word of the EFF large word list: about 77 bits. Both people read their own account's words on their own device and compare out of band. In person, one device shows a QR code of `TPF1:` and the 52 Crockford Base32 symbols of f, and the other scans it.
- **Own devices.** A device approved by another device starts with that device's pins (Approving a device), so a server cannot show a new device a different teammate than its other devices see. A device recovered with R starts with none. Own-device pins, the devices a device compared with, are kept beside them.
- **Where they live.** In the TablePro Sync state file's key tables, under 0054's anchor (Rollback).

Bitwarden's fingerprint phrase is five EFF words over the public key. The sixth word here adds margin, since a teammate's pin lasts and the words are compared remotely.

### Approving a device

The new device N and an approved device A, both online, with a commitment so an attacker that controls both views gets one guess (Vaudenay, CRYPTO 2005; Apple's Contact Key Verification and Matrix SAS use it).

1. N signs in, makes DSK and DEK, reads the account's newest certificate and fixes its view: IK, DEK and DSK. It draws a 32-byte `r_N` and writes `key.request`: its device id, DEK, DSK, `c = SHA-256(LP("tablepro/v1/sas-commit") || LP("tp1") || LP(origin) || LP(request id) || LP(IK pub) || LP(DEK pub) || LP(DSK pub) || LP(r_N))`, and `exp`, 600 s later.
2. A shows the request with the device's name, platform and time. The person picks it. A writes the `nonce` step: its own device id, DEK and DSK, and a random 32-byte `r_A`.
3. N writes the `reveal` step, `r_N`. A refuses an `r_N` that does not open `c` with the keys the request carries.
4. Each side computes `d = SHA-256(LP("tablepro/v1/sas") || LP("tp1") || LP(origin) || LP(account) || LP(request id) || LP(IK pub) || LP(N's DEK pub) || LP(N's DSK pub) || LP(r_N) || LP(A's device id) || LP(A's DEK pub) || LP(A's DSK pub) || LP(r_A))` from its own view: A with its own account's IK, the request's keys and its own keys, N with the IK it read, its own keys and the `nonce` step it received. Five words: the first five base-7776 digits of d, as above, about 64 bits. Matching words authenticate both ways: N's keys to A, and the account's IK and A's keys to N.
5. The person compares the words and confirms on both devices. Words that differ end the request as a possible interception.
6. A writes N's device certificate under ASK at the current `av`, the `account` wrap of the account keys to N's DEK, and a `trust` wrap of its pins and newest versions, both wraps signed by its DSK.
7. N checks both wraps under the DSK it compared, opens them, checks the account keys against the certificate at the `av` they name under the IK it compared, pins what A sent, and reads the scope keys through their wraps to AEK. A stolen device that holds ASK cannot sign as A, so it can neither give N old keys nor pins of its choosing.
8. Each side keeps the other's device id, DEK and DSK, as the words covered them and never from a certificate, as an **own-device pin**: a device whose keys it holds from a comparison of its own.

The request expires after 10 minutes, a session allows one comparison, and both devices poll every 1 to 2 seconds while the sheet is open (0051's rate limits).

**Admin-assisted approval is not offered.** Bitwarden's admin approval works because the organization holds every member's user key through account recovery, which is admin escrow of personal secrets: 0044 rules it out, and ePrint 2026/058's key escrow attacks are that class. Team secrets come back after a reset through an owner or admin re-confirming the person (Teams), which is the help an admin can give without escrow.

### Account flows

**Genesis,** on the first device of an account with no certificate.

1. The device makes R and shows it, has two groups typed back, then derives IK and makes ASK, AEK, PK v1 and HK v1.
2. It pushes, as one change set the server applies whole: the certificate at `av` 1, the recovery blob, its own device certificate, and the PK and HK version records with their wraps to AEK.
3. If another device's genesis won, it discards its keys and asks for approval instead. The server takes a genesis from any interactive sign-in while the account has none: it is trust on first use.

**Rotation,** the one procedure behind removing devices, recovery and replace. A device X, with R typed, moves the account from `av` to `av + 1`, keeping a set D of devices: X itself, and only those of its own-device pins the person ticks. A device certificate alone does not qualify a device for D, since every certificate so far is signed by an ASK a stolen device may hold.

1. It makes ASK', AEK', PK and HK at their next versions, and with a replace a new R'.
2. It pushes, as one change set the server applies whole: the certificate at `av + 1` under IK (with a replace, under the new IK with the old IK's endorsement), the recovery blob under R (with a replace, under R'), a device certificate under ASK' and an `account` wrap signed by X's DSK for each device in D, and the PK and HK version records, wraps to AEK' and rings.
3. It copies the new certificate into each team as `key.member`, and rotates each team's key (Teams).
4. It zeroizes R, R' and IK once the change set is built and R' has been typed back.

The server then treats only the devices in D as approved. Each of them pulls, finds its new certificate and wrap, checks the wrap under X's DSK from its own-device pin and the keys under IK, and adopts them. A device left out sees a verified certificate with no entry for it, erases its keys and joins again by approval from a device in D.

**Removing a device** (D7).

- From any approved device, the person picks the lost device. The app removes its device row first, which needs a fresh IdP sign-in within 300 s (0051): the server revokes its tokens and its certificate at once. Then the person types R, and the app runs a rotation. The sheet lists the account's devices with name, platform and when each was added. Those this device compared with can be kept, ticked by default except the lost one; every other device joins again by approval afterwards.
- An install admin can remove a row from the portal, behind the portal's step-up (0044). The browser holds no keys, so this only locks the device: the server answers it `device_removed`. The person's next device asks for R to finish.
- Until R is typed nothing rotates. The device is cut off from the honest server at once, and a compromised server could still give it what is written meanwhile. The app keeps asking.
- Every device left sees the rotation. Teammates see the same IK at a higher `av` and follow it silently.

**Recovery with R** on a device with no approved device at hand: the device reads the newest certificate and blob, which any signed-in device may read, takes R, derives IK, checks the certificate, opens the blob and checks its keys. It has compared with no device, so its rotation keeps only itself, and the person's other devices join again by approval from it. IK's signature on the new certificate authorizes the change set. A server that showed it an older certificate gains nothing: the rotation issues keys no removed device ever had, and on an honest server its `av` must be the next one.

**Sign Out** revokes the device's own certificate when online and erases its keys. Nothing rotates (D7). Offline, it erases anyway and the certificate stays until a rotation leaves it out.

**Replace Recovery Key,** with the current R: a rotation with a new R' and a new IK', endorsed by the old IK. It takes effect at once. Own devices and teammates follow the endorsement with a notice. The honest server deletes the old blob, and a copy someone kept opens only keys older than the replace.

**Reset,** when R is lost.

- Started from an approved device, or from a sign-in with no approved device left after a fresh IdP sign-in within 300 s (`step_up_required` otherwise).
- The device makes R', IK' and new account keys, and pushes the certificate at `av + 1` under IK' with a reset mark, its own device certificate and the new blob. The server holds them pending for 7 days. Every device, the portal and, on the SaaS, an email show it.
- Any device certified at the current `av` cancels it, and so does R through a cancel signed by IK: `Sign(IK, LP("tablepro/v1/cancel") || LP("tp1") || LP(origin) || LP(account) || u32(av + 1) || LP(the pending reset's new IK pub))`. Each reset has a new IK, so a cancel never applies to a later attempt. A revoked or locked device cannot cancel, so a person who lost R first removes a stolen device's row from another device, which needs no R.
- After 7 days with no cancel, the reset takes effect. Only the resetting device is approved. It then writes the rest: PK and HK versions with their wraps and rings, and a copy of its certificate in each team. A device that had the old keys writes new PK and HK versions whose rings hold the old ones, so data stays readable, and the person's other devices join again by approval. A device that had none starts empty: at that moment the server deletes every other record in the account's personal and history scopes (decided).
- Teammates see an IK that nothing endorsed: an alert, and no team key reaches the person until an owner or admin re-confirms them.
- At most one reset is pending per account.

### Teams

Owners and admins manage membership on the server, behind the portal's step-up (0044). The app's keys follow it.

- **Holders.** The holders of version v of a team key are the account and IK that signed v's version record, plus each account and IK that a wrap of v names, when a holder of v signed that wrap. An IK that replaced a holder's IK with its endorsement is the same holder. A client works this out from the version record and the wraps, which every member can read.
- **Who signs a version.** Version 1 is signed by the team's creator, pinned on first use. Version v + 1 counts only when a holder of v signs it, under that holder's newest `av`. So a member the server makes up cannot bring in a key of its own: it holds nothing (ePrint 2026/058's organisation injection and overwrite).
- **Joining.** A member takes the version it was confirmed with on first use, from the wrap a person confirmed, and applies the rule from that version on.
- **Creating a team.** The owner's app makes TK v1, its version record and a wrap to its own AEK.
- **Confirming a member** is an owner's or admin's action in the app, as Bitwarden's Confirm step is. The app pins the member on first use, shows the words with Compare, and on Confirm wraps the current version to the member's AEK. That version's ring gives the older ones. A member added in the portal waits, shown as "waiting for confirmation", until an owner or admin opens the app. Nothing is wrapped automatically, so a member the server invents receives no key until a person confirms it.
- **Removing a member.** The server removes the seat and marks the team `rotation due`. The removing admin's app, or the first holder's app that sees the mark, signs v + 1, writes its ring, and wraps it to every holder of v still on the roster whose pin has no open alert, at each one's newest `av`.
- **A member's account keys rotate** after a device removal, a recovery, a replace or a reset. The server marks `rotation due` each team where that member holds a team key. The member's own app rotates each team in the same flow. After a reset, another holder rotates, and the person waits for re-confirmation.
- **Rotation due.** While it is set, the honest server refuses new team envelopes with `rotation_due`, and apps hold them in their queue. It clears when the next version applies.
- **Re-confirming** after an alert: an owner or admin compares or accepts, then wraps the current version to the new key.
- **No holder left.** When a reset leaves a team with no holder of its current version on the roster, an owner starts it over: the owner signs the next version as at the team's creation, with a ring of the older versions its device still holds, and members take it on first use with a notice that the team key started over. A client that holds the current version never accepts a restart, so a server cannot use one to replace a key a member holds.
- **A member checks what reaches it.** A member whose app sees a wrap or version addressed to one of its own superseded `av` raises an alarm and copies its newest certificate into that team again. A server that withheld the member's rotation from a teammate shows up this way.
- **Old data.** Envelopes stay under the version they were written with (lazy revocation): a removed party already read them. "Credentials to rotate" lists the database credentials it could read.

### What the server stores and checks

Key objects are records of reserved kinds under 0051's record rules, with 0052's ids. The server verifies the Ed25519 signatures it can, with Go's `crypto/ed25519`, as an honest-server control. Clients verify everything anyway.

| Kind | Scope | Id | Written by | Server checks |
|---|---|---|---|---|
| `key.account` | personal | `<account>/<av>` | Genesis; a rotation from an approved device or a device holding R; a reset | Its signature: at genesis under its own IK while the account has none; for a rotation under the current IK; for a replace under the new IK with the current IK's endorsement; for a reset under the new IK, from an approved device or a sign-in stepped up within 300 s, held 7 days, one pending at a time. `av` is the current plus one. Create only |
| `key.device` | personal | `<account>/<device>/<av>` | An approved device, or inside a genesis, rotation or reset change set | Its signature, under ASK at `av`; the device row is the account's. Create only |
| `key.recovery` | personal | `<account>/<av>` | With its `key.account` | A certificate exists at that `av`. Older blobs are deleted once a newer certificate applies |
| `key.cancel` | personal | `<account>/<av>` | A device certified at the current `av`, or any device carrying an IK signature | It names the pending reset's new IK; the IK signature over it when present. Each cancel replaces the last |
| `key.request` | personal | `<request>` | The requesting device, bound to its DPoP key | `exp` at most 600 s after `iat`; one open request per device; purged after expiry |
| `key.sas` | personal | `<request>/<step>` | The step's device | Its form; a `nonce` step's DSK is the caller's DPoP key; purged with its request |
| `key.version` | personal, team | `<owner>/<purpose>/<version>` | Its signer, from an approved device; in a team, an owner for version 1 or a restart, else a member holding a wrap of the current version since its last reset | Its signature, under the signer's ASK at the `av` it names, which for a new record is the signer's current one; the version is the current plus one. Create only |
| `key.wrap` | personal, team | `<owner>/<purpose>/<version>/<recipient type>/<recipient id>/<recipient version>` | Its signer, from an approved device | Its signature, under the writing device's DSK for `account` and `trust`, else under the wrapper's ASK at the `av` it names, the current one for a new record. The recipient is a device certified at that `av`, in the store or the same push, or, for a scope key, the scope's own account or a team member on the roster, at the `av` it names, which for a new record is its current one. In a team, a wrap to an account that holds no wrap of an earlier version since its last reset comes only from an owner or admin. Only its writer replaces one |
| `key.ring` | personal, team | `<owner>/<purpose>/<version>` | The version's signer, from an approved device | Its form |
| `key.member` | team | `<account>/<av>` | That account, any role | A byte-for-byte copy of the account's `key.account` at that `av` |
| `secret_envelope` | personal, team | 0052 | Personal: approved devices. Team: owner, admin, editor, from an approved device | `kv` is the scope's current version (`key_version_stale`, `key_version_unknown`); not while the team is `rotation due` |
| `history_entry` | history | 0052 | Approved devices | `kv` is the current HK version |

- **Republishing.** After a new epoch (0051), any approved device of the account, or in a team of a member, republishes the key objects it holds, byte for byte, whoever signed them, oldest version first, in pushes it marks as republishing. The server checks each signature under the signer and the `av` the object names, against the certificates it holds, and the version step. It skips the checks against the current `av` and the signer's role, since a historical object met them when it was made, and the uploader need not be the signer. Clients check a republished object as they check any.
- **Change sets.** A genesis, a rotation and a reset each go up as one change set that the server applies whole or not at all. Inside one, the current `av` is the one the set introduces, and IK's signature on its `key.account` authorizes the rest.
- **Approved** means the DPoP key (RFC 9449, as 0051 profiles it) is the DSK of a device certified at the account's current `av`, on the device row of the token's sign-in, and not revoked. In a team scope it is the writing member's own device.
- **Before approval** a signed-in device reads only the key kinds of the personal scope, which hold public keys and ciphertext and no plaintext record, so a recovery can open the scope keys it must carry forward. It writes only its request and `reveal` step, a genesis while the account has none, a rotation change set that IK signs, a reset after a step-up, and a cancel signed by IK. Anything else is `device_not_approved`.
- **A locked device** (`device_removed`) keeps its keys, stops syncing and shows that an admin removed it. A server can send that signal, so it erases nothing.
- **Removing a device row** of an account with keys needs a DPoP proof from an approved device and a fresh IdP sign-in, or an install admin in the portal. Either is audited and every device of the account is told.
- **Past grace and after a lapse,** key kinds stay writable and data kinds do not (0051, Gates), so a person can still remove a stolen device.
- **`personalSync` off** keeps the key kinds (0051, 0055). Key objects live in the personal scope on TablePro Sync even when the device's personal provider is iCloud or Off, since team secrets need the account keys.
- **The server reads** no secret and no history. It reads the key kinds' fields this table names, `kv`, and DPoP proofs.

### Rollback

- **Per account,** a client keeps the newest `av` and the IK it verified, and refuses a lower `av` or an IK it saw replaced.
- **Per scope key,** it keeps the newest version, refuses a version record below it, and never writes below it.
- **Per envelope,** it never takes a copy under a lower `kv` than the copy it holds.
- **In order.** A pull serves a scope's changes in revision order, and the client applies key objects and envelopes in that order. A new or changed envelope counts only under the scope's newest version at its place in the order, which is the rule the honest server writes by. A device that was offline while another wrote under v and then rotated to v + 1 meets the write before the rotation and takes it. A removed device's write that a server slips in after the rotation is refused.
- **Snapshots,** a device's first and every refill, carry no order. A record the device does not hold may come under any version up to the newest, since old envelopes stay under old keys. A server can force a refill, so this is where a removed device with the server's help can still plant content under a key it held (threat model).
- **History** entries live in their own scope, apart from their key's version records, so they have no order against them: an entry under any HK version up to the newest is taken.
- These values, the pins and the open alerts live in the state file's key tables under 0054's MAC and anchor, so a restored file cannot forget a newer version or an alert.
- **Restore on the server.** Key objects are records, so 0051's refill republishes them, from whichever device holds them, and their signatures make them valid as they were (Republishing). A key object at a position a client already holds with different bytes is refused and raises an alarm.

### Libraries

- **Rust:** aws-lc-rs for AES-256-GCM, HKDF-SHA256, Ed25519, X25519, SHA-256 and the system RNG; the AWS-LC 3 module holds FIPS 140-3 certificate #5314. HPKE comes from rustls 0.23 `crypto::aws_lc_rs::hpke::DH_KEM_X25519_HKDF_SHA256_AES_256`, which runs the RFC 9180 vectors but has no audit of its own; G1 adds Wycheproof and the Go differential. rustls leaves X25519 suites out under its `fips` feature, which TablePro does not build. RustCrypto's `hpke` and `ed25519-dalek` are not used, and `ring` stays banned.
- **Go:** `crypto/ed25519` and `crypto/sha256` for the server's checks, and `encoding/base64` in strict mode. `crypto/hpke` (Go 1.26) opens our wraps in differential tests only.
- **Ed25519 validity.** Both refuse a non-canonical S. The edge-case vectors must get the same answer from both (Chalkias, Garillot and Nikolaenko, 2020).
- **Word list.** The EFF large word list, CC BY 3.0 US; `deny.toml` gains `CC-BY-3.0` and the notices credit it.

### Vectors that `tablepro-keys` ships

JSON in `core/crates/keys/vectors/`, one file per area, with every random input (R, keys, nonces, `r_N`, `r_A`) an input of the case. HPKE draws its own ephemeral key, so wrap cases run the open direction plus a seal-then-open round trip.

- **Standard:** the RFC 9180 vectors for (0x0020, 0x0001, 0x0002); Wycheproof for AES-GCM, X25519, Ed25519 and HKDF-SHA256.
- **Known answers:** recovery key text, checksum and parsing (lower case, `I`, `L`, `O`, hyphens, spaces); IK seed and `K_rec`; the blob; account certificates of each kind with the replace endorsement; device certificates; cancels; `kid`; version records; every wrap purpose and recipient type with its signature; rings; envelopes for each secret kind at padding boundaries (63, 64, 4,096 and 4,097 bytes); history entries; the SAS commitment and words, both directions; fingerprint words and QR text; DPoP proofs.
- **Negative,** each with the error code it must produce:
  - a suite not listed, a wrong label, each AAD or `info` field changed, non-canonical base64url, a version of 0 or at or above 2^31;
  - a certificate under another IK, an `av` that goes back or skips, a replace without the old IK's endorsement, a certificate under an IK seen replaced;
  - account keys in a wrap or blob that do not match their certificate; a blob for another origin, account or `av`; a recovery key with a bad checksum or length;
  - a wrap whose signature fails, whose signer is not on the newest `av`, or whose `pkR` differs from the recipient's certificate; a `kid` mismatch;
  - a team version signed by an account that holds no wrap of the previous version, or by a holder under an older `av`; a member the server added with no confirming wrap, given no key;
  - an IK change with no endorsement, which alerts and blocks wraps until re-confirmed;
  - an envelope under a version below the scope's newest at its place in the revision order, and below the copy held; the same envelope taken in order before the rotation that follows it;
  - an `r_N` that does not open its commitment, a commitment over other keys, words that differ, an approval wrap signed by ASK or by a DSK other than the compared one;
  - a rotation that keeps a device that is not an own-device pin of the rotating device; an own-device pin whose DEK came from a certificate a stolen ASK signed rather than from the words;
  - recovery from zero devices that reads the old PK and HK versions and rings before approval and carries them into the new rings;
  - after a restore that lost a team version, its republication by a holder other than its signer, taken, also once the signer's newer certificate was republished first; the same record as a new write, refused;
  - a cancel signed for one reset, replayed against a later reset at the same `av`, refused;
  - a team restart shown to a client that holds the current version;
  - a sealed destination that differs from the record's;
  - Ed25519 small-order points, a non-canonical R or A, and S at or above L.
- **Go side.** The cloud repository copies the vectors and verifies every certificate, version record and wrap signature in Go, and opens every wrap with `crypto/hpke`.

### Review

- G0 reviews this ADR and the threat model before any key code: a Codex review and an independent security agent.
- G1 reviews `tablepro-keys` against the vectors, with at least an hour of cargo-fuzz per parser and the Go differential.
- G3 runs the hostile-server suite before any release: substituted keys at and after first contact, a made-up member, a server-made wrap, withholding, rollback, split view, a destination rewrite, a fake revocation, a stale version and a suite downgrade.
- 0053's Tamarin model does not carry over. The SAS exchange is Vaudenay's, which has its own proof, and the rest is signatures and AEAD over fixed inputs.
- No text says a third party verified this design. Whether to commission an external audit is decided before end-to-end encryption leaves beta.

## Threat model summary

The full model is the threat model document. In short:

- **A malicious server alone** never reads a secret, a history entry or a scope key. It cannot forge a certificate, a wrap, a version record or a recovery blob, and cannot change a pinned identity without an alert. It can substitute a key at first contact (a new member, a new teammate on a device recovered with R, a genesis), which the fingerprint words catch. It can withhold, delay, serve older state to a device that never saw newer, keep two groups of devices on different views, deny service, and read plaintext records and metadata.
- **Self-hosted,** the operator is the customer's own IT, usually also the IdP admin and the endpoint manager. End-to-end encryption protects secrets from database staff, dumps and backups, not from the organization that runs every endpoint.
- **A phished IdP sign-in** gets team plaintext records its seat allows, and nothing personal or secret. It can start a reset, which waits 7 days in view of every device.
- **A stolen unlocked device** reads what the person can until it is removed. Removal with R gives every scope keys it never had. Before R is typed, a compromised server can still give it new data.
- **A stolen device working with the server** cannot take the identity: IK is not on the device.
- **A member** reads every team secret by design, and with the server's help can write one. A removed member keeps what it read.

## Consequences

- **A recovery key comes first** (D6). Team secrets need the account keys, so they need it too. Team plaintext records need none.
- **Removing a lost device needs the recovery key** (D7). Cutting it off from the server does not.
- **Teammates see no change** when a person removes a device or recovers, a notice when the person replaces the recovery key, and an alert after a reset.
- **Approving a device needs both devices online,** with five words to compare. After a device removal, the devices the removing device never compared with join again the same way, and after a recovery every other device does.
- **A new member waits** for an owner or admin to confirm them in the app. A team key rotation briefly holds new team secrets in the queue.
- **A reset takes 7 days.** With no device left, it deletes the personal and history records (decided).
- **An API origin change** is a new identity, as for tokens and the license (0047). History written under the old origin is not readable (decided).
- **The server verifies Ed25519 signatures** on certificates, version records and wraps, and reads `kv`. It reads no secret.
- **No FIPS build of the HPKE suite.** No customer has asked for one. A later suite can add hybrid ML-KEM once draft-ietf-hpke-pq is an RFC; it protects what is written after the move.
- **What other ADRs drop.** 0051, 0052 and 0054 lose the signed logs, member bundles of log statements, forks and generations, signer proposals and time locks, receipts and `taken_at` waits, writer signatures and envelope counters, and keep or adapt the rest, each in its own change. 0044's Secrets section points here.
- **Docs.** The cloud repository's `SECURITY.md` links the threat model.

## Alternatives considered

- **0053's own design.** Hash-chained logs, fork freezes, generations, k-of-n signers with time-locked removal and receipts aimed at split views and stolen signer devices. Each G0 round found new critical or high flaws in those mechanisms. 1Password and Bitwarden ship without them, and the maintainer accepted their trade-off.
- **Signing each account key version with the previous ASK instead of IK.** Every device holds ASK, so a stolen device with the server's help could sign a rotation to keys of its own, and teammates would follow it silently.
- **Rotating nothing on device removal,** as 1Password does. A stolen device keeps AEK and would read every later team key from any copy of the wraps.
- **Every key change as an alert,** as Signal shows a new safety number. Each device removal would alert the whole team, and alerts people see often get clicked through.
- **Wrapping team keys automatically on first use.** A server that invents a member, with a public key of its own, would receive the team key: the unauthenticated public key behind ePrint 2026/058's key escrow attacks. Bitwarden's Confirm step is the fix.
- **Admin-assisted device approval.** It needs admin escrow of personal keys (Approving a device).
- **A fingerprint over the new device's key only,** as Bitwarden's login with device. The new device could not check which account it joins. Covering both directions without a commitment leaves a birthday search: about 2^32 work at 64 bits.
- **MLS** (RFC 9420). It gives forward secrecy for message streams, and "messages sent before they were added to the group will not be accessible" (§3.2), while a vault member must read old secrets. Its Authentication Service, the hard part here, is outside the protocol (§3), and its Commits need one sequencer (§14).
- **A Matrix-style device list that teammates verify,** with keys wrapped per device. Teammates would track every device of every member and wrap again on each change. Wrapping to the account, as a vault does, keeps device lists between the person's own devices and the server.
- **Pins synced between a person's devices.** A new device copies the approver's pins, which covers the gap that matters. Syncing adds a record kind and a merge rule.
- **Writer signatures and counters on envelopes** (0053). Members hold the team key and are trusted with its secrets, and an older envelope under the current version only rolls a value back, which a server can do by withholding anyway.
- **A password-derived key or SRP.** Sign-in is the IdP's, and a password brings back the KDF downgrade attacks of ePrint 2026/058.
- **P-256 for a FIPS build** (0053). No customer has asked for FIPS, and X25519 is the curve the maintainer's brief names.
- **Key transparency** (draft-ietf-keytrans-protocol). It would catch split views, and is still a draft.

## Sources

- 1Password Security Design: account password and Secret Key (§3), keys and enrolling a client (§8.2, §8.4), sharing vaults (§6), revoking access (§10), recovery keys and recovery groups (§12), verifying public keys (Appendix C): https://agilebits.github.io/security-design/
- Bitwarden Security Whitepaper, organizations, account recovery and key rotation: https://bitwarden.com/help/bitwarden-security-white-paper/ ; trusted devices: https://bitwarden.com/help/about-trusted-devices/ ; log in with device: https://bitwarden.com/help/log-in-with-device/ ; fingerprint phrase: https://bitwarden.com/help/fingerprint-phrase/ and https://sdk-api-docs.bitwarden.com/src/bitwarden_crypto/fingerprint.rs.html
- Apple Platform Security, secure keychain syncing: https://support.apple.com/guide/security/secure-keychain-syncing-sec0a319b35f/web ; Advanced Data Protection: https://support.apple.com/guide/security/advanced-data-protection-for-icloud-sec973254c5f/web ; iMessage Contact Key Verification: https://security.apple.com/blog/imessage-contact-key-verification/
- RFC 9180, HPKE: https://www.rfc-editor.org/rfc/rfc9180.html ; RFC 5869, HKDF: https://www.rfc-editor.org/rfc/rfc5869.html ; RFC 8032, EdDSA; RFC 7748, X25519; RFC 9449, DPoP; RFC 9420, MLS; RFC 4648; RFC 6454
- NIST SP 800-38D (GCM, §8.3), FIPS 180-4
- S. Vaudenay, "Secure Communications over Insecure Channels Based on Short Authenticated Strings", CRYPTO 2005; Matrix SAS verification: https://spec.matrix.org/latest/client-server-api/#short-authentication-string-sas-verification
- Matrix cross-signing: https://matrix.org/docs/older/e2ee-cross-signing/
- Scarlata et al., "Zero Knowledge (About) Encryption", ePrint 2026/058: https://eprint.iacr.org/2026/058
- Albertini, Duong, Gueron, Kölbl, Luykx, Schmieg, "How to Abuse and Fix Authenticated Encryption Without Key Commitment", USENIX Security 2022
- Chalkias, Garillot, Nikolaenko, "Taming the many EdDSAs", SSR 2020
- Crockford Base32: https://www.crockford.com/base32.html ; EFF large word list: https://www.eff.org/deeplinks/2016/07/new-wordlists-random-passphrases
- draft-ietf-hpke-pq: https://datatracker.ietf.org/doc/draft-ietf-hpke-pq/ ; draft-ietf-keytrans-protocol: https://datatracker.ietf.org/doc/draft-ietf-keytrans-protocol/
