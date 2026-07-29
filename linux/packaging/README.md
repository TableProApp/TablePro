# Packaging

Community packaging for TablePro Linux. Flathub remains the primary distribution channel; `.deb` and AUR are secondary.

## Flatpak

Manifest: [`../flatpak/com.tablepro.linux.json`](../flatpak/com.tablepro.linux.json)

```bash
./scripts/build-flatpak.sh
```

CI: [`.github/workflows/flatpak-linux.yml`](../../.github/workflows/flatpak-linux.yml) builds the manifest on every Linux-path PR. The app module uses `--share=network` so Cargo can fetch crates during CI. Flathub forbids that, so generate offline sources before a Flathub submission:

```bash
git clone https://github.com/flatpak/flatpak-builder-tools
./scripts/generate-cargo-sources.sh ./flatpak-builder-tools
```

Then wire `flatpak/generated-sources.json` into the module sources and set `CARGO_NET_OFFLINE=true` (see the script's output).
## Debian / Ubuntu (`.deb`)

Debian source packaging lives in [`debian/`](debian/). For a quick local binary package without a full source upload:

```bash
./scripts/build-deb.sh
# → packaging/out/tablepro_0.1.0-1_amd64.deb
sudo apt install ./packaging/out/tablepro_0.1.0-1_amd64.deb
```

Build-Depends (source package): `cargo`, `rustc (>= 1.93)`, `libgtk-4-dev`, `libadwaita-1-dev`, `libgtksourceview-5-dev`, `libssl-dev`, `libsecret-1-dev`, `gettext`.

## Arch (AUR)

[`aur/PKGBUILD`](aur/PKGBUILD) builds from the upstream `linux` branch.

```bash
cd packaging/aur
makepkg -si
```

Pin a release tag / commit and fill `sha256sums` before submitting to the AUR.
