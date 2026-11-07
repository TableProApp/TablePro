#!/bin/sh
# Cargo's target runner for the Meson test suites, which all select the
# same packages so that they share one build: each suite runs only its own
# package's tests, or only the others'. Cargo sets CARGO_PKG_NAME for every
# test it runs.
# Usage: cargo-test-runner.sh only|skip <package> <test> <argument>...
set -eu

usage() {
    echo "usage: cargo-test-runner.sh only|skip <package> <test> <argument>..." >&2
    exit 2
}

[ "$#" -ge 3 ] || usage
mode=$1
package=$2
shift 2
: "${CARGO_PKG_NAME:?cargo-test-runner.sh: CARGO_PKG_NAME is not set}"

case "$mode" in
    only) [ "$CARGO_PKG_NAME" = "$package" ] || exit 0 ;;
    skip) [ "$CARGO_PKG_NAME" != "$package" ] || exit 0 ;;
    *) usage ;;
esac
exec "$@"
