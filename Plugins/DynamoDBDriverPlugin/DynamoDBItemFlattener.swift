//
//  DynamoDBItemFlattener.swift
//  DynamoDBDriverPlugin
//
//  Converts DynamoDB items to flat tabular rows for display.
//

import Foundation

struct DynamoDBItemFlattener {
    /// Maximum serialized JSON length for nested values
    private static let maxNestedJsonLength = 10_000

    // MARK: - Column Discovery

    /// Union of all attribute names across items.
    /// Key schema columns come first, then remaining columns sorted alphabetically.
    static func unionColumns(
        from items: [[String: DynamoDBAttributeValue]],
        keySchema: [(name: String, keyType: String)]
    ) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        // Key columns first: HASH then RANGE
        let sortedKeys = keySchema.sorted { lhs, _ in lhs.keyType == "HASH" }
        for key in sortedKeys {
            if !seen.contains(key.name) {
                seen.insert(key.name)
                ordered.append(key.name)
            }
        }

        // Collect all other attribute names across all items
        var remaining = Set<String>()
        for item in items {
            for key in item.keys where !seen.contains(key) {
                remaining.insert(key)
            }
        }

        // Append remaining sorted alphabetically
        ordered.append(contentsOf: remaining.sorted())

        return ordered
    }

    // MARK: - Flattening

    /// Convert items to a 2D grid of string values. Missing attributes become nil.
    static func flatten(items: [[String: DynamoDBAttributeValue]], columns: [String]) -> [[String?]] {
        items.map { item in
            columns.map { column in
                guard let value = item[column] else { return nil }
                return attributeValueToString(value)
            }
        }
    }

    // MARK: - Type Inference

    /// Majority-vote type name for each column across all items.
    static func columnTypeNames(for columns: [String], items: [[String: DynamoDBAttributeValue]]) -> [String] {
        columns.map { column in
            var typeCounts: [String: Int] = [:]
            for item in items {
                guard let value = item[column] else { continue }
                let typeName = typeNameForValue(value)
                typeCounts[typeName, default: 0] += 1
            }
            return typeCounts.max(by: { $0.value < $1.value })?.key ?? "S"
        }
    }

    // MARK: - Value Serialization

    /// Serialize a single DynamoDB attribute value to its display string.
    static func attributeValueToString(_ value: DynamoDBAttributeValue) -> String {
        switch value {
        case .string(let s):
            return s
        case .number(let n):
            return n
        case .binary(let data):
            return data.base64EncodedString()
        case .bool(let b):
            return b ? "true" : "false"
        case .null:
            return "NULL"
        case .list(let items):
            return serializeToJson(listToTypedEnvelopes(items))
        case .map(let map):
            return serializeToJson(mapToTypedEnvelopes(map))
        case .stringSet(let values):
            return serializeToJson(values)
        case .numberSet(let values):
            return serializeToJson(values)
        case .binarySet(let values):
            return serializeToJson(values.map { $0.base64EncodedString() })
        }
    }

    /// Reverse conversion: parse a display string back to a DynamoDBAttributeValue,
    /// using the type hint to determine the correct type.
    static func stringToAttributeValue(_ string: String?, typeHint: String) -> DynamoDBAttributeValue? {
        guard let string = string else { return .null }

        switch typeHint {
        case "S":
            return .string(string)
        case "N":
            return .number(string)
        case "B":
            if let data = Data(base64Encoded: string) {
                return .binary(data)
            }
            return .binary(Data(string.utf8))
        case "BOOL":
            let lower = string.lowercased()
            return .bool(lower == "true" || lower == "1")
        case "NULL":
            return .null
        case "L":
            if let data = string.data(using: .utf8),
               let array = try? JSONDecoder().decode([DynamoDBAttributeValue].self, from: data)
            {
                return .list(array)
            }
            return .string(string)
        case "M":
            if let data = string.data(using: .utf8),
               let map = try? JSONDecoder().decode([String: DynamoDBAttributeValue].self, from: data)
            {
                return .map(map)
            }
            return .string(string)
        case "SS":
            if let data = string.data(using: .utf8),
               let values = try? JSONSerialization.jsonObject(with: data) as? [String]
            {
                return .stringSet(values)
            }
            return .stringSet([string])
        case "NS":
            if let data = string.data(using: .utf8),
               let values = try? JSONSerialization.jsonObject(with: data) as? [String]
            {
                return .numberSet(values)
            }
            return .numberSet([string])
        case "BS":
            if let data = string.data(using: .utf8),
               let values = try? JSONSerialization.jsonObject(with: data) as? [String]
            {
                return .binarySet(values.compactMap { Data(base64Encoded: $0) })
            }
            return .string(string)
        default:
            return .string(string)
        }
    }

    // MARK: - Private Helpers

    private static func typeNameForValue(_ value: DynamoDBAttributeValue) -> String {
        switch value {
        case .string: return "S"
        case .number: return "N"
        case .binary: return "B"
        case .bool: return "BOOL"
        case .null: return "NULL"
        case .list: return "L"
        case .map: return "M"
        case .stringSet: return "SS"
        case .numberSet: return "NS"
        case .binarySet: return "BS"
        }
    }

    private static func listToJson(_ items: [DynamoDBAttributeValue]) -> [Any] {
        items.map { valueToJsonPrimitive($0) }
    }

    private static func mapToJson(_ map: [String: DynamoDBAttributeValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in map {
            result[key] = valueToJsonPrimitive(value)
        }
        return result
    }

    /// Convert a list to DynamoDB-typed envelope format (e.g., [{"S":"val"},{"N":"123"}])
    /// so that `stringToAttributeValue` can round-trip correctly.
    private static func listToTypedEnvelopes(_ items: [DynamoDBAttributeValue]) -> [Any] {
        items.map { valueToTypedEnvelope($0) }
    }

    /// Convert a map to DynamoDB-typed envelope format (e.g., {"k":{"S":"val"}})
    /// so that `stringToAttributeValue` can round-trip correctly.
    private static func mapToTypedEnvelopes(_ map: [String: DynamoDBAttributeValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in map {
            result[key] = valueToTypedEnvelope(value)
        }
        return result
    }

    /// Wrap a single DynamoDBAttributeValue in its DynamoDB JSON type envelope.
    private static func valueToTypedEnvelope(_ value: DynamoDBAttributeValue) -> [String: Any] {
        switch value {
        case .string(let s):
            return ["S": s]
        case .number(let n):
            return ["N": n]
        case .binary(let data):
            return ["B": data.base64EncodedString()]
        case .bool(let b):
            return ["BOOL": b]
        case .null:
            return ["NULL": true]
        case .list(let items):
            return ["L": listToTypedEnvelopes(items)]
        case .map(let map):
            return ["M": mapToTypedEnvelopes(map)]
        case .stringSet(let values):
            return ["SS": values]
        case .numberSet(let values):
            return ["NS": values]
        case .binarySet(let values):
            return ["BS": values.map { $0.base64EncodedString() }]
        }
    }

    private static func valueToJsonPrimitive(_ value: DynamoDBAttributeValue) -> Any {
        switch value {
        case .string(let s):
            return s
        case .number(let n):
            if let intVal = Int64(n) {
                return intVal
            }
            if let dblVal = Double(n) {
                return dblVal
            }
            return n
        case .binary(let data):
            return data.base64EncodedString()
        case .bool(let b):
            return b
        case .null:
            return NSNull()
        case .list(let items):
            return listToJson(items)
        case .map(let map):
            return mapToJson(map)
        case .stringSet(let values):
            return values
        case .numberSet(let values):
            return values.map { str -> Any in
                if let intVal = Int64(str) { return intVal }
                if let dblVal = Double(str) { return dblVal }
                return str
            }
        case .binarySet(let values):
            return values.map { $0.base64EncodedString() }
        }
    }

    private static func serializeToJson(_ value: Any) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            if let json = String(data: data, encoding: .utf8) {
                let nsJson = json as NSString
                if nsJson.length > maxNestedJsonLength {
                    return String(json.prefix(maxNestedJsonLength)) + "..."
                }
                return json
            }
        } catch {
            // Fall through
        }
        return String(describing: value)
    }
}
