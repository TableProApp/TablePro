//
//  ExternalConnectionDirectory.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

internal struct ExternalConnectionListing: Sendable, Equatable {
    internal struct Group: Sendable, Equatable {
        internal let id: UUID
        internal let name: String
        internal let path: [String]
        internal let color: ConnectionColor
    }

    internal struct Tag: Sendable, Equatable {
        internal let id: UUID
        internal let name: String
        internal let color: ConnectionColor
    }

    internal let id: UUID
    internal let name: String
    internal let databaseType: String
    internal let host: String
    internal let port: Int
    internal let database: String
    internal let schema: String?
    internal let isConnected: Bool
    internal let color: ConnectionColor
    internal let group: Group?
    internal let tags: [Tag]
    internal let aiPolicy: AIConnectionPolicy
    internal let externalAccess: ExternalAccessLevel
    internal let safeModeLevel: SafeModeLevel
}

/// The saved connections an outside client (MCP, AppleScript) may list. Blocked connections are
/// dropped here so no surface can list one by forgetting the filter.
internal enum ExternalConnectionDirectory {
    internal struct LiveState: Sendable, Equatable {
        internal let database: String
        internal let schema: String?
        internal let isConnected: Bool
    }

    @MainActor
    internal static func listings() -> [ExternalConnectionListing] {
        listings(
            connections: ConnectionStorage.shared.loadConnections(),
            groups: GroupStorage.shared.loadGroups(),
            tags: TagStorage.shared.loadTags(),
            live: DatabaseManager.shared.activeSessions.mapValues { session in
                LiveState(
                    database: session.resolvedBrowseDatabase,
                    schema: session.browseSchema,
                    isConnected: session.reportedStatus.isConnected
                )
            },
            defaultPolicy: AppSettingsManager.shared.ai.defaultConnectionPolicy
        )
    }

    internal static func listings(
        connections: [DatabaseConnection],
        groups: [ConnectionGroup],
        tags: [ConnectionTag],
        live: [UUID: LiveState],
        defaultPolicy: AIConnectionPolicy
    ) -> [ExternalConnectionListing] {
        let graph = LibraryGroupGraph(groups: groups)
        let groupsById = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tagsById = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return connections
            .filter { $0.externalAccess != .blocked }
            .map { connection in
                let session = live[connection.id]
                return ExternalConnectionListing(
                    id: connection.id,
                    name: connection.name,
                    databaseType: connection.type.rawValue,
                    host: connection.host,
                    port: connection.port,
                    database: session?.database ?? connection.database,
                    schema: session?.schema,
                    isConnected: session?.isConnected ?? false,
                    color: connection.color,
                    group: group(of: connection, graph: graph, groupsById: groupsById),
                    tags: tagList(of: connection, tagsById: tagsById),
                    aiPolicy: connection.aiPolicy ?? defaultPolicy,
                    externalAccess: connection.externalAccess,
                    safeModeLevel: connection.safeModeLevel
                )
            }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private static func group(
        of connection: DatabaseConnection,
        graph: LibraryGroupGraph,
        groupsById: [UUID: ConnectionGroup]
    ) -> ExternalConnectionListing.Group? {
        guard let groupId = connection.groupId, let group = groupsById[groupId] else { return nil }
        return ExternalConnectionListing.Group(
            id: group.id,
            name: group.name,
            path: graph.pathNames(to: group.id),
            color: group.color
        )
    }

    private static func tagList(
        of connection: DatabaseConnection,
        tagsById: [UUID: ConnectionTag]
    ) -> [ExternalConnectionListing.Tag] {
        var seen: Set<UUID> = []
        return connection.tagIds.compactMap { tagId in
            guard seen.insert(tagId).inserted, let tag = tagsById[tagId] else { return nil }
            return ExternalConnectionListing.Tag(id: tag.id, name: tag.name, color: tag.color)
        }
    }
}

internal extension ConnectionColor {
    /// The lowercase name outside clients read. Fixed: it is part of the MCP contract and must not
    /// follow `rawValue` or the localized display name.
    var externalName: String? {
        switch self {
        case .none: nil
        case .red: "red"
        case .orange: "orange"
        case .yellow: "yellow"
        case .green: "green"
        case .blue: "blue"
        case .purple: "purple"
        case .pink: "pink"
        case .gray: "gray"
        }
    }
}
