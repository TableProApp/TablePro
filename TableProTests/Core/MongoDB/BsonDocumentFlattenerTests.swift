//
//  BsonDocumentFlattenerTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("BSON Document Flattener")
struct BsonDocumentFlattenerTests {
    // MARK: - unionColumns(from:)

    @Suite("unionColumns")
    struct UnionColumnsTests {
        @Test("Empty array returns empty columns")
        func emptyArray() {
            let result = BsonDocumentFlattener.unionColumns(from: [])
            #expect(result.isEmpty)
        }

        @Test("Single document returns all keys with _id first")
        func singleDocument() {
            let doc: [String: Any] = ["_id": "abc", "name": "John", "age": 30]
            let result = BsonDocumentFlattener.unionColumns(from: [doc])
            #expect(result == ["_id", "age", "name"])
        }

        @Test("_id is always placed first regardless of insertion order")
        func idAlwaysFirst() {
            let doc: [String: Any] = ["name": "John", "_id": "abc"]
            let result = BsonDocumentFlattener.unionColumns(from: [doc])
            #expect(result == ["_id", "name"])
        }

        @Test("Multiple documents union their fields in first-seen order per doc")
        func multipleDocumentsUnion() {
            let doc1: [String: Any] = ["_id": "1", "name": "John"]
            let doc2: [String: Any] = ["_id": "2", "email": "john@example.com"]
            let result = BsonDocumentFlattener.unionColumns(from: [doc1, doc2])
            #expect(result == ["_id", "name", "email"])
        }

        @Test("Document without _id omits _id from columns")
        func documentWithoutId() {
            let doc: [String: Any] = ["name": "John"]
            let result = BsonDocumentFlattener.unionColumns(from: [doc])
            #expect(result == ["name"])
        }
    }

    // MARK: - flatten(documents:columns:kinds:representation:)

    @Suite("flatten")
    struct FlattenTests {
        @Test("Single document with all columns present returns all values as strings")
        func allColumnsPresent() {
            let doc: [String: Any] = ["_id": "abc", "name": "John", "age": 30]
            let columns = ["_id", "name", "age"]
            let result = FlattenFixture.rows([doc], columns: columns)
            #expect(result.count == 1)
            #expect(result[0] == ["abc", "John", "30"])
        }

        @Test("Missing field produces nil in that cell")
        func missingField() {
            let doc: [String: Any] = ["_id": "abc", "name": "John"]
            let columns = ["_id", "name", "email"]
            let result = FlattenFixture.rows([doc], columns: columns)
            #expect(result[0][0] == "abc")
            #expect(result[0][1] == "John")
            #expect(result[0][2] == nil)
        }

        @Test("Nested object is serialized as compact JSON string")
        func nestedObject() {
            let nested: [String: Any] = ["city": "NYC", "zip": "10001"]
            let doc: [String: Any] = ["_id": "1", "address": nested]
            let columns = ["_id", "address"]
            let result = FlattenFixture.rows([doc], columns: columns)
            #expect(result[0][0] == "1")
            // Keys are sorted in JSON output
            #expect(result[0][1] == "{\"city\":\"NYC\",\"zip\":\"10001\"}")
        }

        @Test("Array value is serialized as compact JSON string")
        func arrayValue() {
            let tags: [Any] = ["swift", "macos"]
            let doc: [String: Any] = ["_id": "1", "tags": tags]
            let columns = ["_id", "tags"]
            let result = FlattenFixture.rows([doc], columns: columns)
            #expect(result[0][1] == "[\"swift\",\"macos\"]")
        }

        @Test("Boolean values are serialized as true/false strings")
        func booleanValue() {
            let doc: [String: Any] = ["_id": "1", "active": NSNumber(value: true)]
            let columns = ["_id", "active"]
            let result = FlattenFixture.rows([doc], columns: columns)
            #expect(result[0][1] == "true")
        }

        @Test("Integer values are serialized as string representation")
        func integerValue() {
            let doc: [String: Any] = ["_id": "1", "count": 42]
            let columns = ["_id", "count"]
            let result = FlattenFixture.rows([doc], columns: columns)
            #expect(result[0][1] == "42")
        }

        @Test("NSNull produces nil")
        func nsNullValue() {
            let doc: [String: Any] = ["_id": "1", "deleted": NSNull()]
            let columns = ["_id", "deleted"]
            let result = FlattenFixture.rows([doc], columns: columns)
            #expect(result[0][1] == nil)
        }

        @Test("Date values are serialized as ISO8601 strings")
        func dateValue() {
            let date = Date(timeIntervalSince1970: 0)
            let doc: [String: Any] = ["_id": "1", "created": date]
            let columns = ["_id", "created"]
            let result = FlattenFixture.rows([doc], columns: columns)
            let expected = ISO8601DateFormatter().string(from: date)
            #expect(result[0][1].asText == expected)
        }

        @Test("Nested non-finite double does not crash and renders as a token")
        func nestedNonFiniteDouble() {
            let metrics: [String: Any] = ["score": Double.nan, "ratio": Double.infinity]
            let doc: [String: Any] = ["_id": "1", "metrics": metrics]
            let columns = ["_id", "metrics"]
            let result = FlattenFixture.rows([doc], columns: columns)
            #expect(result[0][1] == "{\"ratio\":\"Infinity\",\"score\":\"NaN\"}")
        }
    }

    // MARK: - columnKinds(for:documents:representation:)

    @Suite("columnKinds")
    struct ColumnTypesTests {
        @Test("String values produce kind string")
        func stringType() {
            let docs: [[String: Any]] = [["name": "Alice"], ["name": "Bob"]]
            let result = FlattenFixture.kinds(docs, columns: ["name"])
            #expect(result == [.string])
        }

        @Test("Int32 values produce kind int32")
        func int32Type() {
            let docs: [[String: Any]] = [["val": Int32(42)], ["val": Int32(99)]]
            let result = FlattenFixture.kinds(docs, columns: ["val"])
            #expect(result == [.int32])
        }

        @Test("Int64 values produce kind int64")
        func int64Type() {
            let docs: [[String: Any]] = [["val": Int64(9_999_999_999)], ["val": Int64(1_234_567_890)]]
            let result = FlattenFixture.kinds(docs, columns: ["val"])
            #expect(result == [.int64])
        }

        @Test("Double values produce kind double")
        func doubleType() {
            let docs: [[String: Any]] = [["val": 3.14], ["val": 2.71]]
            let result = FlattenFixture.kinds(docs, columns: ["val"])
            #expect(result == [.double])
        }

        @Test("Boolean NSNumber values produce kind boolean")
        func booleanType() {
            let docs: [[String: Any]] = [
                ["flag": NSNumber(value: true)],
                ["flag": NSNumber(value: false)]
            ]
            let result = FlattenFixture.kinds(docs, columns: ["flag"])
            #expect(result == [.boolean])
        }

        @Test("Date values produce kind date")
        func dateType() {
            let docs: [[String: Any]] = [["ts": Date()], ["ts": Date(timeIntervalSince1970: 0)]]
            let result = FlattenFixture.kinds(docs, columns: ["ts"])
            #expect(result == [.date])
        }

        @Test("Dictionary values produce kind document")
        func dictType() {
            let docs: [[String: Any]] = [
                ["meta": ["key": "value"] as [String: Any]],
                ["meta": ["a": 1] as [String: Any]]
            ]
            let result = FlattenFixture.kinds(docs, columns: ["meta"])
            #expect(result == [.document])
        }

        @Test("Array values produce kind array")
        func arrayType() {
            let docs: [[String: Any]] = [
                ["tags": ["a", "b"] as [Any]],
                ["tags": [1, 2] as [Any]]
            ]
            let result = FlattenFixture.kinds(docs, columns: ["tags"])
            #expect(result == [.array])
        }

        @Test("Missing field with no values defaults to kind string")
        func missingFieldDefaultsToString() {
            let docs: [[String: Any]] = [["other": "val"], ["other": "val2"]]
            let result = FlattenFixture.kinds(docs, columns: ["nonexistent"])
            #expect(result == [.string])
        }

        @Test("Majority vote: 2 strings and 1 int yields kind string")
        func majorityVote() {
            let docs: [[String: Any]] = [
                ["val": "hello"],
                ["val": "world"],
                ["val": Int32(42)]
            ]
            let result = FlattenFixture.kinds(docs, columns: ["val"])
            #expect(result == [.string])
        }
    }

    // MARK: - UUID columns

    @Suite("UUID columns")
    struct UuidColumnTests {
        private static func legacyDocs(count: Int = 2) -> [[String: Any]] {
            (0 ..< count).map { _ in
                ["id": MongoDBBinaryValue(data: Data(BsonUuidFixture.javaBytes), subtype: 0x03)]
            }
        }

        @Test("A legacy UUID column keeps the binary type name until a representation is set")
        func undecodedColumnStaysBinary() {
            let kinds = FlattenFixture.kinds(Self.legacyDocs(), columns: ["id"])
            #expect(kinds == [.binary(subtype: 3)])
            #expect(
                BsonDocumentFlattener.typeName(for: .binary(subtype: 3), representation: .unspecified)
                    == "BLOB(3)"
            )
            #expect(
                BsonDocumentFlattener.typeName(for: .binary(subtype: 0), representation: .unspecified)
                    == "BLOB"
            )
        }

        @Test("A configured legacy UUID column reports the representation in its type name")
        func decodedColumnReportsUuidType() {
            let kinds = FlattenFixture.kinds(Self.legacyDocs(), columns: ["id"], representation: .javaLegacy)
            #expect(kinds == [.legacyUuid])
            #expect(
                BsonDocumentFlattener.typeName(for: .legacyUuid, representation: .javaLegacy)
                    == "LegacyJavaUUID"
            )
        }

        @Test("A standard UUID column reports UUID without any configuration")
        func standardColumnReportsUuidType() {
            let docs: [[String: Any]] = [
                ["id": MongoDBBinaryValue(data: Data(BsonUuidFixture.standardBytes), subtype: 0x04)]
            ]
            let kinds = FlattenFixture.kinds(docs, columns: ["id"])
            #expect(kinds == [.uuid])
            #expect(BsonDocumentFlattener.typeName(for: .uuid, representation: .unspecified) == "UUID")
        }

        @Test("Cells stay binary while the column is undecoded")
        func undecodedCellsStayBytes() {
            let result = FlattenFixture.rows(Self.legacyDocs(count: 1), columns: ["id"])
            #expect(result[0][0] == .bytes(Data(BsonUuidFixture.javaBytes)))
        }

        @Test("Cells become wrapper text once the column is a UUID column")
        func decodedCellsBecomeText() {
            let result = FlattenFixture.rows(
                Self.legacyDocs(count: 1), columns: ["id"], representation: .javaLegacy
            )
            #expect(result[0][0] == .text("LegacyJavaUUID(\"\(BsonUuidFixture.uuidString)\")"))
        }

        /// A wrapper string in a column the app still types as BLOB would be hex-encoded for display,
        /// so a minority UUID must not decode inside a binary column.
        @Test("A minority UUID in a binary column is never decoded")
        func minorityUuidStaysBytes() {
            var docs: [[String: Any]] = (0 ..< 3).map { index in
                ["id": MongoDBBinaryValue(data: Data(repeating: UInt8(index), count: 8), subtype: 0x00)]
            }
            docs.append(["id": MongoDBBinaryValue(data: Data(BsonUuidFixture.javaBytes), subtype: 0x03)])

            let kinds = FlattenFixture.kinds(docs, columns: ["id"], representation: .javaLegacy)
            #expect(kinds == [.binary(subtype: 0)])

            let rows = FlattenFixture.rows(docs, columns: ["id"], representation: .javaLegacy)
            #expect(rows.allSatisfy { $0[0].asText == nil })
        }

        @Test("A non-UUID binary inside a UUID column stays binary rather than being mislabelled")
        func strayBinaryInUuidColumn() {
            var docs = Self.legacyDocs(count: 3)
            docs.append(["id": MongoDBBinaryValue(data: Data([0x01, 0x02]), subtype: 0x03)])

            let rows = FlattenFixture.rows(docs, columns: ["id"], representation: .javaLegacy)
            #expect(rows[3][0] == .bytes(Data([0x01, 0x02])))
        }

        @Test("A nested UUID decodes inside the serialized JSON of its parent")
        func nestedUuidDecodes() {
            let nested: [String: Any] = [
                "ref": MongoDBBinaryValue(data: Data(BsonUuidFixture.javaBytes), subtype: 0x03)
            ]
            let docs: [[String: Any]] = [["meta": nested]]
            let rows = FlattenFixture.rows(docs, columns: ["meta"], representation: .javaLegacy)
            #expect(rows[0][0] == .text("{\"ref\":\"LegacyJavaUUID(\\\"\(BsonUuidFixture.uuidString)\\\")\"}"))
        }
    }

    // MARK: - stringValue(for:)

    @Suite("stringValue")
    struct StringValueTests {
        @Test("nil returns nil")
        func nilValue() {
            let result = BsonDocumentFlattener.stringValue(for: nil, representation: .unspecified)
            #expect(result == nil)
        }

        @Test("NSNull returns nil")
        func nsNullValue() {
            let result = BsonDocumentFlattener.stringValue(for: NSNull(), representation: .unspecified)
            #expect(result == nil)
        }

        @Test("String returns itself")
        func stringValue() {
            let result = BsonDocumentFlattener.stringValue(for: "hello", representation: .unspecified)
            #expect(result == "hello")
        }

        @Test("Int returns string representation")
        func intValue() {
            let result = BsonDocumentFlattener.stringValue(for: 42, representation: .unspecified)
            #expect(result == "42")
        }

        @Test("Int32 returns string representation")
        func int32Value() {
            let result = BsonDocumentFlattener.stringValue(for: Int32(42), representation: .unspecified)
            #expect(result == "42")
        }

        @Test("Int64 returns string representation")
        func int64Value() {
            let result = BsonDocumentFlattener.stringValue(for: Int64(9_999_999_999), representation: .unspecified)
            #expect(result == "9999999999")
        }

        @Test("Double returns string representation")
        func doubleValue() {
            let result = BsonDocumentFlattener.stringValue(for: 3.14, representation: .unspecified)
            #expect(result == "3.14")
        }

        @Test("Double keeps every digit needed to round-trip")
        func doubleRoundTrips() {
            let value = -3.9192320754595876e-07
            let result = BsonDocumentFlattener.stringValue(for: value, representation: .unspecified)
            #expect(result == "-3.9192320754595876e-07")
            #expect(Double(result ?? "") == value)
        }

        @Test("Double never gains binary floating point noise")
        func doubleHasNoExcessDigits() {
            #expect(BsonDocumentFlattener.stringValue(for: 1847.27, representation: .unspecified) == "1847.27")
            #expect(BsonDocumentFlattener.stringValue(for: 0.1, representation: .unspecified) == "0.1")
        }

        @Test("Integral double keeps its whole number form")
        func integralDoubleHasNoTrailingZero() {
            #expect(BsonDocumentFlattener.stringValue(for: 1.0, representation: .unspecified) == "1")
            #expect(BsonDocumentFlattener.stringValue(for: 100.0, representation: .unspecified) == "100")
        }

        @Test("Double nested in a sub-document keeps the same digits as a top level one")
        func nestedDoubleMatchesScalar() {
            let document: [String: Any] = ["rate": 0.1, "total": 1847.27, "qty": 3.0]
            let result = BsonDocumentFlattener.stringValue(for: document, representation: .unspecified)
            #expect(result == #"{"qty":3,"rate":0.1,"total":1847.27}"#)
        }

        @Test("Double nested in an array keeps the same digits as a top level one")
        func nestedArrayDoubleMatchesScalar() {
            let values: [Any] = [0.1, 1847.27, 1.0 / 3.0]
            let result = BsonDocumentFlattener.stringValue(for: values, representation: .unspecified)
            #expect(result == "[0.1,1847.27,0.3333333333333333]")
        }

        @Test("NaN double returns NaN token")
        func nanValue() {
            let result = BsonDocumentFlattener.stringValue(for: Double.nan, representation: .unspecified)
            #expect(result == "NaN")
        }

        @Test("Positive infinity returns Infinity token")
        func positiveInfinityValue() {
            let result = BsonDocumentFlattener.stringValue(for: Double.infinity, representation: .unspecified)
            #expect(result == "Infinity")
        }

        @Test("Negative infinity returns -Infinity token")
        func negativeInfinityValue() {
            let result = BsonDocumentFlattener.stringValue(for: -Double.infinity, representation: .unspecified)
            #expect(result == "-Infinity")
        }

        @Test("Bool true via NSNumber returns true")
        func boolTrueValue() {
            let result = BsonDocumentFlattener.stringValue(for: NSNumber(value: true), representation: .unspecified)
            #expect(result == "true")
        }

        @Test("Bool false via NSNumber returns false")
        func boolFalseValue() {
            let result = BsonDocumentFlattener.stringValue(for: NSNumber(value: false), representation: .unspecified)
            #expect(result == "false")
        }

        @Test("Date returns ISO8601 string")
        func dateValue() {
            let date = Date(timeIntervalSince1970: 0)
            let result = BsonDocumentFlattener.stringValue(for: date, representation: .unspecified)
            let expected = ISO8601DateFormatter().string(from: date)
            #expect(result == expected)
        }

        @Test("Untyped Data renders as generic BinData carrying its subtype")
        func dataValue() {
            let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
            let result = BsonDocumentFlattener.stringValue(for: data, representation: .unspecified)
            #expect(result == "BinData(0, \"3q2+7w==\")")
        }

        @Test("A 16-byte generic binary is never guessed to be a UUID")
        func genericBinaryIsNotAUuid() {
            let binary = MongoDBBinaryValue(data: Data(repeating: 0xAB, count: 16), subtype: 0x00)
            let result = BsonDocumentFlattener.stringValue(for: binary, representation: .javaLegacy)
            #expect(result == "BinData(0, \"q6urq6urq6urq6urq6urqw==\")")
        }

        @Test("Subtype 4 decodes to UUID with no representation configured")
        func standardUuidValue() {
            let binary = MongoDBBinaryValue(
                data: Data(BsonUuidFixture.standardBytes), subtype: 0x04
            )
            let result = BsonDocumentFlattener.stringValue(for: binary, representation: .unspecified)
            #expect(result == "UUID(\"\(BsonUuidFixture.uuidString)\")")
        }

        @Test("Subtype 3 stays undecoded until a representation is configured")
        func legacyUuidWithoutRepresentation() {
            let binary = MongoDBBinaryValue(data: Data(BsonUuidFixture.javaBytes), subtype: 0x03)
            let result = BsonDocumentFlattener.stringValue(for: binary, representation: .unspecified)
            #expect(result == "BinData(3, \"\(Data(BsonUuidFixture.javaBytes).base64EncodedString())\")")
        }

        @Test("Subtype 3 decodes with the configured legacy byte order")
        func legacyUuidWithRepresentation() {
            let binary = MongoDBBinaryValue(data: Data(BsonUuidFixture.javaBytes), subtype: 0x03)
            let result = BsonDocumentFlattener.stringValue(for: binary, representation: .javaLegacy)
            #expect(result == "LegacyJavaUUID(\"\(BsonUuidFixture.uuidString)\")")
        }

        @Test("A legacy value read with the wrong representation does not produce the right UUID")
        func legacyUuidWithWrongRepresentation() {
            let binary = MongoDBBinaryValue(data: Data(BsonUuidFixture.javaBytes), subtype: 0x03)
            let result = BsonDocumentFlattener.stringValue(for: binary, representation: .pythonLegacy)
            #expect(result != "LegacyPythonUUID(\"\(BsonUuidFixture.uuidString)\")")
        }

        @Test("Dictionary returns compact sorted-key JSON")
        func dictValue() {
            let dict: [String: Any] = ["b": 2, "a": 1]
            let result = BsonDocumentFlattener.stringValue(for: dict, representation: .unspecified)
            #expect(result == "{\"a\":1,\"b\":2}")
        }

        @Test("Array returns compact JSON")
        func arrayValue() {
            let array: [Any] = [1, "two", 3]
            let result = BsonDocumentFlattener.stringValue(for: array, representation: .unspecified)
            #expect(result == "[1,\"two\",3]")
        }
    }

    // MARK: - serializeToJson(_:)

    @Suite("serializeToJson")
    struct SerializeToJsonTests {
        @Test("Simple dictionary produces compact JSON with sorted keys")
        func simpleDict() {
            let dict: [String: Any] = ["z": 1, "a": 2]
            let result = BsonDocumentFlattener.serializeToJson(dict, representation: .unspecified)
            #expect(result == "{\"a\":2,\"z\":1}")
        }

        @Test("Simple array produces compact JSON")
        func simpleArray() {
            let array: [Any] = [1, "hello", true]
            let result = BsonDocumentFlattener.serializeToJson(array, representation: .unspecified)
            #expect(result == "[1,\"hello\",true]")
        }

        @Test("Output is capped at 10k characters with ellipsis suffix")
        func capsAtTenThousandChars() {
            // Build a large dictionary that serializes to >10k chars
            var largeDict: [String: Any] = [:]
            for i in 0 ..< 2_000 {
                largeDict["key_\(String(format: "%04d", i))"] = String(repeating: "x", count: 10)
            }
            let result = BsonDocumentFlattener.serializeToJson(largeDict, representation: .unspecified)
            let nsResult = result as NSString
            #expect(nsResult.length <= 10_003) // 10000 + "..."
            #expect(result.hasSuffix("..."))
        }

        @Test("NaN double in a dictionary serializes to NaN token instead of crashing")
        func nanInDictionary() {
            let dict: [String: Any] = ["v": Double.nan]
            let result = BsonDocumentFlattener.serializeToJson(dict, representation: .unspecified)
            #expect(result == "{\"v\":\"NaN\"}")
        }

        @Test("Positive infinity in a dictionary serializes to Infinity token")
        func positiveInfinityInDictionary() {
            let dict: [String: Any] = ["v": Double.infinity]
            let result = BsonDocumentFlattener.serializeToJson(dict, representation: .unspecified)
            #expect(result == "{\"v\":\"Infinity\"}")
        }

        @Test("Negative infinity in a dictionary serializes to -Infinity token")
        func negativeInfinityInDictionary() {
            let dict: [String: Any] = ["v": -Double.infinity]
            let result = BsonDocumentFlattener.serializeToJson(dict, representation: .unspecified)
            #expect(result == "{\"v\":\"-Infinity\"}")
        }

        @Test("Non-finite double in an array keeps finite siblings as numbers")
        func nonFiniteInArray() {
            let array: [Any] = [Double.nan, 1.5, Double.infinity]
            let result = BsonDocumentFlattener.serializeToJson(array, representation: .unspecified)
            #expect(result == "[\"NaN\",1.5,\"Infinity\"]")
        }

        @Test("Unsupported nested type is stringified instead of crashing")
        func unsupportedTypeStringified() {
            struct Custom: CustomStringConvertible { var description: String { "custom" } }
            let dict: [String: Any] = ["v": Custom()]
            let result = BsonDocumentFlattener.serializeToJson(dict, representation: .unspecified)
            #expect(result == "{\"v\":\"custom\"}")
        }
    }
}

private enum FlattenFixture {
    static func kinds(
        _ documents: [[String: Any]],
        columns: [String],
        representation: MongoDBUuidRepresentation = .unspecified
    ) -> [BsonValueKind] {
        BsonDocumentFlattener.columnKinds(
            for: columns, documents: documents, representation: representation
        )
    }

    static func rows(
        _ documents: [[String: Any]],
        columns: [String],
        representation: MongoDBUuidRepresentation = .unspecified
    ) -> [[PluginCellValue]] {
        BsonDocumentFlattener.flatten(
            documents: documents,
            columns: columns,
            kinds: kinds(documents, columns: columns, representation: representation),
            representation: representation
        )
    }
}
