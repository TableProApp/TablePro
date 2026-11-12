import Foundation

/// Weaviate has no array value field: an `int[]` property filters with `valueInt`, so the kind is
/// always the element's.
public enum WeaviateValueKind: String, Sendable, Equatable {
    case text
    case uuid
    case int
    case number
    case boolean
    case date

    public var graphQLField: String {
        switch self {
        case .text, .uuid: return "valueText"
        case .int: return "valueInt"
        case .number: return "valueNumber"
        case .boolean: return "valueBoolean"
        case .date: return "valueDate"
        }
    }

    public var isOrdered: Bool {
        self == .int || self == .number || self == .date
    }

    /// `Like` compiles to a regex over the inverted index, which Weaviate only builds for text.
    public var acceptsPatternMatch: Bool {
        self == .text
    }

    public static func forDataType(_ dataType: String) -> WeaviateValueKind {
        var name = dataType.trimmingCharacters(in: .whitespaces).lowercased()
        while name.hasSuffix("[]") {
            name = String(name.dropLast(2))
        }
        switch name {
        case "int": return .int
        case "number": return .number
        case "boolean", "bool": return .boolean
        case "date": return .date
        case "uuid": return .uuid
        default: return .text
        }
    }
}
