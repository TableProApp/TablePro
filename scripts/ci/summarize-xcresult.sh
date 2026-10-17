#!/usr/bin/env bash
set -euo pipefail

# Usage: summarize-xcresult.sh <bundle.xcresult | swift-test-xunit.xml>...

exec python3 "$(dirname "$0")/../lib/xcresult-cases.py" summary "$@"
