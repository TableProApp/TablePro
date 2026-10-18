#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/Native/HanaBridge"
BIN_DIR="$BRIDGE_DIR/bin"
HELPER_NAME="tablepro-hana-helper"
OUTPUT="$BIN_DIR/$HELPER_NAME"
ARCH="${1:-both}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/deployment-target.sh"

if ! command -v go > /dev/null; then
    echo "Go is required to build $HELPER_NAME. Install it from https://go.dev/dl/" >&2
    exit 1
fi

# Named exactly: the default GOTOOLCHAIN=auto treats this line as a minimum and keeps a newer local go.
GO_TOOLCHAIN="$(awk '$1 == "toolchain" { print $2 }' "$BRIDGE_DIR/go.mod")"
if [ -z "$GO_TOOLCHAIN" ]; then
    echo "$BRIDGE_DIR/go.mod has no toolchain line" >&2
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

mkdir -p "$BIN_DIR"

case "$ARCH" in
    arm64|x86_64)
        build_slice "$ARCH"
        cp "$BIN_DIR/$HELPER_NAME-$ARCH" "$OUTPUT"
        ;;
    both)
        build_slice arm64
        build_slice x86_64
        lipo -create "$BIN_DIR/$HELPER_NAME-arm64" "$BIN_DIR/$HELPER_NAME-x86_64" -output "$OUTPUT"
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]" >&2
        exit 1
        ;;
esac

codesign --force -o runtime -s - "$OUTPUT"
lipo -info "$OUTPUT"
verify_deployment_target "$OUTPUT"
