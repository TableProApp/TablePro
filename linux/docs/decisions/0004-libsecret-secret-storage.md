# 0004: Secret storage through oo7

- **Status**: Accepted; store API, attributes, labels and the Flatpak path amended 2026-09-15, the rules for edits 2026-10-15
- **Date**: 2026-04-26

## Context

Database connections require credentials. The macOS app stores passwords in the macOS Keychain, keyed by connection UUID, with the `KeychainHelper` wrapper providing a typed API. Linux has no Keychain.

The Linux ecosystem offers:

- **Secret Service** D-Bus API. Implemented by GNOME Keyring (gnome-keyring-daemon) and by KWallet (via `kwalletd6`'s Secret Service compatibility layer).
- **Direct GNOME Keyring** access (older, deprecated in favour of Secret Service).
- **Direct KWallet** access (KDE-only, no GNOME story).
- **Plain-text JSON file** under `~/.config/`. Universal but unsafe.
- **OS-level full-disk encryption** as the only protection. Common in distros but does not protect a running session.
- **No persistence** (prompt every connect). Bad UX, used by some lower-tier tools.

The choice must work on both GNOME and KDE without per-DE branching, must have a maintained Rust binding, and must fail gracefully when the Secret Service is unavailable.

## Decision

Secrets are stored through the **Secret Service D-Bus API**, reached with the **[`oo7`](https://crates.io/crates/oo7)** Rust crate.

- Schema: the `xdg:schema` attribute is the application id plus `.Password`, so a development build never reads an installed build's secrets.
- Attributes: `connection-id` (the UUID) and `kind` (`db_password`, `ssh_password` or `ssh_passphrase`), one item per connection and kind.
- Label: the kind and the target, such as `TablePro database password for app@db.example.com:5432/shop`, translated. A kept secret is relabeled when its target changes. Renaming the connection leaves it.
- Store: `tablepro_storage::SecretStore`, the app's `SecretVault`, with `store`, `load`, `relabel`, `delete_kind` and `delete_connection`.

When the Secret Service or the portal is unavailable (no daemon, sandbox without the portal, headless system), `load` returns `SecretError::ServiceUnavailable` or `SecretError::PortalUnavailable`, and `KeyringCredentials` prompts at connect time with no Remember switch. A connection with nothing saved gets `SecretLookup::NotStored`. The app never falls back to writing passwords to plain files.

## Rationale

Secret Service is the only Linux-wide secret API. Both major desktop environments implement it; outside Flatpak, both `seahorse` (GNOME) and `kwalletmanager` (KDE) display the items under our schema. Choosing a DE-specific API would require runtime DE detection and double the implementation cost.

`oo7` is the most active modern Rust binding for the Secret Service API, maintained by GNOME developers, keeps up with portal API additions, and has clean async API that fits our `tokio`-centric backend. The older `secret-service` crate is unmaintained; the older `libsecret` C-binding crates are heavier and require system development packages.

Falling back to plain files is rejected. Storing user database passwords in cleartext on disk is a class of vulnerability we will not introduce. The only acceptable fallback is the prompt-every-time behaviour.

## Consequences

Accepted:

- **No system library.** oo7 is pure Rust here (`tokio` and `native_crypto`, default features off), so the build needs no libsecret package.
- **Daemon dependency.** Headless or minimal Linux installs without `gnome-keyring-daemon` or `kwalletd` will not store passwords. We accept this and prompt instead.
- **Flatpak.** Inside the sandbox oo7 keeps the items in its own keyring file, encrypted with a key from the Secret portal, so the manifest has no `org.freedesktop.secrets` talk-name. The section below has the details.
- **Keyed by UUID.** A stored secret belongs to the connection's UUID. A rename or a new host keeps it. An import keeps the UUID only for an entry that connects the same way; any other entry gets a new UUID and no secrets.

Gained:

- Single API across GNOME and KDE.
- Outside Flatpak, users can audit and delete the items in `seahorse` or `kwalletmanager`. Inside Flatpak they live in oo7's own file.
- No password is written in clear text. Inside Flatpak, oo7's keyring file is encrypted.
- A small, async-first, well-maintained Rust binding (`oo7`).

## Alternatives considered

**Plain-text JSON file under `~/.config/`.** Rejected on security grounds. Even with file permissions of 600, it loses to `seahorse` for any threat model that includes "another process running as the same user".

**Direct libsecret C bindings.** Workable but adds a system-package dependency for a problem `oo7` solves at the Rust level.

**KWallet-only on KDE, GNOME Keyring-only on GNOME.** Rejected on complexity. We would gain DE-specific UX (KWallet's session unlock prompt is friendlier in KDE) at the cost of doubling the storage backend implementation. Secret Service abstracts both.

**No persistence; prompt every time.** Acceptable as the failsafe behaviour but unacceptable as the primary UX. Power users connect to dozens of databases per day.

**Per-connection encrypted blob with a master password the user enters once per session.** Considered, rejected as YAGNI for the spike's user base. Revisit if a user explicitly requests it; the storage layer's variant model can absorb it.

## How oo7 reaches the keyring (2026-09-15)

Outside Flatpak, oo7 talks to the host Secret Service over D-Bus.

Inside Flatpak, `Keyring::new` first calls the Secret portal's `retrieve`
(oo7 0.6.0, `keyring.rs:30-37`, with `?`). A missing or failing portal
therefore returns `File(Portal(_))` straight away, which the store maps to
`SecretError::PortalUnavailable`. With the portal's key, oo7 opens its own
keyring file under the sandbox's data directory. The D-Bus path is only
reached when `retrieve` succeeds and the file load reports
`PortalNotFound`. The manifest carries no `org.freedesktop.secrets`
talk-name.

## Rules this store follows

- **Unlock before reading.** `Keyring::is_locked` then `unlock`, and the
  same for the item, because a locked keyring otherwise returns nothing
  and the app cannot tell that from "no password saved".
- **Typed failures.** `SecretError` separates a dismissed prompt, a locked
  keyring, a missing service, a missing portal and a bad encoding, because
  the user's next step differs in each case. `is_retryable` marks the two
  that clear once the keyring is unlocked.
- **`NotStored` is not an error.** A connection may legitimately have no
  saved password; the app prompts instead of failing.
- **One item per (connection, kind).** Deleting a connection is a single
  `Keyring::delete` on the connection attributes, so no kind can be left
  orphaned when a later delete fails.
- **Secrets before the list write.** The list records whether a passphrase
  was actually stored, so it has to be written after the attempt. If the
  list write then fails for a new connection, the secrets just stored are
  deleted. For an existing one, connect-and-save keeps them, and an edit
  saved without connecting puts back what the keyring held before.
- **One edit at a time.** Saved-connection edits and copies run in turn,
  since each writes the keyring and then the list; two windows editing
  one connection would otherwise leave one edit's host with the other's
  password.
- **Labels name the kind and the target**, so Seahorse and GNOME Settings
  identify the item without opening TablePro.
- **No migration.** There is no `oo7::migrate` call: the application id
  changed and the old items are abandoned deliberately.
