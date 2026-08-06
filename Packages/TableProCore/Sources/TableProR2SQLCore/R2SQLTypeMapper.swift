import Foundation

public enum R2SQLTypeCategory: Sendable, Equatable {
    case scalar
    case binary
    case structured
}

public enum R2SQLTypeMapper {
    private static let structuredBases: Set<String> = [
        "list", "largelist", "fixedsizelist", "array", "struct", "map", "union", "dictionary"
    ]

    private static let binaryBases: Set<String> = [
        "binary", "largebinary", "fixedsizebinary"
    ]

    private static let normalizedBases: [String: String] = [
        "utf8": "STRING",
        "largeutf8": "STRING",
        "utf8view": "STRING",
        "list": "ARRAY",
        "largelist": "ARRAY",
        "fixedsizelist": "ARRAY",
        "struct": "STRUCT",
        "map": "MAP",
        "binaryview": "BINARY",
        "largebinary": "BINARY",
        "fixedsizebinary": "BINARY"
    ]

    public static func baseName(_ typeName: String) -> String {
        let trimmed = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let paren = trimmed.firstIndex(of: "(") else { return trimmed }
        return String(trimmed[trimmed.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
    }

    public static func displayTypeName(for field: R2SQLField) -> String {
        displayTypeName(rawTypeName: field.typeName)
    }

    public static func displayTypeName(rawTypeName: String) -> String {
        let raw = rawTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        let base = baseName(raw)
        guard let normalized = normalizedBases[base.lowercased()] else { return raw }
        return normalized
    }

    public static func category(rawTypeName: String) -> R2SQLTypeCategory {
        let base = baseName(rawTypeName).lowercased()
        if structuredBases.contains(base) { return .structured }
        if binaryBases.contains(base) { return .binary }
        return .scalar
    }

    public static func value(for json: R2SQLJSONValue?, rawTypeName: String) -> R2SQLValue {
        guard let json, !json.isNull else { return .null }
        switch category(rawTypeName: rawTypeName) {
        case .scalar:
            if case .array = json { return .text(json.jsonText()) }
            if case .object = json { return .text(json.jsonText()) }
            return .text(json.scalarText ?? "")
        case .binary:
            if case .string(let encoded) = json, let data = Data(base64Encoded: encoded) {
                return .bytes([UInt8](data))
            }
            return .text(json.scalarText ?? "")
        case .structured:
            return .text(json.jsonText())
        }
    }
}
