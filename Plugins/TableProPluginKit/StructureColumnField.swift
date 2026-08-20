import Foundation

public enum StructureColumnField: String, Sendable, CaseIterable {
    case name
    case type
    case nullable
    case defaultValue
    case onUpdate
    case primaryKey
    case autoIncrement
    case comment
    case charset
    case collation

    public var displayName: String {
        switch self {
        case .name: String(localized: "Name")
        case .type: String(localized: "Type")
        case .nullable: String(localized: "Nullable")
        case .defaultValue: String(localized: "Default")
        case .onUpdate: String(localized: "On Update")
        case .primaryKey: String(localized: "Primary Key")
        case .autoIncrement: String(localized: "Auto Inc")
        case .comment: String(localized: "Comment")
        case .charset: String(localized: "Charset")
        case .collation: String(localized: "Collation")
        }
    }
}
