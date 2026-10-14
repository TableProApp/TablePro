# Packaging

See [platforms](../../../docs/platforms.md) for released artifacts, native requirements and package support. This guide covers package builds and validation. BookiE keeps the existing repository and application ID. Portal permissions and the public update channel still need release review.

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

For native-library and toolchain requirements, see [platforms](../../../docs/platforms.md). Use `apps/linux/flatpak/com.tablepro.linux.Devel.json` for an isolated development Flatpak. Flatpak/Flathub are left out of 0.2.0.

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
