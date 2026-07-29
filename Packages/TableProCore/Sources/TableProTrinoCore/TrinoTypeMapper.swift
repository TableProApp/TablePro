import Foundation

public enum TrinoTypeCategory: Sendable, Equatable {
    case scalar
    case binary
    case structured
}

public enum TrinoTypeMapper {
    static let binaryTypes: Set<String> = [
        "varbinary", "hyperloglog", "p4hyperloglog", "qdigest", "tdigest", "setdigest"
    ]

    static let structuredTypes: Set<String> = ["array", "map", "row"]

    public static func baseType(fromDisplayType type: String) -> String {
        let trimmed = type.trimmingCharacters(in: .whitespaces).lowercased()
        guard let parenIndex = trimmed.firstIndex(of: "(") else {
            return trimmed
        }
        return String(trimmed[..<parenIndex]).trimmingCharacters(in: .whitespaces)
    }

    public static func category(forRawType rawType: String) -> TrinoTypeCategory {
        let base = baseType(fromDisplayType: rawType)
        if binaryTypes.contains(base) {
            return .binary
        }
        if structuredTypes.contains(base) {
            return .structured
        }
        return .scalar
    }

    public static func displayType(_ column: TrinoColumn) -> String {
        column.type
    }
}
