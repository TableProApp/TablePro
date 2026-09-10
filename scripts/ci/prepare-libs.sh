#!/usr/bin/env bash
set -euo pipefail

# Selects the per-architecture slice of every vendored static library, so an Xcode build links the
# right one. Called by the release workflow before scripts/build-release.sh.
#
# The selection lives in scripts/lib/macos.sh and is shared with build-release.sh, which used to
# carry four near-identical copies of it. This script did a bare `cp` of the per-architecture file
# with no fallback, so the two took different sources for the same library.

# shellcheck source=../lib/macos.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/macos.sh"

ARCH="${1:-}"
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
    echo "Usage: $0 <arm64|x86_64>" >&2
    exit 1
fi

echo "📦 Preparing static libraries for $ARCH..."
prepare_arch_libs "$ARCH" \
    libmariadb \
    libpq libpgcommon libpgport libssl libcrypto \
    libmongoc libbson \
    libhiredis libhiredis_ssl
echo "✅ Static libraries ready for $ARCH"
