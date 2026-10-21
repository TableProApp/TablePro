# Release process

A release is a git tag named `linux-vX.Y.Z` on the `linux` branch. Pushing the tag runs `.github/workflows/release.yml`, which builds every package on GitHub and drafts the release. Nothing is published until a maintainer reviews the draft and presses Publish.

## What a release contains

| File | Built by | Install |
|---|---|---|
| `tablepro_X.Y.Z-1_amd64.deb` | `scripts/build-deb.sh` on Debian testing | `sudo apt install ./tablepro_X.Y.Z-1_amd64.deb` |
| `bookie-X.Y.Z-1-x86_64.pkg.tar.zst` | `scripts/build-arch-rc.sh` in an Arch container | `sudo pacman -U bookie-X.Y.Z-1-x86_64.pkg.tar.zst` |
| `bookie.flatpak` | `flatpak-builder` from `apps/linux/flatpak` | `flatpak install --user bookie.flatpak` |
| `BookiE-X.Y.Z-x86_64.AppImage` | `scripts/build-appimage.sh` (linuxdeploy with the GTK plugin) | `chmod +x` and run |
| `bookie.pot` | `scripts/update-translations.py` | gettext template for translators; not committed to the repository |
| `SHA256SUMS` | the publish job | `sha256sum --check SHA256SUMS` |

Every file also has build provenance recorded by GitHub (`gh attestation verify <file> --repo cozyGarage/BookiE`). Releases below 1.0 are marked pre-release. The AppImage is built on Debian testing, so it needs a distribution with a comparable glibc.

## Cutting a release

1. On a branch from `linux`, move the `[Unreleased]` entries under the new version: `python3 scripts/release-notes.py cut X.Y.Z YYYY-MM-DD`. Check that the workspace version in `Cargo.toml`, `meson.build` and the newest `<release>` in `apps/linux/flatpak/com.tablepro.linux.metainfo.xml` all say X.Y.Z (`python3 scripts/check-release-version.py`). Merge the pull request through the normal Forgejo gate.
2. Tag the merged commit and push the tag from a checkout of `linux`:
   `git tag -a linux-vX.Y.Z -m "BookiE X.Y.Z" && git push origin linux-vX.Y.Z`.
3. Wait for the Release workflow. It refuses a tag that differs from the source version or a version with no changelog section. The release notes are the version's `CHANGELOG.md` section.
4. Open the draft release on GitHub, install at least one package, then press Publish.

A change to the workflow or the AppImage script builds all packages on the pull request without publishing, so packaging breakage shows up before a tag.

## Fixing a bad release

Delete the draft (or unpublish), fix on `linux`, and cut the next patch version. Do not move a tag that anyone may have downloaded.
