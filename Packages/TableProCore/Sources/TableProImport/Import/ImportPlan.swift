import Foundation

public struct PlannedConnection: Sendable, Equatable {
    public enum Write: Sendable, Equatable {
        case add
        case replace
    }

    public let ref: BundleRef
    public let id: UUID
    public let write: Write
    public let settings: ExportableConnection
    public let groupPath: [PathComponent]
    public let tagNames: [String]
    public let credentialProfileRef: BundleRef?
    public let credentials: ExportableCredentials?

    public init(
        ref: BundleRef,
        id: UUID,
        write: Write,
        settings: ExportableConnection,
        groupPath: [PathComponent],
        tagNames: [String],
        credentialProfileRef: BundleRef?,
        credentials: ExportableCredentials?
    ) {
        self.ref = ref
        self.id = id
        self.write = write
        self.settings = settings
        self.groupPath = groupPath
        self.tagNames = tagNames
        self.credentialProfileRef = credentialProfileRef
        self.credentials = credentials
    }
}

public struct PlannedTag: Sendable, Equatable {
    public let name: String
    public let color: String?

    public init(name: String, color: String?) {
        self.name = name
        self.color = color
    }
}

public struct PlannedCredentialProfile: Sendable, Equatable {
    public let ref: BundleRef
    public let name: String
    public let username: String
    public let passwordMode: BundlePasswordMode
    public let secureFieldIds: [String]

    public init(
        ref: BundleRef,
        name: String,
        username: String,
        passwordMode: BundlePasswordMode,
        secureFieldIds: [String]
    ) {
        self.ref = ref
        self.name = name
        self.username = username
        self.passwordMode = passwordMode
        self.secureFieldIds = secureFieldIds
    }
}

public struct PlannedQuery: Sendable, Equatable {
    public let ref: BundleRef
    public let name: String
    public let sql: String
    public let keyword: String?
    public let connectionId: UUID?
    public let folderPath: [PathComponent]

    public init(
        ref: BundleRef,
        name: String,
        sql: String,
        keyword: String?,
        connectionId: UUID?,
        folderPath: [PathComponent]
    ) {
        self.ref = ref
        self.name = name
        self.sql = sql
        self.keyword = keyword
        self.connectionId = connectionId
        self.folderPath = folderPath
    }
}

public struct QueryStatus: Sendable, Equatable {
    public enum Availability: Sendable, Equatable {
        case available
        case alreadySaved
        /// Another selected row in this import adds the same query to the same connection.
        case addedByAnotherRow
        case tooLarge
        case connectionSkipped
    }

    public let availability: Availability
    public let isIncluded: Bool
    public let nameExists: Bool
    public let droppedKeyword: SavedQueryKeywordDrop?

    public init(
        availability: Availability,
        isIncluded: Bool,
        nameExists: Bool,
        droppedKeyword: SavedQueryKeywordDrop?
    ) {
        self.availability = availability
        self.isIncluded = isIncluded
        self.nameExists = nameExists
        self.droppedKeyword = droppedKeyword
    }
}

public struct ImportPlan: Sendable, Equatable {
    public let connections: [PlannedConnection]
    public let keptConnections: [BundleRef: UUID]
    public let tags: [PlannedTag]
    public let credentialProfiles: [PlannedCredentialProfile]
    public let queries: [PlannedQuery]
    public let queryStatuses: [BundleRef: QueryStatus]

    public var isEmpty: Bool {
        connections.isEmpty && queries.isEmpty
    }

    public init(
        connections: [PlannedConnection],
        keptConnections: [BundleRef: UUID],
        tags: [PlannedTag],
        credentialProfiles: [PlannedCredentialProfile],
        queries: [PlannedQuery],
        queryStatuses: [BundleRef: QueryStatus]
    ) {
        self.connections = connections
        self.keptConnections = keptConnections
        self.tags = tags
        self.credentialProfiles = credentialProfiles
        self.queries = queries
        self.queryStatuses = queryStatuses
    }
}
