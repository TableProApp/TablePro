#!/usr/bin/env bash
# Proves what KerberosCredentialCache in PluginKit relies on: the macOS GSS framework reads
# KRB5CCNAME on every call, so setting, changing and unsetting it moves GSS between a private
# FILE cache and the user's default cache within one process.
#
# Needs no KDC and no ticket. Each step asks GSS for a service ticket to a name nobody has
# registered, and the error names the cache GSS looked in. Each step uses a new target, because
# GSS remembers a failed lookup per target.
#
# Run after a macOS update, or before changing how a driver points GSS at a private cache.

set -euo pipefail

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/probe.c" << 'EOF'
#include <GSS/GSS.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void lookup(const char *step, const char *service) {
    OM_uint32 minor = 0, ignored = 0, context = 0;
    gss_buffer_desc name = { strlen(service), (void *)service };
    gss_name_t target = GSS_C_NO_NAME;
    gss_import_name(&minor, &name, GSS_C_NT_HOSTBASED_SERVICE, &target);
    gss_ctx_id_t ctx = GSS_C_NO_CONTEXT;
    gss_buffer_desc token = GSS_C_EMPTY_BUFFER, text = GSS_C_EMPTY_BUFFER;
    gss_init_sec_context(&minor, GSS_C_NO_CREDENTIAL, &ctx, target, GSS_KRB5_MECHANISM, 0, 0,
                         GSS_C_NO_CHANNEL_BINDINGS, GSS_C_NO_BUFFER, NULL, &token, NULL, NULL);
    gss_display_status(&ignored, minor, GSS_C_MECH_CODE, GSS_KRB5_MECHANISM, &context, &text);
    printf("%s|%.*s\n", step, (int)text.length, (const char *)text.value);
    gss_release_buffer(&ignored, &text);
    gss_release_buffer(&ignored, &token);
    gss_release_name(&ignored, &target);
}

int main(void) {
    unsetenv("KRB5CCNAME");
    lookup("default", "postgres@a.tablepro-probe.invalid");
    setenv("KRB5CCNAME", "FILE:/tmp/tablepro-probe-cache-a", 1);
    lookup("cache-a", "postgres@b.tablepro-probe.invalid");
    setenv("KRB5CCNAME", "FILE:/tmp/tablepro-probe-cache-b", 1);
    lookup("cache-b", "postgres@c.tablepro-probe.invalid");
    unsetenv("KRB5CCNAME");
    lookup("unset", "postgres@d.tablepro-probe.invalid");
    return 0;
}
EOF

clang -Wno-deprecated-declarations -framework GSS -o "$WORK_DIR/probe" "$WORK_DIR/probe.c"
output="$("$WORK_DIR/probe")"
echo "$output"

step() { echo "$output" | sed -n "s/^$1|//p"; }

failures=0
expect() {
    local name="$1" pattern="$2" negate="${3:-}"
    local line
    line="$(step "$name")"
    if [ -n "$negate" ]; then
        if echo "$line" | grep -F "$pattern" > /dev/null; then
            echo "FAIL: $name still looks in $pattern" >&2
            failures=$((failures + 1))
        fi
    elif ! echo "$line" | grep -F "$pattern" > /dev/null; then
        echo "FAIL: $name did not look in $pattern" >&2
        failures=$((failures + 1))
    fi
}

expect cache-a /tmp/tablepro-probe-cache-a
expect cache-b /tmp/tablepro-probe-cache-b
expect default /tmp/tablepro-probe-cache not
expect unset /tmp/tablepro-probe-cache not

if [ "$failures" -ne 0 ]; then
    echo "GSS no longer follows KRB5CCNAME per call; KerberosCredentialCache needs another way in." >&2
    exit 1
fi
echo "OK: GSS follows KRB5CCNAME on every call."
