import Foundation

struct DatabaseTreeObjectGroup: Hashable, Sendable {
    let database: String
    let schema: String?
    let kind: SidebarObjectKind
}

/// Which model a kind's rows are drawn from. Every helper that used to ask `isRoutine` and pick
/// one of two buckets asks this instead, so a kind added later cannot silently read the wrong one.
enum SidebarObjectCategory: Sendable, Hashable {
    case table
    case routine
    case trigger
    case type
}

enum SidebarObjectKind: String, CaseIterable, Sendable, Hashable {
    case table
    case view
    case materializedView
    case foreignTable
    case procedure
    case function
    case trigger
    case type

    var displayName: String {
        switch self {
        case .table:            return String(localized: "Table")
        case .view:             return String(localized: "View")
        case .materializedView: return String(localized: "Materialized View")
        case .foreignTable:     return String(localized: "Foreign Table")
        case .procedure:        return String(localized: "Procedure")
        case .function:         return String(localized: "Function")
        case .trigger:          return String(localized: "Trigger")
        case .type:             return String(localized: "Type")
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
        case .trigger:          return String(localized: "Triggers")
        case .type:             return String(localized: "Types")
        }
    }

    var emptyDescription: String {
        switch self {
        case .table:            return String(localized: "No tables")
        case .view:             return String(localized: "No views")
        case .materializedView: return String(localized: "No materialized views")
        case .foreignTable:     return String(localized: "No foreign tables")
        case .procedure:        return String(localized: "No procedures")
        case .function:         return String(localized: "No functions")
        case .trigger:          return String(localized: "No triggers")
        case .type:             return String(localized: "No types")
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
        case .trigger:          return "bolt"
        case .type:             return "cube"
        }
    }

    var category: SidebarObjectCategory {
        switch self {
        case .table, .view, .materializedView, .foreignTable: return .table
        case .procedure, .function:                           return .routine
        case .trigger:                                        return .trigger
        case .type:                                           return .type
        }
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

    /// Which kinds a container lists, in declaration order: the kinds holding objects, and the kinds in
    /// `keeping`. Both sidebar layouts ask the same question, so toggling the layout never changes which
    /// kinds are on screen.
    ///
    /// A kind is listed for what its driver returned, never for what the plugin declares. Gating on a
    /// capability flag hid objects that came back, and listing every declared kind filled the sidebar
    /// with Procedures, Triggers and Types sections that held nothing.
    ///
    /// `keeping` is for a section with something to say and no rows to say it with: a table kind whose
    /// objects all sit in folders, which is where a drag takes one back out, and a kind whose fetch
    /// failed, which shows the error where its rows would be.
    static func visible(
        itemCounts: [SidebarObjectKind: Int],
        keeping: Set<SidebarObjectKind> = []
    ) -> [SidebarObjectKind] {
        allCases.filter { kind in
            itemCounts[kind, default: 0] > 0 || keeping.contains(kind)
        }
    }
}
