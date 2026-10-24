# TablePro Linux

Native Linux database client, the Linux sibling of the macOS TablePro app. The two share no code.

## Status

It connects to nine engines: PostgreSQL, MySQL and MariaDB, SQL Server, ClickHouse, Cassandra and ScyllaDB, SQLite, DuckDB, Redis and MongoDB. Each connection session gets a window of its own. Nothing is released yet: no `linux-v*` tag exists. [ROADMAP.md](ROADMAP.md) lists what is built, what is not, and the release criteria.

## Supported servers

TablePro supports the server releases their vendors still support. CI runs each driver's whole Docker suite on every release in the second column ([docs/testing.md](docs/testing.md#server-releases)).

| Engine | Tested releases | Not supported |
|---|---|---|
| PostgreSQL | 14, 17 and 18 | 13 and older, past end of life (13 on 2025-11-13). 19 until it is released |
| MySQL | 8.0, 8.4 and 9.7 | 8.1 to 9.6, innovation releases past end of life. 5.7 and older |
| MariaDB | 10.11, 11.4 and 12.3 | 10.6 and older, past end of life (10.6 on 2026-07-06). Rolling releases such as 13.0 |
| SQL Server | 2017, 2019, 2022 and 2025 | 2016 and older, past extended support (2016 on 2026-07-14) |
| ClickHouse | 26.3 and 26.8 | Monthly releases between long-term ones. 25.8 and older long-term releases, past end of life (25.8 on 2026-08-29) |
| Apache Cassandra | 4.0 and 5.0 | 3.11 and older, past end of life. 6.0 until it is released |
| ScyllaDB | 2025.1 and 2026.1 | Feature releases between long-term ones, such as 2026.3. Enterprise 2024.1 and older, past end of life |
| SQLite | the system library, 3.37.0 or newer | older libraries, which the driver refuses when it opens a file |
| DuckDB | 1.5.6, compiled into the app ([ADR 0025](docs/decisions/0025-bundled-duckdb.md)) | files a newer DuckDB wrote in a storage format 1.5.6 cannot read |
| Redis | 7.4 and 8.10 | 7.2 and older, past end of life. Cluster and Sentinel deployments. Valkey answers the same commands and is not tested |
| MongoDB | 7.0 and 8.0 | 6.0 and older, past end of life (6.0 on 2025-07-31). Minor releases between major ones, such as 8.2, are not tested. A sharded cluster is reached through `mongos` and is not tested |

- PostgreSQL 14 reaches end of life on 2026-11-12.
- MySQL 8.0 reached end of life on 2026-04-30, but Amazon RDS keeps 8.0 instances under paid Extended Support until 2029-07-31, so it stays tested.
- MariaDB 11.8, PostgreSQL 15 and 16, and Cassandra 4.1 are supported between the tested releases, which bound them.

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

TablePro makes no network requests of its own: no telemetry, no update check and no crash upload. DuckDB fetches no extension unless your own SQL runs `INSTALL`. It connects to the database servers and SSH hosts you set up, and nothing else. With a provider chosen for the [AI assistant](#ai-assistant), it also sends what the assistant asks to that provider: Anthropic (`api.anthropic.com`), OpenAI (`api.openai.com`), or the Ollama or other server whose address you enter. That is your questions, your SQL, the structure of the tables involved and, for Fix with AI, the server's error message, and only from connections whose AI Assistant setting allows it; it reads no rows for it. With the [MCP server](#mcp-server) on, it also listens on `127.0.0.1` for MCP clients on this computer, which send what they read wherever their own settings say. Crash reports stay on your disk until you attach one to a bug report. Updates come from apt or dnf.

## Stack

| Layer | Pick |
|---|---|
| Language | Rust: 1.98 in `rust-toolchain.toml`, 1.97 the `rust-version` floor |
| GUI toolkit | GTK 4, libadwaita, GtkSourceView and GLib at the GNOME 50 floor ([ADR 0015](docs/decisions/0015-gnome-50-platform-floor.md)) |
| App architecture | gtk-rs subclasses with composite templates, one window per connection session ([ADR 0012](docs/decisions/0012-window-per-session.md)); the saved-queries and CSV import dialogs are still [Relm4](https://relm4.org) 0.11 components |
| Async | the app's tokio runtime (`AppRuntime`) for background work, results delivered to the GLib main loop |
| Database drivers | tokio-postgres with deadpool-postgres (PostgreSQL), sqlx 0.9 (MySQL and MariaDB, SQLite), tiberius 0.13 (SQL Server), the official `clickhouse` crate, scylla 1.9 (Cassandra and ScyllaDB), redis 1.7 (Redis) and the `duckdb` crate with DuckDB compiled in, all from crates.io ([ADR 0016](docs/decisions/0016-driver-contract-v2.md)) |
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
sudo dnf install -y gcc gcc-c++ pkgconf meson ninja-build gettext desktop-file-utils appstream glib2-devel libxml2 gtk4-devel libadwaita-devel gtksourceview5-devel sqlite-devel krb5-devel clang-devel openssh-clients

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

## Opening database files

Once installed, TablePro is in the file manager's **Open With** for
SQLite databases (`application/vnd.sqlite3`). shared-mime-info has no
type for DuckDB files, so a `.duckdb` file opens from the connect dialog
or a terminal:

```bash
tablepro app.sqlite3 sales.duckdb
```

The file's own header picks the engine, whatever its name. A running
TablePro opens each file in its own window and the new launch exits. A
file already open brings its window forward. A database on a network or
FUSE filesystem asks whether to open read-only first, because neither
engine's locking can be trusted there.

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

MCP clients on this computer, such as Claude Code, can use your saved connections through TablePro ([ADR 0022](docs/decisions/0022-ai-assistant-and-mcp-server.md)). The server is off until you turn on **Preferences > MCP > Enable MCP Server**, and runs while TablePro is open. It listens on `127.0.0.1` only, on port 23508 unless you change it there.

Copy the address and the access token from the same page into the client. With Claude Code:

```bash
claude mcp add --transport http tablepro http://127.0.0.1:23508/mcp \
  --header "Authorization: Bearer <access token>"
```

**Regenerate Access Token** on that page turns the old token away from the next request.

Each connection's **External Clients** level, under Options in its connect dialog, decides what a client may do there:

| Level | A client |
|---|---|
| Blocked | does not see the connection |
| Read Only, the default | reads the schema and the data |
| Read & Write | also writes, each statement after you approve it |

Read Only stops statements that write. A function the connection's login may call that reads files on the server still runs, so give such a connection a login without that privilege.

A client works on a connection open in a TablePro window; its `connect` tool opens one there, and anything the connect needs, such as a password, is asked in that window. A read runs on a read-only connection. A write runs one statement per call, never under Safe Mode Read-Only, and only after you click **Run** in Safe Mode's dialog in the connection's window, whatever the Safe Mode level. What a client runs with `execute_query` goes into the query history as the editor's runs do.

The tools are `list_connections`, `connect`, `list_schemas`, `list_tables`, `describe_table`, `get_table_ddl`, `browse_table`, `count_rows` and `execute_query`. An answer keeps at most 20 result sets of 1,000 rows each, and a statement stops at 300 seconds.

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
