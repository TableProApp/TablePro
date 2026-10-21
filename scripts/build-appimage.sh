#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/target/appimage"
VERSION="$(python3 "$ROOT/scripts/check-release-version.py" --print)"
TOOLS="$OUT/tools"
LINUXDEPLOY_URL=https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage
LINUXDEPLOY_SHA256=c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d
APPIMAGE_PLUGIN_URL=https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/1-alpha-20250213-1/linuxdeploy-plugin-appimage-x86_64.AppImage
APPIMAGE_PLUGIN_SHA256=992d502a248e14ab185448ddf6f6e7d25558cb84d4623c354c3af350c25fccb3
GTK_PLUGIN_URL=https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/7a3fbc31a9e5075073ff8790f26effbac5f84453/linuxdeploy-plugin-gtk.sh
GTK_PLUGIN_SHA256=b0f4cbc684a0103a9651f0955b635eaea0096b3a66c0f5a2c2aa337960375171

fetch() {
  local url="$1" sha="$2" target="$3"
  curl -fsSL --retry 3 -o "$target" "$url"
  echo "$sha  $target" | sha256sum --check --status || { echo "checksum mismatch for $url" >&2; exit 1; }
  chmod +x "$target"
}

rm -rf "$OUT"
mkdir -p "$TOOLS"
fetch "$LINUXDEPLOY_URL" "$LINUXDEPLOY_SHA256" "$TOOLS/linuxdeploy-x86_64.AppImage"
fetch "$APPIMAGE_PLUGIN_URL" "$APPIMAGE_PLUGIN_SHA256" "$TOOLS/linuxdeploy-plugin-appimage-x86_64.AppImage"
fetch "$GTK_PLUGIN_URL" "$GTK_PLUGIN_SHA256" "$TOOLS/linuxdeploy-plugin-gtk.sh"

DEB_OUT="$OUT/stage" "$ROOT/scripts/build-deb.sh"
APPDIR="$OUT/BookiE.AppDir"
cp -a "$OUT/stage/tablepro_${VERSION}-1_amd64" "$APPDIR"
rm -rf "$APPDIR/DEBIAN"

cd "$OUT"
export APPIMAGE_EXTRACT_AND_RUN=1 DEPLOY_GTK_VERSION=4 ARCH=x86_64 VERSION
export OUTPUT="BookiE-${VERSION}-x86_64.AppImage"
export PATH="$TOOLS:$PATH"
IBUS_LIBRARY="$(ldconfig -p | awk '/libibus-1.0.so.5 .*x86-64/ {print $NF; exit}')"
"$TOOLS/linuxdeploy-x86_64.AppImage" \
  --appdir "$APPDIR" \
  --desktop-file "$APPDIR/usr/share/applications/com.tablepro.linux.desktop" \
  --icon-file "$APPDIR/usr/share/icons/hicolor/scalable/apps/com.tablepro.linux.svg" \
  --executable "$APPDIR/usr/bin/bookie" \
  --executable "$APPDIR/usr/bin/bookie-agentd" \
  ${IBUS_LIBRARY:+--library "$IBUS_LIBRARY"} \
  --plugin gtk
sed -i 's|^export GDK_BACKEND=x11.*$|export GDK_BACKEND="${GDK_BACKEND:-wayland,x11}"|' "$APPDIR"/apprun-hooks/linuxdeploy-plugin-gtk.sh
grep -q 'wayland,x11' "$APPDIR"/apprun-hooks/linuxdeploy-plugin-gtk.sh
for module in "$APPDIR"/usr/lib/gtk-4.0/*/immodules/*.so; do
  patchelf --set-rpath '$ORIGIN/../../..' "$module"
done
"$TOOLS/linuxdeploy-x86_64.AppImage" --appdir "$APPDIR" --output appimage
sha256sum "$OUTPUT" > "$OUTPUT.sha256"
echo "Wrote $OUT/$OUTPUT"
