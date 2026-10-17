#!/usr/bin/env bash
set -euo pipefail

# Loads every built .tableplugin with dlopen and fails naming any that will not load.
#
# Usage: verify-plugin-loads.sh <directory-with-tableplugins> [more-directories...]
#
# dlopen resolves the binary and every library and framework it links, the dyld path behind
# "Bundle failed to load executable". It does not instantiate the principal class. PluginKit ABI:
# .claude/rules/plugin-system.md, ABI, checked with `verify.sh abi`.

[ $# -gt 0 ] || { echo "Usage: $0 <directory-with-tableplugins>..." >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/probe.c" <<'PROBE'
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) { return 2; }
    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    return 0;
}
PROBE
clang -o "$WORK/probe" "$WORK/probe.c"

# The plugins link the app's frameworks, which sit beside them in the products directory. Without
# these dyld cannot resolve TableProPluginKit and every plugin would "fail" for the wrong reason.
search_paths=""
for dir in "$@"; do
    [ -d "$dir" ] || { echo "verify-plugin-loads.sh: no such directory: $dir" >&2; exit 1; }
    search_paths="${search_paths:+$search_paths:}$dir:$dir/PackageFrameworks"
done
export DYLD_FRAMEWORK_PATH="$search_paths"
export DYLD_LIBRARY_PATH="$search_paths"

checked=0
failed=()

while IFS= read -r bundle; do
    name="$(basename "$bundle" .tableplugin)"
    binary="$bundle/Contents/MacOS/$name"
    if [ ! -f "$binary" ]; then
        echo "  ✗ $name has no executable at Contents/MacOS/$name" >&2
        failed+=("$name")
        continue
    fi
    if output="$("$WORK/probe" "$binary" 2>&1)"; then
        echo "  ✓ $name"
    else
        # dlerror lists every path it tried, which is a screenful. The reason is the part before
        # that list, and the distinct "(...)" causes after it.
        reason="${output%% tried:*}"
        causes="$(printf '%s' "$output" | grep -oE "\\(([a-z][^)]*)\\)" | sort -u | tr '\n' ' ')"
        echo "  ✗ $name: $reason${causes:+ [$causes]}" >&2
        failed+=("$name")
    fi
    checked=$((checked + 1))
done < <(for dir in "$@"; do find "$dir" -maxdepth 1 -name '*.tableplugin'; done | sort)

if [ "$checked" -eq 0 ]; then
    echo "verify-plugin-loads.sh: found no .tableplugin bundles in $*" >&2
    exit 1
fi

if [ "${#failed[@]}" -gt 0 ]; then
    echo "" >&2
    echo "${#failed[@]} of $checked plugins will not load: ${failed[*]}" >&2
    echo "This is the 'Bundle failed to load executable' a user would hit. Each ✗ line above gives" >&2
    echo "the cause: a missing executable, or a binary, library or framework dyld could not load." >&2
    exit 1
fi

echo "All $checked plugins load."
