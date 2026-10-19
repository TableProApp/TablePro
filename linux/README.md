# TablePro Linux

Native Linux database client, the Linux sibling of the macOS TablePro app. The two share no code.

## Status

It connects to five engines: PostgreSQL, MySQL and MariaDB, SQL Server, ClickHouse and SQLite. Each connection session gets a window of its own. Nothing is released yet: no `linux-v*` tag exists. [ROADMAP.md](ROADMAP.md) lists what is built, what is not, and the release criteria.

## Supported servers

TablePro supports the server releases their vendors still support. CI runs each driver's whole Docker suite on every release in the second column ([docs/testing.md](docs/testing.md#server-releases)).

| Engine | Tested releases | Not supported |
|---|---|---|
| PostgreSQL | 14, 17 and 18 | 13 and older, past end of life (13 on 2025-11-13). 19 until it is released |
| MySQL | 8.0, 8.4 and 9.7 | 8.1 to 9.6, innovation releases past end of life. 5.7 and older |
| MariaDB | 10.11, 11.4 and 12.3 | 10.6 and older, past end of life (10.6 on 2026-07-06). Rolling releases such as 13.0 |
| SQL Server | 2017, 2019, 2022 and 2025 | 2016 and older, past extended support (2016 on 2026-07-14) |
| ClickHouse | 26.3 and 26.8 | Monthly releases between long-term ones. 25.8 and older long-term releases, past end of life (25.8 on 2026-08-29) |
| SQLite | the system library, 3.37.0 or newer | older libraries, which the driver refuses when it opens a file |

- PostgreSQL 14 reaches end of life on 2026-11-12.
- MySQL 8.0 reached end of life on 2026-04-30, but Amazon RDS keeps 8.0 instances under paid Extended Support until 2029-07-31, so it stays tested.
- MariaDB 11.8 and PostgreSQL 15 and 16 are supported between the tested releases, which bound them.

## Install

These commands work from the first release, 0.1.0, on amd64 and arm64.

Ubuntu 26.04 and 26.10, from the Launchpad PPA:

```bash
sudo add-apt-repository ppa:tablepro/tablepro
sudo apt install tablepro
```

Fedora 44 and later, from COPR:

```bash
sudo dnf copr enable @tablepro/tablepro
sudo dnf install tablepro
```

apt and dnf, and Software Updater and GNOME Software with them, install the updates. Other distributions build from source ([Quickstart](#quickstart)) until Flathub has the app.

[docs/troubleshooting.md](docs/troubleshooting.md) covers saved passwords, SSH, Kerberos, logs, crash reports and bug reports.

## Privacy

TablePro makes no network requests of its own: no telemetry, no update check and no crash upload. It connects to the database servers and SSH hosts you set up, and nothing else. Crash reports stay on your disk until you attach one to a bug report. Updates come from apt or dnf.

## Stack

| Layer | Pick |
|---|---|
| Language | Rust: 1.98 in `rust-toolchain.toml`, 1.97 the `rust-version` floor |
| GUI toolkit | GTK 4, libadwaita, GtkSourceView and GLib at the GNOME 50 floor ([ADR 0015](docs/decisions/0015-gnome-50-platform-floor.md)) |
| App architecture | gtk-rs subclasses with composite templates, one window per connection session ([ADR 0012](docs/decisions/0012-window-per-session.md)); the saved-queries and CSV import dialogs are still [Relm4](https://relm4.org) 0.11 components |
| Async | the app's tokio runtime (`AppRuntime`) for background work, results delivered to the GLib main loop |
| Database drivers | tokio-postgres with deadpool-postgres (PostgreSQL), sqlx 0.9 (MySQL and MariaDB, SQLite), tiberius 0.13 (SQL Server) and the official `clickhouse` crate, all from crates.io ([ADR 0016](docs/decisions/0016-driver-contract-v2.md)) |
| SSH | the system OpenSSH client ([ADR 0013](docs/decisions/0013-openssh-client-transport.md)) |
| TLS | rustls with aws-lc-rs as the only crypto provider ([ADR 0009](docs/decisions/0009-crypto-provider-and-sources.md)) |
| Secrets | oo7: the Secret portal inside Flatpak, the Secret Service over D-Bus on the host ([ADR 0004](docs/decisions/0004-libsecret-secret-storage.md)) |
| Storage | GSettings for preferences and window state ([ADR 0007](docs/decisions/0007-gsettings-preferences.md)), JSON files for connections and workspace state, SQLite for query history ([docs/storage.md](docs/storage.md)) |
| Build | Meson driving Cargo ([ADR 0006](docs/decisions/0006-meson-cargo-build.md)) |
| Distribution | A Launchpad PPA for Ubuntu 26.04 and later and a COPR project for Fedora 44 and later, Flathub later ([ADR 0018](docs/decisions/0018-ppa-copr-and-flathub-later.md)) |

## What this is not

| Not | Why |
|---|---|
| A port of the macOS app | The macOS app is AppKit and SwiftUI, which Linux does not have, and Swift's GTK bindings are immature. The Linux app shares no source with macOS. |
| A plugin host | Drivers are statically linked at compile time. Adding a database engine = adding one crate + one register call. See [decisions/0001-no-plugin-system.md](docs/decisions/0001-no-plugin-system.md). |
| Cross-platform | Linux only. macOS and iOS have separate apps in this monorepo. |
| Electron / WebView | Native GTK4 widgets throughout. No HTML rendering of any kind. |

## Quickstart

System dependencies:

```bash
# Ubuntu 26.04
sudo apt install -y build-essential pkgconf meson ninja-build gettext desktop-file-utils appstream libglib2.0-bin libxml2-utils libgtk-4-dev libadwaita-1-dev libgtksourceview-5-dev libsqlite3-dev libkrb5-dev clang libclang-dev openssh-client

# Fedora 44
sudo dnf install -y gcc pkgconf meson ninja-build gettext desktop-file-utils appstream glib2-devel libxml2 gtk4-devel libadwaita-devel gtksourceview5-devel sqlite-devel krb5-devel clang-devel openssh-clients

# Arch (not covered by CI)
sudo pacman -S --needed base-devel pkgconf meson ninja gettext desktop-file-utils appstream libxml2 gtk4 libadwaita gtksourceview5 sqlite krb5 clang openssh
```

The Ubuntu list is the .deb's build dependencies in `build-aux/debian/control` and the Fedora list the RPM's in `build-aux/rpm/tablepro.spec`, less the ones only their tests need. CI builds both.

The test suites need a few more: an X server for the GTK tests, a session
bus, the icon theme, a generated `en_US.UTF-8` locale for the catalogue
test, and gnome-keyring for the Secret Service tests.

```bash
# Ubuntu 26.04
sudo apt install -y xvfb xauth dbus-daemon adwaita-icon-theme locales gnome-keyring
sudo localedef -i en_US -f UTF-8 en_US.UTF-8

# Fedora 44
sudo dnf install -y xorg-x11-server-Xvfb xorg-x11-xauth dbus-daemon adwaita-icon-theme glibc-langpack-en gnome-keyring
```

Check the installed versions against the floors in
[ADR 0015](docs/decisions/0015-gnome-50-platform-floor.md). SQLite needs
3.46 or later.

```bash
pkg-config --modversion gtk4 libadwaita-1 gtksourceview-5 glib-2.0 sqlite3
```

Install Rust with [rustup](https://rustup.rs). `rust-toolchain.toml` pins
1.98, and rustup fetches it on the first `cargo` call in this directory.
The workspace also builds on 1.97, the `rustc` the PPA packages build
with.

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
metainfo, the GSettings schema, the icons and the man page. See
[ADR 0006](docs/decisions/0006-meson-cargo-build.md).

Before pushing, run the [fast-job commands](CONTRIBUTING.md#fast-job-commands). [docs/testing.md](docs/testing.md) describes the test suites, including the ones that need Docker.

`libsqlite3-dev` is there because the SQLite driver and the query history
link the system SQLite through sqlx's `sqlite-unbundled` feature rather
than compiling a second copy into the binary. `libclang-dev` lets
`libsqlite3-sys` run bindgen against the installed `sqlite3.h`.

`libkrb5-dev` is there for the app's default `kerberos` feature: SQL
Server Windows integrated auth links MIT Kerberos and runs bindgen against
its headers. `meson setup _build -Dkerberos=false`, or
`cargo build -p tablepro --no-default-features`, leaves it out, and the
connect dialog then hides Windows (Kerberos). clang and libclang stay
either way, for the SQLite bindings.

## Flatpak

`build-aux/flatpak/app.tablepro.TablePro.Devel.json` builds the development
profile from this tree, with network access during the build so cargo can
fetch the crates `Cargo.lock` pins. From `linux/`:

```bash
flatpak-builder --user --install-deps-from=flathub --install --force-clean \
  _flatpak build-aux/flatpak/app.tablepro.TablePro.Devel.json
flatpak run app.tablepro.TablePro.Devel
```

Lint the manifest with Flathub's linter. Its two expected findings are
listed in `build-aux/flatpak/lint-exceptions.json`, and the file only
counts when `--exceptions` is passed too:

```bash
flatpak run --command=flatpak-builder-lint org.flatpak.Builder \
  --exceptions --user-exceptions build-aux/flatpak/lint-exceptions.json \
  manifest build-aux/flatpak/app.tablepro.TablePro.Devel.json
```

The sandbox gets the network, the display, the home folder and the mount
points of removable drives, the SSH agent and the Kerberos KCM socket. The
Secret Service, file choosers, notifications and links go through portals.
[ADR 0008](docs/decisions/0008-flatpak-sandbox-permissions.md) gives the
reason for each grant.

The repository keeps no Flathub manifest. Flathub's policy refuses
manifests and submissions written with AI tools, so maintainers write and
submit that one by hand ([ADR 0018](docs/decisions/0018-ppa-copr-and-flathub-later.md)).

### Screenshots

The metainfo lists the PNGs in `data/screenshots` at the release tag's
URL, so a catalogue fetches the ones of the version it lists.

Take new ones from the app at default settings (light style, blue accent,
Adwaita Sans and Adwaita Mono at 11 pt, scale 1) with a 1000×700 window,
keeping the window shadow and rounded corners, and keep the file names and
captions in step with the metainfo.

## Packages

A `linux-vX.Y.Z` tag publishes the source and vendor tarballs on GitHub
Releases, uploads a source package for Ubuntu 26.04 and 26.10 to the
Launchpad PPA, and starts a COPR build of the spec for Fedora 44 and
later. Both build offline from those tarballs, Launchpad with the Ubuntu
Rust team's `rustc-1.97` and COPR with Fedora's Rust, and apt, dnf and
the software centres update the installed packages
([ADR 0018](docs/decisions/0018-ppa-copr-and-flathub-later.md)).
The packaging is `build-aux/debian` and `build-aux/rpm/tablepro.spec`, and
[docs/releasing.md](docs/releasing.md) has the release steps.

To build both from the committed tree the way CI does, each step in a
fresh container, with Docker or Podman:

```bash
build-aux/packaging/build-packages.sh all _packages
```

It writes the source and vendor tarballs, the Debian source package and
its .deb built offline as Launchpad builds it (checked by lintian), and
the RPMs (checked by rpmlint) under `_packages`, then installs each
package in a fresh container and starts it. `deb` or `rpm` in place of
`all` builds one, and Ubuntu series names after the output directory
replace the default `resolute`. `meson dist` archives `HEAD`, so commit
first.

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
port you typed, not from an SSH tunnel's local forward. Two things are
worth knowing:

- tiberius imports that SPN as a raw Kerberos principal, so it takes the
  default realm and nothing else: `default_realm` from `/etc/krb5.conf`,
  or under Flatpak a DNS record. `[domain_realm]` does not apply: that
  lookup only runs for host-based service names, and tiberius exposes no
  SPN override. A server in another realm works only when your KDC
  answers with a referral, which Active Directory does inside a forest.
  Otherwise the login fails with `KRB5KDC_ERR_S_PRINCIPAL_UNKNOWN`.
- The host has to match the SPN registered on the server. An IP address
  or a CNAME usually does not.

Under Flatpak the app brings its own Kerberos configuration and reads
tickets from the KCM cache. [Kerberos inside Flatpak](docs/drivers/sql-server.md#kerberos-inside-flatpak)
says where the realm, the KDC and the tickets come from there.

## Documentation index

| Topic | File |
|---|---|
| Layered architecture, crate boundaries, dependency rules | [ARCHITECTURE.md](ARCHITECTURE.md) |
| What is built, the backlog and the release criteria | [ROADMAP.md](ROADMAP.md) |
| Contributing: dev workflow, lint, commits, PRs | [CONTRIBUTING.md](CONTRIBUTING.md) |
| **Adding a database driver** | [docs/adding-drivers.md](docs/adding-drivers.md) |
| State management: windows, sessions, background work | [docs/state-management.md](docs/state-management.md) |
| Persistence: secrets, settings, files | [docs/storage.md](docs/storage.md) |
| Error handling conventions | [docs/error-handling.md](docs/error-handling.md) |
| Testing conventions and suites | [docs/testing.md](docs/testing.md) |
| Saved passwords, SSH, Kerberos, logs and crash reports, for users | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Release setup, releases and packaging fixes | [docs/releasing.md](docs/releasing.md) |
| Every guide and driver page | [docs/README.md](docs/README.md) |
| Architecture decision records | [docs/decisions/](docs/decisions/) |

## License

AGPL-3.0-or-later, as the parent TablePro project: see [LICENSE](LICENSE).
