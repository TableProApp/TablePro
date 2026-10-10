import Foundation

public struct BundleExportOptions: Sendable, Equatable {
    public static let connectionsOnly = BundleExportOptions(includesSavedQueries: false)

    public var includesCredentials: Bool
    public var includesSavedQueries: Bool
    public var includesGlobalSavedQueries: Bool

    public init(
        includesCredentials: Bool = false,
        includesSavedQueries: Bool = true,
        includesGlobalSavedQueries: Bool = false
    ) {
        self.includesCredentials = includesCredentials
        self.includesSavedQueries = includesSavedQueries
        self.includesGlobalSavedQueries = includesGlobalSavedQueries
    }
}

public struct SavedQueryCounts: Sendable, Equatable {
    public let connectionScoped: Int
    public let global: Int

    public init(connectionScoped: Int, global: Int) {
        self.connectionScoped = connectionScoped
        self.global = global
    }
}

public struct BundleExportInput: Sendable {
    public struct Connection: Sendable {
        public let id: UUID
        public let settings: ExportableConnection
        public let groupId: UUID?
        public let tagIds: [UUID]
        public let credentialProfileId: UUID?
        public let credentials: ExportableCredentials?

        public init(
            id: UUID,
            settings: ExportableConnection,
            groupId: UUID? = nil,
            tagIds: [UUID] = [],
            credentialProfileId: UUID? = nil,
            credentials: ExportableCredentials? = nil
        ) {
            self.id = id
            self.settings = settings
            self.groupId = groupId
            self.tagIds = tagIds
            self.credentialProfileId = credentialProfileId
            self.credentials = credentials
        }
    }

    public struct Group: Sendable {
        public let id: UUID
        public let name: String
        public let color: String?
        public let parentId: UUID?

        public init(id: UUID, name: String, color: String? = nil, parentId: UUID? = nil) {
            self.id = id
            self.name = name
            self.color = color
            self.parentId = parentId
        }
    }

    public struct Tag: Sendable {
        public let id: UUID
        public let name: String
        public let color: String?

        public init(id: UUID, name: String, color: String? = nil) {
            self.id = id
            self.name = name
            self.color = color
        }
    }

    public struct CredentialProfile: Sendable {
        public let id: UUID
        public let name: String
        public let username: String
        public let passwordMode: BundlePasswordMode
        public let secureFieldIds: [String]

        public init(id: UUID, name: String, username: String, passwordMode: BundlePasswordMode, secureFieldIds: [String] = []) {
            self.id = id
            self.name = name
            self.username = username
            self.passwordMode = passwordMode
            self.secureFieldIds = secureFieldIds
        }
    }

    public struct QueryFolder: Sendable {
        public let id: UUID
        public let name: String
        public let parentId: UUID?
        public let connectionId: UUID?

        public init(id: UUID, name: String, parentId: UUID? = nil, connectionId: UUID? = nil) {
            self.id = id
            self.name = name
            self.parentId = parentId
            self.connectionId = connectionId
        }
    }

    public struct SavedQuery: Sendable {
        public let id: UUID
        public let name: String
        public let sql: String
        public let keyword: String?
        public let folderId: UUID?
        public let connectionId: UUID?

        public init(
            id: UUID,
            name: String,
            sql: String,
            keyword: String? = nil,
            folderId: UUID? = nil,
            connectionId: UUID? = nil
        ) {
            self.id = id
            self.name = name
            self.sql = sql
            self.keyword = keyword
            self.folderId = folderId
            self.connectionId = connectionId
        }
    }

    public var connections: [Connection]
    public var groups: [Group]
    public var tags: [Tag]
    public var credentialProfiles: [CredentialProfile]
    public var queryFolders: [QueryFolder]
    public var savedQueries: [SavedQuery]

    public init(
        connections: [Connection],
        groups: [Group] = [],
        tags: [Tag] = [],
        credentialProfiles: [CredentialProfile] = [],
        queryFolders: [QueryFolder] = [],
        savedQueries: [SavedQuery] = []
    ) {
        self.connections = connections
        self.groups = groups
        self.tags = tags
        self.credentialProfiles = credentialProfiles
        self.queryFolders = queryFolders
        self.savedQueries = savedQueries
    }
}

public enum BundleExportAssembler {
    public static func assemble(
        _ input: BundleExportInput,
        options: BundleExportOptions,
        appVersion: String,
        exportedAt: Date = Date()
    ) throws -> ConnectionBundle {
        var builder = ConnectionBundleBuilder(appVersion: appVersion, exportedAt: exportedAt)
        let groups = Dictionary(input.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tags = Dictionary(input.tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let profiles = Dictionary(input.credentialProfiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var refs: [UUID: BundleRef] = [:]
        for connection in input.connections where refs[connection.id] == nil {
            let ref = BundleRef("c\(refs.count + 1)")
            refs[connection.id] = ref
            builder.addConnection(
                connection.settings,
                ref: ref,
                groupPath: chain(from: connection.groupId, in: groups, parent: \.parentId).map {
                    ConnectionBundleBuilder.GroupComponent(name: $0.name, color: $0.color)
                },
                tags: connection.tagIds.compactMap { tags[$0] }.map { BundleTag(name: $0.name, color: $0.color) },
                credentialProfile: connection.credentialProfileId.flatMap { profiles[$0] }.map {
                    ConnectionBundleBuilder.ProfileSpec(
                        name: $0.name,
                        username: $0.username,
                        passwordMode: $0.passwordMode,
                        secureFieldIds: $0.secureFieldIds
                    )
                },
                credentials: options.includesCredentials ? connection.credentials : nil
            )
        }

        if options.includesSavedQueries {
            addSavedQueries(input, options: options, refs: refs, to: &builder)
        }
        return try builder.build()
    }

    public static func savedQueryCounts(_ input: BundleExportInput) -> SavedQueryCounts {
        let exported = Set(input.connections.map(\.id))
        var scoped = 0
        var global = 0
        for query in input.savedQueries {
            if let connectionId = query.connectionId {
                if exported.contains(connectionId) { scoped += 1 }
            } else {
                global += 1
            }
        }
        return SavedQueryCounts(connectionScoped: scoped, global: global)
    }

    private static func addSavedQueries(
        _ input: BundleExportInput,
        options: BundleExportOptions,
        refs: [UUID: BundleRef],
        to builder: inout ConnectionBundleBuilder
    ) {
        let folders = Dictionary(input.queryFolders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for query in input.savedQueries {
            let connectionRef = query.connectionId.flatMap { refs[$0] }
            if query.connectionId == nil {
                guard options.includesGlobalSavedQueries else { continue }
            } else if connectionRef == nil {
                continue
            }
            builder.addSavedQuery(
                name: query.name,
                sql: query.sql,
                keyword: query.keyword,
                folderPath: folderPath(from: query.folderId, in: folders, refs: refs),
                connection: connectionRef
            )
        }
    }

    /// The deepest folder whose whole chain from the root is global or belongs to an exported connection.
    private static func folderPath(
        from folderId: UUID?,
        in folders: [UUID: BundleExportInput.QueryFolder],
        refs: [UUID: BundleRef]
    ) -> [ConnectionBundleBuilder.FolderComponent] {
        var path: [ConnectionBundleBuilder.FolderComponent] = []
        for folder in chain(from: folderId, in: folders, parent: \.parentId) {
            let connection = folder.connectionId.flatMap { refs[$0] }
            guard folder.connectionId == nil || connection != nil else { break }
            path.append(ConnectionBundleBuilder.FolderComponent(name: folder.name, connection: connection))
        }
        return path
    }

    private static func chain<Node>(from id: UUID?, in nodes: [UUID: Node], parent: KeyPath<Node, UUID?>) -> [Node] {
        var chain: [Node] = []
        var visited: Set<UUID> = []
        var next = id
        while let current = next, visited.insert(current).inserted, let node = nodes[current] {
            chain.append(node)
            next = node[keyPath: parent]
        }
        return chain.reversed()
    }
}
