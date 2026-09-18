#!/usr/bin/env bash
set -euo pipefail

# Thin wrapper so callers do not repeat the python3 invocation. Every argument after the version
# is passed straight through, which is how sign-and-appcast.sh asks for --highlights-only.

VERSION="${1:?Usage: extract-release-notes.sh <version> [--highlights-only] [--out PATH]}"
shift

python3 "$(dirname "$0")/extract-release-notes.py" "$VERSION" "$@"
