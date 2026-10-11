# Platforms, toolchains and packaging

One page for what runs where. The [sprint](bookie-0.2-sprint.md) owns release approval; [packaging](../apps/linux/packaging/README.md) owns package builds.

## Supported stacks

Two native-library floors are defined in [ADR 0002](decisions/0002-rust-gtk4-libadwaita.md): the **build / CI floor** and the **GNOME 50 package line**.

The build floor is the Ubuntu 24.04 stack: GTK 4.14, GLib 2.80, libadwaita 1.5 and GtkSourceView 5.12. Debian 13 (GTK 4.18, libadwaita 1.7) and newer are above it. `scripts/test-distro-floor.sh` builds and runs the unit and widget tiers on both in containers, and the Forgejo job `distro-floor` runs it on every push. The installed AT-SPI pass on those distros is still open (PKG-2 in the [ledger](known-issues.md)).

The GitHub Release `.deb` that needs GNOME 50 libraries follows the higher package line (GTK 4.22, GLib 2.88, libadwaita 1.9, GtkSourceView 5.18). Arch and Omarchy packages track current GNOME. Neither floor replaces the other.

Neither distro packages Rust 1.98. Build with rustup.

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
- Release evidence for 0.1.4: [archive/release-0.1.4.md](archive/release-0.1.4.md).

## Flathub

Flatpak and Flathub are left out of 0.2.0 ([PRODUCT.md](../PRODUCT.md)). The Flatpak manifests (`apps/linux/flatpak/com.tablepro.linux*`) build, but a manifest build is not release qualification or publication. Submission checklist for later packaging work:

1. Capture screenshots under `apps/linux/flatpak/screenshots/` (1280x800 or larger): welcome, browse, editor, structure; reference them from the metainfo.
2. `flatpak-builder --user --install build-dir apps/linux/flatpak/com.tablepro.linux.json`.
3. `appstreamcli validate apps/linux/flatpak/com.tablepro.linux.metainfo.xml`.
4. Fork flathub/flathub, open the manifest PR, attach a release blurb.

Permissions stay minimal: network, home (saved connections, SSH keys) and `org.freedesktop.secrets`. The manifests grant `--socket=ssh-auth` for the built-in client's agent authentication. The system OpenSSH option needs a host `ssh` and must refuse explicitly in the sandbox instead of falling back to the built-in client.

## Accessibility

In tree: accessible names on primary chrome and the find fields, a shortcuts window, Adwaita alert and preferences dialogs with default and close responses, destructive styling only on the confirm response, status never by colour alone, and multi-window through New Window.

Open before Flathub (DOC-3): an Orca pass over connect, browse, edit, run SQL and disconnect; keyboard-only tab order through the connect dialog, sidebar, grid and editor; high contrast and large text; accessible names on custom grid cells and popovers.

Translations: `apps/linux/po/tablepro.pot` exists, new strings go through `tr!`, see [../apps/linux/po/README.md](../apps/linux/po/README.md).
