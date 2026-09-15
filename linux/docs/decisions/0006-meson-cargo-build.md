# 0006. Meson drives Cargo

Date: 2026-09-15

## Status

Accepted.

## Context

Cargo builds the Rust code, but it cannot install a desktop entry, merge
translations into AppStream metadata, compile a GSchema, or place an icon
in the hicolor theme. It also has no way to hand the binary a build-time
application ID or locale directory, which the app needs so a development
build never writes over an installed one.

Flathub, Debian and Fedora all expect a build system that honours
`--prefix`, `DESTDIR` and the standard directory options. Every GNOME
Rust app that ships through those channels (Fractal, Loupe, Shortwave,
Video Trimmer) solves this the same way.

## Decision

Meson is the build system; Cargo stays the Rust compiler.

- `meson.build` resolves the application ID, version and profile, then
  exports them to Cargo as `TABLEPRO_APP_ID`, `TABLEPRO_VERSION`,
  `TABLEPRO_PROFILE`, `TABLEPRO_LOCALEDIR` and `TABLEPRO_LIBEXECDIR`.
  `crates/app/src/config.rs` reads them through `option_env!`, so a plain
  `cargo build` still works and falls back to the `.Devel` ID.
- `crates/app/meson.build` wraps `cargo build` in one `custom_target` that
  installs `tablepro` to bindir and `tablepro-askpass` to libexecdir.
  `CARGO_HOME` and `CARGO_TARGET_DIR` live in the build directory, so a
  Flatpak build never writes outside it.
- `data/meson.build` owns the desktop entry, the D-Bus service file, the
  AppStream metainfo and the icons. The desktop and metainfo templates are
  `.in.in`: `configure_file` substitutes the application ID, then
  `i18n.merge_file` merges the translations.
- Tests run through `meson test`, grouped into the `unit`, `gtk` and
  `data` suites. The `data` suite runs `desktop-file-validate` and
  `appstreamcli validate`, which is what Flathub checks.
- `meson devenv -C _build` exports the same environment, so
  `meson devenv -C _build cargo test` runs against the configured
  application ID without an install.

## Consequences

- Contributors need meson and ninja on top of the Rust toolchain. The
  plain `cargo build` path keeps working for quick edits.
- The version number lives in `meson.build` alone. Crate manifests carry
  no version, and the About dialog reads `config::VERSION`.
- A development build is a separate application: its own ID, icon,
  config directory and keyring schema. Installing one never disturbs the
  other.
- `meson dist` produces the release tarball, so the tarball and the
  Flatpak build from the same tree.
