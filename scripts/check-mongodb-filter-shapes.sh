#!/usr/bin/env bash
#
# Every filter document MongoDBQueryBuilder can emit, built into BSON by the MongoDB driver's own
# MongoBsonBuilder against the libbson we actually link.
#
# The builder assembles Extended JSON by hand. MongoBsonBuilder hands the text to
# bson_new_from_json whole, or builds it member by member when it holds a $type, $regex or
# $options operator document, which libbson would otherwise read as a binary or regular
# expression value. A shape that stops building fails at run time with an unhelpful error, and one
# built as the wrong BSON type matches something else without failing, while the Swift tests only
# compare strings. So this compiles the plugin's planner and builder with swiftc, builds every
# shape, and checks the BSON type wherever libbson's own reading and the query's meaning part.
# Run it after bumping libbson, or after adding an operator arm that emits a new shape.
#
# Usage: scripts/check-mongodb-filter-shapes.sh [arm64|x86_64]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-$(uname -m)}"
PLUGIN="$ROOT/Plugins/MongoDBDriverPlugin"
LIB="$ROOT/Libs/libbson_${ARCH}.a"
INCLUDE="$PLUGIN/CLibMongoc/include"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$LIB" ]; then
    echo "missing $LIB (run scripts/download-libs.sh)" >&2
    exit 2
fi

cat > "$WORK/main.swift" <<'PROBE'
import CLibMongoc
import Foundation

/// What libbson stored a value as, read back from its canonical Extended JSON, which spells every
/// type but a document, an array, a string, a boolean and null as a one-key wrapper.
enum Kind: String {
    case document, array, string, bool, null, regex, binary, date, objectId, decimal, other

    init(_ value: Any) {
        switch value {
        case is String: self = .string
        case is NSNull: self = .null
        case is [Any]: self = .array
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool
        case let object as [String: Any]:
            let wrappers: [String: Kind] = [
                "$regularExpression": .regex, "$binary": .binary, "$date": .date, "$oid": .objectId,
                "$numberDecimal": .decimal, "$numberInt": .other, "$numberLong": .other, "$numberDouble": .other,
                "$timestamp": .other, "$code": .other, "$symbol": .other, "$minKey": .other, "$maxKey": .other,
                "$undefined": .other, "$dbPointer": .other
            ]
            guard object.count == 1, let key = object.keys.first, let kind = wrappers[key] else {
                self = .document
                return
            }
            self = kind
        default: self = .other
        }
    }
}

struct ShapeCheck {
    private(set) var failures = 0

    mutating func check(_ label: String, _ json: String, kinds: KeyValuePairs<String, Kind> = [:]) {
        var reason = "libbson refused it"
        guard let document = MongoBsonBuilder.document(from: json, onParseFailure: { reason = $0 }) else {
            report(label, "does not build: \(reason)", json)
            return
        }
        defer { bson_destroy(document) }
        guard let text = bson_as_canonical_extended_json(document, nil) else {
            report(label, "has no canonical Extended JSON", json)
            return
        }
        defer { bson_free(text) }
        let built = try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8))
        for (path, expected) in kinds {
            guard let value = Self.value(at: path, in: built) else {
                report(label, "has no \(path)", json)
                return
            }
            let actual = Kind(value)
            guard actual == expected else {
                report(label, "holds \(path) as \(actual.rawValue), not \(expected.rawValue)", json)
                return
            }
        }
        print("ok    \(label)")
    }

    private static func value(at path: String, in root: Any?) -> Any? {
        path.split(separator: ".").reduce(root) { node, key in
            if let object = node as? [String: Any] { return object[String(key)] }
            if let array = node as? [Any], let index = Int(key), array.indices.contains(index) { return array[index] }
            return nil
        }
    }

    private mutating func report(_ label: String, _ problem: String, _ json: String) {
        print("FAIL  \(label): \(problem)\n        \(json)")
        failures += 1
    }
}

print("libbson \(String(cString: bson_get_version()))")
var shapes = ShapeCheck()

shapes.check("dotted equality", #"{"customer.country": "US"}"#)
shapes.check("dotted comparison", #"{"customer.age": {"$gte": 18}}"#)
shapes.check("array dot notation", #"{"items.sku": "A100"}"#)
shapes.check("elemMatch multi", #"{"items": {"$elemMatch": {"price": {"$gt": 500}, "name": "Laptop"}}}"#)
shapes.check("elemMatch single", #"{"items": {"$elemMatch": {"sku": "A100"}}}"#)
shapes.check("elemMatch dotted inner", #"{"orders": {"$elemMatch": {"customer.country": "US"}}}"#)
shapes.check(
    "elemMatch colliding key",
    #"{"items": {"$elemMatch": {"$and": [{"price": {"$gt": 10}}, {"price": {"$lt": 90}}]}}}"#
)
shapes.check(
    "elemMatch match-any",
    #"{"items": {"$elemMatch": {"$or": [{"price": {"$gt": 500}}, {"name": "Laptop"}]}}}"#
)
shapes.check("elemMatch non-BMP key", #"{"🎁items": {"$elemMatch": {"sku": "A100"}}}"#)
shapes.check("string field quoted", #"{"customer.zip": "12345"}"#)
shapes.check(
    "elemMatch regex",
    #"{"items": {"$elemMatch": {"name": {"$regex": "^Lap", "$options": "i"}}}}"#,
    kinds: ["items.$elemMatch.name": .document, "items.$elemMatch.name.$regex": .string]
)
shapes.check(
    "elemMatch not regex",
    #"{"items": {"$elemMatch": {"name": {"$not": {"$regularExpression": {"pattern": "^Lap", "options": ""}}}}}}"#,
    kinds: ["items.$elemMatch.name.$not": .regex]
)
shapes.check(
    "not regex ignoring case",
    #"{"name": {"$not": {"$regularExpression": {"pattern": "^a$", "options": "i"}}}}"#,
    kinds: ["name.$not": .regex]
)
shapes.check("and of clauses", #"{"$and": [{"items.sku": "A100"}, {"customer.country": "US"}]}"#)
shapes.check("or of clauses", #"{"$or": [{"items": {"$elemMatch": {"price": {"$gt": 500}}}}, {"a": 1}]}"#)
shapes.check("raw wrapped", #"{"$and": [{"customer.country": "US"}]}"#)
shapes.check("raw match all", #"{"$and": [{}]}"#)
shapes.check("impossible filter", #"{"_id": {"$in": []}}"#)
shapes.check(
    "date coercion",
    #"{"createdAt": {"$gte": {"$date": {"$numberLong": "1704067200000"}}}}"#,
    kinds: ["createdAt.$gte": .date]
)
shapes.check(
    "objectId coercion",
    #"{"_id": {"$gt": {"$oid": "507f1f77bcf86cd799439011"}}}"#,
    kinds: ["_id.$gt": .objectId]
)
shapes.check(
    "decimal coercion",
    #"{"price": {"$gte": {"$numberDecimal": "19.99"}}}"#,
    kinds: ["price.$gte": .decimal]
)
shapes.check(
    "objectId both ways",
    #"{"$or": [{"ref": {"$oid": "507f1f77bcf86cd799439011"}}, {"ref": "507f1f77bcf86cd799439011"}]}"#,
    kinds: ["$or.0.ref": .objectId, "$or.1.ref": .string]
)
shapes.check(
    "binary wrapper",
    #"{"id": {"$binary": {"base64": "TGVnYWN5AAAAAAAAAAAAAA==", "subType": "03"}}}"#,
    kinds: ["id": .binary]
)
shapes.check(
    "regex no options",
    #"{"name": {"$regex": "^A"}}"#,
    kinds: ["name": .document, "name.$regex": .string]
)
shapes.check("ne null", #"{"name": {"$ne": null}}"#, kinds: ["name.$ne": .null])
shapes.check(
    "nor list",
    #"{"$nor": [{"a": {"$regex": "^x$", "$options": "i"}}]}"#,
    kinds: ["$nor": .array, "$nor.0.a": .document, "$nor.0.a.$options": .string]
)
shapes.check("between", #"{"name": {"$gte": "Smith, John", "$lte": "Zed"}}"#)
shapes.check("getField escape hatch", #"{"$expr": {"$gt": [{"$getField": "price.usd"}, 40]}}"#)
shapes.check(
    "raw type operator",
    #"{"sig": {"$type": "binData"}}"#,
    kinds: ["sig": .document, "sig.$type": .string]
)
shapes.check(
    "raw regex beside another operator",
    #"{"f": {"$regex": "^a", "$exists": true}}"#,
    kinds: ["f": .document, "f.$exists": .bool]
)

guard shapes.failures == 0 else {
    print("\n\(shapes.failures) shape(s) failed")
    exit(1)
}
print("\nevery shape builds as the query means it")
PROBE

xcrun --sdk macosx swiftc -swift-version 6 -Onone -module-name FilterShapes \
    -target "${ARCH}-apple-macos14.0" \
    -I "$PLUGIN/CLibMongoc" \
    -Xcc -I"$INCLUDE" -Xcc -I"$INCLUDE/libbson-1.0" -Xcc -I"$INCLUDE/libmongoc-1.0" \
    "$PLUGIN/MongoScriptJson.swift" "$PLUGIN/MongoBsonAssembly.swift" "$PLUGIN/MongoBsonBuilder.swift" \
    "$WORK/main.swift" "$LIB" -lresolv -framework CoreFoundation -framework Security \
    -o "$WORK/probe" || exit 2

"$WORK/probe"
