#!/usr/bin/env bash
# Every database call the GUI makes must carry an OperationControl, so a
# slow statement is bounded and a Stop can reach the driver. A bare
# `conn.query(...)` in the app has no deadline and no cancellation: it
# runs until the server answers, however long that takes.
#
# The controlled forms end in `_controlled`. Anything else on a
# connection handle in `crates/app/src` is a regression.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

exec python3 scripts/check-bounded-operations.py
