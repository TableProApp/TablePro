import Foundation

/// How a column's values are read, decided once from the type R2 SQL names in the result schema.
public enum R2SQLValueKind: Sendable, Equatable {
    case integer
    case floatingPoint
    case decimal
    case boolean
    case binary
    case nested
    case text
}

/// Maps the type names in an R2 SQL result schema (`int64`, `bytes`, `list`, `struct`) to the SQL
/// names the grid classifies (`BIGINT`, `BINARY`, `ARRAY`, `STRUCT`) and to how each value is read.
public enum R2SQLTypeMapper {
    private struct Entry {
        let displayName: String
        let kind: R2SQLValueKind
    }

    private static let entries: [String: Entry] = [
        "int8": Entry(displayName: "TINYINT", kind: .integer),
        "int16": Entry(displayName: "SMALLINT", kind: .integer),
        "int32": Entry(displayName: "INT", kind: .integer),
        "int64": Entry(displayName: "BIGINT", kind: .integer),
        "uint8": Entry(displayName: "TINYINT UNSIGNED", kind: .integer),
        "uint16": Entry(displayName: "SMALLINT UNSIGNED", kind: .integer),
        "uint32": Entry(displayName: "INT UNSIGNED", kind: .integer),
        "uint64": Entry(displayName: "BIGINT UNSIGNED", kind: .integer),
        "float16": Entry(displayName: "REAL", kind: .floatingPoint),
        "float32": Entry(displayName: "REAL", kind: .floatingPoint),
        "float64": Entry(displayName: "DOUBLE", kind: .floatingPoint),
        "decimal": Entry(displayName: "DECIMAL", kind: .decimal),
        "decimal128": Entry(displayName: "DECIMAL", kind: .decimal),
        "decimal256": Entry(displayName: "DECIMAL", kind: .decimal),
        "bool": Entry(displayName: "BOOLEAN", kind: .boolean),
        "boolean": Entry(displayName: "BOOLEAN", kind: .boolean),
        "utf8": Entry(displayName: "TEXT", kind: .text),
        "largeutf8": Entry(displayName: "TEXT", kind: .text),
        "utf8view": Entry(displayName: "TEXT", kind: .text),
        "string": Entry(displayName: "TEXT", kind: .text),
        "bytes": Entry(displayName: "BINARY", kind: .binary),
        "binary": Entry(displayName: "BINARY", kind: .binary),
        "largebinary": Entry(displayName: "BINARY", kind: .binary),
        "binaryview": Entry(displayName: "BINARY", kind: .binary),
        "fixedsizebinary": Entry(displayName: "BINARY", kind: .binary),
        "date": Entry(displayName: "DATE", kind: .text),
        "date32": Entry(displayName: "DATE", kind: .text),
        "date64": Entry(displayName: "DATE", kind: .text),
        "time": Entry(displayName: "TIME", kind: .text),
        "time32": Entry(displayName: "TIME", kind: .text),
        "time64": Entry(displayName: "TIME", kind: .text),
        "timestamp": Entry(displayName: "TIMESTAMP", kind: .text),
        "list": Entry(displayName: "ARRAY", kind: .nested),
        "largelist": Entry(displayName: "ARRAY", kind: .nested),
        "fixedsizelist": Entry(displayName: "ARRAY", kind: .nested),
        "struct": Entry(displayName: "STRUCT", kind: .nested),
        "map": Entry(displayName: "MAP", kind: .nested)
    ]

    public static func displayTypeName(_ typeName: String) -> String {
        entry(typeName)?.displayName ?? typeName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public static func valueKind(_ typeName: String) -> R2SQLValueKind {
        entry(typeName)?.kind ?? .text
    }

    public static func cell(_ value: R2SQLJSONValue?, kind: R2SQLValueKind) -> R2SQLValue {
        guard let value else { return .null }
        switch value {
        case .null:
            return .null
        case .bool(let flag):
            return .text(flag ? "true" : "false")
        case .number(let number):
            return .text(text(number, kind: kind))
        case .string(let string):
            guard kind == .binary, let data = Data(base64Encoded: string) else { return .text(string) }
            return .bytes([UInt8](data))
        case .array, .object:
            return .text(value.jsonText)
        }
    }

    private static func text(_ number: Decimal, kind: R2SQLValueKind) -> String {
        guard kind == .floatingPoint else { return number.description }
        return Double(truncating: number as NSDecimalNumber).description
    }

    private static func entry(_ typeName: String) -> Entry? {
        entries[typeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}
