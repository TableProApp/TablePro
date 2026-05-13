import Foundation
import TableProPluginKit

enum SidebarObjectKind: String, CaseIterable, Sendable, Hashable {
    case table
    case view
    case materializedView
    case foreignTable
    case procedure
    case function

    var displayName: String {
        switch self {
        case .table:            return String(localized: "Table")
        case .view:             return String(localized: "View")
        case .materializedView: return String(localized: "Materialized View")
        case .foreignTable:     return String(localized: "Foreign Table")
        case .procedure:        return String(localized: "Procedure")
        case .function:         return String(localized: "Function")
        }
    }

    var pluralDisplayName: String {
        switch self {
        case .table:            return String(localized: "Tables")
        case .view:             return String(localized: "Views")
        case .materializedView: return String(localized: "Materialized Views")
        case .foreignTable:     return String(localized: "Foreign Tables")
        case .procedure:        return String(localized: "Procedures")
        case .function:         return String(localized: "Functions")
        }
    }

    var iconName: String {
        switch self {
        case .table:            return "tablecells"
        case .view:             return "eye"
        case .materializedView: return "square.stack.3d.up"
        case .foreignTable:     return "link"
        case .procedure:        return "curlybraces.square"
        case .function:         return "function"
        }
    }

    var capabilityFlag: PluginCapabilities? {
        switch self {
        case .table, .view:     return nil
        case .materializedView: return .materializedViews
        case .foreignTable:     return .foreignTables
        case .procedure:        return .storedProcedures
        case .function:         return .userFunctions
        }
    }

    var isRoutine: Bool {
        self == .procedure || self == .function
    }
}
