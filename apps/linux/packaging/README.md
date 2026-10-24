# Packaging

See [platforms](../../../docs/platforms.md) for released artifacts, native requirements and package support. This guide covers package builds and validation. BookiE keeps the existing repository and application ID.

## Arch package candidate

The recipe in [`arch/PKGBUILD`](arch/PKGBUILD) accepts only an immutable commit archive and a real SHA-256 checksum. It installs `bookie`, `bookie-agentd`, `tablepro-askpass`, compatibility aliases `tablepro` and `tablepro-agentd`, desktop/AppStream/icon metadata, the license, the example policy, and any compiled translation catalogs. It deliberately does not ship a systemd unit: stdio agentd is launched on demand by its MCP client.

After committing and validating the candidate (no published tag required), from the repository root:

```bash
TABLEPRO_RC_COMMIT="$(git rev-parse HEAD)" \
TABLEPRO_RC_VERSION="$(python3 scripts/check-release-version.py --print)" \
TABLEPRO_RC_DATE="$(date -u +%F)" bash scripts/build-arch-rc.sh
```

The example builds the workspace release version from the committed tree. The helper refuses a dirty tree or a candidate SHA other than `HEAD`. It archives that exact local commit, computes the checksum, builds with `makepkg`, and runs `namcap` and package-content validation. Set `TABLEPRO_RC_TAG=linux-v…` instead of `TABLEPRO_RC_COMMIT` to verify an already published tag against the remote. The Arch package replaces/conflicts with `tablepro`; it retains production paths, application ID, gettext domain, keyring records, and legacy commands. Publication remains a separate decision.

The standalone build, upgrade and removal wrapper runs in an isolated Arch container:

```bash
bash scripts/test-arch-package-container.sh
```

Its version defaults to the workspace version and must match it. The candidate date uses `ARCH_CANDIDATE_DATE`, then an inherited `TABLEPRO_RC_DATE`, then the current UTC date. Pin `ARCH_CANDIDATE_DATE` when repeating a dated candidate. Invalid versions and calendar dates are refused before Docker starts. `ARCH_RELEASED_URL` selects the published upgrade fixture.

Package-content checks can run in a clean Arch VM or container; they do not qualify PKG-1. Install, upgrade, rollback and removal acceptance requires the target Arch or Omarchy system running Hyprland on native Wayland. Run the UI smoke in that graphical session:

```bash
desktop-file-validate /usr/share/applications/com.tablepro.linux.desktop
appstreamcli validate --no-net /usr/share/metainfo/com.tablepro.linux.metainfo.xml
dbus-run-session -- bookie
bookie-agentd --help
```

Test install, upgrade, downgrade, and removal. Package operations must leave the user's XDG configuration, data, state, and keyring records untouched.

## Debian / Ubuntu package

For native-library and toolchain requirements, see [platforms](../../../docs/platforms.md).

The Debian builder and validator use the workspace release version with Debian revision `-1` by default. `DEB_VERSION` can select another packaging revision. The commands below build and install a local package from the current workspace; they do not establish Debian desktop acceptance, which remains tracked under [PKG-2](../../../docs/bookie-0.2-sprint.md#delivery-boundary).

```bash
DEB_VERSION=0.2.0-1 ./scripts/build-deb.sh
sudo apt install ./apps/linux/packaging/out/bookie_0.2.0-1_amd64.deb
```

The package name is `bookie`. It installs `/usr/bin/bookie`, `/usr/bin/bookie-agentd`, and `/usr/bin/tablepro-askpass`, with legacy `tablepro` / `tablepro-agentd` aliases. It does not install or enable a user service.

## Flatpak builds

The local helper builds `apps/linux/flatpak/com.tablepro.linux.json` with GNOME 51 and writes `/tmp/bookie.flatpak`. For an isolated development install, build `apps/linux/flatpak/com.tablepro.linux.Devel.json` directly. Published Flatpak and Flathub status is in [platforms](../../../docs/platforms.md#published-020-release). From the repository root:

```bash
./scripts/build-flatpak.sh
```

The isolated development build is:

```bash
flatpak-builder --user --install build-dir apps/linux/flatpak/com.tablepro.linux.Devel.json
```

Flathub submission still needs offline Cargo sources; portal permissions and public update-channel behavior remain under PKG-8 review. A local manifest build does not establish release or Flathub acceptance.

## Release versions

`[workspace.package].version` in the root `Cargo.toml` is the BookiE release version. Every workspace crate inherits it. For a release or hotfix, update that value, the Meson version and the newest AppStream entry together, then regenerate `Cargo.lock`. Keep older AppStream entries and published upgrade fixtures intact. The published 0.2.0 entry remains `type="development"` and records its preparation date, 2026-10-21; this type does not mean the release is unpublished.

Run `python3 scripts/check-release-version.py` to check consistency; the script harness also runs it. `--print` returns the source version for packaging. Translation generation resolves the inherited version, and MCP advertises its compiled crate version. These version declarations do not change compatibility identifiers, create a tag or publish artifacts.
