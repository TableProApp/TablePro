# 0036: The copyright file describes the source tarballs

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

[ADR 0018](0018-ppa-copr-and-flathub-later.md) generated `debian/copyright` and the spec's `License` tag from `data/licenses/third-party.json`, the cargo-about inventory of the crates linked into the two binaries. The Debian source package also ships the vendor tarball, which `cargo vendor` fills with every package in `Cargo.lock`: build-only and test-only crates, crates for other platforms, and packages no feature of the workspace reaches. cargo-about walks the build graph and never sees those, so about 300 vendored crates fell to the `Files: *` paragraph under TablePro's own copyright and AGPL, and the code some crates carry from other projects, such as the DuckDB archive, had no paragraph of its own. Debian Policy 12.5 and DEP-5 describe the copyright file as covering the source package.

## Decision

`debian/copyright` describes every file of the two source tarballs, from `cargo metadata` and each vendored crate's own license files; the binary inventory keeps the About dialog, the license notices and the RPM `License` tag.

## Rationale

`cargo metadata` lists the same packages `cargo vendor` copies, so the copyright file and the vendor tarball cannot drift apart, and a Meson test checks every `Cargo.lock` crate has its paragraph without network. Each crate keeps the license files it ships, which carry its holders; a crate that ships none is credited to its Cargo.toml authors and points at a stand-alone license paragraph, the way Debian packages do. Code a crate carries from another project is listed in `build-aux/about/source.json` or a bundled manifest, and a license file or archive inside a crate that neither lists fails the update script.

The RPM keeps the binary scope: Fedora's `License` tag covers what the binary package contains, and its `bundled()` Provides name the native libraries compiled in, from the same bundled manifests.

## Consequences

- The copyright file grows with the whole lock file, about 800 crates.
- A new crate that bundles another project's code, or a new version of one, needs a look and an entry before the update script passes.
- Trimming the vendor tarball to the Linux build graph would shrink it again; it would also need stub crates, since Cargo resolves the whole lock file.

## Alternatives considered

- **Widen `Files: *`**: keeps the file short and states the wrong holder and license for every crate it swallows.
- **A second cargo-about run over the workspace with every target and kind**: still misses the 41 packages no feature reaches, measured on the lock of this date.
- **cargo vendor-filterer with stub crates**: a new build tool for the PPA, the COPR build and the Flatpak, for a smaller tarball rather than a correct description.
