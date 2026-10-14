# Platforms, toolchains and packaging

One page for what runs where. The [sprint](bookie-0.2-sprint.md) owns release approval; [packaging](../apps/linux/packaging/README.md) owns package builds.

## Supported stacks

Two native-library floors are defined in [ADR 0002](decisions/0002-rust-gtk4-libadwaita.md): the **Cargo compile / CI floor** and the **GNOME 50 Meson / package line**.

The Cargo compile / CI floor is the Ubuntu 24.04 stack: GTK 4.14, GLib 2.80, libadwaita 1.5 and GtkSourceView 5.12. Debian 13 (GTK 4.18, libadwaita 1.7) and newer are above it. `scripts/test-distro-floor.sh` runs app unit and widget tests there; with `DISTRO_FLOOR_INSTALLED=1`, it also runs GTK safety against a Cargo-built binary staged under the target directory. This does not configure the root Meson project or install a distro package.

The root Meson project declares the higher GNOME 50 library line (GTK 4.22, GLib 2.88, libadwaita 1.9, GtkSourceView 5.18). The released `.deb` has that same runtime baseline. Arch and Omarchy packages track current GNOME. Native installed-package acceptance remains open (PKG-1); Debian and Ubuntu desktop acceptance remains open for the later GNOME target (PKG-2). Neither floor replaces the other.

At the 2026-10-14 review, Arch packaged Rust 1.98.1 while Debian 13 packaged Rust 1.85.1 ([Arch package](https://archlinux.org/packages/extra/x86_64/rust/), [Debian package](https://packages.debian.org/trixie/rust/rustc)). Arch's `rust` package ignores `rust-toolchain.toml`, and Debian 13 is below the workspace MSRV. Use rustup to select the repository's pinned toolchain consistently.

## Released packages

The latest release is [`linux-v0.1.5`](https://github.com/cozyGarage/BookiE/releases/tag/linux-v0.1.5). These packages do not qualify the 0.2.0 source.

| Target | Architecture | Artifact | Package / launch command |
|---|---|---|---|
| Arch Linux / Omarchy | x86_64 | `bookie-0.1.5-1-x86_64.pkg.tar.zst` | `bookie` |
| Debian / Ubuntu with GNOME 50 libraries | amd64 | `tablepro_0.1.5-1_amd64.deb` | `tablepro` package, `bookie` command |

No Fedora, AUR, Flathub, 32-bit or ARM packages are published.

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

The Arch package is an internal candidate, not an AUR or Flathub release. It installs `bookie` and `bookie-agentd`, with `tablepro` aliases. The application ID, D-Bus name, XDG paths and keyring schema stay `com.tablepro.linux` and `tablepro`.

- Build from a clean tree at a recorded commit: `scripts/build-arch-rc.sh` refuses a dirty tree or a SHA that is not `HEAD`, then runs `makepkg --cleanbuild`, `namcap` and package-content checks.
- Saved connections, drafts, favorites and the audit journal live in `~/.config/tablepro` and `~/.local/share/tablepro`. Stop the app before an upgrade or rollback and never delete those directories or the keyring records.
- The package replaces and conflicts with `tablepro`. Install, upgrade and removal must keep user XDG data (PKG-6).
- The 0.1.4 package report is historical evidence only.

## Flathub

Flatpak and Flathub are left out of 0.2.0 ([PRODUCT.md](../PRODUCT.md)). The Flatpak manifests (`apps/linux/flatpak/com.tablepro.linux*`) build, but a manifest build is not release qualification or publication. Submission checklist for later packaging work:

1. Capture screenshots under `apps/linux/flatpak/screenshots/` (1280x800 or larger): welcome, browse, editor, structure; reference them from the metainfo.
2. `flatpak-builder --user --install build-dir apps/linux/flatpak/com.tablepro.linux.json`.
3. `appstreamcli validate apps/linux/flatpak/com.tablepro.linux.metainfo.xml`.
4. Fork flathub/flathub, open the manifest PR, attach a release blurb.

The current manifests allow network and IPC, X11/Wayland display and graphics access, home-directory access, read-only host configuration, the Kerberos credential-cache socket, `org.freedesktop.secrets`, and the SSH-agent socket. Home-directory access versus portal-only access remains undecided (PKG-8). The `ssh-auth` socket supports the built-in client's agent authentication. The system OpenSSH option needs a host `ssh` executable and must refuse explicitly in the sandbox instead of falling back to the built-in client.

A manual run on a Debian 13 guest on October 7–8, 2026 verified building, installing, launching, uninstalling and showing the default manifest's window ([archived PKG-4 record](archive/known-issues-pre-project-migration-2026-10-12.md#packaging-and-qualification)). This is historical packaging evidence, not release qualification for the current source. Flathub submission and screenshots remain open.

## Accessibility

In tree: accessible names on primary chrome and the find fields, a shortcuts window, Adwaita alert and preferences dialogs with default and close responses, destructive styling only on the confirm response, status never by colour alone, and multi-window through New Window.

Open before Flathub (DOC-3): an Orca pass over connect, browse, edit, run SQL and disconnect; keyboard-only tab order through the connect dialog, sidebar, grid and editor; high contrast and large text; accessible names on custom grid cells and popovers.

Translations: `apps/linux/po/tablepro.pot` exists, new strings go through `tr!`, see [../apps/linux/po/README.md](../apps/linux/po/README.md).
