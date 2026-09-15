# Contributing to TablePro Linux

This file governs the Linux subproject only. The repository-level [CLAUDE.md](../CLAUDE.md) covers cross-cutting rules (no comments in source, security first, root-cause fixes, etc.) — those apply here too.

## Dev environment

System packages — see [README.md](README.md) for distro-specific commands. After they are installed, work happens entirely from the `linux/` directory.

```bash
cd linux
meson setup _build -Dprofile=development
meson compile -C _build        # builds tablepro and tablepro-askpass
meson test -C _build           # unit, gtk and data suites
meson devenv -C _build cargo test   # cargo against the configured app ID
cargo fmt --all                # format
```

`cargo build` works on its own for a quick edit. Running needs the compiled
GSettings schema on the search path, which `meson devenv` puts there:

```bash
meson compile -C _build        # keeps the schema in step with data/*.gschema.xml
meson devenv -C _build cargo run -p tablepro
```

A bare `cargo run -p tablepro` aborts with `GSettings schema
app.tablepro.TablePro is not installed`, because the compiled schema lives in
`_build/data` and nothing points GLib at it. Both fall back to the
`app.tablepro.TablePro.Devel` application ID, so a development build never
writes over an installed one.

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

- **No comments unless they explain a hidden constraint or invariant.** Code must be self-documenting through naming. Inherited from CLAUDE.md.
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

Conventional Commits, single line, no body. Same rule as the macOS app:

```
feat(drivers): add ClickHouse driver via clickhouse-arrow
fix(app): debounce sidebar selection to avoid duplicate fetches
refactor(core): split DatabaseDriver into Driver + Connection traits
docs(adding-drivers): clarify TLS configuration step
```

## Pull requests

1. Branch from `main`. Branch name format: `feat/short-slug`, `fix/short-slug`, `refactor/short-slug`.
2. PR title is the conventional commit message you intend to land.
3. PR description has two sections: **Summary** (what and why, 2–4 bullets) and **Test plan** (checkbox list).
4. Run the [fast-job commands](#fast-job-commands) locally before pushing.
5. UI changes must include before / after screenshots in the PR description, taken at HiDPI on both light and dark themes.

## What does not belong here

- Documentation for end users (installation, FAQ, screenshots for the marketing site) lives in the repository-level `docs/` Mintlify project.
- Cross-platform decisions (release cadence, branding, pricing) are not made in this subproject.
- macOS plugin work — that lives in `apps/macos/Plugins/` (post Phase B restructure) or the current `Plugins/` directory.

## Where to start as a contributor

In rough order of impact:

1. Read [ARCHITECTURE.md](ARCHITECTURE.md) and [docs/decisions/](docs/decisions/). 20 minutes, fixes most "why is it shaped like this" questions.
2. Pick an issue tagged `good-first-issue` or `driver:<engine>`.
3. If adding a driver, copy the most recently merged driver crate as a template. Do not copy the spike code.
4. Open the PR small. We prefer five small PRs over one big one.
