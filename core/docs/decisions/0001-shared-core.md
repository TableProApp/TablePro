# 0001: One shared Rust core, a native UI per platform

- **Status**: Accepted; SSH on Windows amended by [0009](0009-in-process-ssh-on-windows.md)
- **Date**: 2026-11-02

## Context

TablePro had two apps that shared no code: the Swift app for macOS and iOS, and the Linux app in Rust and GTK 4. A Windows app is next. The Linux workspace already kept its domain types, drivers, sessions, storage, SSH, the MCP server and the AI client in crates with no GUI dependency, but they read GLib's directories, GSettings, the Secret Service through oo7, `/proc` and Unix sockets, and the workspace, the release tarball and every package lived under `linux/`.

## Decision

The UI-free crates move to `core/crates`, build on Linux, Windows and macOS, and every platform's app uses them: the GTK app directly, a Windows app in C# with WinUI 3 over FFI, and the Swift app later.

## Rationale

- One implementation of each driver, the SQL script reader, the session's health and the keyring rules, instead of one per app.
- Rust already holds them, with their tests against the real engines.
- A native UI per platform keeps each app on its toolkit (GTK and libadwaita, WinUI 3, AppKit and UIKit), which a cross-platform UI toolkit would not.

## Consequences

- The Cargo workspace is the top of the repository. `linux/crates` keeps the GTK app and `tablepro-linux-platform`, which holds GSettings, the oo7 store and GLib's XDG paths.
- A platform service reaches the core as a value or a trait the host passes in: `StoragePaths`, `SecretItems` and `SecretVault`, `SecretLabeler` and `SecretItemLabeler`, `ProcessHold` and `SshTunnels`.
- Code that needs a platform's own calls is split with `cfg`: file identity, the safe write, `TCP_USER_TIMEOUT`, the DuckDB file lock, SQL Server's integrated login (MIT Kerberos on Unix, SSPI on Windows). The OpenSSH transport and the relays of MongoDB and Cassandra stay on Unix and Linux for now.
- Linux links the distribution's SQLite; the other targets build the copy sqlx ships.
- Each boundary error has a stable `code()`, so a UI outside Rust can word it; core holds no translation catalog.
- The Linux release tarball is a `git archive` of the workspace files, `core/` and `linux/`, and the Debian, RPM and Flatpak builds run Meson in `linux/`.
- CI checks the core crates and runs the core's unit tests on Windows x64, Windows Arm64 and macOS on every change the Linux suite runs for.
- Drivers stay linked in at compile time ([Linux ADR 0001](../../../linux/docs/decisions/0001-no-plugin-system.md)) until a decision on downloadable driver plugins replaces it.

## Alternatives considered

- **A separate core per app.** Every driver and rule written three times, in Swift, Rust and C#.
- **A cross-platform UI toolkit over the core.** Gives up the native controls each app is built on.
- **Keeping the workspace under `linux/`.** A Windows build would reach into the Linux app's folder, and the Linux packages would carry a path that no longer names what they hold.
