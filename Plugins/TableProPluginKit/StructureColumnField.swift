import Foundation

public enum StructureColumnField: String, Sendable, CaseIterable {
    case name
    case type
    case nullable
    case defaultValue
    case autoIncrement
    case comment

    public var displayName: String {
        switch self {
        case .name: String(localized: "Name")
        case .type: String(localized: "Type")
        case .nullable: String(localized: "Nullable")
        case .defaultValue: String(localized: "Default")
        case .autoIncrement: String(localized: "Auto Inc")
        case .comment: String(localized: "Comment")
        }
    }
}
