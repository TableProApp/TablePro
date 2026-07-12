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
}

public extension PluginPrivilegeScope {
    var isEditableInPrivilegeGrid: Bool {
        switch self {
        case .server, .database:
            true
        case .schema, .table:
            false
        }
    }

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
        }
    }
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
    public let supportsDynamicPrivileges: Bool

    public init(
        serverPrivileges: [PluginPrivilegeDescriptor],
        databasePrivileges: [PluginPrivilegeDescriptor],
        supportsDynamicPrivileges: Bool = false
    ) {
        self.serverPrivileges = serverPrivileges
        self.databasePrivileges = databasePrivileges
        self.supportsDynamicPrivileges = supportsDynamicPrivileges
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
