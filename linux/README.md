# TablePro Linux

Native Linux database client. Sister product to the macOS TablePro app, sharing no code but matching the feature set.

## Status

Phases 2 and 3 in progress (see [ROADMAP.md](ROADMAP.md)). The stack (Rust + GTK4 + libadwaita + Relm4 + sqlx / tiberius) runs as an app you can build and use: PostgreSQL, MySQL, SQLite, and MSSQL drivers, workspace tabs, structure editing, SSH tunnels, and query history. It is not beta-shippable yet. Flatpak / Flathub distribution and the remaining hardening items are open.

## Stack

| Layer | Pick |
|---|---|
| Language | Rust 1.98+ |
| GUI toolkit | GTK4 4.22+ + libadwaita 1.9+ + GtkSourceView 5.18+ (GNOME 50, [ADR 0015](docs/decisions/0015-gnome-50-platform-floor.md)) |
| App architecture | gtk-rs subclasses with composite templates, one window per connection session ([ADR 0012](docs/decisions/0012-window-per-session.md)); a few views still on [Relm4](https://relm4.org) |
| Async | the app's tokio runtime (`AppRuntime`) for background work, results delivered to the GLib main loop |
| DB drivers | sqlx (PG / MySQL / SQLite), tiberius (MSSQL), official `clickhouse` crate; planned: fred (Redis), official mongodb / duckdb crates, etc. |
| Persistence | libsecret (passwords), gio::Settings (prefs), JSON files (connection metadata) |
| Distribution | Flathub primary; .deb for Ubuntu 26.04 on GitHub Releases and .rpm for Fedora 44 on COPR ([ADR 0017](docs/decisions/0017-distribution-channels.md)) |

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
pkg-config --modversion gtk4 libadwaita-1 gtksourceview-5 glib-2.0 sqlite3   # need 4.22+ / 1.9+ / 5.18+ / 2.88+ / 3.46+
```

Install Rust with [rustup](https://rustup.rs). `rust-toolchain.toml` pins
1.98, and rustup fetches it on the first `cargo` call in this directory.
Distribution `rustc` packages are usually older than that.

Build and run:

```bash
cd linux
meson setup _build -Dprofile=development
meson compile -C _build
meson devenv -C _build ./crates/app/tablepro
```

`meson devenv` puts the compiled GSettings schema and the askpass helper on
the search paths. Starting `./_build/crates/app/tablepro` outside it aborts
with `GSettings schema app.tablepro.TablePro is not installed`.

Install with `meson install -C _build`, which places the binary, the
askpass helper, the desktop entry, the D-Bus service, the AppStream
metainfo, the icons and the third-party license notices. See
[ADR 0006](docs/decisions/0006-meson-cargo-build.md).

Before pushing, run the [fast-job commands](CONTRIBUTING.md#fast-job-commands).

`libsqlite3-dev` is there because the SQLite driver and the query history
link the system SQLite through sqlx's `sqlite-unbundled` feature rather
than compiling a second copy into the binary. `libclang-dev` lets
`libsqlite3-sys` run bindgen against the installed `sqlite3.h`.

`libkrb5-dev` and `clang` are there for the app's default `kerberos`
feature: SQL Server Windows integrated auth links MIT Kerberos and runs
bindgen at build time. `cargo build -p tablepro --no-default-features`
leaves it out, and the connect dialog then hides Windows (Kerberos).

## Packages

A `linux-vX.Y.Z` tag publishes a .deb for Ubuntu 26.04 on GitHub Releases
and an .rpm for Fedora 44 through COPR, both built from `meson install`
with the crates from the release's vendor tarball
([ADR 0017](docs/decisions/0017-distribution-channels.md)). The packaging
is `build-aux/debian` and `build-aux/rpm/tablepro.spec`.

To build both from the committed tree the way CI does, each step in a
fresh container, with Docker or Podman:

```bash
build-aux/packaging/build-packages.sh all _packages
```

It writes the source and vendor tarballs, the .deb (checked by lintian)
and the RPMs (checked by rpmlint) under `_packages`, then installs each
package in a fresh container and starts it. `deb` or `rpm` in place of
`all` builds one. `meson dist` archives `HEAD`, so commit first.

After a change to `Cargo.lock`, `build-aux/update-third-party-licenses.sh`
rewrites `debian/copyright` and the spec's `License` tag along with
`data/licenses`.

## Opening SQLite files

Once installed, TablePro is in the file manager's **Open With** for
SQLite databases (`application/vnd.sqlite3`). From a terminal:

```bash
tablepro app.sqlite3
```

A running TablePro opens the file in its own window and the new launch
exits. A file already open brings its window forward. A database on a
network or FUSE filesystem asks whether to open read-only first, because
SQLite's locking cannot be trusted there.

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
| State management: windows, sessions, background work | [docs/state-management.md](docs/state-management.md) |
| Persistence: secrets, settings, files | [docs/storage.md](docs/storage.md) |
| Error handling conventions | [docs/error-handling.md](docs/error-handling.md) |
| Testing conventions | [docs/testing.md](docs/testing.md) |
| Architecture decision records | [docs/decisions/](docs/decisions/) |

## License

Same as the parent TablePro project.
