#!/usr/bin/env bash
# The driver's own serializers and document payload, without a database server.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRODUCTS="${1:?Pass the Debug build products directory for this worktree}"
PLUGIN="$ROOT/Plugins/MongoDBDriverPlugin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/unrelated.swift" <<'SWIFT'
// The display serializer does not call the write-side field-order guard.
enum MongoDBCollectionDDL {
    static func isReorderedByTheShell(_ key: String) -> Bool {
        guard let index = UInt32(key), index != UInt32.max else { return false }
        return String(index) == key
    }
}
SWIFT
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
import TableProPluginKit

@main
struct Probe {
    static func main() throws {
        let large = String(repeating: "x", count: 20_000)
        let serialized = BsonDocumentFlattener.serializeToJson(["text": large], representation: .unspecified)
        let decoded = try JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: String]
        precondition(decoded?["text"] == large, "Nested serialization lost text")
        let canonical = #"{"text":\#(PluginExportDocument.jsonString(large)),"long":{"$numberLong":"42"},"oid":{"$oid":"65a1b2c3d4e5f60718293a4b"},"date":{"$date":{"$numberLong":"-1"}},"decimal":{"$numberDecimal":"1.50"}}"#
        let value = try MongoDocumentText.Value(parsing: canonical)
        let displayed = BsonDocumentFlattener.nestedDisplayText(value)
        precondition(displayed.contains(large), "Nested display lost text")
        precondition(displayed.contains(#""$numberLong":"42""#))
        precondition(displayed.contains(#""$oid":"65a1b2c3d4e5f60718293a4b""#))
        precondition(displayed.contains(#""$numberDecimal":"1.50""#))
        let nested: [String: Any] = ["text": large, "long": Int64(42), "oid": MongoDBObjectId(hex: "65a1b2c3d4e5f60718293a4b"), "date": Date(timeIntervalSince1970: -0.001), "decimal": MongoDBDecimal128(digits: "1.50")]
        let text = #"{"v":{"$numberInt":"42"},"10":null,"2":"true","__proto__":\#(canonical),"late":{"$numberLong":"42"}}"#
        let dictionary: [String: Any] = ["v": Int32(42), "10": NSNull(), "2": "true", "__proto__": nested, "late": Int64(42)]
        let document = try MongoExportDocument.read(canonicalJSON: text, dictionary: dictionary, representation: .unspecified)
        precondition(document.fields.map(\.name) == ["v", "10", "2", "__proto__", "late"])
        precondition(document.fields[0].typeName == "INTEGER")
        precondition(document.fields[0].canonicalJSON == #"{"$numberInt":"42"}"#)
        precondition(document.fields[1].canonicalJSON == "null")
        precondition(document.fields[2].canonicalJSON == #""true""#)
        precondition(document.fields[3].canonicalJSON == canonical)
        precondition(document.fields[3].cellValue.asText?.contains(large) == true)
        precondition(document.fields[4].typeName == "BIGINT")
        let rows = BsonDocumentFlattener.flatten(documents: [dictionary], columns: ["v", "__proto__"], kinds: [.string, .document], representation: .unspecified, storedTexts: [text])
        precondition(rows[0][1].asText?.contains(large) == true)
        let code = #"{"v":{"$code":"return x","$scope":{"x":{"$numberLong":"42"}}}}"#
        let codeRows = BsonDocumentFlattener.flatten(
            documents: [["v": ["$code": "return x", "$scope": ["x": Int64(42)]]]],
            columns: ["v"], kinds: [.document], representation: .unspecified, storedTexts: [code]
        )
        precondition(codeRows[0][0].asText?.contains(#""$numberLong":"42""#) == true)
        print("PASS driver export values: long nested text, mixed types, stored null, nested BSON values and late fields")
    }
}
SWIFT
xcrun swiftc -emit-library -emit-module -module-name TableProNumberFormatting \
    "$ROOT"/Packages/TableProCore/Sources/TableProNumberFormatting/*.swift \
    -emit-module-path "$WORK/TableProNumberFormatting.swiftmodule" -o "$WORK/libTableProNumberFormatting.dylib"
xcrun swiftc -parse-as-library -I "$WORK" -L "$WORK" -lTableProNumberFormatting \
    -F "$PRODUCTS" -framework TableProPluginKit \
    -Xlinker -rpath -Xlinker "$PRODUCTS" -Xlinker -rpath -Xlinker "$WORK" \
    "$PLUGIN/BsonDocumentFlattener.swift" "$PLUGIN/MongoDocumentText.swift" \
    "$PLUGIN/MongoExtendedJsonForm.swift" "$PLUGIN/MongoExtendedJsonType.swift" \
    "$PLUGIN/MongoDBWriteRefusal.swift" "$PLUGIN/MongoDBDecimal128.swift" "$PLUGIN/MongoExportDocument.swift" \
    "$WORK/unrelated.swift" "$WORK/main.swift" -o "$WORK/probe"
"$WORK/probe"
