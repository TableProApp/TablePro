#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/Native/HanaBridge"
BIN_DIR="$BRIDGE_DIR/bin"
HELPER_NAME="tablepro-hana-helper"
OUTPUT="$BIN_DIR/$HELPER_NAME"
GO_TOOLCHAIN="go1.27.1"
ARCH="${1:-both}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/deployment-target.sh"

if ! command -v go > /dev/null; then
    echo "Go is required to build $HELPER_NAME. Install it from https://go.dev/dl/" >&2
    exit 1
fi

go_arch() {
    case "$1" in
        arm64) echo arm64 ;;
        x86_64) echo amd64 ;;
    esac
}

build_slice() {
    local arch="$1"
    local output="$BIN_DIR/$HELPER_NAME-$arch"
    (
        cd "$BRIDGE_DIR"
        env GOTOOLCHAIN="$GO_TOOLCHAIN" GOWORK=off GOFLAGS= CGO_ENABLED=0 GOOS=darwin GOARCH="$(go_arch "$arch")" \
            go build -trimpath -buildvcs=false -ldflags='-s -w' -o "$output" .
    )
}

version_at_most() {
    awk -v actual="$1" -v limit="$2" 'BEGIN {
        split(actual, a, ".")
        split(limit, l, ".")
        for (i = 1; i <= 3; i++) {
            if ((a[i] + 0) < (l[i] + 0)) exit 0
            if ((a[i] + 0) > (l[i] + 0)) exit 1
        }
        exit 0
    }'
}

slice_minimum_os() {
    vtool -arch "$2" -show-build "$1" | awk '$1 == "minos" { print $2; exit }'
}

verify_minimum_os() {
    local binary="$1"
    local arch
    local version
    for arch in $(lipo -archs "$binary"); do
        version="$(slice_minimum_os "$binary" "$arch")"
        if [ -z "$version" ]; then
            echo "$binary ($arch) records no minimum macOS" >&2
            exit 1
        fi
        if ! version_at_most "$version" "$DEPLOY_TARGET"; then
            echo "$binary ($arch) targets macOS $version, above the deployment target $DEPLOY_TARGET" >&2
            exit 1
        fi
        echo "$arch: minimum macOS $version, deployment target $DEPLOY_TARGET"
    done
}

mkdir -p "$BIN_DIR"

case "$ARCH" in
    arm64|x86_64)
        build_slice "$ARCH"
        cp "$BIN_DIR/$HELPER_NAME-$ARCH" "$OUTPUT"
        ;;
    both|universal)
        build_slice arm64
        build_slice x86_64
        lipo -create "$BIN_DIR/$HELPER_NAME-arm64" "$BIN_DIR/$HELPER_NAME-x86_64" -output "$OUTPUT"
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]" >&2
        exit 1
        ;;
esac

codesign --force -s - "$OUTPUT"
file "$OUTPUT"
verify_minimum_os "$OUTPUT"
