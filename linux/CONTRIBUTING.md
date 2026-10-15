# Contributing to TablePro Linux

This file governs the Linux subproject only. [AGENTS.md](AGENTS.md) is the short guide to it, and the repository-level [AGENTS.md](../AGENTS.md) holds the rules every app shares: security first, root-cause fixes, tests define behavior and the writing style.

## Dev environment

Install the system packages listed in [README.md](README.md#quickstart). After that, work happens entirely from the `linux/` directory.

```bash
cd linux
meson setup _build -Dprofile=development
meson compile -C _build        # builds tablepro and tablepro-askpass
meson test -C _build           # unit, gtk, data and packaging suites
meson devenv -C _build ./crates/app/tablepro   # run the app
meson devenv -C _build cargo test --workspace --exclude tablepro   # the unit suite through cargo
GTK_A11Y=test GSK_RENDERER=cairo GDK_BACKEND=x11 meson devenv -C _build cargo test -p tablepro   # the app's tests
cargo fmt --all                # format
```

The app's tests need the variables the gtk Meson suite sets
(`crates/app/meson.build`), and `meson devenv` does not export them:
`GTK_A11Y=test` for the accessibility checks, `GSK_RENDERER=cairo` for a
machine with no GPU, and `GDK_BACKEND=x11` for the tests that press keys
through XTEST.

Run every other `cargo` command through `meson devenv -C _build` too. It
points Cargo at the `CARGO_HOME` and target directory inside `_build`, so
Cargo reuses what `meson compile` already built, and it puts the compiled
GSettings schema on the search path. A bare `cargo` builds a second copy
of the whole tree into `target/`, and a bare `cargo run -p tablepro` aborts
with `GSettings schema app.tablepro.TablePro is not installed`.

Run `meson compile -C _build` after editing `data/*.gschema.xml`, so the
compiled schema stays in step with it. A development build uses the
`app.tablepro.TablePro.Devel` application ID, so it never writes over an
installed one.

### Fast-job commands

The fast job in `.github/workflows/build-linux.yml` runs these steps in this order:

```bash
localedef -i en_US -f UTF-8 en_US.UTF-8   # as root, once: the catalogue test needs a real locale
meson setup _build -Dprofile=development
cargo fmt --all -- --check
meson devenv -C _build cargo clippy --locked --workspace --all-targets -- -D warnings
meson devenv -C _build cargo clippy --locked --workspace --all-targets --no-default-features -- -D warnings
meson compile -C _build
xvfb-run -a dbus-run-session -- meson test -C _build --print-errorlogs
dbus-run-session -- bash -c "gnome-keyring-daemon --components=secrets --daemonize --unlock <<< ci \
  && meson devenv -C _build cargo test --locked -p tablepro-storage --test secret_service -- --ignored"
meson dist -C _build --no-tests --formats xztar
```

Inside a desktop session, `dbus-run-session -- meson test -C _build` runs the same suites without xvfb.

The fast job also runs a few source greps and `scripts/check-doc-symbols.sh` from the repository root. The supply-chain, documentation and Docker jobs run these, among others; [docs/testing.md](docs/testing.md#ci) describes every job, and the Docker job runs the last line once per package that has Docker tests:

```bash
cargo deny --locked check advisories bans licenses sources
cargo shear
build-aux/update-third-party-licenses.sh     # then a diff against the committed files
lychee --offline --include-fragments --no-progress 'linux/**/*.md'   # from the repository root
cargo nextest run --locked --profile ci -p tablepro-driver-postgres --run-ignored only
```

Logs go to stderr and the filter comes from `RUST_LOG`; a development
build defaults to `debug`. `TABLEPRO_LOG_FORMAT=json` writes one JSON
object per line.

```bash
RUST_LOG=debug meson devenv -C _build ./crates/app/tablepro
```

The gtk Meson suite sets `GTK_A11Y=test`, and `meson devenv` does not. With `GTK_A11Y=none` GTK records no accessible properties, and the accessibility helpers report that the test backend is missing.

### Dependencies

`data/licenses` holds the license notices of every crate the app ships, written from `Cargo.lock` by cargo-about. The About dialog embeds `third-party.json`, and both files install next to `LICENSE`. After a change to `Cargo.lock`, regenerate them and commit the result; the Supply chain CI job fails until they match:

```bash
cargo install --locked cargo-about@0.9.2 --features cli
build-aux/update-third-party-licenses.sh
```

A license added to `[licenses].allow` in `deny.toml` goes into `accepted` in `about.toml` at the same position.

The script stops and names each crate it read no license file for, since the notice would carry the SPDX template text with no copyright holder. Give that crate a `[<crate>.clarify]` entry in `about.toml` with the file's path and SHA-256: under `files` for a file in the crate, under `git` for one in its repository at the published commit. An entry whose checksum no longer matches names its crate the same way. The script needs the network for the `git` entries.

## Code style

| Tool | Config | Notes |
|---|---|---|
| `rustfmt` | `rustfmt.toml` at the workspace root | CI fails on any diff from `cargo fmt --all -- --check`. There is no pre-commit hook. |
| `clippy` | `[workspace.lints]` in `Cargo.toml`, `clippy.toml`, `crates/app/clippy.toml`, `crates/session/clippy.toml` | Every crate passes with `-D warnings`, with and without default features. |
| Edition | 2024 | Set per workspace. Do not override per crate. |
| MSRV | 1.98 | `rust-version` in `Cargo.toml` and `rust-toolchain.toml`; matches the Flatpak rust-stable extension. |

The workspace denies `unwrap_used`, `expect_used`, `panic`, `todo`, `unimplemented`, `dbg_macro`, `print_stdout`, `print_stderr`, `allow_attributes`, `allow_attributes_without_reason`, `ignore_without_reason` and `too_many_lines`, plus `unsafe_op_in_unsafe_fn`. `clippy.toml` lets tests unwrap, expect, panic, print and use `dbg!`, and bans `serde_json::Map`, which reorders a server's JSON. Clippy reads only the `clippy.toml` nearest a crate, so `crates/app/clippy.toml` and `crates/session/clippy.toml` replace the root file for their crate. Both keep its test allowances and ban reaching for the ambient tokio runtime: background work goes through `Tasks`. The app's also keeps the `serde_json::Map` ban and bans the Relm4 spawns, `MainContext::block_on` and `ApplicationExt::quit`. The session's has no `serde_json::Map` ban.

Conventions, beyond what `rustfmt` decides:

- **Comments say why, never what.** A short comment belongs where the code would surprise a careful reader: a hidden constraint, an invariant, a platform quirk. Code is otherwise self-documenting through naming.
- **No `unwrap()` or `expect()` in production paths.** Tests are the only callers; the workspace lints deny the rest.
- **No `panic!`, `todo!`, `unimplemented!` in merged code.** Stub a real `Err` variant instead.
- **One public type per module file** when the type's surface is non-trivial. Internal helpers stay private.
- **A function holds at most 100 lines of code**, tests included. The workspace denies `clippy::too_many_lines` at its default threshold, so split a long function by what each part does instead of allowing the lint.
- **User-facing strings go through `crate::i18n`.** `gettext` for a plain
  string, `gettext_f` with named `{placeholders}` when values are
  interpolated, `ngettext_f` for counts, `pgettext` when a word's sense
  depends on where it appears. See [po/README.md](po/README.md).
- **Errors are `thiserror` enums.** The workspace has no `anyhow`. See [docs/error-handling.md](docs/error-handling.md).

## Adding a database driver

This is the most common substantive change. Follow [docs/adding-drivers.md](docs/adding-drivers.md) end to end. It is short and the steps are mechanical. Skipping a step (most often the registry registration) breaks the app silently.

## Commits

Conventional Commits, single line, at most 72 characters, same rule as the macOS app. The scope is `linux`, or `linux-<area>` for one area of the app: `linux-grid`, `linux-browse`, `linux-structure`, `linux-editor`, `linux-history`, `linux-export`, `linux-sidebar`, `linux-picker`, `linux-session`, `linux-storage`, `linux-ssh`, `linux-core`, `linux-flatpak`, or a driver as `linux-postgres`, `linux-mysql`, `linux-sqlite`, `linux-mssql`, `linux-clickhouse`.

```
fix(linux-sidebar): keep the filter text when the catalog refreshes
feat(linux-export): export the entire table from the table tab
docs(linux): clarify the TLS step for a new driver
```

## Changelog

A user-visible change gets one fragment under `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md), in the format the root `.claude/rules/changelog.md` describes. The repository-level `CHANGELOG.md` is the macOS release notes; a Linux change never goes there.

## Pull requests

1. Branch from `linux`, where this subproject lives until the first Linux release, and open the PR against `linux`. Branch name format: `feat/short-slug`, `fix/short-slug`, `refactor/short-slug`.
2. PR title is the conventional commit message you intend to land.
3. The PR description follows the repository's `.github/pull_request_template.md`.
4. Run the [fast-job commands](#fast-job-commands) locally before pushing.
5. A change to `Cargo.lock` commits what `build-aux/update-third-party-licenses.sh` rewrites: `data/licenses`, `build-aux/debian/copyright` and the spec's `License` tag ([Dependencies](#dependencies)). `cargo-sources.json` is not committed: CI writes it from `Cargo.lock`.
6. A new or removed file under `crates/app/src` regenerates `po/POTFILES.in`, and a changed user-facing string regenerates `po/tablepro.pot` ([po/README.md](po/README.md)).
7. A user-visible change has its [changelog](#changelog) fragment.
8. UI changes include before and after screenshots in the PR description, light and dark when color is involved. A change to a window shown in the metainfo retakes its screenshot in `data/screenshots` ([README.md](README.md#screenshots)).

## What does not belong here

- Documentation for end users (installation, FAQ, screenshots) lives in the [TableProApp/docs](https://github.com/TableProApp/docs) repository.
- Cross-platform decisions (release cadence, branding, pricing) are not made in this subproject.
- macOS plugin work, which lives in the repository's `Plugins/` directory.

## Where to start as a contributor

In rough order of impact:

1. Read [ARCHITECTURE.md](ARCHITECTURE.md) and [docs/decisions/](docs/decisions/). 20 minutes, fixes most "why is it shaped like this" questions.
2. Pick an issue labelled `platform-linux`, or `good first issue` among those.
3. If adding a driver, start from the most recently merged driver crate and [docs/adding-drivers.md](docs/adding-drivers.md).
4. Open the PR small. We prefer five small PRs over one big one.
