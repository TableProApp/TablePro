# Packaging

GitHub Release `linux-v0.1.5` ships an Arch/Omarchy `.pkg.tar.zst` and an amd64 `.deb`. Nothing here is ready for AUR or Flathub. BookiE keeps the existing repository and application ID. Portal permissions and the public update channel still need release review.

## Internal Arch RC

The recipe in [`arch/PKGBUILD`](arch/PKGBUILD) accepts only an immutable commit archive and a real SHA-256 checksum. It installs `bookie`, `bookie-agentd`, `tablepro-askpass`, compatibility aliases `tablepro` and `tablepro-agentd`, desktop/AppStream/icon metadata, the license, the example policy, and any compiled translation catalogs. It deliberately does not ship a systemd unit: stdio agentd is launched on demand by its MCP client.

After committing and validating the candidate (no published tag required), from the repository root:

```bash
TABLEPRO_RC_COMMIT="$(git rev-parse HEAD)" TABLEPRO_RC_VERSION=0.1.5 ./scripts/build-arch-rc.sh
```

The helper refuses a dirty tree or a candidate SHA other than `HEAD`. It archives that exact local commit, computes the checksum, builds with `makepkg`, and runs `namcap` and package-content validation. Set `TABLEPRO_RC_TAG=linux-v…` instead of `TABLEPRO_RC_COMMIT` to verify an already published tag against the remote. The Arch package replaces/conflicts with `tablepro`; it retains production paths, application ID, gettext domain, keyring records, and legacy commands. Publication remains a separate decision.

Also validate the installed artifact in a clean Arch VM or container:

```bash
desktop-file-validate /usr/share/applications/com.tablepro.linux.desktop
appstreamcli validate --no-net /usr/share/metainfo/com.tablepro.linux.metainfo.xml
dbus-run-session -- bookie
bookie-agentd --help
```

Test install, upgrade, downgrade, and removal. Package operations must leave the user's XDG configuration, data, state, and keyring records untouched.

## Debian / Ubuntu package

The Cargo compile and distro-floor test tier supports the Ubuntu 24.04 stack: GTK 4.14, GLib 2.80, libadwaita 1.5 and GtkSourceView 5.12. Debian 13 (GTK 4.18, libadwaita 1.7) is above it. The root Meson project declares the GNOME 50 line: GTK 4.22, GLib 2.88, libadwaita 1.9 and GtkSourceView 5.18. The released GitHub `.deb` has the same runtime baseline, so Ubuntu 24.04 and 25.10 cannot run it; check library requirements when rebuilding packages. Neither distro packages Rust 1.98, so build with rustup. Use `apps/linux/flatpak/com.tablepro.linux.Devel.json` for an isolated development Flatpak. Flatpak/Flathub are left out of 0.2.0.

```bash
DEB_VERSION=0.1.5-1 ./scripts/build-deb.sh
sudo apt install ./apps/linux/packaging/out/tablepro_0.1.5-1_amd64.deb
```

The package name stays `tablepro`. It installs `/usr/bin/bookie`, `/usr/bin/bookie-agentd`, and `/usr/bin/tablepro-askpass`, with legacy `tablepro` / `tablepro-agentd` aliases. It does not install or enable a user service.

## Flatpak development build

The Flatpak manifest remains a non-release CI build. From the repository root:

```bash
./scripts/build-flatpak.sh
```

It still needs offline Cargo sources, portal work, and a filesystem-permission review before any Flathub submission. A successful manifest build is not release evidence for the Arch RC.
