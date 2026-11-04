#!/usr/bin/env bash
# Canonical document serialization against the libbson linked by the driver; no server is needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="$ROOT/Plugins/MongoDBDriverPlugin"
LIBRARY="$ROOT/Libs/libbson.a"
[[ -f "$LIBRARY" ]] || { echo "Missing $LIBRARY" >&2; exit 3; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/probe.c" <<'C'
#include <bson/bson.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    const char *json = "{\"z\":\"42\",\"10\":{\"$numberInt\":\"42\"},\"2\":{\"$numberLong\":\"42\"},"
        "\"__proto__\":null,\"nested\":{\"oid\":{\"$oid\":\"65a1b2c3d4e5f60718293a4b\"},"
        "\"date\":{\"$date\":{\"$numberLong\":\"-1\"}},\"decimal\":{\"$numberDecimal\":\"1.50\"}}}";
    bson_error_t error;
    bson_t *document = bson_new_from_json((const uint8_t *)json, -1, &error);
    assert(document);
    char *large = malloc(20001);
    memset(large, 'x', 20000);
    large[20000] = 0;
    bson_t child;
    assert(BSON_APPEND_DOCUMENT_BEGIN(document, "large", &child));
    assert(BSON_APPEND_UTF8(&child, "text", large));
    assert(bson_append_document_end(document, &child));
    size_t length;
    char *canonical = bson_as_canonical_extended_json(document, &length);
    assert(canonical && length > 20000);
    assert(strstr(canonical, large));
    bson_t *restored = bson_new_from_json((const uint8_t *)canonical, (ssize_t)length, &error);
    assert(restored && bson_equal(document, restored));
    bson_iter_t iter;
    const char *keys[] = {"z", "10", "2", "__proto__", "nested", "large"};
    assert(bson_iter_init(&iter, restored));
    for (size_t i = 0; i < 6; i++) {
        assert(bson_iter_next(&iter));
        assert(strcmp(bson_iter_key(&iter), keys[i]) == 0);
    }
    assert(!bson_iter_next(&iter));
    printf("PASS libbson %s: mixed types, nested values, stored null, field order, 20000-character value\n", bson_get_version());
    bson_destroy(restored);
    bson_free(canonical);
    bson_destroy(document);
    free(large);
    return 0;
}
C
xcrun clang -I "$PLUGIN/CLibMongoc/include" "$WORK/probe.c" "$LIBRARY" -o "$WORK/probe"
"$WORK/probe"
