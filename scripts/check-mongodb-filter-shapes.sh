#!/usr/bin/env bash
#
# Every filter document MongoDBQueryBuilder can emit, parsed by the libbson we actually link.
#
# The builder assembles Extended JSON by hand, and MongoDBConnection hands the result to
# bson_new_from_json. A shape that stops parsing there fails at run time with an unhelpful
# error and no test catches it, because the Swift tests only compare strings. Run this after
# bumping libbson, or after adding an operator arm that emits a new shape.
#
# Usage: scripts/check-mongodb-filter-shapes.sh [arm64|x86_64]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-$(uname -m)}"
LIB="$ROOT/Libs/libbson_${ARCH}.a"
INCLUDE="$ROOT/Plugins/MongoDBDriverPlugin/CLibMongoc/include"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$LIB" ]; then
    echo "missing $LIB (run scripts/download-libs.sh)" >&2
    exit 2
fi

cat > "$WORK/probe.c" <<'PROBE'
#include <stdio.h>
#include <bson/bson.h>

static int failures = 0;

static void check(const char *label, const char *json) {
    bson_error_t error;
    bson_t *doc = bson_new_from_json((const uint8_t *)json, -1, &error);
    if (!doc) {
        printf("FAIL  %-34s %s\n        %s\n", label, error.message, json);
        failures++;
        return;
    }
    printf("ok    %-34s\n", label);
    bson_destroy(doc);
}

int main(void) {
    printf("libbson %s\n", bson_get_version());

    check("dotted equality",        "{\"customer.country\": \"US\"}");
    check("dotted comparison",      "{\"customer.age\": {\"$gte\": 18}}");
    check("array dot notation",     "{\"items.sku\": \"A100\"}");
    check("elemMatch multi",        "{\"items\": {\"$elemMatch\": {\"price\": {\"$gt\": 500}, \"name\": \"Laptop\"}}}");
    check("elemMatch single",       "{\"items\": {\"$elemMatch\": {\"sku\": \"A100\"}}}");
    check("elemMatch dotted inner", "{\"orders\": {\"$elemMatch\": {\"customer.country\": \"US\"}}}");
    check("elemMatch colliding key","{\"items\": {\"$elemMatch\": {\"$and\": [{\"price\": {\"$gt\": 10}}, {\"price\": {\"$lt\": 90}}]}}}");
    check("elemMatch match-any",    "{\"items\": {\"$elemMatch\": {\"$or\": [{\"price\": {\"$gt\": 500}}, {\"name\": \"Laptop\"}]}}}");
    check("elemMatch non-BMP key",  "{\"🎁items\": {\"$elemMatch\": {\"sku\": \"A100\"}}}");
    check("string field quoted",    "{\"customer.zip\": \"12345\"}");
    check("elemMatch regex",        "{\"items\": {\"$elemMatch\": {\"name\": {\"$regex\": \"^Lap\", \"$options\": \"i\"}}}}");
    check("elemMatch not regex",    "{\"items\": {\"$elemMatch\": {\"name\": {\"$not\": {\"$regex\": \"^Lap\"}}}}}");
    check("and of clauses",         "{\"$and\": [{\"items.sku\": \"A100\"}, {\"customer.country\": \"US\"}]}");
    check("or of clauses",          "{\"$or\": [{\"items\": {\"$elemMatch\": {\"price\": {\"$gt\": 500}}}}, {\"a\": 1}]}");
    check("raw wrapped",            "{\"$and\": [{\"customer.country\": \"US\"}]}");
    check("raw match all",          "{\"$and\": [{}]}");
    check("impossible filter",      "{\"_id\": {\"$in\": []}}");
    check("date coercion",          "{\"createdAt\": {\"$gte\": {\"$date\": {\"$numberLong\": \"1704067200000\"}}}}");
    check("objectId coercion",      "{\"_id\": {\"$gt\": {\"$oid\": \"507f1f77bcf86cd799439011\"}}}");
    check("decimal coercion",       "{\"price\": {\"$gte\": {\"$numberDecimal\": \"19.99\"}}}");
    check("objectId both ways",     "{\"$or\": [{\"ref\": {\"$oid\": \"507f1f77bcf86cd799439011\"}}, {\"ref\": \"507f1f77bcf86cd799439011\"}]}");
    check("binary wrapper",         "{\"id\": {\"$binary\": {\"base64\": \"TGVnYWN5AAAAAAAAAAAAAA==\", \"subType\": \"03\"}}}");
    check("regex no options",       "{\"name\": {\"$regex\": \"^A\"}}");
    check("ne null",                "{\"name\": {\"$ne\": null}}");
    check("nor list",               "{\"$nor\": [{\"a\": {\"$regex\": \"^x$\", \"$options\": \"i\"}}]}");
    check("between",                "{\"name\": {\"$gte\": \"Smith, John\", \"$lte\": \"Zed\"}}");
    check("getField escape hatch",  "{\"$expr\": {\"$gt\": [{\"$getField\": \"price.usd\"}, 40]}}");

    if (failures) {
        printf("\n%d shape(s) failed to parse\n", failures);
        return 1;
    }
    printf("\nall shapes parse\n");
    return 0;
}
PROBE

clang -arch "$ARCH" -I "$INCLUDE" "$WORK/probe.c" "$LIB" \
    -lresolv -framework CoreFoundation -framework Security \
    -o "$WORK/probe" || exit 2

"$WORK/probe"
