# TablePro Linux

Native Linux database client. Sister product to the macOS TablePro app, sharing no code but matching the feature set.

## Status

Phases 2 and 3 in progress (see [ROADMAP.md](ROADMAP.md)). The stack (Rust + GTK4 + libadwaita + Relm4 + sqlx / tiberius) runs as an app you can build and use: PostgreSQL, MySQL, SQLite, and MSSQL drivers, workspace tabs, structure editing, SSH tunnels, and query history. It is not beta-shippable yet. Flatpak / Flathub distribution and the remaining hardening items are open.

## Stack

| Layer | Pick |
|---|---|
| Language | Rust 1.93+ |
| GUI toolkit | GTK4 4.14+ + libadwaita 1.6+ + GtkSourceView 5.12+ |
| App architecture | [Relm4](https://relm4.org) — Elm-style components on gtk4-rs |
| Async | tokio (DB drivers) bridged to glib main loop (UI) |
| DB drivers | sqlx (PG / MySQL / SQLite), tiberius (MSSQL), official `clickhouse` crate; planned: fred (Redis), official mongodb / duckdb crates, etc. |
| Persistence | libsecret (passwords), gio::Settings (prefs), JSON files (connection metadata) |
| Distribution | Flathub primary, .deb / .rpm / AppImage secondary |

## What this is not

| Not | Why |
|---|---|
| A port of the macOS app | Swift code does not run on Linux, and Swift / GTK bindings are immature. The Linux app shares zero source with macOS. |
| A plugin host | Drivers are statically linked at compile time. Adding a database engine = adding one crate + one register call. See [decisions/0001-no-plugin-system.md](docs/decisions/0001-no-plugin-system.md). |
| Cross-platform | Linux only. macOS and iOS have separate apps in this monorepo. |
| Electron / WebView | Native GTK4 widgets throughout. No HTML rendering of any kind. |

## Quickstart

System dependencies:

```bash
# Ubuntu / Debian
sudo apt install -y build-essential pkg-config meson ninja-build gettext desktop-file-utils appstream libgtk-4-dev libadwaita-1-dev libgtksourceview-5-dev libssl-dev libsecret-1-dev libsqlite3-dev libkrb5-dev clang libclang-dev

# Fedora
sudo dnf install -y gcc pkg-config meson ninja-build gettext desktop-file-utils appstream gtk4-devel libadwaita-devel gtksourceview5-devel openssl-devel libsecret-devel sqlite-devel krb5-devel clang clang-devel

# Arch
sudo pacman -S --needed base-devel pkg-config meson ninja gettext desktop-file-utils appstream gtk4 libadwaita gtksourceview5 openssl libsecret sqlite krb5 clang
```

Verify the right versions are present:

```bash
pkg-config --modversion gtk4 libadwaita-1 gtksourceview-5 sqlite3   # need 4.14+ / 1.6+ / 5.12+ / 3.46+
rustc --version                                             # need 1.93+
```

Build and run:

```bash
cd linux
meson setup _build -Dprofile=development
meson compile -C _build
./_build/crates/app/tablepro
```

`meson devenv -C _build cargo run -p tablepro` runs the same build through
Cargo. Plain `cargo run -p tablepro` also works and falls back to the
`app.tablepro.TablePro.Devel` application ID.

Install with `meson install -C _build`, which places the binary, the
askpass helper, the desktop entry, the D-Bus service, the AppStream
metainfo and the icons. See
[ADR 0006](docs/decisions/0006-meson-cargo-build.md).

Before pushing, run the [fast-job commands](CONTRIBUTING.md#fast-job-commands).

Optional: if the system `-dev` packages above are missing, extract the package payloads under `../.local-deps/root/` (so headers land in `../.local-deps/root/usr/include`) and `source scripts/dev-env.sh` before cargo. Debian-family layouts only.

`libsqlite3-dev` is there because the SQLite driver and the query history
link the system SQLite through sqlx's `sqlite-unbundled` feature rather
than compiling a second copy into the binary. `libclang-dev` lets
`libsqlite3-sys` run bindgen against the installed `sqlite3.h`.

`libkrb5-dev` and `clang` are there for the app's default `kerberos`
feature: SQL Server Windows integrated auth links MIT Kerberos and runs
bindgen at build time. `cargo build -p tablepro --no-default-features`
leaves it out, and the connect dialog then hides Windows (Kerberos).

## SQL Server with Windows integrated auth

Pick **Method → Windows (Kerberos)** in the connect dialog. There is no
username or password to enter: the driver uses whatever ticket `klist`
shows, so get one first.

```bash
kinit you@EXAMPLE.COM
```

The driver asks for `MSSQLSvc/<host>:<port>`, built from the host and
port you typed, not from an SSH tunnel's local forward. Three things are
worth knowing:

- tiberius imports that SPN as a raw Kerberos principal, so it picks up
  `default_realm` from `/etc/krb5.conf` and nothing else. `[domain_realm]`
  does not apply: that lookup only runs for host-based service names, and
  tiberius exposes no SPN override. A server in another realm works only
  when your KDC answers with a referral, which Active Directory does
  inside a forest. Otherwise the login fails with
  `KRB5KDC_ERR_S_PRINCIPAL_UNKNOWN`.
- The host has to match the SPN registered on the server. An IP address
  or a CNAME usually does not.
- Running from source is the supported path today. Under Flatpak the
  sandbox has no `/etc/krb5.conf` and its `/tmp` is private, so a FILE
  ticket cache there is invisible; the manifest grants the config file
  and the KCM socket, and a FILE cache needs `KRB5CCNAME` pointed
  somewhere under `$HOME`.

## Documentation index

| Topic | File |
|---|---|
| Layered architecture, crate boundaries, dependency rules | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Roadmap and current phase | [ROADMAP.md](ROADMAP.md) |
| Contributing: dev workflow, lint, commits, PRs | [CONTRIBUTING.md](CONTRIBUTING.md) |
| **Adding a database driver** | [docs/adding-drivers.md](docs/adding-drivers.md) |
| State management with Relm4 | [docs/state-management.md](docs/state-management.md) |
| Persistence: secrets, settings, files | [docs/storage.md](docs/storage.md) |
| Error handling conventions | [docs/error-handling.md](docs/error-handling.md) |
| Testing conventions | [docs/testing.md](docs/testing.md) |
| Architecture decision records | [docs/decisions/](docs/decisions/) |

## License

Same as the parent TablePro project.
