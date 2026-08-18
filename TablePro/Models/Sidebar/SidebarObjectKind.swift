import Foundation

struct DatabaseTreeObjectGroup: Hashable, Sendable {
    let database: String
    let schema: String?
    let kind: SidebarObjectKind
}

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

    /// A plugin names its own table equivalent, so a Mongo tree says Collections where a Postgres
    /// one says Tables. Every other kind keeps the app's name. The row, its menu and type-select all
    /// have to agree, which is why they ask here instead of each spelling the rule out.
    func title(tableEntityName: String?) -> String {
        guard self == .table, let tableEntityName else { return pluralDisplayName }
        return tableEntityName
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

    var isRoutine: Bool {
        self == .procedure || self == .function
    }

    static func resolve(tableType: TableInfo.TableType) -> SidebarObjectKind {
        switch tableType.rawValue {
        case "VIEW":              return .view
        case "MATERIALIZED VIEW": return .materializedView
        case "FOREIGN TABLE":     return .foreignTable
        default:                  return .table
        }
    }

    var isExpandedByDefault: Bool {
        self == .table
    }

    /// Which kinds a container lists, in declaration order. The count is the whole rule: a plugin's
    /// capability flag says what it declared, not what its driver returned, so gating on one hides
    /// objects that came back with no section, no status row and no error.
    ///
    /// `includingEmptyTables` is the only thing the two sidebar layouts disagree on. The flat root's
    /// sections are chrome that exists before their contents do, so it keeps Tables whatever the
    /// count. A tree container answers for itself with its own status row instead.
    static func visible(
        itemCounts: [SidebarObjectKind: Int],
        includingEmptyTables: Bool
    ) -> [SidebarObjectKind] {
        allCases.filter { kind in
            if includingEmptyTables, kind == .table { return true }
            return itemCounts[kind, default: 0] > 0
        }
    }
}
