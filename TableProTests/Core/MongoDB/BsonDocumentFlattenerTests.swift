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

    // MARK: - flatten(documents:columns:)

    @Suite("flatten")
    struct FlattenTests {
        @Test("Single document with all columns present returns all values as strings")
        func allColumnsPresent() {
            let doc: [String: Any] = ["_id": "abc", "name": "John", "age": 30]
            let columns = ["_id", "name", "age"]
            let result = BsonDocumentFlattener.flatten(documents: [doc], columns: columns)
            #expect(result.count == 1)
            #expect(result[0] == ["abc", "John", "30"])
        }

        @Test("Missing field produces nil in that cell")
        func missingField() {
            let doc: [String: Any] = ["_id": "abc", "name": "John"]
            let columns = ["_id", "name", "email"]
            let result = BsonDocumentFlattener.flatten(documents: [doc], columns: columns)
            #expect(result[0][0] == "abc")
            #expect(result[0][1] == "John")
            #expect(result[0][2] == nil)
        }

        @Test("Nested object is serialized as compact JSON string")
        func nestedObject() {
            let nested: [String: Any] = ["city": "NYC", "zip": "10001"]
            let doc: [String: Any] = ["_id": "1", "address": nested]
            let columns = ["_id", "address"]
            let result = BsonDocumentFlattener.flatten(documents: [doc], columns: columns)
            #expect(result[0][0] == "1")
            // Keys are sorted in JSON output
            #expect(result[0][1] == "{\"city\":\"NYC\",\"zip\":\"10001\"}")
        }

        @Test("Array value is serialized as compact JSON string")
        func arrayValue() {
            let tags: [Any] = ["swift", "macos"]
            let doc: [String: Any] = ["_id": "1", "tags": tags]
            let columns = ["_id", "tags"]
            let result = BsonDocumentFlattener.flatten(documents: [doc], columns: columns)
            #expect(result[0][1] == "[\"swift\",\"macos\"]")
        }

        @Test("Boolean values are serialized as true/false strings")
        func booleanValue() {
            let doc: [String: Any] = ["_id": "1", "active": NSNumber(value: true)]
            let columns = ["_id", "active"]
            let result = BsonDocumentFlattener.flatten(documents: [doc], columns: columns)
            #expect(result[0][1] == "true")
        }

        @Test("Integer values are serialized as string representation")
        func integerValue() {
            let doc: [String: Any] = ["_id": "1", "count": 42]
            let columns = ["_id", "count"]
            let result = BsonDocumentFlattener.flatten(documents: [doc], columns: columns)
            #expect(result[0][1] == "42")
        }

        @Test("NSNull produces nil")
        func nsNullValue() {
            let doc: [String: Any] = ["_id": "1", "deleted": NSNull()]
            let columns = ["_id", "deleted"]
            let result = BsonDocumentFlattener.flatten(documents: [doc], columns: columns)
            #expect(result[0][1] == nil)
        }

        @Test("Date values are serialized as ISO8601 strings")
        func dateValue() {
            let date = Date(timeIntervalSince1970: 0)
            let doc: [String: Any] = ["_id": "1", "created": date]
            let columns = ["_id", "created"]
            let result = BsonDocumentFlattener.flatten(documents: [doc], columns: columns)
            let expected = ISO8601DateFormatter().string(from: date)
            #expect(result[0][1] == expected)
        }

        @Test("Nested non-finite double does not crash and renders as a token")
        func nestedNonFiniteDouble() {
            let metrics: [String: Any] = ["score": Double.nan, "ratio": Double.infinity]
            let doc: [String: Any] = ["_id": "1", "metrics": metrics]
            let columns = ["_id", "metrics"]
            let result = BsonDocumentFlattener.flatten(documents: [doc], columns: columns)
            #expect(result[0][1] == "{\"ratio\":\"Infinity\",\"score\":\"NaN\"}")
        }
    }

    // MARK: - columnTypes(for:documents:)

    @Suite("columnTypes")
    struct ColumnTypesTests {
        @Test("String values produce type code 2")
        func stringType() {
            let docs: [[String: Any]] = [["name": "Alice"], ["name": "Bob"]]
            let result = BsonDocumentFlattener.columnTypes(for: ["name"], documents: docs)
            #expect(result == [2])
        }

        @Test("Int32 values produce type code 16")
        func int32Type() {
            let docs: [[String: Any]] = [["val": Int32(42)], ["val": Int32(99)]]
            let result = BsonDocumentFlattener.columnTypes(for: ["val"], documents: docs)
            #expect(result == [16])
        }

        @Test("Int64 values produce type code 18")
        func int64Type() {
            let docs: [[String: Any]] = [["val": Int64(9_999_999_999)], ["val": Int64(1_234_567_890)]]
            let result = BsonDocumentFlattener.columnTypes(for: ["val"], documents: docs)
            #expect(result == [18])
        }

        @Test("Double values produce type code 1")
        func doubleType() {
            let docs: [[String: Any]] = [["val": 3.14], ["val": 2.71]]
            let result = BsonDocumentFlattener.columnTypes(for: ["val"], documents: docs)
            #expect(result == [1])
        }

        @Test("Boolean NSNumber values produce type code 8")
        func booleanType() {
            let docs: [[String: Any]] = [
                ["flag": NSNumber(value: true)],
                ["flag": NSNumber(value: false)]
            ]
            let result = BsonDocumentFlattener.columnTypes(for: ["flag"], documents: docs)
            #expect(result == [8])
        }

        @Test("Date values produce type code 9")
        func dateType() {
            let docs: [[String: Any]] = [["ts": Date()], ["ts": Date(timeIntervalSince1970: 0)]]
            let result = BsonDocumentFlattener.columnTypes(for: ["ts"], documents: docs)
            #expect(result == [9])
        }

        @Test("Dictionary values produce type code 3")
        func dictType() {
            let docs: [[String: Any]] = [
                ["meta": ["key": "value"] as [String: Any]],
                ["meta": ["a": 1] as [String: Any]]
            ]
            let result = BsonDocumentFlattener.columnTypes(for: ["meta"], documents: docs)
            #expect(result == [3])
        }

        @Test("Array values produce type code 4")
        func arrayType() {
            let docs: [[String: Any]] = [
                ["tags": ["a", "b"] as [Any]],
                ["tags": [1, 2] as [Any]]
            ]
            let result = BsonDocumentFlattener.columnTypes(for: ["tags"], documents: docs)
            #expect(result == [4])
        }

        @Test("Missing field with no values defaults to type code 2")
        func missingFieldDefaultsToString() {
            let docs: [[String: Any]] = [["other": "val"], ["other": "val2"]]
            let result = BsonDocumentFlattener.columnTypes(for: ["nonexistent"], documents: docs)
            #expect(result == [2])
        }

        @Test("Majority vote: 2 strings and 1 int yields type code 2")
        func majorityVote() {
            let docs: [[String: Any]] = [
                ["val": "hello"],
                ["val": "world"],
                ["val": Int32(42)]
            ]
            let result = BsonDocumentFlattener.columnTypes(for: ["val"], documents: docs)
            #expect(result == [2])
        }
    }

    // MARK: - stringValue(for:)

    @Suite("stringValue")
    struct StringValueTests {
        @Test("nil returns nil")
        func nilValue() {
            let result = BsonDocumentFlattener.stringValue(for: nil)
            #expect(result == nil)
        }

        @Test("NSNull returns nil")
        func nsNullValue() {
            let result = BsonDocumentFlattener.stringValue(for: NSNull())
            #expect(result == nil)
        }

        @Test("String returns itself")
        func stringValue() {
            let result = BsonDocumentFlattener.stringValue(for: "hello")
            #expect(result == "hello")
        }

        @Test("Int returns string representation")
        func intValue() {
            let result = BsonDocumentFlattener.stringValue(for: 42)
            #expect(result == "42")
        }

        @Test("Int32 returns string representation")
        func int32Value() {
            let result = BsonDocumentFlattener.stringValue(for: Int32(42))
            #expect(result == "42")
        }

        @Test("Int64 returns string representation")
        func int64Value() {
            let result = BsonDocumentFlattener.stringValue(for: Int64(9_999_999_999))
            #expect(result == "9999999999")
        }

        @Test("Double returns string representation")
        func doubleValue() {
            let result = BsonDocumentFlattener.stringValue(for: 3.14)
            #expect(result == "3.14")
        }

        @Test("NaN double returns NaN token")
        func nanValue() {
            let result = BsonDocumentFlattener.stringValue(for: Double.nan)
            #expect(result == "NaN")
        }

        @Test("Positive infinity returns Infinity token")
        func positiveInfinityValue() {
            let result = BsonDocumentFlattener.stringValue(for: Double.infinity)
            #expect(result == "Infinity")
        }

        @Test("Negative infinity returns -Infinity token")
        func negativeInfinityValue() {
            let result = BsonDocumentFlattener.stringValue(for: -Double.infinity)
            #expect(result == "-Infinity")
        }

        @Test("Bool true via NSNumber returns true")
        func boolTrueValue() {
            let result = BsonDocumentFlattener.stringValue(for: NSNumber(value: true))
            #expect(result == "true")
        }

        @Test("Bool false via NSNumber returns false")
        func boolFalseValue() {
            let result = BsonDocumentFlattener.stringValue(for: NSNumber(value: false))
            #expect(result == "false")
        }

        @Test("Date returns ISO8601 string")
        func dateValue() {
            let date = Date(timeIntervalSince1970: 0)
            let result = BsonDocumentFlattener.stringValue(for: date)
            let expected = ISO8601DateFormatter().string(from: date)
            #expect(result == expected)
        }

        @Test("Data returns BinData format string")
        func dataValue() {
            let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
            let result = BsonDocumentFlattener.stringValue(for: data)
            #expect(result == "BinData(4, \"3q2+7w==\")")
        }

        @Test("16-byte Data returns UUID format string")
        func uuidDataValue() {
            let data = Data([
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10
            ])
            let result = BsonDocumentFlattener.stringValue(for: data)
            #expect(result == "UUID(\"01020304-0506-0708-090a-0b0c0d0e0f10\")")
        }

        @Test("Dictionary returns compact sorted-key JSON")
        func dictValue() {
            let dict: [String: Any] = ["b": 2, "a": 1]
            let result = BsonDocumentFlattener.stringValue(for: dict)
            #expect(result == "{\"a\":1,\"b\":2}")
        }

        @Test("Array returns compact JSON")
        func arrayValue() {
            let array: [Any] = [1, "two", 3]
            let result = BsonDocumentFlattener.stringValue(for: array)
            #expect(result == "[1,\"two\",3]")
        }
    }

    // MARK: - serializeToJson(_:)

    @Suite("serializeToJson")
    struct SerializeToJsonTests {
        @Test("Simple dictionary produces compact JSON with sorted keys")
        func simpleDict() {
            let dict: [String: Any] = ["z": 1, "a": 2]
            let result = BsonDocumentFlattener.serializeToJson(dict)
            #expect(result == "{\"a\":2,\"z\":1}")
        }

        @Test("Simple array produces compact JSON")
        func simpleArray() {
            let array: [Any] = [1, "hello", true]
            let result = BsonDocumentFlattener.serializeToJson(array)
            #expect(result == "[1,\"hello\",true]")
        }

        @Test("Output is capped at 10k characters with ellipsis suffix")
        func capsAtTenThousandChars() {
            // Build a large dictionary that serializes to >10k chars
            var largeDict: [String: Any] = [:]
            for i in 0 ..< 2_000 {
                largeDict["key_\(String(format: "%04d", i))"] = String(repeating: "x", count: 10)
            }
            let result = BsonDocumentFlattener.serializeToJson(largeDict)
            let nsResult = result as NSString
            #expect(nsResult.length <= 10_003) // 10000 + "..."
            #expect(result.hasSuffix("..."))
        }

        @Test("NaN double in a dictionary serializes to NaN token instead of crashing")
        func nanInDictionary() {
            let dict: [String: Any] = ["v": Double.nan]
            let result = BsonDocumentFlattener.serializeToJson(dict)
            #expect(result == "{\"v\":\"NaN\"}")
        }

        @Test("Positive infinity in a dictionary serializes to Infinity token")
        func positiveInfinityInDictionary() {
            let dict: [String: Any] = ["v": Double.infinity]
            let result = BsonDocumentFlattener.serializeToJson(dict)
            #expect(result == "{\"v\":\"Infinity\"}")
        }

        @Test("Negative infinity in a dictionary serializes to -Infinity token")
        func negativeInfinityInDictionary() {
            let dict: [String: Any] = ["v": -Double.infinity]
            let result = BsonDocumentFlattener.serializeToJson(dict)
            #expect(result == "{\"v\":\"-Infinity\"}")
        }

        @Test("Non-finite double in an array keeps finite siblings as numbers")
        func nonFiniteInArray() {
            let array: [Any] = [Double.nan, 1.5, Double.infinity]
            let result = BsonDocumentFlattener.serializeToJson(array)
            #expect(result == "[\"NaN\",1.5,\"Infinity\"]")
        }

        @Test("Unsupported nested type is stringified instead of crashing")
        func unsupportedTypeStringified() {
            struct Custom: CustomStringConvertible { var description: String { "custom" } }
            let dict: [String: Any] = ["v": Custom()]
            let result = BsonDocumentFlattener.serializeToJson(dict)
            #expect(result == "{\"v\":\"custom\"}")
        }
    }
}

// MARK: - Local copy of BsonDocumentFlattener

/// Local copy of BsonDocumentFlattener for testing purposes.
/// The actual implementation lives in the MongoDBDriverPlugin bundle.
private struct BsonDocumentFlattener {
    static func unionColumns(from documents: [[String: Any]]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for doc in documents {
            if doc["_id"] != nil && !seen.contains("_id") {
                seen.insert("_id")
                ordered.append("_id")
                break
            }
        }

        for doc in documents {
            for key in doc.keys.sorted() {
                if !seen.contains(key) {
                    seen.insert(key)
                    ordered.append(key)
                }
            }
        }

        return ordered
    }

    static func flatten(documents: [[String: Any]], columns: [String]) -> [[String?]] {
        documents.map { doc in
            columns.map { column in
                guard let value = doc[column] else { return nil }
                return stringValue(for: value)
            }
        }
    }

    static func columnTypes(for columns: [String], documents: [[String: Any]]) -> [Int32] {
        columns.map { column in
            inferBsonType(for: column, in: documents)
        }
    }

    static func stringValue(for value: Any?) -> String? {
        guard let value = value else { return nil }

        if value is NSNull { return nil }

        switch value {
        case let str as String:
            return str
        case let num as NSNumber:
            return displayString(for: num)
        case let date as Date:
            return iso8601Formatter.string(from: date)
        case let data as Data:
            return formatBinaryData(data)
        case let dict as [String: Any]:
            if let code = dict["$code"] as? String {
                if let scope = dict["$scope"] as? [String: Any] {
                    return "Code(\"\(code)\", \(serializeToJson(scope)))"
                }
                return "Code(\"\(code)\")"
            }
            if let ref = dict["$ref"] as? String, let id = dict["$id"] {
                let idStr = stringValue(for: id) ?? String(describing: id)
                if let db = dict["$db"] as? String {
                    return "DBRef(\"\(ref)\", \(idStr), \"\(db)\")"
                }
                return "DBRef(\"\(ref)\", \(idStr))"
            }
            return serializeToJson(dict)
        case let array as [Any]:
            return serializeToJson(array)
        default:
            return String(describing: value)
        }
    }

    static func serializeToJson(_ value: Any) -> String {
        let sanitized = sanitizeForJson(value)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        let nsJson = json as NSString
        if nsJson.length > 10_000 {
            return String(json.prefix(10_000)) + "..."
        }
        return json
    }

    static func sanitizeForJson(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { sanitizeForJson($0) }
        case let array as [Any]:
            return array.map { sanitizeForJson($0) }
        case let data as Data:
            return formatBinaryData(data)
        case let date as Date:
            return iso8601Formatter.string(from: date)
        case is NSNull:
            return value
        case let str as String:
            return str
        case let num as NSNumber:
            return sanitizeNumber(num)
        default:
            return String(describing: value)
        }
    }

    private static let iso8601Formatter = ISO8601DateFormatter()

    private static func displayString(for num: NSNumber) -> String {
        if isBoolean(num) {
            return num.boolValue ? "true" : "false"
        }
        if isFloatingPoint(num), !num.doubleValue.isFinite {
            return nonFiniteToken(num.doubleValue)
        }
        return num.stringValue
    }

    private static func sanitizeNumber(_ num: NSNumber) -> Any {
        guard !isBoolean(num) else { return num }
        guard isFloatingPoint(num), !num.doubleValue.isFinite else { return num }
        return nonFiniteToken(num.doubleValue)
    }

    private static func isBoolean(_ num: NSNumber) -> Bool {
        CFBooleanGetTypeID() == CFGetTypeID(num)
    }

    private static func isFloatingPoint(_ num: NSNumber) -> Bool {
        let objCType = String(cString: num.objCType)
        return objCType == "d" || objCType == "f"
    }

    private static func nonFiniteToken(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        return value > 0 ? "Infinity" : "-Infinity"
    }

    private static func formatBinaryData(_ data: Data) -> String {
        if data.count == 16 {
            let uuid = UUID(uuid: (
                data[0], data[1], data[2], data[3],
                data[4], data[5], data[6], data[7],
                data[8], data[9], data[10], data[11],
                data[12], data[13], data[14], data[15]
            ))
            return "UUID(\"\(uuid.uuidString.lowercased())\")"
        }
        return "BinData(\(data.count), \"\(data.base64EncodedString())\")"
    }

    private static func inferBsonType(for field: String, in documents: [[String: Any]]) -> Int32 {
        var typeCounts: [Int32: Int] = [:]

        for doc in documents {
            guard let value = doc[field] else { continue }
            if value is NSNull { continue }

            let type = bsonTypeCode(for: value)
            typeCounts[type, default: 0] += 1
        }

        return typeCounts.max(by: { $0.value < $1.value })?.key ?? 2
    }

    private static func bsonTypeCode(for value: Any) -> Int32 {
        if value is NSNull { return 10 }

        switch value {
        case let num as NSNumber:
            if isBoolean(num) {
                return 8
            }
            if isFloatingPoint(num) {
                return 1
            }
            let objCType = String(cString: num.objCType)
            return objCType == "q" || objCType == "l" ? 18 : 16
        case is String:
            return 2
        case is Date:
            return 9
        case is Data:
            return 5
        case is [String: Any]:
            return 3
        case is [Any]:
            return 4
        default:
            return 2
        }
    }
}
