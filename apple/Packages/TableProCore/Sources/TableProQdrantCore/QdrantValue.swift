import Foundation

public enum QdrantValueError: Error, LocalizedError, Equatable, Sendable {
    case notAnInteger(column: String, value: String)
    case notANumber(column: String, value: String)
    case notABoolean(column: String, value: String)
    case notAGeoPoint(column: String)
    case notAnObject(column: String)
    case notAnArray(column: String)
    case notAVector(column: String)
    case notAMultivector(column: String)
    case notASparseVector(column: String)

    public var errorDescription: String? {
        switch self {
        case .notAnInteger(let column, let value):
            return String(format: String(localized: "%@ holds integers, and %@ is not one."), column, value)
        case .notANumber(let column, let value):
            return String(format: String(localized: "%@ holds numbers, and %@ is not a number."), column, value)
        case .notABoolean(let column, let value):
            return String(format: String(localized: "%@ holds booleans, so it takes true or false, not %@."), column, value)
        case .notAGeoPoint(let column):
            return String(format: String(localized: "%@ holds geo points, written as {\"lon\": 13.4, \"lat\": 52.5}."), column)
        case .notAnObject(let column):
            return String(format: String(localized: "%@ holds JSON objects, written as {\"key\": \"value\"}."), column)
        case .notAnArray(let column):
            return String(format: String(localized: "%@ holds JSON arrays, written as [1, 2, 3]."), column)
        case .notAVector(let column):
            return String(format: String(localized: "%@ is a vector, written as an array of numbers such as [0.1, 0.2]."), column)
        case .notAMultivector(let column):
            return String(format: String(localized: "%@ is a multivector, written as arrays of numbers such as [[0.1, 0.2], [0.3, 0.4]]."), column)
        case .notASparseVector(let column):
            return String(format: String(localized: "%@ is a sparse vector, written as {\"indices\": [1, 5], \"values\": [0.2, 0.7]}."), column)
        }
    }
}

// The grid's text becomes the JSON type its column holds. Parsing every cell as JSON would turn a
// keyword holding `42` into a number and stop `match` from finding it.
public enum QdrantValue {
    // The grid's boolean menu offers 1 and 0 to an engine without a SQL dialect.
    public static func bool(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    public static func integer(_ text: String) -> Int64? {
        Int64(text.trimmingCharacters(in: .whitespaces))
    }

    public static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    public static func payload(_ text: String, cellType: QdrantCellType, column: String) throws -> Any {
        if cellType.allowsList, let list = QdrantJSON.parse(text) as? [Any] {
            return list
        }
        return try payload(text, type: cellType.element, column: column)
    }

    public static func payload(_ text: String, type: QdrantFieldType, column: String) throws -> Any {
        switch type {
        case .keyword, .text, .string, .uuid, .datetime:
            return text
        case .integer:
            guard let value = integer(text) else { throw QdrantValueError.notAnInteger(column: column, value: text) }
            return NSNumber(value: value)
        case .float:
            guard let value = number(text) else { throw QdrantValueError.notANumber(column: column, value: text) }
            return NSNumber(value: value)
        case .bool:
            guard let value = bool(text) else { throw QdrantValueError.notABoolean(column: column, value: text) }
            return value
        case .geo:
            guard let point = QdrantJSON.parse(text) as? [String: Any],
                  point["lon"] is NSNumber, point["lat"] is NSNumber
            else { throw QdrantValueError.notAGeoPoint(column: column) }
            return point
        case .object:
            guard let object = QdrantJSON.parse(text) as? [String: Any] else {
                throw QdrantValueError.notAnObject(column: column)
            }
            return object
        case .array:
            guard let array = QdrantJSON.parse(text) as? [Any] else { throw QdrantValueError.notAnArray(column: column) }
            return array
        case .json:
            return QdrantJSON.parse(text) ?? text
        }
    }

    public static func vector(_ text: String, kind: QdrantVectorSpec.Kind, column: String) throws -> Any {
        let parsed = QdrantJSON.parse(text)
        switch kind {
        case .dense:
            guard let values = numbers(parsed), !values.isEmpty else { throw QdrantValueError.notAVector(column: column) }
            return values
        case .multi:
            guard let rows = parsed as? [Any], !rows.isEmpty else { throw QdrantValueError.notAMultivector(column: column) }
            return try rows.map { row in
                guard let values = numbers(row), !values.isEmpty else { throw QdrantValueError.notAMultivector(column: column) }
                return values
            }
        case .sparse:
            guard let object = parsed as? [String: Any],
                  let indices = object["indices"] as? [Any], let values = numbers(object["values"]),
                  indices.count == values.count,
                  indices.allSatisfy({ ($0 as? NSNumber).map { !QdrantJSON.isBoolean($0) } ?? false })
            else { throw QdrantValueError.notASparseVector(column: column) }
            return ["indices": indices, "values": values]
        }
    }

    private static func numbers(_ value: Any?) -> [NSNumber]? {
        guard let array = value as? [Any] else { return nil }
        let numbers = array.compactMap { $0 as? NSNumber }.filter { !QdrantJSON.isBoolean($0) }
        return numbers.count == array.count ? numbers : nil
    }
}
