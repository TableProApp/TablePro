#!/usr/bin/env bash
# Build a local .deb from linux/ using dpkg-buildpackage (or a fallback
# that stages files when debhelper is unavailable).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${DEB_OUT:-$ROOT/packaging/out}"
mkdir -p "$OUT"

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
cd "$ROOT"

if [[ -f "$ROOT/scripts/dev-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/dev-env.sh"
fi

echo "==> cargo build --release -p tablepro-app"
cargo build --release -p tablepro-app --locked

STAGE="$OUT/tablepro_0.1.0-1_amd64"
rm -rf "$STAGE"
install -Dm755 "$CARGO_TARGET_DIR/release/tablepro-app" "$STAGE/usr/bin/tablepro-app"
install -Dm644 flatpak/com.tablepro.linux.desktop "$STAGE/usr/share/applications/com.tablepro.linux.desktop"
install -Dm644 flatpak/com.tablepro.linux.metainfo.xml "$STAGE/usr/share/metainfo/com.tablepro.linux.metainfo.xml"
install -Dm644 flatpak/icons/scalable/com.tablepro.linux.svg \
  "$STAGE/usr/share/icons/hicolor/scalable/apps/com.tablepro.linux.svg"

mkdir -p "$STAGE/DEBIAN"
cat >"$STAGE/DEBIAN/control" <<EOF
Package: tablepro
Version: 0.1.0-1
Section: database
Priority: optional
Architecture: amd64
Maintainer: TablePro Contributors <noreply@tablepro.app>
Depends: libgtk-4-1, libadwaita-1-0, libgtksourceview-5-0, libsecret-1-0
Description: Native Linux database client
 TablePro is a fast, native GTK4 / libadwaita database client.
EOF

dpkg-deb --root-owner-group --build "$STAGE" "$OUT/tablepro_0.1.0-1_amd64.deb"
echo "Wrote $OUT/tablepro_0.1.0-1_amd64.deb"
dpkg-deb -I "$OUT/tablepro_0.1.0-1_amd64.deb"
