#!/usr/bin/env bash
#
# Fails when a build script writes the macOS deployment target down itself.
#
# The number belongs to project.yml and reaches the scripts through
# scripts/lib/deployment-target.sh. It used to live in five places, and when #2874 moved the app to
# macOS 13 none of them followed: every archive in Libs/ was built for macOS 14 and linked into a
# 13.0 app, which the linker reported 121 times into a build that silenced linker warnings.
#
# Usage: check-deployment-target.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

offenders=$(
    grep -rnE '(MACOS|DEPLOY|MIN)[A-Z_]*(TARGET|MACOS)[A-Z_]*="[0-9]+(\.[0-9]+)?"' scripts/*.sh scripts/lib/*.sh 2> /dev/null |
        grep -viE 'ios|iphone|watch|tv|visionos' || true
)

if [ -n "$offenders" ]; then
    echo "A macOS deployment target is written down in a build script." >&2
    echo "Source scripts/lib/deployment-target.sh and use \$DEPLOY_TARGET instead:" >&2
    echo "$offenders" >&2
    exit 1
fi

echo "No build script hardcodes the macOS deployment target."
