# Packaging

See [platforms](../../../docs/platforms.md) for released artifacts, native requirements and package support. This guide covers package builds and validation. BookiE keeps the existing repository and application ID. Portal permissions and the public update channel still need release review.

## Arch package candidate

The recipe in [`arch/PKGBUILD`](arch/PKGBUILD) accepts only an immutable commit archive and a real SHA-256 checksum. It installs `bookie`, `bookie-agentd`, `tablepro-askpass`, compatibility aliases `tablepro` and `tablepro-agentd`, desktop/AppStream/icon metadata, the license, the example policy, and any compiled translation catalogs. It deliberately does not ship a systemd unit: stdio agentd is launched on demand by its MCP client.

After committing and validating the candidate (no published tag required), from the repository root:

```bash
TABLEPRO_RC_COMMIT="$(git rev-parse HEAD)" TABLEPRO_RC_VERSION=0.2.0 ./scripts/build-arch-rc.sh
```

The example builds the current 0.2.0 candidate from the committed tree; it does not rebuild the released 0.1.5 package. The helper refuses a dirty tree or a candidate SHA other than `HEAD`. It archives that exact local commit, computes the checksum, builds with `makepkg`, and runs `namcap` and package-content validation. Set `TABLEPRO_RC_TAG=linux-v…` instead of `TABLEPRO_RC_COMMIT` to verify an already published tag against the remote. The Arch package replaces/conflicts with `tablepro`; it retains production paths, application ID, gettext domain, keyring records, and legacy commands. Publication remains a separate decision.

Package-content checks can run in a clean Arch VM or container; they do not qualify PKG-1. Install, upgrade, rollback and removal acceptance requires the target Arch or Omarchy system running Hyprland on native Wayland. Run the UI smoke in that graphical session:

```bash
desktop-file-validate /usr/share/applications/com.tablepro.linux.desktop
appstreamcli validate --no-net /usr/share/metainfo/com.tablepro.linux.metainfo.xml
dbus-run-session -- bookie
bookie-agentd --help
```

Test install, upgrade, downgrade, and removal. Package operations must leave the user's XDG configuration, data, state, and keyring records untouched.

## Debian / Ubuntu package

For native-library and toolchain requirements, see [platforms](../../../docs/platforms.md). Use `apps/linux/flatpak/com.tablepro.linux.Devel.json` for an isolated development Flatpak. Flatpak/Flathub are left out of 0.2.0.

The Debian builder and validator use the workspace release version with Debian revision `-1` by default. `DEB_VERSION` can select another packaging revision. The commands below build and install a 0.2.0 candidate; they do not establish Debian desktop acceptance, which remains later work under [PKG-2](../../../docs/0.2.0-scope.md#delivery-boundary).

```bash
DEB_VERSION=0.2.0-1 ./scripts/build-deb.sh
sudo apt install ./apps/linux/packaging/out/tablepro_0.2.0-1_amd64.deb
```

The package name stays `tablepro`. It installs `/usr/bin/bookie`, `/usr/bin/bookie-agentd`, and `/usr/bin/tablepro-askpass`, with legacy `tablepro` / `tablepro-agentd` aliases. It does not install or enable a user service.

## Flatpak development build

The Flatpak manifest remains a non-release CI build. From the repository root:

```bash
./scripts/build-flatpak.sh
```

It still needs offline Cargo sources, portal work, and a filesystem-permission review before any Flathub submission. A successful manifest build is not release evidence for the Arch RC.

## Release versions

`[workspace.package].version` in the root `Cargo.toml` is the BookiE release version. Every workspace crate inherits it. For a release or hotfix, update that value, the Meson version and the newest AppStream entry together, then regenerate `Cargo.lock`. Keep older AppStream entries and published upgrade fixtures intact. The unpublished 0.2.0 entry has `type="development"` and records the preparation date required by AppStream. Set the publication date when publishing the release.

Run `python3 scripts/check-release-version.py` to check consistency; the script harness also runs it. `--print` returns the source version for packaging. Translation generation resolves the inherited version, and MCP advertises its compiled crate version. These version declarations do not change compatibility identifiers, create a tag or publish artifacts.
