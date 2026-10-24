# Platforms, toolchains and packaging

One page for what runs where. The [completion page](bookie-0.2-sprint.md) records 0.2.0 status; [release-process](release-process.md) owns release steps and [packaging](../apps/linux/packaging/README.md) owns package builds.

## Supported stacks

The current `linux` branch supports one native-library floor, set by [ADR 0021](decisions/0021-toolkit-floor.md): GTK 4.24, libadwaita 1.10 and GtkSourceView 5.22, with GLib 2.88. Arch Linux and Debian testing ship this stack. The root Meson project, the Debian and Arch package dependencies and a startup check enforce it; an older stack makes the application exit with a message naming the required and found versions.

Ubuntu 26.04 LTS (GTK 4.22), Debian 13 (GTK 4.18) and Ubuntu 24.04 (GTK 4.14) are below the native-library floor and unsupported for native packages. The published 0.2.0 Flatpak bundle uses GNOME 50 and does not qualify the current branch; a GNOME 51 bundle is not yet published. Fixes are not backported to older native toolkits.

`scripts/test-distro-floor.sh` runs app unit and widget tests on `debian:testing`; with `DISTRO_FLOOR_INSTALLED=1`, it also runs GTK safety against a Cargo-built binary staged under the target directory. Installed-package acceptance is tracked under PKG-1; Debian GNOME desktop acceptance is tracked under PKG-2.

At the 2026-10-14 review, Arch packaged Rust 1.99.0 while Debian 13 packaged Rust 1.85.1 ([Arch package](https://archlinux.org/packages/extra/x86_64/rust/), [Debian package](https://packages.debian.org/trixie/rust/rustc)). Arch's `rust` package ignores `rust-toolchain.toml`, and Debian 13 is below the workspace MSRV. Use rustup to select the repository's pinned toolchain consistently.

## Published 0.2.0 release

GitHub published [`linux-v0.2.0`](https://github.com/cozyGarage/BookiE/releases/tag/linux-v0.2.0) on 2026-10-23 with these installable artifacts:

| Target | Architecture | Artifact | Package / launch command |
|---|---|---|---|
| Arch Linux / Omarchy | x86_64 | `bookie-0.2.0-1-x86_64.pkg.tar.zst` | `bookie` |
| Debian package | amd64 | `tablepro_0.2.0-1_amd64.deb` | `tablepro` package, `bookie` command |
| AppImage | x86_64 | `BookiE-0.2.0-x86_64.AppImage` | Run the downloaded file |
| Flatpak bundle | x86_64 | `bookie.flatpak` | Install the downloaded bundle |

The release also includes an Arch debug package, `bookie.pot` and `SHA256SUMS`. The Debian package keeps the `tablepro` filename because it was built from the release tag. The 0.2.0 Flatpak bundle uses GNOME 50; the current branch manifest uses GNOME 51, so the published bundle does not qualify the current toolkit floor.

The 0.2.0 release did not publish a Fedora package, AUR package, Flathub listing, 32-bit package or ARM package. The published AppImage's `AppRun` sources a GTK hook that defaults to `GDK_BACKEND=wayland,x11`; its exact-asset Wayland behavior remains unverified because the recorded desktop run used a different PR artifact ([manual verification](manual-verification-0.2-features.md#appimage-run-on-2026-10-21)). Published artifacts prove availability, not installation or desktop acceptance on every distribution; see PKG-1 and PKG-2 below.

The release tag used the GNOME 50 native-library line (GTK 4.22, GLib 2.88, libadwaita 1.9 and GtkSourceView 5.18). [ADR 0021](decisions/0021-toolkit-floor.md) raised the current branch floor after publication. Do not treat the 0.2.0 package as a build of the current `linux` tree.

Builds from the `linux` branch after the 0.2.0 release name the Debian package `bookie` (`bookie_X.Y.Z-1_amd64.deb`). It declares `Replaces`, `Conflicts` and `Provides` for `tablepro`, so installing it replaces an installed `tablepro` package and keeps settings and credentials. The published 0.2.0 Debian package retains the `tablepro` name.

## Rust toolchain

Rust 1.98 is the minimum supported version, declared in `rust-toolchain.toml`, `Cargo.toml` and `clippy.toml`. CI compiles and lints with 1.98, and a weekly job lints with current stable.

Arch's `rust` package installs `/usr/bin/cargo` directly and ignores `rust-toolchain.toml`. Use Arch's `rustup` instead (the two conflict):

```bash
sudo pacman -S rustup
rustup toolchain install 1.98.0 --profile minimal --component rustfmt,clippy
rustup toolchain install stable --profile minimal --component clippy
rustup default stable
```

In this repository the pin selects 1.98. Use `cargo +stable clippy ...` for the forward-compatibility check. Do not change the pin because Arch ships a newer compiler. With the distro compiler, `scripts/preflight.sh` checks current stable, not the minimum, so rely on CI for the 1.98 result.

## Arch and Omarchy package

The published Arch package installs `bookie` and `bookie-agentd`, with `tablepro` aliases. It is not an AUR package. The application ID, D-Bus name, XDG paths and keyring schema stay `com.tablepro.linux` and `tablepro`.

- Build from a clean 0.2.0 tree with `TABLEPRO_RC_VERSION=0.2.0` and an explicit `TABLEPRO_RC_DATE=YYYY-MM-DD`.
- `scripts/build-arch-rc.sh` requires the full `HEAD` SHA or a remotely verified tag. It retains checksummed source and Cargo vendor archives plus a build-input manifest, then runs Cargo build and tests offline through `makepkg --cleanbuild`, `namcap` and package-content checks. Native Arch packages stay external inputs, and this command does not create a release tag.
- Saved connections, drafts, favorites and the audit journal live in `~/.config/tablepro` and `~/.local/share/tablepro`. Stop the app before an upgrade or rollback and never delete those directories or the keyring records.
- The package replaces and conflicts with `tablepro`. Install, upgrade and removal must keep user XDG data (PKG-6).
- The 0.1.4 package report is historical evidence only.

## Flathub

The 0.2.0 release includes a Flatpak bundle, but BookiE is not listed on Flathub. That bundle uses GNOME 50 and predates the current GNOME 51 runtime and toolkit floor. Current manifests build for GNOME 51; a manifest build is not a published artifact or runtime acceptance. Check PKG-8's file-access decision before starting Flathub submission; the steps below do not settle it. Submission checklist for later packaging work:

1. Capture screenshots under `apps/linux/flatpak/screenshots/` (1280x800 or larger): welcome, browse, editor, structure; reference them from the metainfo.
2. `flatpak-builder --user --install build-dir apps/linux/flatpak/com.tablepro.linux.json`.
3. `appstreamcli validate apps/linux/flatpak/com.tablepro.linux.metainfo.xml`.
4. Fork flathub/flathub, open the manifest PR, attach a release blurb.

The current manifests allow network and IPC, X11/Wayland display and graphics access, home-directory access, read-only host configuration, the Kerberos credential-cache socket, `org.freedesktop.secrets`, and the SSH-agent socket. Home-directory access versus portal-only access is the decision recorded under PKG-8. The `ssh-auth` socket supports the built-in client's agent authentication. The system OpenSSH option needs a host `ssh` executable and must refuse explicitly in the sandbox instead of falling back to the built-in client.

A manual run on a Debian 13 guest on October 7–8, 2026 verified building, installing, launching, uninstalling and showing the default manifest's window ([archived PKG-4 record](archive/known-issues-pre-project-migration-2026-10-12.md#packaging-and-qualification)). This is historical packaging evidence, not release qualification for the current source. Flathub submission and screenshots are tracked under PKG-4.

## Accessibility

In tree: accessible names on primary chrome and the find fields, a shortcuts window, Adwaita alert and preferences dialogs with default and close responses, destructive styling only on the confirm response, status never by colour alone, and multi-window through New Window.

DOC-3 tracks the remaining acceptance: an Orca pass over connect, browse, edit, run SQL and disconnect; keyboard-only tab order through the connect dialog, sidebar, grid and editor; high contrast and large text; accessible names on custom grid cells and popovers.

Translations: the `bookie.pot` template is generated by `scripts/update-translations.py` and attached to each release (not committed); new strings go through `tr!`, see [../apps/linux/po/README.md](../apps/linux/po/README.md).
