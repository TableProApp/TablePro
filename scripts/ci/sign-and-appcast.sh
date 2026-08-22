#!/usr/bin/env bash
set -euo pipefail

# Signs release archives and generates appcast.xml using Sparkle's
# generate_appcast — the official tool for building Sparkle update feeds.
#
# Sparkle 2.9+ rejects multiple archives with the same bundle version in
# a single directory, so we run generate_appcast once per architecture
# and merge the resulting appcast entries.
#
# Usage: sign-and-appcast.sh <version>
# Requires: SPARKLE_PRIVATE_KEY env var, artifacts/ directory with ZIPs.

SEED_APPCAST="${SEED_APPCAST:-appcast.xml}"
VERSION="${1:?Usage: sign-and-appcast.sh <version>}"

if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "❌ ERROR: SPARKLE_PRIVATE_KEY environment variable is not set"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Locate Sparkle tools
# ---------------------------------------------------------------------------
# Pinned and checksum-verified rather than installed from a cask that tracks latest. This step
# holds the EdDSA private key that signs every update every user receives, so it should not run a
# binary whose contents can change between releases. The version matches the Sparkle framework
# pinned in Package.resolved, so both move together.
SPARKLE_VERSION="2.9.5"
SPARKLE_SHA256="015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc"
SPARKLE_DIR="$(mktemp -d)"
curl -sSLo "$SPARKLE_DIR/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
echo "$SPARKLE_SHA256  $SPARKLE_DIR/sparkle.tar.xz" | shasum -a 256 -c -
tar xf "$SPARKLE_DIR/sparkle.tar.xz" -C "$SPARKLE_DIR"
SPARKLE_BIN="$SPARKLE_DIR/bin"

# ---------------------------------------------------------------------------
# 2. Extract release notes from CHANGELOG.md → HTML
# ---------------------------------------------------------------------------
if [ -f release_notes.md ]; then
  NOTES=$(cat release_notes.md)
else
  NOTES=$(awk "/^## \\[${VERSION}\\]/{flag=1; next} /^## \\[/{flag=0} flag" CHANGELOG.md)
fi

if [ -z "$NOTES" ]; then
  RELEASE_HTML="<ul><li>Bug fixes and improvements</li></ul>"
else
  RELEASE_HTML=$(echo "$NOTES" | sed -E \
    -e 's/^### (.+)$/<h3>\1<\/h3>/' \
    -e 's/^- (.+)$/<li>\1<\/li>/' \
    -e '/^[[:space:]]*$/d' \
  | awk '
    /<li>/ {
      if (!in_list) { print "<ul>"; in_list=1 }
      print; next
    }
    {
      if (in_list) { print "</ul>"; in_list=0 }
      print
    }
    END { if (in_list) print "</ul>" }
  ')
fi

DOWNLOAD_PREFIX="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-TableProApp/TablePro}/releases/download/v${VERSION}/"

KEY_FILE=$(mktemp)
trap 'rm -rf "$KEY_FILE"' EXIT

echo "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"

# ---------------------------------------------------------------------------
# 3. Generate appcast per architecture
# ---------------------------------------------------------------------------
# Sparkle 2.9+ does not allow two archives with the same bundle version
# in one directory. Process each architecture separately and merge.

ARCHS=("arm64" "x86_64")
APPCAST_XMLS=()

for arch in "${ARCHS[@]}"; do
  ZIP="artifacts/TablePro-${VERSION}-${arch}.zip"
  if [ ! -f "$ZIP" ]; then
    echo "⚠️  Skipping $arch — $ZIP not found"
    continue
  fi

  STAGING=$(mktemp -d)

  cp "$ZIP" "$STAGING/"

  # Release notes file matching archive name
  basename="${STAGING}/TablePro-${VERSION}-${arch}"
  echo "$RELEASE_HTML" > "${basename}.html"

  # Seed the generator with the feed that is actually published, so every version already in it
  # survives. The default is the checkout's own appcast.xml, which is the file as of the tag
  # rather than the state of main, and generate_appcast only keeps what it is given.
  if [ "${#APPCAST_XMLS[@]}" -eq 0 ] && [ -f "$SEED_APPCAST" ]; then
    cp "$SEED_APPCAST" "$STAGING/appcast.xml"
  fi

  "$SPARKLE_BIN/generate_appcast" \
    --ed-key-file "$KEY_FILE" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --embed-release-notes \
    --maximum-versions 0 \
    "$STAGING"

  APPCAST_XMLS+=("$STAGING/appcast.xml")
done

# ---------------------------------------------------------------------------
# 4. Merge appcast files
# ---------------------------------------------------------------------------
if [ "${#APPCAST_XMLS[@]}" -eq 0 ]; then
  echo "❌ ERROR: No archives found to process"
  exit 1
fi

if [ "${#APPCAST_XMLS[@]}" -eq 1 ]; then
  # Single arch — use as-is
  FINAL_APPCAST="${APPCAST_XMLS[0]}"
else
  # Merge: take the first appcast (has history + arm64 entry), then
  # extract only the NEW item(s) from the second appcast and insert them.
  FINAL_APPCAST="${APPCAST_XMLS[0]}"
  SECOND_APPCAST="${APPCAST_XMLS[1]}"

  # Extract <item>...</item> blocks for the current version from second appcast
  ITEMS_FILE=$(mktemp)
  awk "
    /<item>/ { capture=1; buf=\"\" }
    capture { buf = buf \$0 \"\\n\" }
    /<\\/item>/ {
      capture=0
      if (buf ~ /<sparkle:shortVersionString>${VERSION}</) {
        printf \"%s\", buf
      }
    }
  " "$SECOND_APPCAST" > "$ITEMS_FILE"

  if [ -s "$ITEMS_FILE" ]; then
    # Find the line number of the first </item> in the base appcast and
    # insert the second arch's item block right after it.
    FIRST_CLOSE=$(grep -n '</item>' "$FINAL_APPCAST" | head -1 | cut -d: -f1)
    if [ -n "$FIRST_CLOSE" ]; then
      {
        head -n "$FIRST_CLOSE" "$FINAL_APPCAST"
        cat "$ITEMS_FILE"
        tail -n +"$((FIRST_CLOSE + 1))" "$FINAL_APPCAST"
      } > "${FINAL_APPCAST}.merged"
      mv "${FINAL_APPCAST}.merged" "$FINAL_APPCAST"
    fi
  fi
  rm -f "$ITEMS_FILE"
fi

# ---------------------------------------------------------------------------
# 5. Fix download URLs
# ---------------------------------------------------------------------------
# Sparkle 2.9+ may ignore --download-url-prefix for new entries.
# Ensure all archive URLs for this version point to the correct GitHub
# Release download path: .../releases/download/v<VERSION>/<filename>
sed -i '' -E "s|releases/download/(TablePro-${VERSION}-)|releases/download/v${VERSION}/\1|g" "$FINAL_APPCAST"

# ---------------------------------------------------------------------------
# 6. Copy result
# ---------------------------------------------------------------------------
mkdir -p appcast
cp "$FINAL_APPCAST" appcast/appcast.xml

echo "✅ Appcast generated by generate_appcast:"
cat appcast/appcast.xml
