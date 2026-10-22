import Foundation
import TableProConnectionLibrary
import TableProModels

nonisolated struct SavedQueryRemoteChanges: Equatable, Sendable {
    var changedQueries: [SavedQuery] = []
    var deletedQueryIds: Set<UUID> = []
    var changedFolders: [SavedQueryFolder] = []
    var deletedFolderIds: Set<UUID> = []

    var isEmpty: Bool {
        changedQueries.isEmpty && deletedQueryIds.isEmpty && changedFolders.isEmpty && deletedFolderIds.isEmpty
    }
}

nonisolated struct SavedQueryPendingEdits: Equatable, Sendable {
    var dirtyQueryIds: Set<String> = []
    var dirtyFolderIds: Set<String> = []
    var deletedQueryIds: Set<String> = []
    var deletedFolderIds: Set<String> = []
}

nonisolated struct SavedQueryMergeOutcome: Equatable, Sendable {
    let contents: SavedQueryContents
    // Queries that lost a contested keyword; the release is pushed so every device agrees on it.
    let releasedKeywordIds: [UUID]
}

// The Mac's apply order: query deletions, folder upserts, query upserts through the keyword rule, folder deletions.
nonisolated enum SavedQueryRemoteMerge {
    static func merge(
        local: SavedQueryContents,
        remote: SavedQueryRemoteChanges,
        pending: SavedQueryPendingEdits,
        keptLocalOwners: Set<UUID>
    ) -> SavedQueryMergeOutcome {
        var contents = local

        // A record moved to a connection that never syncs keeps an iCloud copy from before the move, which a pull must not apply.
        let keptLocal = { (owner: UUID?) in owner.map(keptLocalOwners.contains) ?? false }
        let keptQueryIds = Set(local.queries.filter { keptLocal($0.connectionId) }.map(\.id))
        let keptFolderIds = Set(local.folders.filter { keptLocal($0.connectionId) }.map(\.id))
        let deletedQueryIds = remote.deletedQueryIds.subtracting(keptQueryIds)
        let deletedFolderIds = remote.deletedFolderIds.subtracting(keptFolderIds)

        // A deletion made here and not pushed yet keeps the record deleted, or the pull brings it back first.
        let incomingQueries = remote.changedQueries.filter {
            !remote.deletedQueryIds.contains($0.id) && !pending.deletedQueryIds.contains($0.id.uuidString)
                && !keptQueryIds.contains($0.id)
        }
        let incomingFolders = remote.changedFolders.filter {
            !remote.deletedFolderIds.contains($0.id) && !pending.deletedFolderIds.contains($0.id.uuidString)
                && !keptFolderIds.contains($0.id)
        }

        contents.queries.removeAll { deletedQueryIds.contains($0.id) }

        for folder in incomingFolders {
            guard let index = contents.folders.firstIndex(where: { $0.id == folder.id }) else {
                contents.folders.append(folder)
                continue
            }
            guard !pending.dirtyFolderIds.contains(folder.id.uuidString) else { continue }
            contents.folders[index] = stored(folder, over: contents.folders[index])
        }

        let upserts = incomingQueries.filter { query in
            !pending.dirtyQueryIds.contains(query.id.uuidString) || contents.query(query.id) == nil
        }
        let resolution = SavedQueryKeywordResolver.resolve(incoming: upserts, local: contents.queries)
        let releasedLocalIds = Set(resolution.releasedLocalIds)
        for index in contents.queries.indices where releasedLocalIds.contains(contents.queries[index].id) {
            contents.queries[index].keyword = nil
        }
        for query in resolution.upserts {
            if let index = contents.queries.firstIndex(where: { $0.id == query.id }) {
                contents.queries[index] = stored(query, over: contents.queries[index])
            } else {
                contents.queries.append(query)
            }
        }

        for id in deletedFolderIds {
            _ = contents.removeFolder(id)
        }

        return SavedQueryMergeOutcome(contents: contents, releasedKeywordIds: resolution.releasedIds)
    }

    // The Mac never rewrites a stored row's createdAt on upsert, and createdAt decides keyword ownership.
    private static func stored(_ incoming: SavedQuery, over existing: SavedQuery) -> SavedQuery {
        guard incoming.createdAt != existing.createdAt else { return incoming }
        return SavedQuery(
            id: incoming.id,
            name: incoming.name,
            query: incoming.query,
            keyword: incoming.keyword,
            folderId: incoming.folderId,
            connectionId: incoming.connectionId,
            sortOrder: incoming.sortOrder,
            createdAt: existing.createdAt,
            updatedAt: incoming.updatedAt
        )
    }

    private static func stored(_ incoming: SavedQueryFolder, over existing: SavedQueryFolder) -> SavedQueryFolder {
        guard incoming.createdAt != existing.createdAt else { return incoming }
        return SavedQueryFolder(
            id: incoming.id,
            name: incoming.name,
            parentId: incoming.parentId,
            connectionId: incoming.connectionId,
            sortOrder: incoming.sortOrder,
            createdAt: existing.createdAt,
            updatedAt: incoming.updatedAt
        )
    }
}
