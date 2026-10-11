import Foundation

public enum ConnectionResolution: Hashable, Sendable {
    case add
    case addCopy
    case replace(UUID)
    case keepExisting(UUID)
}

public struct ExistingConnection: Hashable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ConnectionRow: Identifiable, Sendable {
    public var id: BundleRef { ref }
    public let ref: BundleRef
    public let settings: ExportableConnection
    public let groupPath: [String]
    public let tagNames: [String]
    public let duplicate: ExistingConnection?
    public let warnings: [String]
    public let unsupportedTypeId: String?
    public let savedQueryCount: Int
    /// The first entry is the default once the row is selected.
    public let resolutions: [ConnectionResolution]
    public let isSelectedByDefault: Bool

    public var carriesTunnelCommand: Bool { settings.carriesTunnelCommand }
    public var carriesStartupCommands: Bool { settings.carriesStartupCommands }
    public var carriesCommands: Bool { carriesTunnelCommand || carriesStartupCommands }

    public init(
        ref: BundleRef,
        settings: ExportableConnection,
        groupPath: [String],
        tagNames: [String],
        duplicate: ExistingConnection?,
        warnings: [String],
        unsupportedTypeId: String?,
        savedQueryCount: Int,
        resolutions: [ConnectionResolution],
        isSelectedByDefault: Bool
    ) {
        self.ref = ref
        self.settings = settings
        self.groupPath = groupPath
        self.tagNames = tagNames
        self.duplicate = duplicate
        self.warnings = warnings
        self.unsupportedTypeId = unsupportedTypeId
        self.savedQueryCount = savedQueryCount
        self.resolutions = resolutions
        self.isSelectedByDefault = isSelectedByDefault
    }
}

public struct QueryRow: Identifiable, Sendable {
    public var id: BundleRef { ref }
    public let ref: BundleRef
    public let name: String
    public let keyword: String?
    public let connection: BundleRef?
    public let connectionName: String?
    public let folderPath: [String]
    public let byteCount: Int
    public let isTooLarge: Bool
    public let isSuggested: Bool

    public init(
        ref: BundleRef,
        name: String,
        keyword: String?,
        connection: BundleRef?,
        connectionName: String?,
        folderPath: [String],
        byteCount: Int,
        isTooLarge: Bool,
        isSuggested: Bool
    ) {
        self.ref = ref
        self.name = name
        self.keyword = keyword
        self.connection = connection
        self.connectionName = connectionName
        self.folderPath = folderPath
        self.byteCount = byteCount
        self.isTooLarge = isTooLarge
        self.isSuggested = isSuggested
    }
}

public struct ImportPreview: Sendable {
    public let collected: CollectedImport
    public let environment: ImportEnvironment
    public let library: ImportLibrarySnapshot
    public let connections: [ConnectionRow]
    public let queries: [QueryRow]

    public init(
        collected: CollectedImport,
        environment: ImportEnvironment,
        library: ImportLibrarySnapshot,
        connections: [ConnectionRow],
        queries: [QueryRow]
    ) {
        self.collected = collected
        self.environment = environment
        self.library = library
        self.connections = connections
        self.queries = queries
    }

    public func connectionRow(_ ref: BundleRef) -> ConnectionRow? {
        connections.first { $0.ref == ref }
    }

    public func queryRow(_ ref: BundleRef) -> QueryRow? {
        queries.first { $0.ref == ref }
    }
}
