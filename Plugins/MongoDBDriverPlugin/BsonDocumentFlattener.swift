//
//  BsonDocumentFlattener.swift
//  TablePro
//
//  Converts MongoDB documents into flat tabular format for QueryResult.
//  Handles schema-less documents by unioning all field names across documents.
//

import Foundation

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
    static func flatten(documents: [[String: Any]], columns: [String]) -> [[String?]] {
        documents.map { doc in
            columns.map { column in
                guard let value = doc[column] else { return nil }
                return stringValue(for: value)
            }
        }
    }

    /// Infer ColumnType for each column by majority-vote over document values.
    static func columnTypes(for columns: [String], documents: [[String: Any]]) -> [Int32] {
        columns.map { column in
            inferBsonType(for: column, in: documents)
        }
    }

    // MARK: - Value Serialization

    /// Serialize a single value to its display string representation
    static func stringValue(for value: Any?) -> String? {
        guard let value = value else { return nil }

        if value is NSNull { return nil }

        switch value {
        case let str as String:
            return str
        case let num as NSNumber:
            // Check if it's a boolean (NSNumber wraps booleans too)
            if CFBooleanGetTypeID() == CFGetTypeID(num) {
                return num.boolValue ? "true" : "false"
            }
            return num.stringValue
        case let int as Int:
            return String(int)
        case let int32 as Int32:
            return String(int32)
        case let int64 as Int64:
            return String(int64)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return bool ? "true" : "false"
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let data as Data:
            return formatBinaryData(data)
        case let dict as [String: Any]:
            // Code type: {"$code": "function() {...}"}
            if let code = dict["$code"] as? String {
                if let scope = dict["$scope"] as? [String: Any] {
                    return "Code(\"\(code)\", \(serializeToJson(scope)))"
                }
                return "Code(\"\(code)\")"
            }
            // DBRef convention: {"$ref": "collection", "$id": "..."}
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

    // MARK: - JSON Serialization

    /// Serialize a dictionary or array to compact JSON string
    static func serializeToJson(_ value: Any) -> String {
        let sanitized = sanitizeForJson(value)
        do {
            let data = try JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys])
            if let json = String(data: data, encoding: .utf8) {
                // Cap at 10k chars to prevent mega-document display issues
                let nsJson = json as NSString
                if nsJson.length > 10_000 {
                    return String(json.prefix(10_000)) + "..."
                }
                return json
            }
        } catch {
            // Fall through to description
        }
        return String(describing: value)
    }

    /// Recursively convert non-JSON-safe types (Data, Date, etc.) to JSON-safe representations
    private static func sanitizeForJson(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { sanitizeForJson($0) }
        case let array as [Any]:
            return array.map { sanitizeForJson($0) }
        case let data as Data:
            return formatBinaryData(data)
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        default:
            return value
        }
    }

    /// Format binary data: 16-byte values as UUID, otherwise as hex string
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

    // MARK: - Type Inference

    /// Infer the most common BSON type code for a field across all documents.
    /// Returns BSON type integer: 1=Double, 2=String, 3=Document, 4=Array,
    /// 5=Binary, 7=ObjectId, 8=Boolean, 9=Date, 10=Null, 16=Int32, 18=Int64
    private static func inferBsonType(for field: String, in documents: [[String: Any]]) -> Int32 {
        var typeCounts: [Int32: Int] = [:]

        for doc in documents {
            guard let value = doc[field] else { continue }
            if value is NSNull { continue }

            let type = bsonTypeCode(for: value)
            typeCounts[type, default: 0] += 1
        }

        // Return most common type, default to String (2) if no values found
        return typeCounts.max(by: { $0.value < $1.value })?.key ?? 2
    }

    /// Map a Swift value to its approximate BSON type code
    private static func bsonTypeCode(for value: Any) -> Int32 {
        if value is NSNull { return 10 } // Null

        switch value {
        case let num as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(num) {
                return 8 // Boolean
            }
            let objCType = String(cString: num.objCType)
            if objCType == "d" || objCType == "f" {
                return 1 // Double
            }
            if objCType == "q" || objCType == "l" {
                return 18 // Int64
            }
            return 16 // Int32
        case is String:
            return 2 // String
        case is Bool:
            return 8 // Boolean
        case is Int, is Int32:
            return 16 // Int32
        case is Int64:
            return 18 // Int64
        case is Double, is Float:
            return 1 // Double
        case is Date:
            return 9 // Date
        case is Data:
            return 5 // Binary
        case is [String: Any]:
            return 3 // Document
        case is [Any]:
            return 4 // Array
        default:
            return 2 // Default to String
        }
    }
}
