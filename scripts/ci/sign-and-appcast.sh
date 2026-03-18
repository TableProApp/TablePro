#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: sign-and-appcast.sh <version>}"

if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "❌ ERROR: SPARKLE_PRIVATE_KEY environment variable is not set"
  exit 1
fi

# Install Sparkle tools (Cask — binaries in Caskroom, not on PATH)
brew list --cask sparkle &>/dev/null || brew install --cask sparkle
SPARKLE_BIN="$(brew --caskroom)/sparkle/$(ls "$(brew --caskroom)/sparkle" | head -1)/bin"

ARM64_ZIP="artifacts/TablePro-${VERSION}-arm64.zip"
X86_64_ZIP="artifacts/TablePro-${VERSION}-x86_64.zip"

# Sign each ZIP with EdDSA using sign_update
KEY_FILE=$(mktemp)
trap 'rm -f "$KEY_FILE"' EXIT
echo "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
ARM64_SIG=$("$SPARKLE_BIN/sign_update" "$ARM64_ZIP" -f "$KEY_FILE")
X86_64_SIG=$("$SPARKLE_BIN/sign_update" "$X86_64_ZIP" -f "$KEY_FILE")

# Parse signature and length from sign_update output
# Output format: sparkle:edSignature="..." length="..."
ARM64_ED_SIG=$(echo "$ARM64_SIG" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
ARM64_LENGTH=$(echo "$ARM64_SIG" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
X86_64_ED_SIG=$(echo "$X86_64_SIG" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
X86_64_LENGTH=$(echo "$X86_64_SIG" | sed -n 's/.*length="\([^"]*\)".*/\1/p')

# Extract version info from the top-level app's Info.plist inside the ZIP
# Use -maxdepth 3 to avoid nested framework plists (e.g. Sparkle.framework)
TEMP_DIR=$(mktemp -d)
unzip -q "$ARM64_ZIP" -d "$TEMP_DIR"
INFO_PLIST=$(find "$TEMP_DIR" -maxdepth 3 -path "*/Contents/Info.plist" | head -1)

if [ -n "$INFO_PLIST" ] && [ -f "$INFO_PLIST" ]; then
  BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || echo "1")
  SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "$VERSION")
  MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$INFO_PLIST" 2>/dev/null || echo "14.0")
else
  echo "⚠️  Could not find app Info.plist in ZIP, using defaults from tag"
  BUILD_NUMBER="1"
  SHORT_VERSION="$VERSION"
  MIN_OS="14.0"
fi
rm -rf "$TEMP_DIR"

# Extract release notes for appcast
if [ -f release_notes.md ]; then
    NOTES=$(cat release_notes.md)
else
    NOTES=$(awk "/^## \\[${VERSION}\\]/{flag=1; next} /^## \\[/{flag=0} flag" CHANGELOG.md)
fi

if [ -z "$NOTES" ]; then
  RELEASE_HTML="<li>Bug fixes and improvements</li>"
else
  # Convert markdown to simple HTML:
  #   ### Header -> <h3>Header</h3>
  #   - item    -> <li>item</li>
  #   Wrap consecutive <li> runs in <ul>...</ul>
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

# Wrap in a styled HTML body
DESCRIPTION_HTML="<body style=\"font-family: -apple-system, sans-serif; font-size: 13px; padding: 8px;\">${RELEASE_HTML}</body>"

# Build appcast.xml with architecture-specific items (Sparkle 2 convention)
DOWNLOAD_PREFIX="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-datlechin/TablePro}/releases/download/v${VERSION}"
PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')

mkdir -p appcast
cat > appcast/appcast.xml << APPCAST_EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>TablePro</title>
        <item>
            <title>${SHORT_VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
            <description><![CDATA[${DESCRIPTION_HTML}]]></description>
            <enclosure url="${DOWNLOAD_PREFIX}/TablePro-${VERSION}-arm64.zip" length="${ARM64_LENGTH}" type="application/octet-stream" sparkle:edSignature="${ARM64_ED_SIG}" sparkle:architectures="arm64"/>
        </item>
        <item>
            <title>${SHORT_VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
            <description><![CDATA[${DESCRIPTION_HTML}]]></description>
            <enclosure url="${DOWNLOAD_PREFIX}/TablePro-${VERSION}-x86_64.zip" length="${X86_64_LENGTH}" type="application/octet-stream" sparkle:edSignature="${X86_64_ED_SIG}" sparkle:architectures="x86_64"/>
        </item>
    </channel>
</rss>
APPCAST_EOF

echo "✅ Appcast generated with architecture-specific items:"
cat appcast/appcast.xml
