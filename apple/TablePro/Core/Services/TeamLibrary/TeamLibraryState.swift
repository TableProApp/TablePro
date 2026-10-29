//
//  TeamLibraryState.swift
//  TablePro
//

import Foundation
import os
import TableProCloudAPI

// A push the server refused because the item changed since this Mac last pulled it.
internal struct TeamLibraryConflict: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let teamID: String
    let edit: TeamLibraryEdit
    // The item as the team holds it; nil when the team has no such item any more.
    let current: TeamLibraryChange?

    init(id: UUID = UUID(), teamID: String, edit: TeamLibraryEdit, current: TeamLibraryChange?) {
        self.id = id
        self.teamID = teamID
        self.edit = edit
        self.current = current
    }

    var key: TeamLibraryKey {
        TeamLibraryKey(edit)
    }
}

// One team's library as this Mac last pulled it, with the edits still to push.
internal struct TeamLibraryTeamState: Codable, Equatable, Sendable {
    var teamID: String
    var teamName: String
    var canWrite: Bool
    // Only a pull moves it: a push's cursor covers other writers' commits the next pull still has to fetch.
    var cursor: String?
    var items: [TeamLibraryKey: TeamLibraryChange]
    var pending: [TeamLibraryEdit]
    var conflicts: [TeamLibraryConflict]
    // What this Mac published, so publishing saved queries again removes only the ones it put there.
    var published: Set<TeamLibraryKey>
    // Items deleted on the team whose deletion Keep Theirs accepted, so publishing saved queries leaves them deleted.
    var declined: Set<TeamLibraryKey>
    var syncedAt: Date?

    init(teamID: String, teamName: String, canWrite: Bool) {
        self.teamID = teamID
        self.teamName = teamName
        self.canWrite = canWrite
        self.cursor = nil
        self.items = [:]
        self.pending = []
        self.conflicts = []
        self.published = []
        self.declined = []
        self.syncedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case teamID, teamName, canWrite, cursor, items, pending, conflicts, published, declined, syncedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        teamID = try container.decode(String.self, forKey: .teamID)
        teamName = try container.decode(String.self, forKey: .teamName)
        canWrite = try container.decode(Bool.self, forKey: .canWrite)
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
        let list = try container.decode([TeamLibraryChange].self, forKey: .items)
        items = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { $0.version >= $1.version ? $0 : $1 })
        pending = try container.decode([TeamLibraryEdit].self, forKey: .pending)
        conflicts = try container.decode([TeamLibraryConflict].self, forKey: .conflicts)
        published = try container.decode(Set<TeamLibraryKey>.self, forKey: .published)
        declined = try container.decodeIfPresent(Set<TeamLibraryKey>.self, forKey: .declined) ?? []
        syncedAt = try container.decodeIfPresent(Date.self, forKey: .syncedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(teamID, forKey: .teamID)
        try container.encode(teamName, forKey: .teamName)
        try container.encode(canWrite, forKey: .canWrite)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        try container.encode(Array(items.values), forKey: .items)
        try container.encode(pending, forKey: .pending)
        try container.encode(conflicts, forKey: .conflicts)
        try container.encode(published, forKey: .published)
        try container.encode(declined, forKey: .declined)
        try container.encodeIfPresent(syncedAt, forKey: .syncedAt)
    }

    var liveItems: [TeamLibraryChange] {
        items.values.filter { !$0.deleted }
    }

    // The exact client ID the team stores, since /v2 compares them as sent; a new item gets the lowercase one.
    func clientID(kind: String, for id: String) -> String {
        items[TeamLibraryKey(kind: kind, clientID: id)]?.clientId ?? id.lowercased()
    }
}

// One JSON file per team under Application Support, plus the cache the /v1 library left behind.
internal struct TeamLibraryStateStore {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TeamLibraryStateStore")
    static let legacyPullKey = "com.TablePro.teamLibrary.lastPullAt"

    let directory: URL
    let legacyFile: URL
    let defaults: UserDefaults

    static func live() -> TeamLibraryStateStore {
        let environment = AppStorageEnvironment.shared
        return TeamLibraryStateStore(
            directory: environment.supportDirectory.appendingPathComponent("TeamLibrary", isDirectory: true),
            legacyFile: environment.supportDirectory.appendingPathComponent("team_library.json"),
            defaults: environment.defaults
        )
    }

    func loadAll() -> [TeamLibraryTeamState] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            do {
                return try JSONDecoder().decode(TeamLibraryTeamState.self, from: data)
            } catch {
                Self.logger.error("Dropping an unreadable team library file: \(error.publicLogShape, privacy: .public)")
                try? FileManager.default.removeItem(at: file)
                return nil
            }
        }
    }

    func save(_ state: TeamLibraryTeamState) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file(for: state.teamID), options: .atomic)
        } catch {
            Self.logger.error("Could not store the team library: \(error.publicLogShape, privacy: .public)")
        }
    }

    func remove(teamID: String) {
        try? FileManager.default.removeItem(at: file(for: teamID))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        removeLegacy()
    }

    // What the last /v1 pull cached, keyed by client ID like a /v2 snapshot, so the first one matches it item by item.
    func loadLegacy(now: Date) -> [TeamLibraryChange]? {
        guard let data = try? Data(contentsOf: legacyFile) else { return nil }
        do {
            return try JSONDecoder().decode(TeamLibraryLegacyCache.self, from: data).changes(at: now)
        } catch {
            Self.logger.error("The /v1 team library cache is unreadable: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    func removeLegacy() {
        try? FileManager.default.removeItem(at: legacyFile)
        defaults.removeObject(forKey: Self.legacyPullKey)
    }

    private func file(for teamID: String) -> URL {
        let name = String(teamID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" })
        return directory.appendingPathComponent("\(name).json")
    }
}

// team_library.json as the /v1 sync wrote it: the last pull, connections carrying their settings as the payload.
private struct TeamLibraryLegacyCache: Decodable {
    struct Connection: Decodable {
        let id: String
        let sourceConnectionID: String?
        // /v1 answers an empty array for a connection published without settings.
        let payload: TeamLibraryData?

        enum CodingKeys: String, CodingKey {
            case id
            case sourceConnectionID = "source_connection_id"
            case payload
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            sourceConnectionID = try container.decodeIfPresent(String.self, forKey: .sourceConnectionID)
            payload = try? container.decode(TeamLibraryData.self, forKey: .payload)
        }
    }

    struct Folder: Decodable {
        let clientID: String
        let parentClientID: String?
        let name: String
        let sortOrder: Int?

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case parentClientID = "parent_client_id"
            case name
            case sortOrder = "sort_order"
        }
    }

    struct Query: Decodable {
        let clientID: String
        let folderClientID: String?
        let connectionClientID: String?
        let name: String
        let query: String
        let keyword: String?
        let sortOrder: Int?

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case folderClientID = "folder_client_id"
            case connectionClientID = "connection_client_id"
            case name
            case query
            case keyword
            case sortOrder = "sort_order"
        }
    }

    let connections: [Connection]
    let folders: [Folder]
    let queries: [Query]

    enum CodingKeys: String, CodingKey {
        case connections
        case folders = "query_folders"
        case queries
    }

    func changes(at now: Date) throws -> [TeamLibraryChange] {
        var changes: [TeamLibraryChange] = connections.compactMap { connection in
            connection.payload.map { change(TeamLibraryKind.connection, connection.sourceConnectionID ?? connection.id, $0, now) }
        }
        for folder in folders {
            let data = TeamLibraryFolderData(
                name: folder.name,
                parentClientID: folder.parentClientID,
                sortOrder: folder.sortOrder ?? 0
            )
            changes.append(change(TeamLibraryKind.folder, folder.clientID, try TeamLibraryPayload.data(from: data), now))
        }
        for query in queries {
            let data = TeamLibraryQueryData(
                name: query.name,
                query: query.query,
                keyword: query.keyword,
                folderClientID: query.folderClientID,
                connectionClientID: query.connectionClientID,
                sortOrder: query.sortOrder ?? 0
            )
            changes.append(change(TeamLibraryKind.query, query.clientID, try TeamLibraryPayload.data(from: data), now))
        }
        return changes
    }

    // Version 0: the /v1 pull carried none, so the first /v2 snapshot supplies it before anything is pushed.
    private func change(_ kind: String, _ clientID: String, _ data: TeamLibraryData, _ now: Date) -> TeamLibraryChange {
        TeamLibraryChange(
            clientId: clientID,
            data: .init(additionalProperties: data),
            deleted: false,
            kind: kind,
            updatedAt: now,
            version: 0
        )
    }
}
