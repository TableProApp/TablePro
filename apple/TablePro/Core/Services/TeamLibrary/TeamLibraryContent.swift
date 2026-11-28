//
//  TeamLibraryContent.swift
//  TablePro
//

import Foundation
import TableProFFI

internal struct TeamLibraryTeam: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

internal struct TeamLibraryConnection: Equatable, Identifiable, Sendable {
    // The lowercase id, so a connection keeps its row whatever case the team stores it in.
    let id: String
    // Under an id of its own: the team's copy of a connection this Mac published has that connection's.
    let connection: DatabaseConnection
}

internal struct TeamLibraryQuery: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let query: String
    let keyword: String?
    let folderName: String?
    let lastWriter: String?

    var detail: String? {
        lastWriter ?? folderName
    }
}

// A folder's and a query's fields as the team stores them (core ADR 0051, The library moves in).
internal struct TeamLibraryFolderData: Codable, Equatable, Sendable {
    var name: String
    var parentClientID: String?
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case name
        case parentClientID = "parent_client_id"
        case sortOrder = "sort_order"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        parentClientID = try container.decodeIfPresent(String.self, forKey: .parentClientID)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

internal struct TeamLibraryQueryData: Codable, Equatable, Sendable {
    var name: String
    var query: String
    var keyword: String?
    var folderClientID: String?
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case name
        case query
        case keyword
        case folderClientID = "folder_client_id"
        case sortOrder = "sort_order"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        keyword = try container.decodeIfPresent(String.self, forKey: .keyword)
        folderClientID = try container.decodeIfPresent(String.self, forKey: .folderClientID)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

internal enum TeamLibraryID {
    static func of(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}

// What the welcome window and the Favorites sidebar show: every item of every team this account reads.
internal struct TeamLibraryContent: Equatable, Sendable {
    var connections: [TeamLibraryConnection]
    var queries: [TeamLibraryQuery]

    static let empty = TeamLibraryContent(connections: [], queries: [])
    private static let connectionNamespace = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    init(connections: [TeamLibraryConnection], queries: [TeamLibraryQuery]) {
        self.connections = connections
        self.queries = queries
    }

    init(teams: [TeamLibraryTeamInfo]) {
        var connections: [String: TeamLibraryConnection] = [:]
        var queries: [String: (query: TeamLibraryQuery, order: Int)] = [:]
        for team in teams {
            let folders = Dictionary(
                team.items.compactMap { item -> (String, TeamLibraryFolderData)? in
                    guard item.kind == .folder, let folder = Self.decode(TeamLibraryFolderData.self, item) else { return nil }
                    return (item.id.lowercased(), folder)
                },
                uniquingKeysWith: { first, _ in first }
            )
            for item in team.items {
                let id = item.id.lowercased()
                switch item.kind {
                case .connection:
                    if let connection = Self.connection(item, id: id) {
                        connections[id] = TeamLibraryConnection(id: id, connection: connection)
                    }
                case .query:
                    guard let query = Self.decode(TeamLibraryQueryData.self, item) else { continue }
                    let folder = query.folderClientID.flatMap { folders[$0.lowercased()] }
                    queries[id] = (TeamLibraryQuery(
                        id: id,
                        name: query.name,
                        query: query.query,
                        keyword: query.keyword,
                        folderName: folder?.name,
                        lastWriter: Self.writer(of: item)
                    ), query.sortOrder)
                case .folder:
                    continue
                }
            }
        }
        self.connections = connections.values
            .sorted { ($0.connection.name.localizedLowercase, $0.id) < ($1.connection.name.localizedLowercase, $1.id) }
        self.queries = queries.values
            .sorted { lhs, rhs in
                let left = (lhs.query.folderName ?? "", lhs.order, lhs.query.name.localizedLowercase, lhs.query.id)
                let right = (rhs.query.folderName ?? "", rhs.order, rhs.query.name.localizedLowercase, rhs.query.id)
                return left < right
            }
            .map(\.query)
    }

    // The server leaves the writer out when it names no one to this account.
    static func writer(of item: TeamLibraryItemInfo) -> String? {
        let name = item.updatedBy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    static func wireKind(_ kind: TeamLibraryKindTag) -> String {
        switch kind {
        case .connection: "library_connection"
        case .folder: "library_folder"
        case .query: "library_query"
        }
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, _ item: TeamLibraryItemInfo) -> Value? {
        try? JSONDecoder().decode(type, from: Data(item.fieldsJson.utf8))
    }

    // Another account wrote it, and it lands here with no confirmation step, so the core reads it with nothing the app
    // would run by itself, and a copy whose SSH host ssh would refuse as none. The row is never saved and asks before it
    // signs in with a credential this Mac holds, so its sign-in choice stays.
    private static func connection(_ item: TeamLibraryItemInfo, id: String) -> DatabaseConnection? {
        guard var record = item.connection else { return nil }
        record.connection.id = LinkedFolderWatcher.stableId(namespace: connectionNamespace, key: id).uuidString
        return LibraryRecordMapping.connection(record, isFavorite: false)
    }
}

internal enum TeamLibrarySyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case synced(Date)
    case failed(TeamLibraryFailure)
}
