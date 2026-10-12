# Verification traps: Linux

Read this when a `verify.sh` verdict needs interpreting for the Linux app, or before writing a test. The usage line is `verify.sh [--platform linux] [--root <tree>] [--run <dir>] [--offline] <step> [args]`; on a Linux machine the platform is this one unless the option names another.

## Why the wrapper, always

Cargo prints one "test result:" line per test binary and never adds them up, three of the app crate's test binaries print no counts at all, and Meson prints only the failing tests. The wrapper sums the counts, treats a harness-free binary as one case, copies Meson's `testlog.txt` into the log before the next run overwrites it, and runs Cargo through `meson devenv` so it reuses the tree's build instead of starting a second one in `linux/target/`.

## Setup and build

- **A new tree has no `linux/_build`**: run `setup`, then `build`. Every other step reports `INCONCLUSIVE` until then.
- **The first build of a tree downloads every crate** into `linux/_build/cargo-home` and builds about 20 GB into `linux/_build/cargo-target`. No network means a failed build that is not the change; `--offline` sets `CARGO_NET_OFFLINE` once the tree has its crates.
- **`cargo` not on PATH** in a shell that never read the user's profile: the wrapper sources `~/.cargo/env`, which is where rustup puts it. Run by hand, `meson devenv cargo ...` fails with "Command not found: cargo".
- **A schema or desktop file edit needs `build`**, which recompiles the GSettings schema; a stale one aborts the app on its first settings read.
- **`setup` again after a merge** from the base, or after `linux/meson.build`, `linux/meson_options.txt` or a template under `linux/data/` changed. A new `.rs` file needs nothing: Cargo finds modules itself.

## Tests

- **A filter that matches nothing passes.** `cargo test -p <package> <filter>` exits 0 with "0 passed", and `meson test --suite <unknown>` exits 0 with "No suitable tests defined". The wrapper reports a filter that matched no test as `INCONCLUSIVE`; check the executed count anyway.
- **Harness-free tests ignore the filter.** `startup`, `logging` and `i18n_catalog` in the app crate are `harness = false`: they run whatever the filter says, print nothing on success and count as one case each.
- **Exit 101 is both a compile error and a test failure.** The wrapper tells them apart by whether any test binary ran.
- **Widget tests need `GTK_A11Y=test` and `GSK_RENDERER=cairo`.** Meson's `gtk` suite sets them and `meson devenv` does not; the wrapper adds them for the `tablepro` package. Without the test backend GTK records no accessible properties and the accessibility helpers fail.
- **No display**: GTK fails to initialise ("Failed to initialize GTK", exit 101). Run inside the desktop session; without one the wrapper uses `xvfb-run` when it is installed, as CI does. Unsetting `DISPLAY` and `WAYLAND_DISPLAY` is not enough to reproduce it, since GDK falls back to `wayland-0`.
- **Tests that need a container are ignored** with `#[ignore = "requires docker"]` and run only through `docker <package>`, which CI runs per package: `tablepro-driver-postgres`, `tablepro-driver-mysql`, `tablepro-driver-mssql`, `tablepro-driver-clickhouse`, `tablepro-ssh` and `tablepro-test-fixtures`. SQL Server publishes no arm64 image, so on an arm64 machine the MSSQL tests need x86 emulation and are otherwise CI's to run.
- **Secret Service tests are ignored** and run only through `secrets`, on a private session bus with a throwaway keyring. Never run them with `--ignored` on the user's own bus: they would write to the real keyring.
- **Every test runs on a private session bus** through `dbus-run-session`, as CI does, so test traffic never reaches the user's desktop.

## Lint

- **`lint` covers the whole workspace**, not the files you pass: rustfmt in check mode, then clippy with `-D warnings` with and without default features. The second run compiles the code behind `#[cfg(not(feature = "kerberos"))]`, which the default build never sees.
- **A bare `#[ignore]` fails clippy**: every ignore carries its reason.
- **`unwrap`, `expect` and `panic!` are denied** in the workspace lints, and `clippy.toml` allows them in tests only. The app crate has its own `clippy.toml` with methods it forbids, each with the reason.

## Translations and data

- **`l10n` checks the file list and the catalog**, not the template. Extracting the template needs gettext 0.24 or later, which reads Rust; an older `xgettext` reads it with the C lexer and produces a template that must not be committed. CI's Translations job is the gate for it.
- **`i18n_catalog` needs the `en_US.UTF-8` locale and `msgfmt`**: `localedef -i en_US -f UTF-8 en_US.UTF-8` when the locale is missing.
- **`data` skips a validator whose tool is not installed** (`desktop-file-validate`, `appstreamcli`, `glib-compile-schemas`) and reports it.

## Packaging

- **`dist` packs the last commit** and refuses a tree with uncommitted changes, so run it after the commit.
- **The Flatpak manifest** under `linux/build-aux/flatpak/` is not built in CI.
