import Foundation
import TableProConnectionLibrary
import TableProModels

nonisolated struct SavedQueryContents: Codable, Equatable, Sendable {
    var queries: [SavedQuery]
    var folders: [SavedQueryFolder]

    init(queries: [SavedQuery] = [], folders: [SavedQueryFolder] = []) {
        self.queries = queries
        self.folders = folders
    }

    private enum CodingKeys: String, CodingKey {
        case queries, folders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        queries = try container.decodeIfPresent([SavedQuery].self, forKey: .queries) ?? []
        folders = try container.decodeIfPresent([SavedQueryFolder].self, forKey: .folders) ?? []
    }

    var isEmpty: Bool {
        queries.isEmpty && folders.isEmpty
    }

    func visible(to connectionId: UUID) -> SavedQueryContents {
        SavedQueryContents(
            queries: SavedQueryOutline.visible(queries, to: connectionId),
            folders: SavedQueryOutline.visible(folders, to: connectionId)
        )
    }

    func query(_ id: UUID) -> SavedQuery? {
        queries.first { $0.id == id }
    }

    func folder(_ id: UUID) -> SavedQueryFolder? {
        folders.first { $0.id == id }
    }

    // What sat inside a deleted folder moves up to its parent, as on the Mac.
    mutating func removeFolder(_ id: UUID) -> (removed: SavedQueryFolder, moved: SavedQueryContents)? {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = folders.remove(at: index)
        var moved = SavedQueryContents()
        for index in queries.indices where queries[index].folderId == id {
            queries[index].folderId = removed.parentId
            moved.queries.append(queries[index])
        }
        for index in folders.indices where folders[index].parentId == id {
            folders[index].parentId = removed.parentId
            moved.folders.append(folders[index])
        }
        return (removed, moved)
    }

    // A survivor that pointed into a removed folder is detached to the top level, and reported so it can be pushed.
    mutating func removeRecords(scopedTo connectionIds: Set<UUID>) -> (removed: SavedQueryContents, detached: SavedQueryContents) {
        var removed = SavedQueryContents()
        removed.queries = queries.filter { $0.connectionId.map(connectionIds.contains) == true }
        removed.folders = folders.filter { $0.connectionId.map(connectionIds.contains) == true }
        guard !removed.isEmpty else { return (removed, SavedQueryContents()) }

        let removedQueryIds = Set(removed.queries.map(\.id))
        let removedFolderIds = Set(removed.folders.map(\.id))
        queries.removeAll { removedQueryIds.contains($0.id) }
        folders.removeAll { removedFolderIds.contains($0.id) }

        var detached = SavedQueryContents()
        for index in queries.indices where queries[index].folderId.map(removedFolderIds.contains) == true {
            queries[index].folderId = nil
            detached.queries.append(queries[index])
        }
        for index in folders.indices where folders[index].parentId.map(removedFolderIds.contains) == true {
            folders[index].parentId = nil
            detached.folders.append(folders[index])
        }
        return (removed, detached)
    }

    func isFolder(_ candidate: UUID, insideOrEqualTo folderId: UUID) -> Bool {
        var visited: Set<UUID> = []
        var current: UUID? = candidate
        while let id = current, visited.insert(id).inserted {
            if id == folderId { return true }
            current = folder(id)?.parentId
        }
        return false
    }
}
