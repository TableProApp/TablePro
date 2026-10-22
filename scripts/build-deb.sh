#!/usr/bin/env bash
# Build a local .deb from the repository root using dpkg-buildpackage (or a fallback
# that stages files when debhelper is unavailable).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${DEB_OUT:-$ROOT/apps/linux/packaging/out}"
VERSION="${DEB_VERSION:-$(python3 "$ROOT/scripts/check-release-version.py" --print)-1}"
ARCH="${DEB_ARCH:-amd64}"
PKG_NAME="bookie_${VERSION}_${ARCH}"
PROFILE="${BOOKIE_BUILD_PROFILE:-dist}"
case "$PROFILE" in
  dist | release) ;;
  *)
    echo "BOOKIE_BUILD_PROFILE must be dist or release, got: $PROFILE" >&2
    exit 2
    ;;
esac
mkdir -p "$OUT"

# Force on-disk target dir: agent environments may point CARGO_TARGET_DIR
# at a small tmpfs that cannot hold a release build.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
cd "$ROOT"

if [[ -f "$ROOT/scripts/dev-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/dev-env.sh"
fi

if [[ "${DEB_SKIP_BUILD:-0}" != "1" ]]; then
  echo "==> cargo build --profile $PROFILE -p tablepro-app -p tablepro-agentd"
  cargo build --profile "$PROFILE" -p tablepro-app -p tablepro-agentd --locked
  cargo build --profile "$PROFILE" -p tablepro-ssh --bin tablepro-askpass --locked
else
  echo "==> DEB_SKIP_BUILD=1; packaging existing $PROFILE binaries"
fi

for bin in tablepro-app tablepro-agentd tablepro-askpass; do
  if [[ ! -x "$CARGO_TARGET_DIR/$PROFILE/$bin" ]]; then
    echo "missing $CARGO_TARGET_DIR/$PROFILE/$bin; run without DEB_SKIP_BUILD" >&2
    exit 1
  fi
done

STAGE="$OUT/$PKG_NAME"
rm -rf "$STAGE"
install -Dsm755 "$CARGO_TARGET_DIR/$PROFILE/tablepro-app" "$STAGE/usr/bin/bookie"
install -Dsm755 "$CARGO_TARGET_DIR/$PROFILE/tablepro-agentd" "$STAGE/usr/bin/bookie-agentd"
install -Dsm755 "$CARGO_TARGET_DIR/$PROFILE/tablepro-askpass" "$STAGE/usr/bin/tablepro-askpass"
ln -s bookie "$STAGE/usr/bin/tablepro"
ln -s bookie-agentd "$STAGE/usr/bin/tablepro-agentd"
install -Dm644 apps/linux/flatpak/com.tablepro.linux.desktop "$STAGE/usr/share/applications/com.tablepro.linux.desktop"
install -Dm644 apps/linux/flatpak/com.tablepro.linux.metainfo.xml "$STAGE/usr/share/metainfo/com.tablepro.linux.metainfo.xml"
install -Dm644 apps/linux/data/com.tablepro.linux.gschema.xml "$STAGE/usr/share/glib-2.0/schemas/com.tablepro.linux.gschema.xml"
install -Dm644 apps/linux/flatpak/icons/scalable/com.tablepro.linux.svg \
  "$STAGE/usr/share/icons/hicolor/scalable/apps/com.tablepro.linux.svg"
install -Dm644 apps/linux/packaging/policy.example.toml "$STAGE/usr/share/doc/bookie/policy.example.toml"
install -Dm644 LICENSE.md "$STAGE/usr/share/doc/bookie/LICENSE.md"

mkdir -p "$STAGE/DEBIAN"
cat >"$STAGE/DEBIAN/control" <<EOF
Package: bookie
Version: ${VERSION}
Section: database
Priority: optional
Architecture: ${ARCH}
Maintainer: BookiE Contributors <noreply@tablepro.app>
Homepage: https://github.com/cozyGarage/BookiE
Depends: libgtk-4-1, libadwaita-1-0, libgtksourceview-5-0, libsecret-1-0, libgssapi-krb5-2, libkrb5-3, libsqlite3-0
Replaces: tablepro
Conflicts: tablepro
Provides: tablepro
Description: Native Linux database client
 BookiE is a native GTK4 / libadwaita database client. It installs
 bookie and bookie-agentd, with tablepro aliases.
EOF

dpkg-deb --root-owner-group --build "$STAGE" "$OUT/${PKG_NAME}.deb"
echo "Wrote $OUT/${PKG_NAME}.deb"
dpkg-deb -I "$OUT/${PKG_NAME}.deb"
"$ROOT/scripts/validate-deb-package.sh" "$OUT/${PKG_NAME}.deb"
