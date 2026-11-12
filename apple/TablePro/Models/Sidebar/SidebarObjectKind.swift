import Foundation

struct DatabaseTreeObjectGroup: Hashable, Sendable {
    let database: String
    let schema: String?
    let kind: SidebarObjectKind
}

// Which model a kind's rows are drawn from, so a kind added later cannot read the wrong bucket.
enum SidebarObjectCategory: Sendable, Hashable {
    case table
    case routine
    case trigger
    case type
    case server
}

enum SidebarObjectKind: Sendable, Hashable {
    case table
    case view
    case materializedView
    case foreignTable
    case sequence
    case procedure
    case function
    case trigger
    case type
    case server(SidebarServerObjectKind)

    static let builtIn: [SidebarObjectKind] = [
        .table, .view, .materializedView, .foreignTable, .sequence, .procedure, .function, .trigger, .type,
    ]

    static func ordered(declared: [SidebarServerObjectKind]) -> [SidebarObjectKind] {
        builtIn + declared.map { SidebarObjectKind.server($0) }
    }

    private static let serverPersistencePrefix = "server."

    // Built-in spellings are shipped in UserDefaults keys, the tree expansion JSON and node ids.
    var persistenceName: String {
        switch self {
        case .table:                return "table"
        case .view:                 return "view"
        case .materializedView:     return "materializedView"
        case .foreignTable:         return "foreignTable"
        case .sequence:             return "sequence"
        case .procedure:            return "procedure"
        case .function:             return "function"
        case .trigger:              return "trigger"
        case .type:                 return "type"
        case .server(let kind):     return Self.serverPersistencePrefix + kind.id
        }
    }

    // A declared kind decodes before any driver exists, so it carries only its id.
    init?(persistenceName: String) {
        if let builtIn = Self.builtIn.first(where: { $0.persistenceName == persistenceName }) {
            self = builtIn
            return
        }
        guard persistenceName.hasPrefix(Self.serverPersistencePrefix) else { return nil }
        let id = String(persistenceName.dropFirst(Self.serverPersistencePrefix.count))
        guard !id.isEmpty else { return nil }
        self = .server(SidebarServerObjectKind(id: id))
    }

    var serverKind: SidebarServerObjectKind? {
        if case .server(let kind) = self { return kind }
        return nil
    }

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
        case .sequence:         return String(localized: "Sequence")
        case .server(let kind): return kind.displayName
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
        case .sequence:         return String(localized: "Sequences")
        case .server(let kind): return kind.pluralDisplayName
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
        case .sequence:         return String(localized: "No sequences")
        case .server:           return String(localized: "No items")
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
        case .sequence:         return "number"
        case .server(let kind): return kind.iconName
        }
    }

    var category: SidebarObjectCategory {
        switch self {
        case .table, .view, .materializedView, .foreignTable, .sequence: return .table
        case .procedure, .function:                           return .routine
        case .trigger:                                        return .trigger
        case .type:                                           return .type
        case .server:                                         return .server
        }
    }

    static func resolve(tableType: TableInfo.TableType) -> SidebarObjectKind {
        switch tableType.rawValue {
        case "VIEW":              return .view
        case "MATERIALIZED VIEW": return .materializedView
        case "FOREIGN TABLE":     return .foreignTable
        case "SEQUENCE":          return .sequence
        default:                  return .table
        }
    }

    var isExpandedByDefault: Bool {
        self == .table
    }

    // Listed for its rows or for `keeping` (filed into folders, or a failed fetch), never for being declared.
    static func visible(
        itemCounts: [SidebarObjectKind: Int],
        keeping: Set<SidebarObjectKind> = [],
        declared: [SidebarServerObjectKind] = []
    ) -> [SidebarObjectKind] {
        ordered(declared: declared).filter { kind in
            itemCounts[kind, default: 0] > 0 || keeping.contains(kind)
        }
    }
}
