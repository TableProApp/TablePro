#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: extract-release-notes.sh <version>}"

python3 "$(dirname "$0")/extract-release-notes.py" "$VERSION"
