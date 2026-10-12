# Contributing to TablePro Linux

This file governs the Linux subproject only. [AGENTS.md](AGENTS.md) is the short guide to it, and the repository-level [AGENTS.md](../AGENTS.md) holds the rules every app shares: security first, root-cause fixes, tests define behavior and the writing style.

## Dev environment

System packages — see [README.md](README.md) for distro-specific commands. After they are installed, work happens entirely from the `linux/` directory.

```bash
cd linux
meson setup _build -Dprofile=development
meson compile -C _build        # builds tablepro and tablepro-askpass
meson test -C _build           # unit, gtk and data suites
meson devenv -C _build ./crates/app/tablepro   # run the app
meson devenv -C _build cargo test   # cargo against the configured app ID
cargo fmt --all                # format
```

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
meson setup _build -Dprofile=development
cargo fmt --all -- --check
meson devenv -C _build cargo clippy --locked --workspace --all-targets -- -D warnings
meson devenv -C _build cargo clippy --locked --workspace --all-targets --no-default-features -- -D warnings
meson compile -C _build
xvfb-run -a dbus-run-session -- meson test -C _build --print-errorlogs
meson dist -C _build --no-tests --formats xztar
```

Inside a desktop session, `dbus-run-session -- meson test -C _build` runs the same suites without xvfb.

Logs go to stderr and the filter comes from `RUST_LOG`; a development
build defaults to `debug`.

```bash
RUST_LOG=debug ./_build/crates/app/tablepro
```

CI sets `GTK_A11Y=test` for GTK tests. With `GTK_A11Y=none` GTK records no accessible properties, and the accessibility helpers report that the test backend is missing.

## Code style

| Tool | Config | Notes |
|---|---|---|
| `rustfmt` | `rustfmt.toml` at workspace root | Run before commit. Pre-commit hook enforces it. |
| `clippy` | `clippy.toml` at workspace root | All workspace crates pass with `-D warnings`. New lints are negotiated per PR. |
| Edition | 2024 | Set per workspace. Do not override per crate. |
| MSRV | 1.98 | Pinned in `rust-toolchain.toml` and `rust-version`; matches the Flatpak rust-stable extension. |

Conventions, beyond what `rustfmt` decides:

- **Comments say why, never what.** A short comment belongs where the code would surprise a careful reader: a hidden constraint, an invariant, a platform quirk. Code is otherwise self-documenting through naming.
- **No `unwrap()` or `expect()` in production paths.** Tests and `OnceLock::get_or_init` initialisers are the only acceptable callers.
- **No `panic!`, `todo!`, `unimplemented!` in merged code.** Stub a real `Err` variant instead.
- **One public type per module file** when the type's surface is non-trivial. Internal helpers stay private.
- **User-facing strings go through `crate::i18n`.** `gettext` for a plain
  string, `gettext_f` with named `{placeholders}` when values are
  interpolated, `ngettext_f` for counts, `pgettext` when a word's sense
  depends on where it appears. See [po/README.md](po/README.md).
- **Errors cross crate boundaries as `thiserror` enums.** Inside a crate, `anyhow::Result` is fine. See [docs/error-handling.md](docs/error-handling.md).

## Adding a database driver

This is the most common substantive change. Follow [docs/adding-drivers.md](docs/adding-drivers.md) end to end. It is short and the steps are mechanical. Skipping a step (most often the registry registration) breaks the app silently.

## Commits

Conventional Commits, single line, at most 72 characters, same rule as the macOS app. The scope is `linux`, or `linux-<area>` for one area of the app:

```
feat(linux-drivers): add ClickHouse driver via clickhouse-arrow
fix(linux-sidebar): debounce selection to avoid duplicate fetches
refactor(linux-core): split DatabaseDriver into Driver + Connection traits
docs(linux): clarify the TLS step for a new driver
```

## Changelog

A user-visible change gets one fragment under `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md), in the format the root `.claude/rules/changelog.md` describes. The repository-level `CHANGELOG.md` is the macOS release notes; a Linux change never goes there.

## Pull requests

1. Branch from `linux`, where this subproject lives until the first Linux release, and open the PR against `linux`. Branch name format: `feat/short-slug`, `fix/short-slug`, `refactor/short-slug`.
2. PR title is the conventional commit message you intend to land.
3. The PR description follows the repository's `.github/pull_request_template.md`.
4. Run the [fast-job commands](#fast-job-commands) locally before pushing.
5. UI changes must include before / after screenshots in the PR description, taken at HiDPI on both light and dark themes.

## What does not belong here

- Documentation for end users (installation, FAQ, screenshots) lives in the [TableProApp/docs](https://github.com/TableProApp/docs) repository.
- Cross-platform decisions (release cadence, branding, pricing) are not made in this subproject.
- macOS plugin work — that lives in `apps/macos/Plugins/` (post Phase B restructure) or the current `Plugins/` directory.

## Where to start as a contributor

In rough order of impact:

1. Read [ARCHITECTURE.md](ARCHITECTURE.md) and [docs/decisions/](docs/decisions/). 20 minutes, fixes most "why is it shaped like this" questions.
2. Pick an issue labelled `platform-linux`, or `good first issue` among those.
3. If adding a driver, copy the most recently merged driver crate as a template. Do not copy the spike code.
4. Open the PR small. We prefer five small PRs over one big one.
