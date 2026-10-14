# BookiE

BookiE is a native Linux database client built with Rust, GTK4, libadwaita, GtkSourceView, and Relm4. It was previously called TablePro on this branch. The product repository is [`cozyGarage/BookiE`](https://github.com/cozyGarage/BookiE); current development is on the `linux` branch. The Cargo workspace lives at the repository root (`crates/`, `apps/linux/`, `tests/`, `scripts/`, `docs/`) and requires Rust 1.98.

Current delivery scope and evidence: [active sprint](docs/bookie-0.2-sprint.md). The [October 3 consistency review](docs/archive/architecture-consistency-review-2026-10-03.md) reconciles the accumulated documentation. Earlier audits prove their recorded source trees; package release approval remains separate.

The rename covers the display name, packaging install names (`bookie`, `bookie-agentd`, with `tablepro*` aliases) and branding assets only. Cargo package and binary names stay `tablepro-app` / `tablepro-agentd`. App ID, config and data paths, keyring schema, UUIDs, audit format and protocol contracts stay `tablepro` / `com.tablepro.linux`. Crate names remain `tablepro-*`.

Every shipped feature is free to use. BookiE has no account, license, subscription, paid-tier, or remote entitlement gate.

## Status

The Linux client is under active development toward BookiE 0.2.0. B3 type/value and B4 transport/session correctness blockers remain alongside installed desktop qualification. Workflows include saved connections, SSH tunnels, browse and SQL tabs, structure editing, inline row changes, query history, policy checks, audit records, MCP access, and the headless `bookie-agentd` process. Table browsing fetches bounded pages from the database. Core and PostgreSQL cursor APIs exist, but the policy-governed editor path is not complete, so arbitrary SQL results are still materialized up to configured caps ([ADR 0011](docs/decisions/0011-paged-query-results.md), PERF-2/PERF-8).

PostgreSQL is the furthest along: server-confirmed cancellation, certificate hostname and authority verification, verified TLS through an SSH tunnel, read-only denial, rollback, blocking-lock reporting, and reconnect run as deterministic container checks. MySQL, ClickHouse, Redis, and MongoDB also have driver TLS fixture evidence; those fixtures do not establish full transport or packaging readiness. Packaging is not release-verified. [`ROADMAP.md`](ROADMAP.md) links to current milestone status and the detailed acceptance boards.

| Database | Status |
|---|---|
| PostgreSQL | Implemented; PostgreSQL release fixture |
| MySQL and MariaDB | Implemented; driver and TLS fixtures |
| SQLite | Implemented; local and GTK tests |
| Microsoft SQL Server | Implemented; timed-out query cancellation is not available in BookiE yet |
| ClickHouse | Implemented; driver and TLS fixtures |
| Redis | Experimental; single host/port endpoint in 0.2.0 |
| MongoDB | Experimental |
| DuckDB | Optional build feature |

See [`docs/adding-drivers.md`](docs/adding-drivers.md#driver-maturity) for current limits. Installable 0.1.5 packages are on the [linux-v0.1.5 GitHub Release](https://github.com/cozyGarage/BookiE/releases/tag/linux-v0.1.5); they do not qualify the 0.2.0 source. Wayland soak remains an operator check after install.

## Linux versions

BookiE 0.1.5 (tag `linux-v0.1.5`) targets:

| Distro | Arch | Artifact | Package name | Launch |
|---|---|---|---|---|
| Debian / Ubuntu with the required GNOME 50 libraries | amd64 | `tablepro_0.1.5-1_amd64.deb` | `tablepro` | `bookie` |
| Arch Linux / Omarchy | x86_64 | `bookie-0.1.5-1-x86_64.pkg.tar.zst` | `bookie` | `bookie` |

`tablepro` and `tablepro-agentd` remain command aliases. Application ID and XDG paths stay `com.tablepro.linux` / `tablepro`.

**The released `.deb` does not run on the default Ubuntu 24.04 or 25.10 libraries.** It needs the GNOME 50 runtime line. Cargo compile and distro-floor tests support the lower Ubuntu 24.04 stack; the root Meson project separately declares GNOME 50 library requirements. GTK CI builds in Debian testing, whose library set meets that higher line.

Cargo compile / CI floor: GTK4 4.14+, GLib 2.80+, libadwaita 1.5+, GtkSourceView 5.12+ (Ubuntu 24.04 and Debian 13). The root Meson project and GNOME 50 GitHub Release `.deb` use GTK 4.22+, GLib 2.88+, libadwaita 1.9+, GtkSourceView 5.18+. Details: [ADR 0002](docs/decisions/0002-rust-gtk4-libadwaita.md) and [platforms](docs/platforms.md). Build with Rust 1.98. No AUR, Flathub, or Fedora package. No 32-bit or ARM artifacts.

## Named query parameters

Write `:name` anywhere a value belongs:

```sql
SELECT * FROM orders WHERE customer = :customer AND total > :minimum;
```

Running the statement asks for one value per name and sends them as driver-bound parameters. Each value has a type choice: `Auto` (whole numbers and decimals are detected, everything else is text), `Text`, `Integer`, `Decimal`, `Boolean`, or `Null`. Placeholders inside string literals, quoted identifiers, comments, dollar-quoted bodies, PostgreSQL `::` casts, and existing `$1` or `?` placeholders are left alone.

## Editor productivity

- **Completion**: typing after `FROM` or `JOIN` offers tables; elsewhere it offers the columns of the tables named in the statement. `alias.` and `table.` narrow to that table's columns, and columns are fetched on demand for tables you reference.
- **Favorites**: Ctrl+D saves the current editor query under a name in `$XDG_CONFIG_HOME/tablepro/favorites.json`. Saving an existing name replaces its statement.
- **Open Quickly**: Ctrl+P searches favorites, open tabs, and saved connections. Type to filter (name, statement text, or initials), arrow keys to move, Enter to open, Escape to dismiss.

## Architecture

Crate map, Mermaid pipeline diagrams, trait boundaries and deliberate limits live in [`ARCHITECTURE.md`](ARCHITECTURE.md). The desktop app uses `tablepro-app-services` for GTK-free application state and service logic. Every GUI, MCP and agent database handle is a `PolicyGuard`; token scopes and connection allowlists do not replace it. Drivers are linked at build time. The UI is native GTK (no embedded browser).

## Build requirements

```bash
# Ubuntu / Debian
sudo apt install -y build-essential pkg-config libgtk-4-dev libadwaita-1-dev \
  libgtksourceview-5-dev libssl-dev libsecret-1-dev libkrb5-dev libsqlite3-dev clang

# Fedora (build from source only; no 0.1.5 package)
sudo dnf install -y gcc pkg-config gtk4-devel libadwaita-devel \
  gtksourceview5-devel openssl-devel libsecret-devel krb5-devel clang

# Arch
sudo pacman -S --needed base-devel pkg-config gtk4 libadwaita \
  gtksourceview5 openssl libsecret krb5 sqlite clang
```

Check the native libraries and Rust toolchain:

```bash
pkg-config --modversion gtk4 libadwaita-1 gtksourceview-5
rustc --version
```

## Build and run

From the repository root:

```bash
cargo run -p tablepro-app
```

Optional DuckDB driver:

```bash
cargo run -p tablepro-app --features duckdb
```

A plain `cargo run` shares settings, saved connections, the keyring entries and the single-instance lock with an installed BookiE. To keep test data apart, build with the development profile, which uses `~/.config/tablepro-devel` and its own keyring schema:

```bash
TABLEPRO_PROFILE=development cargo run -p tablepro-app
```

Starting a second copy of the same profile asks the running one to show its window and then exits.

### SQL Server Kerberos

Run `kinit` before connecting and confirm the ticket with `klist`. Select **Windows (Kerberos)** in the SQL Server connection form and enter the server's real DNS hostname. SQL Server requests `MSSQLSvc/<host>:<port>`, including when SSH forwards the socket through localhost.

A FILE credential cache works when `KRB5CCNAME` points to a readable location. Custom SPN overrides and cross-realm setup are not exposed in the connection form.

## Validate

Local cheap checks from the repository root:

```bash
bash scripts/preflight.sh
```

`preflight.sh` covers size and panic guards, formatting, Clippy, unit tests on non-GTK crates (it skips `tablepro-app`) and the sandbox tier. It does not run the installed GTK suite. Deeper layers (Docker drivers, GTK widgets, installed GTK, release fixture) are documented in [`docs/validation-playbook.md`](docs/validation-playbook.md) and [`docs/testing.md`](docs/testing.md).

From the repository root:

```bash
./scripts/smoke-postgres.sh          # optional smoke against a local PostgreSQL
./scripts/test-postgres-socket.sh    # disposable Unix-socket fixture
```

For manual connection checks across every network driver, use the local-only [manual connection fixture](tests/manual-connections/README.md).

If native development packages are unavailable, `scripts/dev-env.sh` can use Debian-family package payloads extracted under `.local-deps/root/`.

GitHub runs the cheap tier only; merge acceptance is the Forgejo gate (`bash scripts/forgejo-gate.sh <branch>`). Details: [AGENTS.md](AGENTS.md) and the [validation playbook](docs/validation-playbook.md#ci-tiers).

## Packaging

The current package is BookiE 0.1.5. Download it from the [linux-v0.1.5 GitHub Release](https://github.com/cozyGarage/BookiE/releases/tag/linux-v0.1.5), or see the [0.1.5 release notes](CHANGELOG.md) and [packaging guide](apps/linux/packaging/README.md). To rebuild the Arch package from a clean commit at the repository root:

```bash
TABLEPRO_RC_COMMIT="$(git rev-parse HEAD)" TABLEPRO_RC_VERSION=0.1.5 ./scripts/build-arch-rc.sh
```

The helper archives that commit, verifies a real checksum, and does not publish to AUR. Set `TABLEPRO_RC_TAG=linux-v…` instead of `TABLEPRO_RC_COMMIT` only to verify an already published tag.

## Documentation

Start at [the documentation map](docs/README.md) for audience and ownership. Common entry points:

| Topic | File |
|---|---|
| Product / personas / principles | [PRODUCT.md](PRODUCT.md), [docs/personas.md](docs/personas.md), [PRINCIPLES.md](PRINCIPLES.md) |
| Capability specs (drafts) | [specs/](specs/README.md) |
| Active sprint | [docs/bookie-0.2-sprint.md](docs/bookie-0.2-sprint.md) |
| Architecture | [ARCHITECTURE.md](ARCHITECTURE.md) |
| User guide | [docs/user-guide.md](docs/user-guide.md) |
| Contributing / agent rules | [CONTRIBUTING.md](CONTRIBUTING.md), [AGENTS.md](AGENTS.md) |
| Changelog | [CHANGELOG.md](CHANGELOG.md) |

## Contributing

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) and the rules in [`AGENTS.md`](AGENTS.md). Pull requests for current development target the `linux` branch and are accepted on a green Forgejo gate run.

## Changelog

Release notes and unreleased changes are in [`CHANGELOG.md`](CHANGELOG.md).

## License

BookiE is licensed under the [GNU Affero General Public License v3.0 or later](LICENSE).
