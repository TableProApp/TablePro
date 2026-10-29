//
//  TeamLibraryPublishPlan.swift
//  TablePro
//

import Foundation
import TableProCloudAPI
import TableProImport

// The edits a publish pushes, from what this Mac holds and the team's library as last pulled. An item the team holds
// as it would be sent is left out, so publishing twice writes nothing the second time.
internal enum TeamLibraryPublishPlan {
    struct Connection {
        let id: UUID
        let settings: ExportableConnection
    }

    static func connections(_ connections: [Connection], in state: TeamLibraryTeamState) throws -> [TeamLibraryEdit] {
        try connections.compactMap { connection in
            let key = TeamLibraryKey(kind: TeamLibraryKind.connection, clientID: TeamLibraryID.of(connection.id))
            let data = try TeamLibraryPayload.data(from: connection.settings)
            if let stored = state.items[key], !stored.deleted,
               let held = Self.settings(in: stored.dataValues), held == Self.settings(in: data) {
                return nil
            }
            return upsert(.connection, key: key, data: data, in: state)
        }
    }

    // Upserts every saved query and folder, deletes the ones this Mac published that are gone here, and moves what
    // other people keep in a deleted folder up to its parent, since a pushed folder delete moves nothing itself.
    static func savedQueries(
        favorites: [SQLFavorite],
        folders: [SQLFavoriteFolder],
        in state: TeamLibraryTeamState
    ) throws -> [TeamLibraryEdit] {
        let folderIDs = Set(folders.map { TeamLibraryID.of($0.id) })
        let favoriteIDs = Set(favorites.map { TeamLibraryID.of($0.id) })
        var edits: [TeamLibraryEdit] = []
        var touched: Set<TeamLibraryKey> = []

        for folder in parentsFirst(folders) {
            let key = TeamLibraryKey(kind: TeamLibraryKind.folder, clientID: TeamLibraryID.of(folder.id))
            let parent = folder.parentId.map(TeamLibraryID.of).flatMap { folderIDs.contains($0) ? $0 : nil }
            let data = TeamLibraryFolderData(
                name: folder.name,
                parentClientID: parent.map { state.clientID(kind: TeamLibraryKind.folder, for: $0) },
                sortOrder: folder.sortOrder
            )
            touched.insert(key)
            if let stored = state.items[key]?.folder, stored.matches(data) { continue }
            edits.append(upsert(.folder, key: key, data: try TeamLibraryPayload.data(from: data), in: state))
        }

        for favorite in favorites {
            let key = TeamLibraryKey(kind: TeamLibraryKind.query, clientID: TeamLibraryID.of(favorite.id))
            let folder = favorite.folderId.map(TeamLibraryID.of).flatMap { folderIDs.contains($0) ? $0 : nil }
            let data = TeamLibraryQueryData(
                name: favorite.name,
                query: favorite.query,
                keyword: favorite.keyword.flatMap { $0.isEmpty ? nil : $0 },
                folderClientID: folder.map { state.clientID(kind: TeamLibraryKind.folder, for: $0) },
                connectionClientID: favorite.connectionId.map(TeamLibraryID.of),
                sortOrder: favorite.sortOrder
            )
            touched.insert(key)
            if let stored = state.items[key]?.query, stored.matches(data) { continue }
            edits.append(upsert(.query, key: key, data: try TeamLibraryPayload.data(from: data), in: state))
        }

        let removed = state.published.filter { key in
            guard let stored = state.items[key], !stored.deleted else { return false }
            switch key.kind {
            case TeamLibraryKind.folder: return !folderIDs.contains(key.clientID)
            case TeamLibraryKind.query: return !favoriteIDs.contains(key.clientID)
            default: return false
            }
        }
        let removedFolders = Set(removed.filter { $0.kind == TeamLibraryKind.folder }.map(\.clientID))

        for item in state.liveItems.sorted(by: { $0.clientId < $1.clientId }) {
            let key = item.key
            guard !touched.contains(key), !removed.contains(key),
                  let container = item.containerClientID?.lowercased(), removedFolders.contains(container)
            else { continue }
            let target = survivingParent(of: container, removed: removedFolders, in: state)
            if var folder = item.folder {
                folder.parentClientID = target
                edits.append(upsert(.folder, key: key, data: try TeamLibraryPayload.data(from: folder), in: state))
            } else if var query = item.query {
                query.folderClientID = target
                edits.append(upsert(.query, key: key, data: try TeamLibraryPayload.data(from: query), in: state))
            }
        }

        for key in removed.sorted(by: { ($0.kind, $0.clientID) > ($1.kind, $1.clientID) }) {
            guard let stored = state.items[key], let kind = Components.Schemas.LibraryItemKind(rawValue: key.kind) else { continue }
            edits.append(TeamLibraryEdit(baseVersion: stored.version, clientId: stored.clientId, kind: kind, op: .delete))
        }
        return edits
    }

    private static func upsert(
        _ kind: Components.Schemas.LibraryItemKind,
        key: TeamLibraryKey,
        data: TeamLibraryData,
        in state: TeamLibraryTeamState
    ) -> TeamLibraryEdit {
        let stored = state.items[key]
        return TeamLibraryEdit(
            baseVersion: stored.map(\.version),
            clientId: stored?.clientId ?? key.clientID,
            data: .init(additionalProperties: data),
            kind: kind,
            op: .upsert
        )
    }

    private static func settings(in data: TeamLibraryData?) -> ExportableConnection? {
        TeamLibraryPayload.decode(ExportableConnection.self, from: data)
    }

    private static func survivingParent(of folder: String, removed: Set<String>, in state: TeamLibraryTeamState) -> String? {
        var current: String? = folder
        var seen: Set<String> = []
        while let id = current, removed.contains(id), seen.insert(id).inserted {
            current = state.items[TeamLibraryKey(kind: TeamLibraryKind.folder, clientID: id)]?.folder?.parentClientID?.lowercased()
        }
        guard let id = current, !removed.contains(id) else { return nil }
        return state.clientID(kind: TeamLibraryKind.folder, for: id)
    }

    // A folder is pushed after its parent, so the team never holds one under a folder it has not seen yet.
    private static func parentsFirst(_ folders: [SQLFavoriteFolder]) -> [SQLFavoriteFolder] {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [SQLFavoriteFolder] = []
        var placed: Set<UUID> = []
        func place(_ folder: SQLFavoriteFolder, depth: Int) {
            guard !placed.contains(folder.id), depth < folders.count else { return }
            if let parentID = folder.parentId, let parent = byID[parentID] {
                place(parent, depth: depth + 1)
            }
            if placed.insert(folder.id).inserted {
                ordered.append(folder)
            }
        }
        for folder in folders.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            place(folder, depth: 0)
        }
        return ordered
    }
}
