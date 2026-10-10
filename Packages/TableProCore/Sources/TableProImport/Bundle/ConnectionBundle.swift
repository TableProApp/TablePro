import Foundation
import TableProConnectionLibrary

public enum BundlePasswordMode: String, Codable, Sendable {
    case stored
    case prompt
    case pgpass

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BundlePasswordMode(rawValue: raw) ?? .prompt
    }
}

public struct BundleConnection: Sendable, Equatable {
    public var ref: BundleRef
    public var settings: ExportableConnection
    public var groupRef: BundleRef?
    public var tagNames: [String]
    public var credentialProfileRef: BundleRef?

    public init(
        ref: BundleRef,
        settings: ExportableConnection,
        groupRef: BundleRef? = nil,
        tagNames: [String] = [],
        credentialProfileRef: BundleRef? = nil
    ) {
        self.ref = ref
        self.settings = settings
        self.groupRef = groupRef
        self.tagNames = tagNames
        self.credentialProfileRef = credentialProfileRef
    }
}

public struct BundleGroup: Codable, Sendable, Equatable {
    public var ref: BundleRef
    public var name: String
    public var color: String?
    public var iconName: String?
    public var parentRef: BundleRef?

    public init(
        ref: BundleRef,
        name: String,
        color: String? = nil,
        iconName: String? = nil,
        parentRef: BundleRef? = nil
    ) {
        self.ref = ref
        self.name = name
        self.color = color
        self.iconName = iconName
        self.parentRef = parentRef
    }
}

public struct BundleTag: Codable, Sendable, Equatable {
    public var name: String
    public var color: String?

    public init(name: String, color: String? = nil) {
        self.name = name
        self.color = color
    }
}

public struct BundleCredentialProfile: Sendable, Equatable {
    public var ref: BundleRef
    public var name: String
    public var username: String
    public var passwordMode: BundlePasswordMode
    public var secureFieldIds: [String]

    public init(
        ref: BundleRef,
        name: String,
        username: String,
        passwordMode: BundlePasswordMode,
        secureFieldIds: [String] = []
    ) {
        self.ref = ref
        self.name = name
        self.username = username
        self.passwordMode = passwordMode
        self.secureFieldIds = secureFieldIds
    }
}

public struct BundleQueryFolder: Codable, Sendable, Equatable {
    public var ref: BundleRef
    public var name: String
    public var parentRef: BundleRef?
    public var connectionRef: BundleRef?

    public init(ref: BundleRef, name: String, parentRef: BundleRef? = nil, connectionRef: BundleRef? = nil) {
        self.ref = ref
        self.name = name
        self.parentRef = parentRef
        self.connectionRef = connectionRef
    }
}

public struct BundleSavedQuery: Codable, Sendable, Equatable {
    public var ref: BundleRef
    public var name: String
    public var sql: String
    public var keyword: String?
    public var folderRef: BundleRef?
    public var connectionRef: BundleRef?

    public init(
        ref: BundleRef,
        name: String,
        sql: String,
        keyword: String? = nil,
        folderRef: BundleRef? = nil,
        connectionRef: BundleRef? = nil
    ) {
        self.ref = ref
        self.name = name
        self.sql = sql
        self.keyword = keyword
        self.folderRef = folderRef
        self.connectionRef = connectionRef
    }
}

public struct ConnectionBundle: Sendable, Equatable {
    public static let formatVersion = 2

    public let exportedAt: Date
    public let appVersion: String
    public let connections: [BundleConnection]
    public let groups: [BundleGroup]
    public let tags: [BundleTag]
    public let credentialProfiles: [BundleCredentialProfile]
    public let credentials: [BundleRef: ExportableCredentials]
    public let queryFolders: [BundleQueryFolder]
    public let savedQueries: [BundleSavedQuery]

    private let connectionPositions: [BundleRef: Int]
    private let groupPositions: [BundleRef: Int]
    private let profilePositions: [BundleRef: Int]
    private let folderPositions: [BundleRef: Int]

    public init(
        exportedAt: Date = Date(),
        appVersion: String,
        connections: [BundleConnection],
        groups: [BundleGroup] = [],
        tags: [BundleTag] = [],
        credentialProfiles: [BundleCredentialProfile] = [],
        credentials: [BundleRef: ExportableCredentials] = [:],
        queryFolders: [BundleQueryFolder] = [],
        savedQueries: [BundleSavedQuery] = []
    ) throws {
        if let violation = BundleViolation.first(
            connections: connections,
            groups: groups,
            credentialProfiles: credentialProfiles,
            credentials: credentials,
            queryFolders: queryFolders,
            savedQueries: savedQueries
        ) {
            throw ConnectionBundleError.invalidBundle(violation.message)
        }
        self.init(
            unchecked: exportedAt,
            appVersion: appVersion,
            connections: connections,
            groups: groups,
            tags: tags,
            credentialProfiles: credentialProfiles,
            credentials: credentials,
            queryFolders: queryFolders,
            savedQueries: savedQueries
        )
    }

    init(
        unchecked exportedAt: Date,
        appVersion: String,
        connections: [BundleConnection],
        groups: [BundleGroup],
        tags: [BundleTag],
        credentialProfiles: [BundleCredentialProfile],
        credentials: [BundleRef: ExportableCredentials],
        queryFolders: [BundleQueryFolder],
        savedQueries: [BundleSavedQuery]
    ) {
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.connections = connections
        self.groups = groups
        self.tags = tags
        self.credentialProfiles = credentialProfiles
        self.credentials = credentials
        self.queryFolders = queryFolders
        self.savedQueries = savedQueries
        connectionPositions = Self.positions(of: connections.map(\.ref))
        groupPositions = Self.positions(of: groups.map(\.ref))
        profilePositions = Self.positions(of: credentialProfiles.map(\.ref))
        folderPositions = Self.positions(of: queryFolders.map(\.ref))
    }

    public func connection(_ ref: BundleRef) -> BundleConnection? {
        connectionPositions[ref].map { connections[$0] }
    }

    public func groupChain(_ ref: BundleRef?) -> [BundleGroup] {
        Self.chain(from: ref, nodes: groups, positions: groupPositions) { $0.parentRef }
    }

    public func folderChain(_ ref: BundleRef?) -> [BundleQueryFolder] {
        Self.chain(from: ref, nodes: queryFolders, positions: folderPositions) { $0.parentRef }
    }

    public func credentialProfile(_ ref: BundleRef?) -> BundleCredentialProfile? {
        guard let ref, let position = profilePositions[ref] else { return nil }
        return credentialProfiles[position]
    }

    public func savedQueryCount(for connection: BundleRef) -> Int {
        savedQueries.filter { $0.connectionRef == connection }.count
    }

    public func withoutCredentials() -> ConnectionBundle {
        guard !credentials.isEmpty else { return self }
        return rebuilt(credentials: [:])
    }

    public func replacingSettings(_ settings: ExportableConnection, of ref: BundleRef) -> ConnectionBundle {
        guard let position = connectionPositions[ref] else { return self }
        var updated = connections
        updated[position].settings = settings
        return rebuilt(connections: updated)
    }

    func sanitizedForImport() -> ConnectionBundle {
        rebuilt(
            connections: connections.map { connection in
                var copy = connection
                copy.settings = connection.settings.sanitizedForImport()
                return copy
            },
            groups: groups.map { group in
                var copy = group
                copy.iconName = LibrarySymbolCatalog.normalizedName(group.iconName)
                return copy
            }
        )
    }

    private func rebuilt(
        connections: [BundleConnection]? = nil,
        groups: [BundleGroup]? = nil,
        credentials: [BundleRef: ExportableCredentials]? = nil
    ) -> ConnectionBundle {
        ConnectionBundle(
            unchecked: exportedAt,
            appVersion: appVersion,
            connections: connections ?? self.connections,
            groups: groups ?? self.groups,
            tags: tags,
            credentialProfiles: credentialProfiles,
            credentials: credentials ?? self.credentials,
            queryFolders: queryFolders,
            savedQueries: savedQueries
        )
    }

    private static func positions(of refs: [BundleRef]) -> [BundleRef: Int] {
        var positions: [BundleRef: Int] = [:]
        for (position, ref) in refs.enumerated() where positions[ref] == nil {
            positions[ref] = position
        }
        return positions
    }

    private static func chain<Node>(
        from ref: BundleRef?,
        nodes: [Node],
        positions: [BundleRef: Int],
        parent: (Node) -> BundleRef?
    ) -> [Node] {
        var chain: [Node] = []
        var visited: Set<BundleRef> = []
        var next = ref
        while let current = next, visited.insert(current).inserted, let position = positions[current] {
            chain.append(nodes[position])
            next = parent(nodes[position])
        }
        return chain.reversed()
    }
}
