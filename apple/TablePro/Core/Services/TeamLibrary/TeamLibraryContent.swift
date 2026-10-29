//
//  TeamLibraryContent.swift
//  TablePro
//

import Foundation
import TableProCloudAPI
import TableProImport

internal struct TeamLibraryTeam: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

internal struct TeamLibraryConnection: Equatable, Identifiable, Sendable {
    // The lowercase client ID, so a connection keeps its row from the /v1 cache to the first /v2 pull.
    let id: String
    let settings: ExportableConnection
}

internal struct TeamLibraryQuery: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let query: String
    let keyword: String?
    let folderName: String?
}

// What the welcome window and the Favorites sidebar show: every live item of every team this account reads.
internal struct TeamLibraryContent: Equatable, Sendable {
    var connections: [TeamLibraryConnection]
    var queries: [TeamLibraryQuery]

    static let empty = TeamLibraryContent(connections: [], queries: [])

    init(connections: [TeamLibraryConnection], queries: [TeamLibraryQuery]) {
        self.connections = connections
        self.queries = queries
    }

    init(items: [TeamLibraryChange]) {
        var byKey: [TeamLibraryKey: TeamLibraryChange] = [:]
        for item in items where !item.deleted {
            byKey[item.key] = item
        }
        let folders = byKey.values.reduce(into: [String: TeamLibraryFolderData]()) { folders, item in
            if let folder = item.folder {
                folders[item.key.clientID] = folder
            }
        }
        connections = byKey.values
            .compactMap { item in item.connection.map { TeamLibraryConnection(id: item.key.clientID, settings: $0) } }
            .sorted { ($0.settings.name.localizedLowercase, $0.id) < ($1.settings.name.localizedLowercase, $1.id) }
        queries = byKey.values
            .compactMap { item -> (TeamLibraryQuery, Int)? in
                guard let query = item.query else { return nil }
                let folder = query.folderClientID.flatMap { folders[$0.lowercased()] }
                return (TeamLibraryQuery(
                    id: item.key.clientID,
                    name: query.name,
                    query: query.query,
                    keyword: query.keyword,
                    folderName: folder?.name
                ), query.sortOrder)
            }
            .sorted { lhs, rhs in
                let left = (lhs.0.folderName ?? "", lhs.1, lhs.0.name.localizedLowercase, lhs.0.id)
                let right = (rhs.0.folderName ?? "", rhs.1, rhs.0.name.localizedLowercase, rhs.0.id)
                return left < right
            }
            .map(\.0)
    }
}

internal enum TeamLibrarySyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case synced(Date)
    case failed(TeamLibraryFailure)
}
