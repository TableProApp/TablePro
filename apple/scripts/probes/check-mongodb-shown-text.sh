#!/usr/bin/env bash
#
# The text a contains, starts with or ends with filter matches a MongoDB value by, asked of a real server.
#
# MongoDBShownText writes an aggregation expression by hand: it converts only the types it lists and formats a date
# only inside years 0 to 9999, because `$convert` raises past its onError on binary data and on a date outside that
# range (measured on 8.0), and one such value fails the whole find. The unit tests pin its text but cannot ask a server.
# So this compiles the expression's own source with swiftc against the libbson and libmongoc the plugin links, stores
# one value of each kind, and counts what each pattern matches: a number, a date and an ObjectId by the text the grid
# shows, and binary data, out-of-range dates and missing values by nothing, with no error.
#
# Usage:
#   scripts/probes/check-mongodb-shown-text.sh [mongodb-uri]
#
# The default URI is mongodb://127.0.0.1:27017. Needs MongoDB 4.2 or later and the static libraries from
# scripts/download-libs.sh. Writes only to a database named tablepro_shown_text_<pid>, which it drops. Exits non-zero
# on a disagreement.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
URI="${1:-mongodb://127.0.0.1:27017}"
PLUGIN="$ROOT/Plugins/MongoDBDriverPlugin"
LIBS="$ROOT/Libs"

for lib in "$LIBS/libmongoc.a" "$LIBS/libbson.a" "$LIBS/dylibs/libssl.3.dylib" "$LIBS/dylibs/libcrypto.3.dylib"; do
    [ -e "$lib" ] || {
        echo "missing $lib (run scripts/download-libs.sh)" >&2
        exit 3
    }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/builder.swift" <<'SWIFT'
enum MongoDBQueryBuilder {
    static func escapeJsonString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
SWIFT

cat > "$WORK/main.swift" <<'SWIFT'
import CLibMongoc
import Foundation

let documents: [(Int, String)] = [
    (1, #""v":{"$numberInt":"42"}"#),
    (2, #""v":{"$numberDouble":"1.5"}"#),
    (3, #""v":true"#),
    (4, #""v":{"$date":{"$numberLong":"1704164645000"}}"#),
    (5, #""v":{"$date":{"$numberLong":"1704164645120"}}"#),
    (6, #""v":{"$oid":"65a1b2c3d4e5f60718293a4b"}"#),
    (7, #""v":{"$binary":{"base64":"AAAAAAAAAAAAAAAAAAAAAA==","subType":"04"}}"#),
    (8, #""v":{"$date":{"$numberLong":"253402300800000"}}"#),
    (9, #""v":[{"$date":{"$numberLong":"253402300800000"}},"a05Z"]"#),
    (10, #""v":{"x":{"$date":{"$numberLong":"-62167219200001"}}}"#),
    (11, #""v":{"$numberLong":"9007199254740993"}"#),
    (12, #""v":{"$numberDecimal":"1.50"}"#),
    (13, ""),
    (14, #""v":null"#),
    (15, #""v":"s 05Z""#),
    (16, #""v":{"$date":{"$numberLong":"-62167219200000"}}"#),
    (17, #""v":{"$binary":{"base64":"AAEC","subType":"00"}}"#)
]

// A pattern as the filter builder escapes it, and the documents it must match.
let cases: [(String, Set<Int>)] = [
    ("42", [1]),
    ("05Z", [4, 9, 15]),
    ("05\\.120Z", [5]),
    ("1\\.5", [2, 12]),
    ("TRUE", [3]),
    ("65A1B2", [6]),
    ("^9007199254740993$", [11]),
    ("^0000-01-01T00:00:00Z$", [16]),
    ("^2024-01-02T03:04:05Z$", [4]),
    ("AAAA", [])
]

func bson(_ json: String) -> OpaquePointer? {
    var error = bson_error_t()
    return json.withCString { bson_new_from_json($0, -1, &error) }
}

func errorText(_ error: inout bson_error_t) -> String {
    withUnsafeBytes(of: &error.message) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

@main
struct Check {
    static func main() {
        mongoc_init()
        exit(run())
    }

    // Returns rather than exits, so the deferred drop runs.
    static func run() -> Int32 {
        let uri = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "mongodb://127.0.0.1:27017"
        guard let client = mongoc_client_new(uri) else {
            print("FAIL  cannot parse \(uri)")
            return 2
        }
        let name = "tablepro_shown_text_\(getpid())"
        let database = mongoc_client_get_database(client, name)
        let collection = mongoc_client_get_collection(client, name, "values")
        defer {
            _ = mongoc_database_drop(database, nil)
            mongoc_collection_destroy(collection)
            mongoc_database_destroy(database)
            mongoc_client_destroy(client)
        }

        var error = bson_error_t()
        for (id, fields) in documents {
            let json = fields.isEmpty ? #"{"_id":\#(id)}"# : #"{"_id":\#(id),\#(fields)}"#
            guard let document = bson(json), mongoc_collection_insert_one(collection, document, nil, nil, &error) else {
                print("FAIL  insert \(id): \(errorText(&error))")
                return 2
            }
            bson_destroy(document)
        }

        var failures = 0
        for (pattern, expected) in cases {
            let regex = #"{"v":{"$regex":"\#(MongoDBQueryBuilder.escapeJsonString(pattern))","$options":"i"}}"#
            let shown = MongoDBShownText.regexMatch(field: "v", pattern: pattern, ignoresCase: true)
            for negated in [false, true] {
                let filter = #"{"\#(negated ? "$nor" : "$or")":[\#(regex),\#(shown)]}"#
                guard let matched = ids(collection, filter) else {
                    failures += 1
                    continue
                }
                let want = negated ? Set(documents.map(\.0)).subtracting(expected) : expected
                let label = "\(negated ? "not " : "")\(pattern)"
                if matched == want {
                    print("ok    \(label): \(matched.sorted())")
                } else {
                    print("FAIL  \(label): matched \(matched.sorted()), expected \(want.sorted())")
                    failures += 1
                }
            }
        }
        return failures == 0 ? 0 : 1
    }

    static func ids(_ collection: OpaquePointer?, _ filter: String) -> Set<Int>? {
        guard let query = bson(filter) else {
            print("FAIL  not JSON: \(filter.prefix(200))")
            return nil
        }
        defer { bson_destroy(query) }
        let cursor = mongoc_collection_find_with_opts(collection, query, nil, nil)
        defer { mongoc_cursor_destroy(cursor) }
        var found = Set<Int>()
        var document: OpaquePointer?
        while mongoc_cursor_next(cursor, &document) {
            guard let document, let text = bson_as_relaxed_extended_json(document, nil) else { continue }
            defer { bson_free(text) }
            let parsed = try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as? [String: Any]
            if let id = parsed?["_id"] as? Int { found.insert(id) }
        }
        var error = bson_error_t()
        if mongoc_cursor_error(cursor, &error) {
            print("FAIL  the server refused the filter: \(errorText(&error))")
            return nil
        }
        return found
    }
}
SWIFT

echo "Building the shown text checker from $PLUGIN"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" xcrun swiftc -swift-version 6 -parse-as-library -O \
    -module-name ShownTextCheck \
    -I "$PLUGIN/CLibMongoc" \
    -Xcc "-I$PLUGIN/CLibMongoc/include" \
    -Xcc "-I$PLUGIN/CLibMongoc/include/libbson-1.0" \
    -Xcc "-I$PLUGIN/CLibMongoc/include/libmongoc-1.0" \
    -L "$LIBS/dylibs" \
    -Xlinker -force_load -Xlinker "$LIBS/libmongoc.a" \
    -Xlinker -force_load -Xlinker "$LIBS/libbson.a" \
    -lssl.3 -lcrypto.3 -lresolv -lz \
    -Xlinker -rpath -Xlinker "$LIBS/dylibs" \
    "$PLUGIN/MongoDBShownText.swift" \
    "$WORK/builder.swift" \
    "$WORK/main.swift" \
    -o "$WORK/check" > "$WORK/build.log" 2>&1 || {
    cat "$WORK/build.log" >&2
    exit 2
}

"$WORK/check" "$URI"
