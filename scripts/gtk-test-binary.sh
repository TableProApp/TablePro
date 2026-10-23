#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"

if [[ -n "${TABLEPRO_GTK_BINARY:-}" ]]; then
  printf '%s\n' "$TABLEPRO_GTK_BINARY"
  exit 0
fi

profile="${TABLEPRO_GTK_BUILD_PROFILE:-ci}"
case "$profile" in
  ci | release) ;;
  *)
    echo "TABLEPRO_GTK_BUILD_PROFILE must be ci or release, got: $profile" >&2
    exit 2
    ;;
esac

(cd "$ROOT" && cargo build --profile "$profile" --locked -p tablepro-app --bin tablepro-app) >&2
test_binary="$TARGET_DIR/installed-$profile/usr/bin/tablepro"
install -Dm755 "$TARGET_DIR/$profile/tablepro-app" "$test_binary"
printf '%s\n' "$test_binary"
