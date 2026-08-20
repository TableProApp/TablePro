//
//  BsonDocumentFlattener.swift
//  TablePro
//
//  Converts MongoDB documents into flat tabular format for QueryResult.
//  Handles schema-less documents by unioning all field names across documents.
//

import Foundation
import TableProNumberFormatting
import TableProPluginKit

enum BsonValueKind: Hashable {
    case double
    case string
    case document
    case array
    case binary(subtype: UInt8)
    case boolean
    case date
    case null
    case int32
    case int64
    case objectId
    case uuid
    case legacyUuid

    var isUuid: Bool {
        switch self {
        case .uuid, .legacyUuid: return true
        default: return false
        }
    }
}

struct BsonDocumentFlattener {
    // MARK: - Public API

    /// Union of all field names across all documents.
    /// `_id` is always first, then other fields in first-seen order.
    static func unionColumns(from documents: [[String: Any]]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        // Ensure _id is always first if present
        for doc in documents {
            if doc["_id"] != nil && !seen.contains("_id") {
                seen.insert("_id")
                ordered.append("_id")
                break
            }
        }

        // Collect all other fields in first-seen order
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

    /// Flatten documents into a grid. Missing fields become nil cells.
    /// Nested objects/arrays are serialized as compact JSON strings.
    static func flatten(
        documents: [[String: Any]],
        columns: [String],
        kinds: [BsonValueKind],
        representation: MongoDBUuidRepresentation
    ) -> [[PluginCellValue]] {
        documents.map { doc in
            columns.enumerated().map { index, column in
                guard let value = doc[column] else { return PluginCellValue.null }
                let kind = index < kinds.count ? kinds[index] : .string
                return cellValue(for: value, kind: kind, representation: representation)
            }
        }
    }

    /// Infer the dominant value kind for each column by majority-vote over document values.
    static func columnKinds(
        for columns: [String],
        documents: [[String: Any]],
        representation: MongoDBUuidRepresentation
    ) -> [BsonValueKind] {
        columns.map { column in
            inferValueKind(for: column, in: documents, representation: representation)
        }
    }

    static func cellValue(
        for value: Any,
        kind: BsonValueKind,
        representation: MongoDBUuidRepresentation
    ) -> PluginCellValue {
        if let binary = value as? MongoDBBinaryValue {
            guard kind.isUuid,
                  let text = MongoDBUuidCodec.decodedText(for: binary, representation: representation) else {
                return .bytes(binary.data)
            }
            return .text(text)
        }
        if let data = value as? Data {
            return .bytes(data)
        }
        return PluginCellValue.fromOptional(stringValue(for: value, representation: representation))
    }

    static func typeName(for kind: BsonValueKind, representation: MongoDBUuidRepresentation) -> String {
        switch kind {
        case .double: return "FLOAT"
        case .string, .null: return "VARCHAR"
        case .document, .array: return "JSON"
        case .binary(let subtype): return MongoDBUuidCodec.columnTypeName(forSubtype: subtype)
        case .boolean: return "BOOLEAN"
        case .date: return "TIMESTAMP"
        case .int32: return "INTEGER"
        case .int64: return "BIGINT"
        case .objectId: return "ObjectId"
        case .uuid:
            return MongoDBUuidCodec.wrapperTag(
                forSubtype: MongoDBUuidCodec.standardUuidSubtype, representation: representation
            ) ?? "BLOB"
        case .legacyUuid:
            return MongoDBUuidCodec.wrapperTag(
                forSubtype: MongoDBUuidCodec.legacyUuidSubtype, representation: representation
            ) ?? "BLOB"
        }
    }

    // MARK: - Value Serialization

    /// Serialize a single value to its display string representation
    static func stringValue(for value: Any?, representation: MongoDBUuidRepresentation) -> String? {
        guard let value = value else { return nil }

        if value is NSNull { return nil }

        switch value {
        case let str as String:
            return str
        case let num as NSNumber:
            return displayString(for: num)
        case let date as Date:
            return iso8601Formatter.string(from: date)
        case let objectId as MongoDBObjectId:
            return objectId.hex
        case let binary as MongoDBBinaryValue:
            return binaryString(for: binary, representation: representation)
        case let data as Data:
            return MongoDBUuidCodec.binaryText(for: MongoDBBinaryValue(data: data, subtype: 0))
        case let dict as [String: Any]:
            // Code type: {"$code": "function() {...}"}
            if let code = dict["$code"] as? String {
                if let scope = dict["$scope"] as? [String: Any] {
                    return "Code(\"\(code)\", \(serializeToJson(scope, representation: representation)))"
                }
                return "Code(\"\(code)\")"
            }
            // DBRef convention: {"$ref": "collection", "$id": "..."}
            if let ref = dict["$ref"] as? String, let id = dict["$id"] {
                let idStr = stringValue(for: id, representation: representation) ?? String(describing: id)
                if let db = dict["$db"] as? String {
                    return "DBRef(\"\(ref)\", \(idStr), \"\(db)\")"
                }
                return "DBRef(\"\(ref)\", \(idStr))"
            }
            return serializeToJson(dict, representation: representation)
        case let array as [Any]:
            return serializeToJson(array, representation: representation)
        default:
            return String(describing: value)
        }
    }

    private static func binaryString(
        for binary: MongoDBBinaryValue,
        representation: MongoDBUuidRepresentation
    ) -> String {
        MongoDBUuidCodec.decodedText(for: binary, representation: representation)
            ?? MongoDBUuidCodec.binaryText(for: binary)
    }

    // MARK: - JSON Serialization

    /// Serialize a dictionary or array to compact JSON string
    static func serializeToJson(_ value: Any, representation: MongoDBUuidRepresentation) -> String {
        let sanitized = sanitizeForJson(value, representation: representation)
        guard let json = NumberText.json(from: sanitized) else {
            return String(describing: value)
        }
        let nsJson = json as NSString
        if nsJson.length > 10_000 {
            return String(json.prefix(10_000)) + "..."
        }
        return json
    }

    /// Recursively convert every value into a JSON-safe representation
    static func sanitizeForJson(_ value: Any, representation: MongoDBUuidRepresentation) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { sanitizeForJson($0, representation: representation) }
        case let array as [Any]:
            return array.map { sanitizeForJson($0, representation: representation) }
        case let objectId as MongoDBObjectId:
            return objectId.hex
        case let binary as MongoDBBinaryValue:
            return binaryString(for: binary, representation: representation)
        case let data as Data:
            return MongoDBUuidCodec.binaryText(for: MongoDBBinaryValue(data: data, subtype: 0))
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
        return NumberText.text(for: num)
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

    // MARK: - Nested Field Paths

    /// Dotted paths across the sampled documents, including paths inside nested objects and
    /// inside the objects an array holds. This is deliberately separate from `unionColumns`,
    /// which stays flat because the grid renders a nested object as one JSON column.
    static func fieldPaths(
        from documents: [[String: Any]],
        representation: MongoDBUuidRepresentation,
        maxDepth: Int = 4
    ) -> [PluginFieldPath] {
        var kinds: [String: [BsonValueKind: Int]] = [:]
        var depths: [String: Int] = [:]
        var order: [String] = []

        func visit(_ document: [String: Any], prefix: String, depth: Int) {
            guard depth <= maxDepth else { return }

            for key in document.keys.sorted() {
                guard let value = document[key], !(value is NSNull) else { continue }
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"

                if depths[path] == nil {
                    depths[path] = depth
                    order.append(path)
                }
                kinds[path, default: [:]][valueKind(for: value, representation: representation), default: 0] += 1

                if let nested = value as? [String: Any] {
                    visit(nested, prefix: path, depth: depth + 1)
                } else if let array = value as? [Any] {
                    for element in array.prefix(20) {
                        guard let nested = element as? [String: Any] else { continue }
                        visit(nested, prefix: path, depth: depth + 1)
                    }
                }
            }
        }

        for document in documents {
            visit(document, prefix: "", depth: 1)
        }

        return order.compactMap { path in
            guard let winner = kinds[path]?.max(by: { $0.value < $1.value })?.key,
                  let depth = depths[path] else { return nil }
            return PluginFieldPath(
                path: path,
                typeName: typeName(for: winner, representation: representation),
                depth: depth
            )
        }
    }

    // MARK: - Type Inference

    private static func inferValueKind(
        for field: String,
        in documents: [[String: Any]],
        representation: MongoDBUuidRepresentation
    ) -> BsonValueKind {
        var counts: [BsonValueKind: Int] = [:]

        for doc in documents {
            guard let value = doc[field] else { continue }
            if value is NSNull { continue }
            counts[valueKind(for: value, representation: representation), default: 0] += 1
        }

        return counts.max(by: { $0.value < $1.value })?.key ?? .string
    }

    private static func valueKind(for value: Any, representation: MongoDBUuidRepresentation) -> BsonValueKind {
        if value is NSNull { return .null }

        switch value {
        case let num as NSNumber:
            if isBoolean(num) {
                return .boolean
            }
            if isFloatingPoint(num) {
                return .double
            }
            let objCType = String(cString: num.objCType)
            return objCType == "q" || objCType == "l" ? .int64 : .int32
        case is String:
            return .string
        case is MongoDBObjectId:
            return .objectId
        case is Date:
            return .date
        case let binary as MongoDBBinaryValue:
            guard MongoDBUuidCodec.isDecodableUuid(binary, representation: representation) else {
                return .binary(subtype: binary.subtype)
            }
            return binary.subtype == MongoDBUuidCodec.standardUuidSubtype ? .uuid : .legacyUuid
        case is Data:
            return .binary(subtype: 0)
        case is [String: Any]:
            return .document
        case is [Any]:
            return .array
        default:
            return .string
        }
    }
}
