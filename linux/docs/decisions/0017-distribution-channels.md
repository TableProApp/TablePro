# 0017: Distribution channels

- **Status**: Superseded by 0018
- **Date**: 2026-10-14

## Context

Flathub is the primary channel. Users of Ubuntu and Fedora also expect a
system package, with the OpenSSH client, Kerberos and the system trust
store of the host rather than of a sandbox runtime. The GNOME 50 floor
(ADR 0015) means only Ubuntu 26.04 and Fedora 44 ship the libraries the
app links.

The workspace needs Rust 1.98. Fedora 44 ships it; Ubuntu 26.04 ships
rustc 1.93.

## Decision

Three channels, all built from one `meson install` and one lock file:

| Channel | Built by | Published to |
|---|---|---|
| Flatpak | the Flathub manifest | Flathub |
| .deb for Ubuntu 26.04 | `dpkg-buildpackage -b` with the committed `build-aux/debian`, Rust from rustup | GitHub Releases |
| .rpm for Fedora 44 | `rpmbuild` with the committed `build-aux/rpm/tablepro.spec` and Fedora's Rust | COPR |

A `linux-vX.Y.Z` tag runs `release-linux.yml`. It checks that the tagged
commit is on the `LINUX_BRANCH` branch (`linux` when unset) and that the
tag, `meson.build`, the newest metainfo release (dated the day of the
tagged commit), the spec and `CHANGELOG.md` name one version, then
publishes, under the `linux-release` environment and without taking the
repository's latest release from macOS:

- `tablepro-X.Y.Z.tar.xz` from `meson dist`;
- `tablepro-X.Y.Z-vendor.tar.xz`: `vendor/` from `cargo vendor --locked
  --versioned-dirs`, with the printed source replacement as
  `vendor/cargo-config.toml`. Both packages build offline from it, the
  .deb through the `cargo_config` Meson option and the .rpm through
  `%cargo_prep -v vendor`;
- the .deb for amd64 and arm64 with its `-dbgsym` package, and
  `SHA256SUMS`;
- the source RPM to COPR for `fedora-44-x86_64` and `fedora-44-aarch64`.

Both packages run every Meson suite during the build, the gtk suite under
`xvfb-run` and `dbus-run-session`. `linux-packages.yml` builds both on a
pull request that touches the packaging, each in a fresh container with
only the declared build dependencies, and installs each in another fresh
container with only its runtime dependencies. There it runs
`tablepro --help`, which opens the installed GSettings schema first,
validates the desktop entry, metainfo and schema, and starts a window
under Xvfb. `build-aux/packaging/build-packages.sh` runs the same steps
locally.

`debian/copyright` and the spec's `License` tag come from
`data/licenses/third-party.json`, the cargo-about output the About dialog
and the license notices use, through
`build-aux/packaging/license_metadata.py`.
`build-aux/update-third-party-licenses.sh` rewrites all of them, and a
Meson test fails when they drift.

## Rationale

- `meson install` is the only build that installs the desktop entry, the
  D-Bus service, the metainfo, the schema, the translations and the
  askpass helper where the compiled-in paths expect them (ADR 0006).
- The .deb cannot enter a PPA or the Ubuntu archive while the archive's
  rustc is older than the workspace's `rust-version`, so it is a release
  asset built with rustup, and binary-only.
- COPR builds with Fedora's own Rust in mock, so the .rpm is a normal
  Fedora build and its users get updates through dnf.
- `cargo-about` templates cannot indent a license text into a deb822
  field, so the Debian file is rendered by a script from the same JSON
  rather than by a template.

## Consequences

- Each release commit bumps `meson.build`, the newest metainfo
  `<release>`, the spec's `Version` and `%changelog` (`rpmdev-bumpspec`),
  and moves `[Unreleased]` in `CHANGELOG.md` under the version. The
  `release-metadata` Meson test keeps the first three in step between
  releases.
- The first translation in `po/LINGUAS` needs `%find_lang %{name}` and
  `-f %{name}.lang` in the spec; the same test fails until it is there.
- A pre-release version such as `0.2.0-rc.1` cannot be packaged: RPM
  forbids `-` in `Version` and git forbids `~` in a tag.
- Publishing needs the `linux-release` environment, limited to `linux-v*`
  tags and holding the `COPR_CONFIG` secret, and the `LINUX_COPR_PROJECT`
  variable; without the secret or the variable the COPR job fails and the
  GitHub release still goes out.
- The vendor tarball holds every crate in the lock file, Windows-only and
  test-only ones included, because `cargo vendor` cannot filter.
- The release profile's fat LTO needs gigabytes per binary. The .deb
  keeps it with line-table debug info, which links within 8 GB; the .rpm
  links with thin LTO, because Fedora's rustc runs out of 8 GB on the fat
  link. Both packages build their test suites without LTO.

## Alternatives considered

- **AppImage**: dropped. It has to be built on the oldest base it
  supports, no base older than Ubuntu 26.04 or Fedora 44 carries GLib
  2.88 and GTK 4.22, and the format cannot honour the compiled-in locale,
  schema and D-Bus service paths.
- **Snap**: skipped, as before; Flathub covers the cross-distribution
  case.
- **cargo-deb, cargo-generate-rpm, nfpm**: they package Cargo's output
  and skip Meson's data files and translations.
- **dh-cargo and Fedora's crate-by-crate packaging**: dh-cargo needs the
  archive's Rust; packaging each dependency as its own Fedora crate is
  far more work than vendoring for an application.
- **A source package with a second orig tarball for vendor/**: the
  archive could not build it with its own rustc, so it would add a format
  nobody consumes.
