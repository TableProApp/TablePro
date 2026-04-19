import Foundation

public enum StructureColumnField: String, Sendable, CaseIterable {
    case name
    case type
    case nullable
    case defaultValue
    case primaryKey
    case autoIncrement
    case comment
    case charset
    case collation

    public var displayName: String {
        switch self {
        case .name: return "Name"
        case .type: return "Type"
        case .nullable: return "Nullable"
        case .defaultValue: return "Default"
        case .primaryKey: return "Primary Key"
        case .autoIncrement: return "Auto Inc"
        case .comment: return "Comment"
        case .charset: return "Charset"
        case .collation: return "Collation"
        }
    }
}
