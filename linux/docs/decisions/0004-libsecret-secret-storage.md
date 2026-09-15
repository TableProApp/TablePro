# 0004 — libsecret via oo7 for password storage

- **Status**: Accepted
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

Passwords are stored via the **Secret Service D-Bus API**, accessed through the **[`oo7`](https://crates.io/crates/oo7)** Rust crate.

- Schema name: `app.tablepro.TablePro.Password`.
- Attributes: `connection-id` (the UUID).
- Label: the human-readable connection name, kept in sync on rename.
- Wrapper: `storage::secrets`, exposing `store_password`, `load_password`, `delete_password`.

When the Secret Service is unavailable (no daemon, sandbox without portal, headless system), the storage layer returns `Ok(None)` from `load_password`. The UI prompts the user at connect time. The app never falls back to writing passwords to plain files.

## Rationale

Secret Service is the only Linux-wide secret API. Both major desktop environments implement it; both `seahorse` (GNOME) and `kwalletmanager` (KDE) display secrets stored under our schema correctly. Choosing a DE-specific API would require runtime DE detection and double the implementation cost.

`oo7` is the most active modern Rust binding for the Secret Service API, maintained by GNOME developers, keeps up with portal API additions, and has clean async API that fits our `tokio`-centric backend. The older `secret-service` crate is unmaintained; the older `libsecret` C-binding crates are heavier and require system development packages.

Falling back to plain files is rejected. Storing user database passwords in cleartext on disk is a class of vulnerability we will not introduce. The only acceptable fallback is the prompt-every-time behaviour.

## Consequences

Accepted:

- **System dependency.** `libsecret-1` development package required at build time on systems where `oo7` falls back to libsecret backend (the "compat" feature).
- **Daemon dependency.** Headless or minimal Linux installs without `gnome-keyring-daemon` or `kwalletd` will not store passwords. We accept this and prompt instead.
- **Flatpak portal.** In sandboxed builds, Secret Service access is mediated by `xdg-desktop-portal`. Verified working on Flatpak 1.16.4+. We pin runtime versions accordingly.
- **One-way migration.** Once a connection's password is stored, it is keyed by UUID. Re-imports keep the same UUID; renames update the label only.

Gained:

- Single API across GNOME and KDE.
- Native integration with `seahorse` / `kwalletmanager` — users can audit and delete secrets through their distro's standard tools.
- No password ever written to a regular file by the app.
- A small, async-first, well-maintained Rust binding (`oo7`).

## Alternatives considered

**Plain-text JSON file under `~/.config/`.** Rejected on security grounds. Even with file permissions of 600, it loses to `seahorse` for any threat model that includes "another process running as the same user".

**Direct libsecret C bindings.** Workable but adds a system-package dependency for a problem `oo7` solves at the Rust level.

**KWallet-only on KDE, GNOME Keyring-only on GNOME.** Rejected on complexity. We would gain DE-specific UX (KWallet's session unlock prompt is friendlier in KDE) at the cost of doubling the storage backend implementation. Secret Service abstracts both.

**No persistence; prompt every time.** Acceptable as the failsafe behaviour but unacceptable as the primary UX. Power users connect to dozens of databases per day.

**Per-connection encrypted blob with a master password the user enters once per session.** Considered, rejected as YAGNI for the spike's user base. Revisit if a user explicitly requests it; the storage layer's variant model can absorb it.
