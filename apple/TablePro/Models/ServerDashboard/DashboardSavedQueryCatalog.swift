//
//  DashboardSavedQueryCatalog.swift
//  TablePro
//

import Foundation

/// The saved queries a connection can see, arranged for the Add menu. A folder holding no query at
/// any depth is left out, and a query or folder whose parent is out of scope sits at the top level.
struct DashboardSavedQueryCatalog: Equatable, Sendable {
    let favorites: [SQLFavorite]
    let folders: [SQLFavoriteFolder]

    private let foldersByParent: [UUID?: [SQLFavoriteFolder]]
    private let favoritesByFolder: [UUID?: [SQLFavorite]]
    private let favoritesById: [UUID: SQLFavorite]

    static let empty = DashboardSavedQueryCatalog(favorites: [], folders: [])

    init(favorites: [SQLFavorite], folders: [SQLFavoriteFolder]) {
        self.favorites = favorites
        self.folders = folders
        favoritesById = Dictionary(favorites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let folderIds = Set(folders.map(\.id))
        let byFolder = Dictionary(grouping: favorites) { favorite in
            favorite.folderId.flatMap { folderIds.contains($0) ? $0 : nil }
        }
        favoritesByFolder = byFolder.mapValues { $0.sorted(by: Self.inOrder) }

        let byParent = Dictionary(grouping: folders) { folder in
            folder.parentId.flatMap { folderIds.contains($0) && $0 != folder.id ? $0 : nil }
        }
        var occupied: Set<UUID> = []
        var visited: Set<UUID> = []
        func fill(_ folderId: UUID) -> Bool {
            guard visited.insert(folderId).inserted else { return occupied.contains(folderId) }
            let childrenHold = (byParent[folderId] ?? []).map { fill($0.id) }.contains(true)
            if childrenHold || byFolder[folderId]?.isEmpty == false {
                occupied.insert(folderId)
            }
            return occupied.contains(folderId)
        }
        for folder in folders {
            _ = fill(folder.id)
        }
        foldersByParent = byParent.mapValues { children in
            children.filter { occupied.contains($0.id) }.sorted(by: Self.inOrder)
        }
    }

    func favorite(id: UUID) -> SQLFavorite? {
        favoritesById[id]
    }

    func folders(in parentId: UUID?) -> [SQLFavoriteFolder] {
        foldersByParent[parentId] ?? []
    }

    func favorites(in folderId: UUID?) -> [SQLFavorite] {
        favoritesByFolder[folderId] ?? []
    }

    static func == (lhs: DashboardSavedQueryCatalog, rhs: DashboardSavedQueryCatalog) -> Bool {
        lhs.favorites == rhs.favorites && lhs.folders == rhs.folders
    }

    private static func inOrder(_ lhs: SQLFavorite, _ rhs: SQLFavorite) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func inOrder(_ lhs: SQLFavoriteFolder, _ rhs: SQLFavoriteFolder) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
