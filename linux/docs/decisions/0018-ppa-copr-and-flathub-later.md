# 0018: A PPA and COPR first, Flathub later

- **Status**: Accepted
- **Date**: 2026-10-15

## Context

[ADR 0017](0017-distribution-channels.md) made Flathub the primary
channel, published a .deb for Ubuntu 26.04 as a GitHub Releases asset
built with rustup, and sent the source RPM to COPR with `copr-cli`.
Nothing was released under it. Checked against what each channel gives
users, three parts of it do not hold:

- **The .deb never updates.** apt only upgrades from a repository it
  knows, so a user who installed the release asset keeps that version
  until they download another.
- **The PPA was not blocked by Rust.** No crate in `Cargo.lock` needs
  more than Rust 1.94, and the workspace builds on 1.97. The Rust
  toolchain team's PPA, `~rust-toolchain/staging`, builds `rustc-1.97`
  for 26.04, and Firefox's PPA builds against it. 1.98 was a choice, not
  a need.
- **A `copr-cli` token expires.** COPR API tokens last 180 days, so the
  release job would start failing on its own.

Flathub also changed. Its generative AI policy says a manifest must not
contain AI-generated or AI-assisted content, that AI tools must not open
or automate submission pull requests, and that AI-generated code in the
app must be disclosed, after which reviewers may reject it. Its linter
policy refuses the home and host exceptions "if there are signs of LLM
usage in the software or in the exception PR". This repository is
written with AI agents (`AGENTS.md`), and ADR 0008 depends on the home
exception. A new submission must also use the latest runtime, GNOME 51
since 2026-09-16.

On Ubuntu, Flathub would not have reached most users anyway: 26.04 does
not install Flatpak, and App Center lists snaps and archive packages
only.

## Decision

The distribution packages are the primary channels. Flathub follows
later, as a submission a maintainer writes by hand.

| Channel | Built by | Users install | Updates |
|---|---|---|---|
| Ubuntu PPA, 26.04 and 26.10 | Launchpad, from a source package with the crates in an orig component tarball, with `rustc-1.97` from `~rust-toolchain/staging` on 26.04 and from the archive on 26.10 | `add-apt-repository ppa:…`, then `apt install tablepro` | apt and Software Updater |
| Fedora COPR, 44 and later | COPR, from the spec and tarballs of each `linux-v*` release, with Fedora's Rust | `dnf copr enable …`, then `dnf install tablepro` | dnf and GNOME Software |
| Flathub, later | Flathub, from a manifest a maintainer writes and submits | GNOME Software or `flatpak install` | GNOME Software |

`release-linux.yml` checks the tag, publishes the GitHub release with the
source and vendor tarballs, uploads the signed source package to the PPA,
and posts the tag to the COPR project's custom webhook. COPR's custom
source method then runs `build-aux/rpm/copr-sources.sh`, which fetches
the spec at that tag and the two tarballs it names. A pre-release skips
the PPA and COPR. The workflow's header names the secrets and variables
it needs.

Both packages build with `meson install` from the release's two
tarballs: `tablepro-X.Y.Z.tar.xz` from `meson dist`, and
`tablepro-X.Y.Z-vendor.tar.xz` with `vendor/` from `cargo vendor --locked
--versioned-dirs` and the source replacement it printed. They build
offline and run every Meson suite during the build, the gtk suite under
`xvfb-run` and `dbus-run-session`. `linux-packages.yml` builds them the
same way before a release, on pull requests that touch the packaging and
on pushes to `linux` (`docs/testing.md`, CI).

`debian/copyright` and the spec's `License` tag come from
`data/licenses/third-party.json`, the cargo-about output the About
dialog lists, through `build-aux/packaging/license_metadata.py`, with
every license choice a crate offers kept.
`build-aux/update-third-party-licenses.sh` rewrites them, and a Meson
test fails when they drift.

The workspace `rust-version` is 1.97, and a CI job checks the workspace
with the PPA's own `rustc-1.97`. `rust-toolchain.toml` stays on the
toolchain the Flatpak rust-stable extension ships.

The repository keeps the Devel Flatpak manifest on GNOME 51 for
development and CI. It does not keep a manifest for Flathub.

## Rationale

- **`meson install` is the one build.** It alone installs the desktop
  entry, D-Bus service, metainfo, schema, translations and askpass helper
  where the compiled-in paths expect them (ADR 0006).
- **Updates come from the package manager.** A PPA and a COPR project
  are repositories apt and dnf already update from; Software Updater and
  GNOME Software show their updates with the system's own.
- **Launchpad and COPR build and sign.** Neither needs a signing key for
  a repository of our own, nor storage for one.
- **The PPA builds what Ubuntu would build.** Offline, from a source
  package, with an Ubuntu-built compiler, the way fish and Firefox ship
  to Ubuntu. The CI job keeps the code on that compiler.
- **Only a Linux release starts a COPR build.** The release job is the
  one caller of the webhook, whose URL holds a project secret that
  lasts until a maintainer regenerates it.
- **Flathub's policy is the maintainers' to meet.** A manifest an agent
  wrote cannot be submitted, so the repository does not pretend to have
  one.

## Consequences

- Before the first tag, maintainers create the PPA with a dependency on
  `~rust-toolchain/staging`, register the upload key with Launchpad,
  create the COPR project with a custom-method package from
  `copr-sources.sh`, and store the webhook URL for the release job.
- COPR runs its own copy of `copr-sources.sh`, so a change to the script
  is applied with `copr-cli edit-package-custom`.
- A crate that needs Rust newer than the staging PPA's newest
  `rustc-1.NN` holds the PPA until that toolchain is built.
- The GitHub release carries no binary package. Users of other
  distributions build from source until Flathub has the app.
- If Flathub refuses the home exception, the Flatpak loses in-place
  SQLite files outside the folders a portal hands over, and ADR 0008
  changes with it.
- An upstream pre-release such as `0.2.0-rc.1` packages as `0.2.0~rc.1`,
  as Debian and Fedora version rules expect.
- Each release commit bumps `meson.build`, the newest metainfo
  `<release>`, the spec's `Version` and `%changelog`, and moves
  `[Unreleased]` in `CHANGELOG.md` under the version. The
  `release-metadata` Meson test keeps them in step. `build-source.sh`
  writes `debian/changelog` per series at upload, as
  `X.Y.Z-0ppaN~YY.MM`. A packaging fix uploads a released version again
  with a higher N, from the release's own tarballs, by a manual run of
  `release-linux.yml` ([releasing.md](../releasing.md#a-packaging-fix)).
- A new Ubuntu series joins `UBUNTU_SERIES` in `linux-packages.yml`, and
  a new Fedora release arrives through COPR's "follow Fedora branching".
- The .deb is `Architecture: amd64 arm64`, and the COPR project builds
  x86_64 and aarch64: the two architectures CI builds, tests and starts
  the packages on. With `any`, Launchpad would also build every other
  architecture the PPA has turned on and publish what no one tested.
- The vendor tarball holds every crate in the lock file, Windows-only and
  test-only ones included, because `cargo vendor` cannot filter.
- The release profile's fat LTO link ran out of 8 GB, so both packages
  link with thin LTO. The .rpm also builds with 16 codegen units, since
  one put the app's test build past 7 GB.

## Alternatives considered

- **An apt repository of our own**: the .deb installs its keyring and a
  deb822 source, as Chrome and VS Code do. It keeps Rust 1.98, but it
  needs a signing key, hosting, and a repository tool in CI, all of
  which Launchpad provides.
- **Snap**: App Center shows it and snapd updates it, but strict
  confinement keeps the SSH agent out, makes `~/.ssh` read-only and
  reads Kerberos tickets only from `/tmp` files, and a database client
  does not qualify for classic confinement.
- **Packit**: Fedora's upstream release tool, with no token in this
  repository. Its COPR job starts on every GitHub release of the
  repository, and its tag filters apply only to dist-git jobs, so once
  `linux/` merges into `main` every plugin and macOS release would start
  a build that fails.
- **COPR's GitHub webhook**: builds a tag only when it reads as
  `<package>-<version>`, or every tag when the URL names the package,
  and builds pushes to the branch unless the SCM settings filter them.
- **Flathub as the primary channel**: the AI policy and the home
  exception make acceptance a reviewer's call, not ours.
- **AppImage**: it has to be built on the oldest base it supports, no
  base older than Ubuntu 26.04 or Fedora 44 carries GLib 2.88 and GTK
  4.22, and the format cannot honour the compiled-in locale, schema and
  D-Bus service paths.
- **cargo-deb, cargo-generate-rpm, nfpm**: they package Cargo's output
  and skip Meson's data files and translations.
- **dh-cargo and Fedora's crate-by-crate packaging**: both need every
  dependency packaged in the archive, far more work than vendoring for
  an application.
