import Foundation

public struct PluginPrincipalRef: Hashable, Sendable {
    public let name: String
    public let host: String?

    public init(name: String, host: String? = nil) {
        self.name = name
        self.host = host
    }
}

public struct PluginPrincipalAttribute: Hashable, Sendable {
    public let key: String
    public let label: String
    public let isEnabled: Bool

    public init(key: String, label: String, isEnabled: Bool) {
        self.key = key
        self.label = label
        self.isEnabled = isEnabled
    }
}

public struct PluginPrincipalInfo: Hashable, Sendable {
    public let ref: PluginPrincipalRef
    public let isRole: Bool
    public let canLogin: Bool
    public let attributes: [PluginPrincipalAttribute]
    public let memberOf: [String]
    public let connectionLimit: Int?
    public let comment: String?

    public init(
        ref: PluginPrincipalRef,
        isRole: Bool = false,
        canLogin: Bool = true,
        attributes: [PluginPrincipalAttribute] = [],
        memberOf: [String] = [],
        connectionLimit: Int? = nil,
        comment: String? = nil
    ) {
        self.ref = ref
        self.isRole = isRole
        self.canLogin = canLogin
        self.attributes = attributes
        self.memberOf = memberOf
        self.connectionLimit = connectionLimit
        self.comment = comment
    }
}

public struct PluginPrincipalDefinition: Hashable, Sendable {
    public let ref: PluginPrincipalRef
    public let password: String?
    public let canLogin: Bool
    public let attributes: [PluginPrincipalAttribute]
    public let memberOf: [String]
    public let connectionLimit: Int?
    public let comment: String?

    public init(
        ref: PluginPrincipalRef,
        password: String? = nil,
        canLogin: Bool = true,
        attributes: [PluginPrincipalAttribute] = [],
        memberOf: [String] = [],
        connectionLimit: Int? = nil,
        comment: String? = nil
    ) {
        self.ref = ref
        self.password = password
        self.canLogin = canLogin
        self.attributes = attributes
        self.memberOf = memberOf
        self.connectionLimit = connectionLimit
        self.comment = comment
    }
}

public enum PluginPrivilegeScope: Hashable, Sendable {
    case server
    case database(String)
    case schema(database: String, schema: String)
    case table(database: String, schema: String?, table: String)
    case column(database: String, schema: String?, table: String, column: String)
}

public extension PluginPrivilegeScope {
    var databaseName: String? {
        switch self {
        case .server:
            nil
        case let .database(name):
            name
        case let .schema(database, _):
            database
        case let .table(database, _, _):
            database
        case let .column(database, _, _, _):
            database
        }
    }

    var schemaName: String? {
        switch self {
        case .server, .database:
            nil
        case let .schema(_, schema):
            schema
        case let .table(_, schema, _):
            schema
        case let .column(_, schema, _, _):
            schema
        }
    }

    var tableName: String? {
        switch self {
        case .server, .database, .schema:
            nil
        case let .table(_, _, table):
            table
        case let .column(_, _, table, _):
            table
        }
    }

    var columnName: String? {
        guard case let .column(_, _, _, column) = self else { return nil }
        return column
    }

    var parent: PluginPrivilegeScope? {
        switch self {
        case .server:
            nil
        case .database:
            .server
        case let .schema(database, _):
            .database(database)
        case let .table(database, schema, _):
            if let schema {
                .schema(database: database, schema: schema)
            } else {
                .database(database)
            }
        case let .column(database, schema, table, _):
            .table(database: database, schema: schema, table: table)
        }
    }

    func contains(_ other: PluginPrivilegeScope) -> Bool {
        var candidate = other.parent
        while let scope = candidate {
            if scope == self { return true }
            candidate = scope.parent
        }
        return false
    }
}

public enum PluginPrivilegeCategoryKey {
    public static let data = "data"
    public static let structure = "structure"
    public static let administration = "administration"
    public static let dynamic = "dynamic"
}

public struct PluginPrivilegeDescriptor: Hashable, Sendable {
    public let name: String
    public let label: String
    public let category: String?

    public init(name: String, label: String, category: String? = nil) {
        self.name = name
        self.label = label
        self.category = category
    }
}

public struct PluginPrivilegeCatalog: Sendable {
    public let serverPrivileges: [PluginPrivilegeDescriptor]
    public let databasePrivileges: [PluginPrivilegeDescriptor]
    public let schemaPrivileges: [PluginPrivilegeDescriptor]
    public let tablePrivileges: [PluginPrivilegeDescriptor]
    public let columnPrivileges: [PluginPrivilegeDescriptor]
    public let supportsDynamicPrivileges: Bool

    public init(
        serverPrivileges: [PluginPrivilegeDescriptor] = [],
        databasePrivileges: [PluginPrivilegeDescriptor] = [],
        schemaPrivileges: [PluginPrivilegeDescriptor] = [],
        tablePrivileges: [PluginPrivilegeDescriptor] = [],
        columnPrivileges: [PluginPrivilegeDescriptor] = [],
        supportsDynamicPrivileges: Bool = false
    ) {
        self.serverPrivileges = serverPrivileges
        self.databasePrivileges = databasePrivileges
        self.schemaPrivileges = schemaPrivileges
        self.tablePrivileges = tablePrivileges
        self.columnPrivileges = columnPrivileges
        self.supportsDynamicPrivileges = supportsDynamicPrivileges
    }

    public func privileges(for scope: PluginPrivilegeScope) -> [PluginPrivilegeDescriptor] {
        switch scope {
        case .server: serverPrivileges
        case .database: databasePrivileges
        case .schema: schemaPrivileges
        case .table: tablePrivileges
        case .column: columnPrivileges
        }
    }

    public var allPrivileges: [PluginPrivilegeDescriptor] {
        var seen = Set<String>()
        return (
            serverPrivileges + databasePrivileges + schemaPrivileges
                + tablePrivileges + columnPrivileges
        ).filter { seen.insert($0.name).inserted }
    }
}

public struct PluginGrantInfo: Hashable, Sendable {
    public let privilege: String
    public let scope: PluginPrivilegeScope
    public let isGrantable: Bool

    public init(privilege: String, scope: PluginPrivilegeScope, isGrantable: Bool = false) {
        self.privilege = privilege
        self.scope = scope
        self.isGrantable = isGrantable
    }
}

public enum PluginPrivilegeName {
    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ _")

    public static func sanitized(_ raw: String) -> String? {
        let normalized = raw.uppercased()
        guard !normalized.isEmpty, normalized.allSatisfy({ allowed.contains($0) }) else { return nil }
        return normalized
    }
}

public struct PluginPrincipalChangeSet: Sendable {
    public let principal: PluginPrincipalRef
    public let grantsToAdd: [PluginGrantInfo]
    public let grantsToRemove: [PluginGrantInfo]

    public init(
        principal: PluginPrincipalRef,
        grantsToAdd: [PluginGrantInfo] = [],
        grantsToRemove: [PluginGrantInfo] = []
    ) {
        self.principal = principal
        self.grantsToAdd = grantsToAdd
        self.grantsToRemove = grantsToRemove
    }
}

public struct PluginPrincipalDropOptions: Sendable {
    public let cascade: Bool
    public let reassignOwnedTo: PluginPrincipalRef?
    public let dropOwned: Bool

    public init(
        cascade: Bool = false,
        reassignOwnedTo: PluginPrincipalRef? = nil,
        dropOwned: Bool = false
    ) {
        self.cascade = cascade
        self.reassignOwnedTo = reassignOwnedTo
        self.dropOwned = dropOwned
    }
}
