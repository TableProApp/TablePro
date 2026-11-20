# 0039: DBX's passwords are read with the key it keeps in the platform's store

- **Status**: Accepted; amends 0033 and 0008
- **Date**: 2026-11-20

## Context

DBX keeps every saved secret in `dbx.db` as an AES-256-GCM envelope under one key, and keeps that key in the platform's store under its own names, so the importer brought DBX's connections over without passwords on every platform ([0033](0033-foreign-import-and-result-editing-through-the-ffi.md), Consequences). The maintainer chose on 2026-11-19 to read that key on macOS, Windows and Linux. The scheme below is DBX's own, read from t8y2/dbx at 3e34951 (`crates/dbx-core/src/persistence/secret_codec.rs` and `storage.rs`) and the keyring crate 3.6.3 it writes through.

## Decision

### Where the key is

- An installed DBX looks for its key in this order, and the importer follows it: the key file an older DBX wrote, `<config>/dbx/secret.key`, when it holds a key; then the store, under service `com.dbx.app.secret-store.v1` and account `local-data-encryption-key`.
- macOS: the keychain's generic password by that service and account, through `ForeignHost::keychain`.
- Windows: the generic credential `local-data-encryption-key.com.dbx.app.secret-store.v1`, its blob read as UTF-16, through the new `ForeignHost::credential_manager`. When there is none, DBX's copy in `%APPDATA%\dbx\secret-store.key.dpapi`: `DBXDPAPI1` and a DPAPI blob sealed with the service's name in UTF-16 as entropy, which `DataProtection::unprotect` now takes.
- Linux: the Secret Service item holding `target=default`, `service` and `username`, in any collection, then one holding only `service` and `username` in the default collection, as an older keyring crate wrote it, through the new `ForeignHost::secret_service`.
- The key is 32 bytes in unpadded URL-safe base64, or 64 hex digits. DBX stretches anything else with Argon2id; only a key written by hand holds one, and it reads as no key.

### What is read

- `connection_secrets` row `(connection id, password)`, and for the hop next to the database its own layer's `transport_layers.<id or place>.ssh_password` and `ssh_key_passphrase`, falling back to where an older DBX kept them. A hop on a tunnel profile takes the profile's own fields, each filled from its blob, `(tunnel_profile.<id>, config)`, only where empty, as DBX merges them.
- An envelope is `dbxenc1.<nonce>.<ciphertext and tag>` over data that names its row, opened with aws-lc-rs, which every app already links for TLS. A row with plain text and no envelope is from before DBX encrypted its secrets, and is read as DBX reads it. A password left in a connection's JSON is not, as DBX never reads it.
- The connections, profiles and secret rows are read in one read transaction, so a save DBX commits meanwhile never pairs a connection's old host with its new password.
- The key is looked up once, after that read ends and only at the first envelope, so an import that needs none never asks the store or prompts.

### The outcome

- A host that hands over no store for its platform reads no DBX password, the key file included, and the review says they stayed in the keyring (`PasswordOutcome::LeftInKeychain`). An app that tells the user it cannot read them never does.
- A store that refuses, no key anywhere, an envelope the key does not open, or secret rows that stop reading before their end, as on a lock, leave those passwords out and the review says some were not read (`PasswordOutcome::Stopped`).
- The FFI's Windows host passes `CredReadW` of one generic credential, never following TablePro's own parts into another app's, so the Windows app reads DBX's passwords with no code of its own and offers them in its import dialog.

## Rationale

- Each store gets a seam named for it, so no other importer starts asking a store it never asked: DataGrip asks `keychain()` on every platform.
- Any app the user runs reads the user's generic credentials without a prompt, so reading DBX's adds no access Windows does not already give.
- aws-lc-rs adds no crate to any app, where `aes-gcm` and `argon2` would add crates to the Linux app's license set.

## Consequences

- The Linux app passes `PlainHost`, so it reads no DBX password until it passes a host with `secret_service()` over the Secret Service's D-Bus API and offers the option for DBX, after Linux 0.1.0. Inside a Flatpak that needs `org.freedesktop.secrets`, since the Secret portal shows an app only its own items.
- The macOS app keeps its own importers, which have no DBX importer; a macOS host through the FFI passes `PlainHost` until it gets a keychain.
- A portable DBX's `data/.dbx/secret.key` and the `DBX_SECRET_KEY` variables are not followed, as `DBX_DATA_DIR` is not.

## Alternatives considered

- **Answering `ForeignKeychain::read_password` on Windows and Linux the way the keyring crate names items.** One crate's convention in every host, and DataGrip would start asking Credential Manager.
- **Reading the key file with no store from the host.** The Linux app would import passwords under a switch that says it cannot read them.
- **Reading the Secret Service in the core.** A platform service ([0008](0008-importers-from-other-apps.md), Alternatives).
