# TablePro Linux

Native Linux database client, the Linux sibling of the macOS TablePro app. It builds on the shared Rust core in [`../core`](../core/ARCHITECTURE.md), which the macOS app does not use yet.

## Status

The public beta is available as [0.1.0-beta.3](https://github.com/TableProApp/TablePro/releases/tag/linux-v0.1.0-beta.3). It connects to 11 engines: PostgreSQL, MySQL, MariaDB, SQL Server, ClickHouse, Cassandra, ScyllaDB, SQLite, DuckDB, Redis and MongoDB. [Supported servers](#supported-servers) lists the tested versions and limits. A window holds several connection sessions side by side in one tab view. Follow the [install guide](https://docs.tablepro.app/linux/install) for the beta PPA, COPR and Flatpak channels. [docs/features.md](docs/features.md) lists what is built, the repository's [ROADMAP.md](../ROADMAP.md) what is not, and [docs/releasing.md](docs/releasing.md#release-criteria) the release criteria.

## Supported servers

TablePro supports the server releases their vendors still support. CI runs each driver's whole Docker suite on every release in the second column ([docs/testing.md](docs/testing.md#server-releases)).

| Engine | Tested releases | Not supported |
|---|---|---|
| PostgreSQL | 14, 15, 17 and 18 | 13 and older, past end of life (13 on 2025-11-13). 19 until it is released |
| MySQL | 8.0, 8.4 and 9.7 | 8.1 to 9.6, innovation releases past end of life. 5.7 and older |
| MariaDB | 10.11, 11.4 and 12.3 | 10.6 and older, past end of life (10.6 on 2026-07-06). Rolling releases such as 13.0 |
| SQL Server | 2017, 2019, 2022 and 2025 | 2016 and older, past extended support (2016 on 2026-07-14) |
| ClickHouse | 26.3 and 26.8 | Monthly releases between long-term ones. 25.8 and older long-term releases, past end of life (25.8 on 2026-08-29) |
| Apache Cassandra | 4.0 and 5.0 | 3.11 and older, past end of life. 6.0 until it is released |
| ScyllaDB | 2025.1 and 2026.1 | Feature releases between long-term ones, such as 2026.3. Enterprise 2024.1 and older, past end of life |
| SQLite | the system library, 3.37.0 or newer | older libraries, which the driver refuses when it opens a file |
| DuckDB | 2.0.0, compiled into the app ([ADR 0031](docs/decisions/0031-duckdb-2.md)) | files a newer DuckDB wrote in a storage format 2.0.0 cannot read |
| Redis | 7.4 and 8.10 | 7.2 and older, past end of life. Cluster and Sentinel deployments. Valkey answers the same commands and is not tested |
| MongoDB | 7.0 and 8.0 | 6.0 and older, past end of life (6.0 on 2025-07-31). Minor releases between major ones, such as 8.2, are not tested. A sharded cluster is reached through `mongos` and is not tested |

- PostgreSQL 14 reaches end of life on 2026-11-12, and 15, the oldest release after it, is tested already.
- MySQL 8.0 reached end of life on 2026-04-30, but Amazon RDS keeps 8.0 instances under paid Extended Support until 2029-07-31, so it stays tested.
- MariaDB 11.8, PostgreSQL 16 and Cassandra 4.1 are supported between the tested releases, which bound them.

Redshift, CockroachDB, TiDB, OceanBase and Databend are untested on Linux. PostgreSQL or MySQL protocol compatibility, or importing a connection from another app, does not establish support. Add a product here only after connect, catalog, read and write tests against that product pass on Linux.

## Known limits

The [Linux connection guide, Limits](https://docs.tablepro.app/linux/connect#limits) covers read-only cell types and entering time and timestamp values. The supported-server table above lists deployment limits, including Redis Cluster and Sentinel.

## Install

TablePro runs on amd64 and arm64. A release such as 0.1.0 goes to the stable repositories and a beta such as 0.1.0-beta.1 to the beta ones, and both go to [GitHub Releases](https://github.com/TableProApp/TablePro/releases), a beta as a pre-release. Until 0.1.0 is out, only betas have packages.

The .deb and .rpm need the GNOME 50 libraries of Ubuntu 26.04 and Fedora 44 ([ADR 0015](docs/decisions/0015-gnome-50-platform-floor.md)). Ubuntu 22.04 and 24.04, Debian, Linux Mint, Pop!_OS and other distributions use the [Flatpak repository](#flatpak-repository).

### Ubuntu 26.04 and 26.10

```bash
sudo add-apt-repository ppa:tablepro/tablepro
sudo apt install tablepro
```

### Fedora 44 and later

```bash
sudo dnf copr enable @tablepro/tablepro
sudo dnf install tablepro
```

apt and dnf, and Software Updater and GNOME Software with them, install the updates.

### Flatpak repository

From TablePro's own Flatpak repository, signed, with the GNOME 51 runtime from Flathub:

```bash
flatpak install --from https://flatpak.tablepro.app/repo/app.tablepro.TablePro.flatpakref
flatpak run app.tablepro.TablePro
```

Opening that link in a browser hands it to GNOME Software or KDE Discover. `flatpak update` and the software centre install the updates. TablePro is not on Flathub itself. If it is your first Flatpak app and the app menu does not open it, see [Troubleshooting, First Flatpak app](docs/troubleshooting.md#first-flatpak-app).

### Betas

Add the beta repository beside the stable one. apt and dnf install the highest version the two hold, so a release replaces its betas and the next beta replaces that release.

```bash
# Ubuntu
sudo add-apt-repository ppa:tablepro/tablepro-beta
sudo apt install tablepro

# Fedora
sudo dnf copr enable @tablepro/tablepro-beta
sudo dnf install tablepro
```

Before 0.1.0, add the beta repository alone, then the stable one once 0.1.0 is out; without it the last beta stays installed until the next one. To stop testing, `sudo add-apt-repository --remove ppa:tablepro/tablepro-beta` or `sudo dnf copr disable @tablepro/tablepro-beta`. The installed beta stays until the stable repository has a newer version.

The Flatpak beta is the branch `beta` of a second repository, and installs beside the release, as Flathub's beta does. The two branches share one set of settings and connections, and Flatpak never moves from one to the other by version: you choose which one the app's name starts.

```bash
flatpak install --from https://flatpak.tablepro.app/beta-repo/app.tablepro.TablePro.flatpakref
flatpak run --branch=beta app.tablepro.TablePro
flatpak make-current app.tablepro.TablePro beta     # the menu and `flatpak run` start the beta
flatpak make-current app.tablepro.TablePro stable   # and the release again
flatpak uninstall app.tablepro.TablePro//beta       # stop testing, after making the release current
```

A beta may store settings the release before it cannot read; [docs/troubleshooting.md](docs/troubleshooting.md#after-a-downgrade) says what that looks like.

### From GitHub Releases

Each release and beta on [GitHub Releases](https://github.com/TableProApp/TablePro/releases) carries the packages CI built and installed, the .deb and .rpm also tested, and their `SHA256SUMS`. The .deb and .rpm do not update themselves; an installed Flatpak bundle takes its updates from the [Flatpak repository](#flatpak-repository).

| File | For |
|---|---|
| `tablepro-<version>-ubuntu-<series>-<arch>.deb` | Ubuntu 26.04 or 26.10, `amd64` or `arm64` |
| `tablepro-<version>-fedora-<release>-<arch>.rpm` | The Fedora release it names, `x86_64` or `aarch64` |
| `tablepro-<version>-<arch>.flatpak` | Any distribution with Flatpak, `x86_64` or `aarch64` |

GitHub attests each file's build. Check a download against it, or against `SHA256SUMS`, before installing it:

```bash
gh attestation verify tablepro-0.1.0-x86_64.flatpak --repo TableProApp/TablePro
sha256sum --check --ignore-missing SHA256SUMS
sudo apt install ./tablepro-0.1.0-ubuntu-26.04-amd64.deb
sudo dnf install ./tablepro-0.1.0-fedora-44-x86_64.rpm
flatpak install ./tablepro-0.1.0-x86_64.flatpak
```

[docs/troubleshooting.md](docs/troubleshooting.md) covers saved passwords, SSH, Kerberos, logs, crash reports and bug reports.

## Privacy

Besides the usage data below, TablePro makes no network requests of its own until you sign in to a TablePro account: no update check and no crash upload. Signing in opens `account.tablepro.app` in your browser. From then on TablePro reaches `account.tablepro.app` and `api.tablepro.app` to keep the sign-in, to register this computer as one of the account's devices (its host name, the TablePro and system versions, and a machine ID made by hashing `/etc/machine-id` with a key of TablePro's own, never the ID itself), to check your plan at launch and once a day, or hourly while that fails, and, while Preferences > Account is open, to list your teams and devices. The packages from the PPA and COPR and the Flatpak from `flatpak.tablepro.app` carry a PostHog key and share usage data by default, as TablePro for macOS does; **Preferences > General > Privacy > Share Usage Data** turns it off, and nothing more goes from then on. While it is on, the events [ADR 0039](docs/decisions/0039-usage-data.md) lists go to PostHog (`eu.i.posthog.com`): a launch once a day with the kinds and number of open connections, the first connection and the first query with the kind of database, a sign-in and sign-out, and clicks on Upgrade and Buy a License, with the license ask. Each carries a random ID for this installation and the system's name and version; signed in, your account's ID instead, with the TablePro and system versions, the processor type and the interface language. PostHog sees the network address they come from, which it uses for a rough location. Never a host name, a password, a query or a row. A build from source sends none, unless it was given a key with `-Dposthog_key`. The days you use TablePro, which decide when it asks about a license, are counted on this computer and never sent. DuckDB fetches no extension unless your own SQL runs `INSTALL`. It connects to the database servers and SSH hosts you set up, and nothing else. With a provider chosen for the [AI assistant](#ai-assistant), it also sends what the assistant asks to that provider: Anthropic (`api.anthropic.com`), OpenAI (`api.openai.com`), or the Ollama or other server whose address you enter. That is your questions, your SQL, the structure of the tables involved and, for Fix with AI, the server's error message, and only from connections whose AI Assistant setting allows it; it reads no rows for it. With the [MCP server](#mcp-server) on, it also listens on `127.0.0.1` for MCP clients on this computer, which send what they read wherever their own settings say. Crash reports stay on your disk until you attach one to a bug report. Updates come from apt, dnf or Flatpak, and the Flatpak ones from `flatpak.tablepro.app`.

## Stack

| Layer | Pick |
|---|---|
| Language | Rust: 1.98 in `rust-toolchain.toml`, 1.97 the `rust-version` floor |
| GUI toolkit | GTK 4, libadwaita, GtkSourceView and GLib at the GNOME 50 floor ([ADR 0015](docs/decisions/0015-gnome-50-platform-floor.md)) |
| App architecture | gtk-rs subclasses with composite templates ([ADR 0012](docs/decisions/0012-window-per-session.md)), several connection sessions to a window ([ADR 0028](docs/decisions/0028-sessions-share-a-window.md)) |
| Async | the app's tokio runtime (`AppRuntime`) for background work, results delivered to the GLib main loop |
| Database drivers | tokio-postgres with deadpool-postgres (PostgreSQL), sqlx 0.9 (MySQL and MariaDB, SQLite), tiberius 0.13 (SQL Server), the official `clickhouse` crate, scylla 1.9 (Cassandra and ScyllaDB), redis 1.7 (Redis), mongodb 3.9 (MongoDB) and the `duckdb` crate with DuckDB compiled in, all from crates.io ([ADR 0016](docs/decisions/0016-driver-contract-v2.md)) |
| SSH | the system OpenSSH client ([ADR 0013](docs/decisions/0013-openssh-client-transport.md)) |
| TLS | rustls with aws-lc-rs as the only crypto provider ([ADR 0009](docs/decisions/0009-crypto-provider-and-sources.md)) |
| Secrets | oo7: the Secret portal inside Flatpak, the Secret Service over D-Bus on the host ([ADR 0004](docs/decisions/0004-libsecret-secret-storage.md)) |
| Storage | GSettings for preferences and window state ([ADR 0007](docs/decisions/0007-gsettings-preferences.md)), JSON files for connections and workspace state, SQLite for query history ([docs/storage.md](docs/storage.md)) |
| Build | Meson driving Cargo ([ADR 0006](docs/decisions/0006-meson-cargo-build.md)) |
| Distribution | A Launchpad PPA for Ubuntu 26.04 and later, a COPR project for Fedora 44 and later and a Flatpak repository of our own for every distribution, each with a beta one beside it, and the packages and a Flatpak bundle on GitHub Releases; Flathub later ([ADR 0018](docs/decisions/0018-ppa-copr-and-flathub-later.md), [ADR 0041](docs/decisions/0041-beta-repositories-and-release-packages.md)) |

## What this is not

| Not | Why |
|---|---|
| A port of the macOS app | The macOS app is AppKit and SwiftUI, which Linux does not have, and Swift's GTK bindings are immature. The Linux app shares no source with macOS. |
| A plugin host | Drivers are statically linked at compile time. Adding a database engine = adding one crate + one register call. See [decisions/0001-no-plugin-system.md](docs/decisions/0001-no-plugin-system.md). |
| Cross-platform | Linux only. The shared core builds for Windows and macOS, whose apps have UIs of their own. |
| Electron / WebView | Native GTK4 widgets throughout. No HTML rendering of any kind. |

## Quickstart

System dependencies:

```bash
# Ubuntu 26.04 and 26.10
sudo apt install -y build-essential pkgconf meson ninja-build gettext desktop-file-utils appstream libglib2.0-bin libxml2-utils libgtk-4-dev libadwaita-1-dev libgtksourceview-5-dev libsqlite3-dev libkrb5-dev liblcms2-dev libseccomp-dev clang libclang-dev openssh-client

# Fedora 44 and 45
sudo dnf install -y gcc gcc-c++ pkgconf meson ninja-build gettext desktop-file-utils appstream glib2-devel libxml2 gtk4-devel libadwaita-devel gtksourceview5-devel sqlite-devel krb5-devel lcms2-devel libseccomp-devel clang-devel openssh-clients

# Arch (not covered by CI)
sudo pacman -S --needed base-devel pkgconf meson ninja gettext desktop-file-utils appstream libxml2 gtk4 libadwaita gtksourceview5 sqlite krb5 lcms2 libseccomp clang openssh
```

The Ubuntu list is the .deb's build dependencies in `build-aux/debian/control` and the Fedora list the RPM's in `build-aux/rpm/tablepro.spec`, less the ones only their tests need. CI builds both.

The test suites need a few more: an X server for the GTK tests, a session
bus, the icon theme, a generated `en_US.UTF-8` locale for the catalogue
test, gnome-keyring for the Secret Service tests and the glycin loaders
for the Row Details picture tests.

```bash
# Ubuntu 26.04 and 26.10
sudo apt install -y xvfb xauth dbus-daemon adwaita-icon-theme locales gnome-keyring glycin-loaders
sudo localedef -i en_US -f UTF-8 en_US.UTF-8

# Fedora 44 and 45
sudo dnf install -y xorg-x11-server-Xvfb xorg-x11-xauth dbus-daemon adwaita-icon-theme glibc-langpack-en gnome-keyring glycin-loaders
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

`libseccomp-dev` and `liblcms2-dev` are there for glycin, which decodes
the picture of a binary value in Row Details in a sandbox
([ADR 0029](docs/decisions/0029-images-decode-in-glycin.md)). At run time
it needs the glycin loaders, which GNOME installs.

A C++ compiler is there for DuckDB, which the `duckdb` crate compiles
from its own sources: `build-essential` brings g++ on Ubuntu, `gcc-c++`
on Fedora. The first build of it takes several minutes.

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

Lint the manifest with Flathub's linter. The local exceptions file keeps
older linter versions usable; it does not grant Flathub permission approval:

```bash
flatpak run --command=flatpak-builder-lint org.flatpak.Builder \
  --exceptions --user-exceptions build-aux/flatpak/lint-exceptions.json \
  manifest build-aux/flatpak/app.tablepro.TablePro.Devel.json
```

The sandbox gets the network, the display, the home folder and the mount
points of removable drives, the SSH agent and the Kerberos KCM socket. The
Secret Service, file choosers, notifications and links go through portals.
[ADR 0008](docs/decisions/0008-flatpak-sandbox-permissions.md) gives the
reason for each grant. [ADR 0041, Context](docs/decisions/0041-beta-repositories-and-release-packages.md#context)
records the later change from lint exceptions to permission review.

`build-aux/flatpak/app.tablepro.TablePro.json` builds what a release
publishes: the release profile under the real app ID, offline from the two
release tarballs. `build-flatpak.sh` writes the unsigned repository and a
bundle to try. From `linux/`, with the version that `meson.build` names:

```bash
build-aux/packaging/make-sources.sh _packages/sources
build-aux/packaging/build-flatpak.sh _packages/sources/tablepro-0.1.0.tar.xz \
  _packages/sources/tablepro-0.1.0-vendor.tar.xz _packages/flatpak
flatpak install --user _packages/flatpak/tablepro-x86_64.flatpak
```

`build-aux/packaging/flatpak-repo.sh` signs that repository's commits into
the one `flatpak.tablepro.app` serves, and `flatpak-publish.sh` uploads it.
`flatpak-test-site.sh` and `smoke-test-flatpak.sh` do the same with a
throwaway key on `127.0.0.1`, install, and update.

Neither manifest is for Flathub. Flathub's policy refuses manifests and
submissions written with AI tools, so maintainers write and submit that one
by hand ([ADR 0041](docs/decisions/0041-beta-repositories-and-release-packages.md)).
An install from our repository does not move to Flathub on its own. See
[releasing.md, A future Flathub submission](docs/releasing.md#a-future-flathub-submission)
for the review and migration checks.

### Screenshots

The metainfo lists the PNGs in `data/screenshots` at the URL of the
commit a release tarball holds, so a catalogue fetches the ones of the
version it lists. `git archive` writes that commit into
`build-aux/source-commit`; a release is built before its tag exists, and
`appstreamcli compose` drops a screenshot it cannot download. A build
from a git checkout names the release tag instead.

Take new ones from the app at default settings (light style, blue accent,
Adwaita Sans and Adwaita Mono at 11 pt, scale 1) with a 1000×700 window,
keeping the window shadow and rounded corners, and keep the file names and
captions in step with the metainfo.

## Packages

A `linux-vX.Y.Z` tag publishes the source and vendor tarballs, the
packages and the Flatpak bundle on GitHub Releases, signs the Flatpak into
the repository at `flatpak.tablepro.app`, uploads a source package for
Ubuntu 26.04 and 26.10 to the Launchpad PPA, and starts a COPR build of
the spec for Fedora 44 and later; a `linux-vX.Y.Z-beta.N` tag goes to the
beta Flatpak repository, PPA and COPR project instead. Both build offline from
those tarballs, Launchpad with the Ubuntu Rust team's `rustc-1.97` and
COPR with Fedora's Rust, and apt, dnf and the software centres update the
installed packages
([ADR 0018](docs/decisions/0018-ppa-copr-and-flathub-later.md),
[ADR 0041](docs/decisions/0041-beta-repositories-and-release-packages.md)).
The packaging is `build-aux/debian` and `build-aux/rpm/tablepro.spec`, and
[docs/releasing.md](docs/releasing.md) has the release steps.

To build both from the committed tree the way CI does, each step in a
fresh container, with Docker or Podman:

```bash
build-aux/packaging/build-packages.sh all _packages
```

It writes the source and vendor tarballs, the Debian source package and
its .deb built offline as Launchpad builds it (checked by lintian), and
the RPMs built offline in Mock as COPR builds them (checked by rpmlint)
under `_packages`, then installs each package in a fresh container and
starts it. `deb` or `rpm` in place of `all` builds one, Ubuntu series
names after the output directory replace the default `resolute`, and
`FEDORA` picks the Fedora release, 44 by default. The RPM build runs in a
privileged container, since Mock mounts filesystems. The source tarball
archives `HEAD`, so commit first.

After a change to `Cargo.lock`, `build-aux/update-third-party-licenses.sh`
rewrites `debian/copyright` and the spec's `License` tag and `bundled()`
Provides along with `data/licenses`.

## Opening files

Once installed, TablePro is in the file manager's **Open With** for
SQLite databases (`application/vnd.sqlite3`) and SQL files
(`application/sql`). shared-mime-info has no type for DuckDB files, so a
`.duckdb` file opens from the connect dialog or a terminal:

```bash
tablepro app.sqlite3 sales.duckdb report.sql
```

The file's own header picks the engine, whatever its name. A running
TablePro opens each database in its own window and the new launch exits.
A database already open brings its window forward. A database on a
network or FUSE filesystem asks whether to open read-only first, because
neither engine's locking can be trusted there.

A SQL file opens in a new editor tab of the connection in front of the
last window you used, and Save writes back to it. It never runs by
itself. With no SQL connection in front, or while a window is still
connecting or reopening its tabs, a window asks you to choose one first.
A file already open in a tab under the same path brings that tab forward.

## Vim keybindings

Turn on **Preferences → Editor → Vim Keybindings**. The SQL editor then
runs GtkSourceView's Vim emulation: normal, insert, replace and visual
modes, motions, text objects, registers, marks, search with `/` and `?`,
and `.` to repeat. The line under the text shows the mode and the command
you are typing.

| Command | Does |
|---|---|
| `:w` | Saves the tab's file, as Ctrl+S does. A tab with no file asks for one |
| `:w name` | Saves to `name`, next to the tab's file or in your home folder, and the tab follows it. An existing file is left alone; `:w! name` replaces it |
| `:e` | Reads the tab's file again, asking first when that loses changes. `:e!` does not ask |
| `:e name` | Opens `name` in the tab, as Open SQL File does. `:e! name` does not ask |
| `:q`, `:q!` | Closes the tab. A tab with unsaved file changes or an open transaction asks first, as closing does |
| `:wq`, `:x` | Saves, then closes the tab. `:x` skips the save when the file has no changes |

The editor's own Ctrl shortcuts work in every mode: Ctrl+Return runs,
Ctrl+Shift+Return runs the statement at the cursor, and find, find and
replace, format, toggle comment, open and save keep their keys. Every
other key goes to Vim, Escape too, so while Vim is on the **Stop** button
stops a running query. Completion opens in insert mode only.

## Snippets

Type a snippet's trigger in the SQL editor and pick it in the completion
list (Down, then Enter or Tab). The editor writes the statement and
selects its first stop; Tab moves to the next stop and Shift+Tab back.

| Trigger | Writes |
|---|---|
| `sel` | `SELECT … FROM … WHERE` |
| `ins` | `INSERT INTO … VALUES` |
| `upd` | `UPDATE … SET … WHERE`, and `ALTER TABLE … UPDATE … WHERE` on ClickHouse |
| `del` | `DELETE FROM … WHERE` |
| `selj` | `SELECT … JOIN … ON`, except on Cassandra and ScyllaDB, which have no joins |
| `ctab` | `CREATE TABLE` with an `id` key column, as the engine spells one: a `uuid` on Cassandra and ScyllaDB |
| `cidx` | `CREATE INDEX` |

Your own snippets live in the folder **Preferences → Editor → Snippets
folder** shows, which **Open Folder** creates:
`~/.local/share/tablepro/snippets`, or
`~/.var/app/app.tablepro.TablePro/data/tablepro/snippets` under Flatpak.
Each `.snippets` file is in GtkSourceView's snippet format, and a file
added, changed or removed takes effect without a restart:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<snippets _group="Mine">
  <snippet _name="Count rows" trigger="cnt" _description="Count the rows of a table">
    <text languages="sql"><![CDATA[SELECT COUNT(*) FROM ${1:table_name};$0]]></text>
  </snippet>
  <snippet _name="Vacuum" trigger="vac">
    <text languages="postgres"><![CDATA[VACUUM (ANALYZE) ${1:table_name};$0]]></text>
  </snippet>
</snippets>
```

- `${1:table_name}` is a stop and the text it starts with, `$1` repeats
  what stop 1 holds, and `$0` is where the cursor ends. GtkSourceView
  reads every `$` this way, so keep PostgreSQL dollar quotes and `$1`
  parameters out of snippets.
- `languages` says where a snippet shows: `sql` on every SQL connection
  and in a tab with no connection, or one engine: `postgres`, `mysql`
  (MySQL and MariaDB), `sqlite`, `mssql`, `clickhouse`, `cassandra`
  (Cassandra and ScyllaDB), `duckdb` or `redis`, whose editor offers its
  own snippets and no SQL ones. Separate several with `;`.
- A snippet for the engine replaces a `sql` one with the same trigger,
  and either replaces the built-in one.
- A file that does not parse is skipped, and GtkSourceView logs its name.

## Multiple cursors

The SQL editor can type, delete, paste and move at several places at once.

| Keys | Does |
|---|---|
| Ctrl+D | Selects the word at the cursor, then adds a cursor at its next match. A word found this way matches whole words only, and a selection you made matches anywhere. Matches are case-sensitive |
| Ctrl+Shift+L | Adds a cursor at every match of the selection or the word |
| Shift+Alt+Up, Shift+Alt+Down | Adds a cursor on the line above or below, in the same column |
| Ctrl+click | Adds a cursor, or takes away the one you click |
| Escape | Returns to one cursor, keeping its selection |

Typing, Return, Tab, BackSpace, Delete and the moves by character, word or line work at every cursor, and one Ctrl+Z takes an edit back at all of them and returns to one cursor. Copy joins the selections with new lines, and pasting as many lines as there are cursors puts one line at each. Ctrl+/ comments every cursor's lines. A click, a find, Format, a query from history and Page Up or Down return to one cursor, as do moving lines (Alt+Up, Alt+Down) and words (Alt+Left, Alt+Right), which act on one line. The completion list, snippets and suggestions while typing work with one cursor, so another cursor ends the snippet being filled in and drops a suggestion, and overwrite (Insert) and Vim mode keep one cursor.

## Export a database and import a SQL file

**Main menu → Export Database…** writes the database, or one of its
schemas, to a `.sql` file, gzipped as `.sql.gz` if you ask. It holds the
tables, views, routines and triggers, and every table's rows as
multi-row INSERTs, in the order a restore needs: structure, then rows,
then keys, indexes, foreign keys and sequence positions, then views and
routines, and triggers last so loading the rows fires none. The file is
meant for an empty database, and loads with the engine's own client as
well as with TablePro:

| Engine | Written like | Load it with | Left out |
|---|---|---|---|
| PostgreSQL | `pg_dump` plain format, INSERTs instead of COPY | `psql -v ON_ERROR_STOP=1 -f file.sql` | Owners, grants, policies, rules, publications, event triggers, foreign tables; the rows of extension configuration tables |
| MySQL, MariaDB | `mysqldump`, with its `SET` header and `DELIMITER ;;` blocks | `mysql db < file.sql` | Events; FEDERATED and CONNECT tables, whose rows are another server's; `DEFINER` clauses, so the account that loads the file owns the objects |
| SQL Server | SSMS's Generate Scripts, a `GO` after each batch | `sqlcmd -b -i file.sql` | CLR and encrypted modules, which have no SQL to write; the indexes of indexed views; system versioning, so a temporal table and its history load as ordinary tables with their period times |
| ClickHouse | `SHOW CREATE` for each table and view | `clickhouse-client < file.sql` | User-defined functions, which belong to no database; the rows a materialized view without `TO` keeps itself, so it fills again only from new rows |
| SQLite | `sqlite3 .dump` | `sqlite3 new.db < file.sql` | |
| DuckDB | `EXPORT DATABASE`, in one file | `duckdb new.duckdb < file.sql` | |

Tables are read one after another, each in a read-only transaction of
its own, so stop writes to the database for a dump whose tables agree.
A value the engine has no SQL for is written as NULL, and the export
says which columns that happened to. Redis, MongoDB, Cassandra and
ScyllaDB have no SQL dump; use `redis-cli --rdb`, `mongodump` or
`nodetool snapshot`.

**Main menu → Import SQL File…** runs a `.sql` or `.sql.gz` file on the
connection, on a session of its own so what the file sets stays there.
The file is read as it runs, so its size does not matter. It is split
as the engine's client splits it: at `;`, at a MySQL `DELIMITER`, and at
SQL Server `GO` lines, a `GO 3` batch running three times. Files from
`pg_dump` load too: their `COPY ... FROM stdin` rows go through
PostgreSQL's copy protocol as psql sends them, text or CSV, and the
`\restrict` and `\unrestrict` lines that only psql reads are passed
over. Any other psql command, such as `\connect`, is refused with its
line.

- **Stop at First Error** is on by default, as with `mysql` and with
  `psql -v ON_ERROR_STOP=1`. Off, the rest of the file runs and the
  summary lists each failure with its line; Copy Details copies them with
  their statements.
- **Run as One Transaction** is offered on PostgreSQL, SQL Server, SQLite
  and DuckDB, whose CREATE and DROP roll back: a failure or Stop then
  undoes everything the file did. The file's own `BEGIN` and `COMMIT`
  are passed over inside it, and a `ROLLBACK`, or a SQL Server batch that
  holds a `COMMIT` or `ROLLBACK`, stops the import before it runs. MySQL,
  MariaDB and ClickHouse commit each statement as it runs, so what ran
  before a failure stays.
- On Safe Mode Read-Only, Import SQL File is off. On Confirm
  Writes, the import dialog is the one question for the whole file.
- A file must be UTF-8. A MySQL dump of binary columns made without
  `--hex-blob` holds raw bytes and is refused at its first such line.

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

## SQL Server with strict encryption

A server set to Force Strict Encryption takes only TDS 8.0 logins, which
start with TLS. Pick **Encryption → Strict** in the connect dialog. It
needs SQL Server 2022 or later on Windows, or 2025 or later on Linux, and
checks the server's certificate as Verify full does, so a self-signed
certificate works once you choose it as the connection's CA certificate.
Older servers take Verify full.

## AI assistant

The assistant answers questions about the connected database, explains, reviews, optimizes and fixes your SQL, and can suggest SQL as you type ([ADR 0022](docs/decisions/0022-ai-assistant-and-mcp-server.md)). It is off until you choose a provider in **Preferences > AI**:

| Provider | Requests go to | Key |
|---|---|---|
| Anthropic | `api.anthropic.com` | an API key from the Claude Console |
| OpenAI | `api.openai.com` | an API key from the OpenAI platform |
| Ollama or Compatible Server | the address you enter, `http://localhost:11434/v1` for Ollama on this computer | optional; sent over plain http only to this computer |

Each request bills to your own account with that provider. The key is kept in the keyring, as passwords are. Pick the model on the same page, from the list the provider offers.

**Show the Assistant** (Ctrl+Alt+A, or the speech bubble in the header bar) opens it beside the tabs. A conversation starts with the SQL in the editor and the structure of the tables named there and in your question; each reply's code blocks carry **Copy** and **Insert**, which puts the code at the editor's cursor, or in a new query tab when the tab in front is not an editor. **Explain with AI**, **Review with AI** and **Optimize with AI** in the editor's menu and context menu send the selection, or the statement at the cursor, and a failed statement's page offers **Fix with AI** with the server's error. Conversations stay in memory and end with the window.

**Suggest While Typing**, off by default, asks for a completion when you pause at the end of a line and shows it dimmed after the cursor: Tab accepts it, Escape or typing on drops it. Each pause sends the text around the cursor.

Each connection's **AI Assistant** setting, under Options in its connect dialog, decides what leaves it:

| Setting | The assistant |
|---|---|
| Ask Each Time, the default | asks before its first request in a window, naming the provider and its address; the answer lasts until the window disconnects |
| Allow | sends without asking |
| Never | sends nothing from the connection: not its structure, its SQL or a question asked beside it |

The assistant reads no rows: the structure comes from the catalog, and a statement it writes runs only when you run it, under the connection's Safe Mode. What leaves the computer is what you type, the SQL it acts on, that structure, and for **Fix with AI** the server's error message, which can quote a value.

## MCP server

MCP clients on this computer, such as Claude Code, can use your saved connections through TablePro ([ADR 0022](docs/decisions/0022-ai-assistant-and-mcp-server.md)). The server is off until you turn on **Preferences > MCP > Enable MCP Server**, and runs while TablePro is open. It listens on `127.0.0.1` only, on port 23508 unless you change it there, and answers only programs running as your user: another account on the computer is refused even with the access token.

**Clients** on that page lists the clients TablePro knows, the ones set up or found on this computer first, each with its state, such as Not set up, Set up, or set up with an old access token:

- **Install** and **Update** write TablePro's entry into the client's own configuration file and keep the rest of it, comments included. **Update** changes only what TablePro sets in its entry and keeps your other settings there. The file as it was is kept beside it as `<file>.tablepro-backup`, and a file that holds the token is readable only by you.
- Claude Code is set up through its own `claude mcp add` command, which TablePro runs without a shell. The Flatpak cannot start it, so there you copy the command instead.
- Select a client for its configuration file, the setup to paste by hand with **Copy**, and **Remove**. The page shows the access token masked; **Copy** includes it.
- A toast says when a client connects.

A client that only starts programs on this computer, such as Claude Desktop, cannot use the server, which is reached at an address.

To set up a client by hand, copy the address and the authorization header from the same page. With Claude Code:

```bash
claude mcp add --scope user --transport http tablepro http://127.0.0.1:23508/mcp \
  --header "Authorization: Bearer <access token>"
```

**Regenerate Access Token** on that page, with the server on or off, turns the old token away from the next request. While the server runs, the clients set up with the old token show **Update**.

Each connection's **External Clients** level, under Options in its connect dialog, decides what a client may do there:

| Level | A client |
|---|---|
| Blocked | does not see the connection |
| Read Only, the default | reads the schema and the data |
| Read & Write | also writes, each statement after you approve it |

Read Only stops statements that write. A function the connection's login may call that reads files on the server still runs, so give such a connection a login without that privilege.

A client works on a connection open in a TablePro window; its `connect` tool opens one there, and anything the connect needs, such as a password, is asked in that window. A read runs on a read-only connection. A write runs one statement per call, never under Safe Mode Read-Only, and only after you click **Run** in Safe Mode's dialog in the connection's window, whatever the Safe Mode level. What a client runs with `execute_query` goes into the query history as the editor's runs do.

The 11 tools are `list_connections`, `connect`, `list_databases`, `list_schemas`, `list_tables`, `describe_table`, `get_table_ddl`, `browse_table`, `count_rows`, `execute_query` and `export_data`. An answer keeps at most 20 result sets of 1,000 rows each and about 4 MB, a value longer than 64 KB is cut, a statement stops at 300 seconds, and an export takes at most 20 tables.

## TablePro account

TablePro for Linux is licensed as the macOS app is: the same plans and accounts, and a license covers 3 devices at a time, Mac or Linux. Signing in uses your plan on this computer; everything else works without an account ([ADR 0038](docs/decisions/0038-account-page-and-license-ask.md), [ADR 0042](docs/decisions/0042-account-page-lists-this-platforms-features.md)).

**Preferences > Account > Sign In** opens `account.tablepro.app` in your browser, which sends you back to TablePro once you approve. The page lists your plan, your devices with **Remove**, and your teams. A computer that never reaches the internet imports an offline file made for the Machine ID the page shows. What is sent, and when: [Privacy](#privacy).

From the 30th day you use TablePro without a license, a toast asks whether you would buy one, with **Buy a License**, then at most every 90 days. Nothing changes whatever you do.

## Documentation index

| Topic | File |
|---|---|
| Layered architecture, crate boundaries, dependency rules | [ARCHITECTURE.md](ARCHITECTURE.md) |
| What is built | [docs/features.md](docs/features.md) |
| The work left, for Linux, Windows and the core | [ROADMAP.md](../ROADMAP.md) |
| The 0.1.0 release criteria | [docs/releasing.md](docs/releasing.md#release-criteria) |
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
