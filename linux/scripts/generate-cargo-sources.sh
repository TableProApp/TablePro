#!/usr/bin/env bash
# Generate flatpak/generated-sources.json from Cargo.lock for offline /
# Flathub builds. Requires flatpak-builder-tools (cargo sources script).
#
#   git clone https://github.com/flatpak/flatpak-builder-tools
#   ./scripts/generate-cargo-sources.sh /path/to/flatpak-builder-tools
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${1:-}"

if [[ -z "$TOOLS" || ! -f "$TOOLS/cargo/flatpak-cargo-generator.py" ]]; then
  echo "usage: $0 /path/to/flatpak-builder-tools" >&2
  echo "Clone https://github.com/flatpak/flatpak-builder-tools and pass its root." >&2
  exit 1
fi

python3 "$TOOLS/cargo/flatpak-cargo-generator.py" \
  "$ROOT/Cargo.lock" \
  -o "$ROOT/flatpak/generated-sources.json"

echo "Wrote $ROOT/flatpak/generated-sources.json"
echo "For Flathub, set CARGO_NET_OFFLINE=true and add \"generated-sources.json\" to the tablepro-app module sources."
