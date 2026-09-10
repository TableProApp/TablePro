#!/usr/bin/env bash
#
# Check the vendored MariaDB Connector/C headers against the version build-mariadb.sh pins.
#
# The headers under Plugins/MySQLDriverPlugin/CMariaDB/include describe the library the plugin
# compiles against, and Libs/libmariadb*.a is what it links. Nothing keeps the two together, and
# they came apart: the headers were copied out of a Homebrew mariadb-connector-c 3.4.8 keg, still
# carrying that keg's plugin directory, while build-mariadb.sh pins and builds 3.4.4. That skew is
# quiet by construction. A declaration the binary does not export fails at link time, which is loud,
# but a macro or a struct that changed between the two versions compiles and then misbehaves.
#
# Usage:
#   scripts/check-mariadb-headers.sh
#
# Downloads the pinned source to a temporary directory, renders mariadb_version.h the way the build
# does, and diffs every vendored header against it. Needs curl and cmake. Exits non-zero on a
# difference; the fix is to copy the upstream headers over the vendored ones.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$PROJECT_DIR/scripts/build-mariadb.sh"
VENDORED="$PROJECT_DIR/Plugins/MySQLDriverPlugin/CMariaDB/include"

for tool in curl cmake; do
    command -v "$tool" > /dev/null || {
        echo "$tool not found" >&2
        exit 2
    }
done

VERSION="$(sed -n 's/^MARIADB_VERSION="\(.*\)"$/\1/p' "$BUILD_SCRIPT")"
[ -n "$VERSION" ] || {
    echo "could not read MARIADB_VERSION from $BUILD_SCRIPT" >&2
    exit 2
}
echo "build-mariadb.sh pins Connector/C $VERSION"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL "https://archive.mariadb.org/connector-c-$VERSION/mariadb-connector-c-$VERSION-src.tar.gz" \
    -o "$WORK/src.tgz" || {
    echo "could not download Connector/C $VERSION" >&2
    exit 2
}
tar xzf "$WORK/src.tgz" -C "$WORK" || exit 2
SRC="$WORK/mariadb-connector-c-$VERSION-src"
[ -d "$SRC/include" ] || {
    echo "unexpected archive layout under $SRC" >&2
    exit 2
}

# mariadb_version.h is generated, so it has to be rendered rather than copied. The install prefix is
# the only input that reaches it, through MARIADB_PLUGINDIR.
cmake -S "$SRC" -B "$WORK/cfg" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_INSTALL_PREFIX=/usr/local > /dev/null 2>&1
[ -f "$WORK/cfg/include/mariadb_version.h" ] || {
    echo "cmake did not generate mariadb_version.h" >&2
    exit 2
}

differences=0
while IFS= read -r relative; do
    upstream="$SRC/include/$relative"
    [ "$relative" = "mariadb_version.h" ] && upstream="$WORK/cfg/include/mariadb_version.h"
    if [ ! -f "$upstream" ]; then
        printf '  EXTRA     %s  (not in Connector/C %s)\n' "$relative" "$VERSION"
        differences=$((differences + 1))
        continue
    fi
    if diff -q "$VENDORED/$relative" "$upstream" > /dev/null 2>&1; then
        printf '  ok        %s\n' "$relative"
    else
        printf '  DIFFERS   %s  (%s changed line(s))\n' \
            "$relative" "$(diff "$VENDORED/$relative" "$upstream" | grep -c '^[<>]')"
        differences=$((differences + 1))
    fi
done < <(cd "$VENDORED" && find . -name '*.h' | sed 's|^\./||' | sort)

if [ "$differences" -ne 0 ]; then
    echo
    echo "$differences vendored header(s) do not match Connector/C $VERSION." >&2
    echo "Copy them from the upstream include/ directory, and render mariadb_version.h" >&2
    echo "from a cmake configure of the same source rather than from a package manager." >&2
    exit 1
fi

echo
echo "every vendored header matches Connector/C $VERSION"
