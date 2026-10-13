# TablePro for Linux

The native Linux app: Rust, GTK 4 and libadwaita through Relm4, built with Meson and Cargo. The platform floor is GNOME 50 (GTK 4.22, libadwaita 1.9, GtkSourceView 5.18, GLib 2.88). It shares no code with the macOS app.

This is the guide for work under `linux/`. The root `AGENTS.md` describes the macOS and iOS apps; of it, only the principles named below, "Writing style" and the commit rules apply here. Claude Code loads this file through `linux/CLAUDE.md` once a file under `linux/` is read; Codex reads it when started in `linux/`, so otherwise read it yourself.

## Branch

`linux/` lives on the `linux` branch until the first Linux release, and `main` does not have it. Start work from `origin/linux` and open the pull request against `linux`.

## Principles

1. **Security first, fix the cause, tests define behavior**, as in the root `AGENTS.md`.
2. **Native only.** GTK 4 and libadwaita, used the way the GNOME Human Interface Guidelines describe, with the widget the toolkit provides before anything drawn by hand. No web views, no cross-platform toolkit.
3. **One-directional crates.** The domain crate (`tablepro-core`) never imports the GUI or a driver, and a new database engine is one crate. `ARCHITECTURE.md` has the graph.
4. **Drivers are linked in at compile time.** There is no plugin system and no plugin ABI (`docs/decisions/0001-no-plugin-system.md`).
5. **Decisions are recorded.** A change that reverses a decision in `docs/decisions/` says so and updates the record.

## Map

- `crates/app`: the binary and every Relm4 component. `crates/core`: domain types and traits, no GUI. `crates/storage`: secrets, settings and files. `crates/session`, `crates/net`, `crates/ssh`: sessions, the network layer and the OpenSSH transport. `crates/drivers/*`: one crate per engine. `crates/test-fixtures` and `crates/test-support`: test-only.
- `data/`: desktop entry, D-Bus service, metainfo, GSettings schema, icons and GResource. `po/`: translations. `build-aux/flatpak/`: the Flatpak manifest.
- `ARCHITECTURE.md`, `CONTRIBUTING.md` and `docs/` (testing, storage, error handling, state management, adding a driver, decisions) are the reference. Read the one for the area you touch.

## Commands

From the repository root, through the verification wrapper, which keeps the full log and prints a verdict:

```bash
.claude/skills/fix-issue/scripts/verify.sh --platform linux setup    # once per tree
.claude/skills/fix-issue/scripts/verify.sh --platform linux build
.claude/skills/fix-issue/scripts/verify.sh --platform linux test <package> [filter]
.claude/skills/fix-issue/scripts/verify.sh --platform linux lint
```

`--help` lists the rest. By hand, from `linux/`: `meson setup _build -Dprofile=development`, `meson compile -C _build`, `meson devenv -C _build ./crates/app/tablepro` to run the app, and every `cargo` command as `meson devenv -C _build cargo ...` so it reuses the build. `CONTRIBUTING.md` has the CI fast-job sequence.

## Code style

`rustfmt.toml`, `clippy.toml` and the workspace lints in `Cargo.toml` are the source of truth. Beyond them:

- **Comments say why, never what**, as in the root guide.
- No `unwrap`, `expect`, `panic!`, `todo!` or `unimplemented!` outside tests; return a real error. Errors cross crate boundaries as `thiserror` enums (`docs/error-handling.md`).
- Logging goes through `tracing`, never `println!` or `eprintln!`; the lints deny both.
- An `#[ignore]` or `#[expect]` always carries its reason.

## Every change

1. **Tests.** A unit test for testable behavior, a `#[gtk4::test]` widget test for UI behavior, and a test against the real engine, ignored with `requires docker`, for driver behavior. No mocks. Details: `docs/testing.md`.
2. **CHANGELOG.** A user-visible change gets one fragment under `[Unreleased]` in `linux/CHANGELOG.md`, in the format of the root `.claude/rules/changelog.md`. The root `CHANGELOG.md` is the macOS release notes: never write a Linux change there.
3. **Translations.** User-facing strings go through `crate::i18n` (`gettext`, `gettext_f` with named placeholders, `ngettext_f`, `pgettext`). A new file that holds them goes in `po/POTFILES.in`. See `po/README.md`.
4. **Lint** the workspace: rustfmt, then clippy with and without default features.
5. **Commits and pull requests** follow the root rules: Conventional Commits, at most 72 characters, scope `linux` or `linux-<area>` (for example `linux-grid`, `linux-storage`), and the root `.github/pull_request_template.md`.

## CI

`.github/workflows/build-linux.yml` runs on a pull request that touches `linux/`:

- **Fast checks**: format, both clippy runs, build, every Meson suite, the Secret Service tests, `meson dist`.
- **Translations**: the POT template, with gettext 0.24.
- **Docker tests** (`integration`): one matrix job per package on the host runner, for the PostgreSQL, MySQL, SQL Server and ClickHouse drivers, `tablepro-ssh` and `tablepro-test-fixtures`.
- **Docker tests (tablepro-session)** (`integration-session`) and **Docker tests (tablepro)** (`integration-app`): in the fast job's `ubuntu:26.04` image with the host's Docker socket, because the session crate links GLib 2.88 and the app GTK 4.22, which the host runner lacks. The app job runs only its named test targets, since the `startup` test needs Meson.
