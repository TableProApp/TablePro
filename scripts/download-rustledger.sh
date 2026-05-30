#!/usr/bin/env bash
set -euo pipefail

# Bundle the rustledger CLI helper used by the Beancount driver for BQL queries.
# Usage: scripts/download-rustledger.sh [output-rledger-path]

VERSION="v0.15.0"
REPO="rustledger/rustledger"
PROJECT_ROOT="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CACHE_ROOT="${TABLEPRO_RUSTLEDGER_CACHE:-$PROJECT_ROOT/Libs/rustledger}"
OUTPUT="${1:-${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/rledger}"

triple_for_arch() {
  case "$1" in
    arm64|aarch64) echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
    *) return 1 ;;
  esac
}

sha_for_triple() {
  case "$1" in
    aarch64-apple-darwin) echo "b8f1190898b1e7ed1585ce3833a9a1814b30b5703e75eed7c276dafac00bc00a" ;;
    x86_64-apple-darwin) echo "b264a51d792d00d138725d8d7eaa6e5354e7ad54e8e93e9efde535d830e217ff" ;;
    *) return 1 ;;
  esac
}

host_triple() {
  triple_for_arch "$(uname -m)"
}

copy_helper() {
  local source_path="$1"
  local message="$2"

  if [[ ! -x "$source_path" ]]; then
    return 1
  fi

  mkdir -p "$(dirname "$OUTPUT")"
  cp -f "$source_path" "$OUTPUT"
  chmod 755 "$OUTPUT"
  echo "$message: $OUTPUT"
  return 0
}

download_release() {
  local triple="$1"
  local archive="rustledger-${VERSION}-${triple}.tar.gz"
  local sha256 tmpdir archive_path actual_sha extracted_helper

  sha256="$(sha_for_triple "$triple")"
  tmpdir="$(mktemp -d)"
  trap "rm -rf '$tmpdir'" RETURN
  archive_path="$tmpdir/$archive"

  if command -v gh >/dev/null 2>&1; then
    gh release download "$VERSION" \
      --repo "$REPO" \
      --pattern "$archive" \
      --dir "$tmpdir" \
      --clobber
  else
    curl -fSL -o "$archive_path" "https://github.com/$REPO/releases/download/$VERSION/$archive"
  fi

  actual_sha="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  if [[ "$actual_sha" != "$sha256" ]]; then
    echo "Checksum mismatch for $archive" >&2
    echo "Expected: $sha256" >&2
    echo "Actual:   $actual_sha" >&2
    return 1
  fi

  mkdir -p "$tmpdir/extract" "$CACHE_ROOT/$VERSION/$triple"
  tar -xzf "$archive_path" -C "$tmpdir/extract"
  extracted_helper="$(find "$tmpdir/extract" -type f -name rledger | head -n 1)"
  if [[ -z "$extracted_helper" ]]; then
    echo "Could not find rledger in $archive" >&2
    return 1
  fi

  cp -f "$extracted_helper" "$CACHE_ROOT/$VERSION/$triple/rledger"
  chmod 755 "$CACHE_ROOT/$VERSION/$triple/rledger"
}

ensure_cached_helper() {
  local triple="$1"
  local helper="$CACHE_ROOT/$VERSION/$triple/rledger"

  if [[ -x "$helper" ]]; then
    echo "$helper"
    return 0
  fi

  download_release "$triple" >&2
  echo "$helper"
}

requested_triples=()
if [[ -n "${ARCHS:-}" ]]; then
  for arch in $ARCHS; do
    triple="$(triple_for_arch "$arch" 2>/dev/null || true)"
    if [[ -n "${triple:-}" && " ${requested_triples[*]} " != *" $triple "* ]]; then
      requested_triples+=("$triple")
    fi
  done
fi
if [[ "${#requested_triples[@]}" -eq 0 ]]; then
  requested_triples+=("$(host_triple)")
fi

if [[ -n "${TABLEPRO_RUSTLEDGER_BINARY:-}" ]]; then
  copy_helper "$TABLEPRO_RUSTLEDGER_BINARY" "Bundled rustledger helper from TABLEPRO_RUSTLEDGER_BINARY"
  exit 0
fi

helpers=()
for triple in "${requested_triples[@]}"; do
  if helper="$(ensure_cached_helper "$triple")"; then
    helpers+=("$helper")
  fi
done

if [[ "${#helpers[@]}" -eq 1 ]]; then
  copy_helper "${helpers[0]}" "Bundled rustledger helper"
  exit 0
fi

if [[ "${#helpers[@]}" -gt 1 && -x "$(command -v lipo)" ]]; then
  mkdir -p "$(dirname "$OUTPUT")"
  lipo -create "${helpers[@]}" -output "$OUTPUT"
  chmod 755 "$OUTPUT"
  echo "Bundled universal rustledger helper: $OUTPUT"
  exit 0
fi

echo "Unable to bundle rustledger from the pinned release. Set TABLEPRO_RUSTLEDGER_BINARY for local builds or retry the release download." >&2
exit 1
