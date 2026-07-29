# TablePro Linux

Native Linux database client. Sister product to the macOS TablePro app, sharing no code but matching the feature set.

## Status

Phase 0 — foundation. The technology stack was validated by a 2-day spike in April 2026: Rust + GTK4 + libadwaita + sqlx + GtkColumnView built and scrolled 100,000 rows with no perceptible lag. Real codebase scaffolding has not started yet.

## Stack

| Layer | Pick |
|---|---|
| Language | Rust 1.93+ |
| GUI toolkit | GTK4 4.14+ + libadwaita 1.5+ |
| App architecture | [Relm4](https://relm4.org) — Elm-style components on gtk4-rs |
| Async | tokio (DB drivers) bridged to glib main loop (UI) |
| DB drivers | sqlx (PG / MySQL / SQLite), tiberius (MSSQL), official clickhouse and mongodb crates, fred (Redis), etc. |
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
sudo apt install -y build-essential pkg-config libgtk-4-dev libadwaita-1-dev libssl-dev libsecret-1-dev

# Fedora
sudo dnf install -y gcc pkg-config gtk4-devel libadwaita-devel openssl-devel libsecret-devel

# Arch
sudo pacman -S --needed base-devel pkg-config gtk4 libadwaita openssl libsecret
```

Verify the right versions are present:

```bash
pkg-config --modversion gtk4 libadwaita-1   # need 4.14+ / 1.5+
rustc --version                              # need 1.93+
```

Build and run (once `crates/app/` exists):

```bash
cd linux
cargo run -p tablepro-app
```

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
