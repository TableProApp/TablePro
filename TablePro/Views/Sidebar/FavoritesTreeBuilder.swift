//
//  FavoritesTreeBuilder.swift
//  TablePro
//

import Foundation

/// Turns the folders and favorites one connection can see into the Queries tree.
///
/// A reference that does not resolve puts the record at the root rather than removing it. Folders
/// and favorites are read in separate statements, each scoped to this connection plus everything
/// global, so a favorite can arrive holding the id of a folder that did not; matching it to a level
/// by `folderId == parentId` alone then placed it at no level at all (#3045). The same rule covers a
/// folder whose parent is missing, and a parent chain that leads back to itself, which `parent_id`
/// allows because it carries no foreign key and no check constraint.
///
/// It writes nothing, so the connection that can see the folder still draws the record inside it.
internal enum FavoritesTreeBuilder {
    internal static func build(folders: [SQLFavoriteFolder], favorites: [SQLFavorite]) -> [FavoriteNode] {
        let placement = FolderPlacement(folders: folders)
        let foldersByParent = Dictionary(grouping: folders) { placement.parentId(of: $0.id) }
        let favoritesByFolder = Dictionary(grouping: favorites) { placement.folderId(holding: $0) }
        return nodes(under: nil, foldersByParent: foldersByParent, favoritesByFolder: favoritesByFolder)
    }

    private static func nodes(
        under parentId: UUID?,
        foldersByParent: [UUID?: [SQLFavoriteFolder]],
        favoritesByFolder: [UUID?: [SQLFavorite]]
    ) -> [FavoriteNode] {
        var items: [FavoriteNode] = []

        for folder in (foldersByParent[parentId] ?? []).sorted(by: precedes) {
            items.append(.folder(folder, children: nodes(
                under: folder.id,
                foldersByParent: foldersByParent,
                favoritesByFolder: favoritesByFolder
            )))
        }

        for favorite in (favoritesByFolder[parentId] ?? []).sorted(by: precedes) {
            items.append(.favorite(favorite))
        }

        return items
    }

    private static func precedes(_ lhs: SQLFavoriteFolder, _ rhs: SQLFavoriteFolder) -> Bool {
        lhs.sortOrder != rhs.sortOrder
            ? lhs.sortOrder < rhs.sortOrder
            : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func precedes(_ lhs: SQLFavorite, _ rhs: SQLFavorite) -> Bool {
        lhs.sortOrder != rhs.sortOrder
            ? lhs.sortOrder < rhs.sortOrder
            : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

/// Where each record sits once unresolvable references are sent to the root.
private struct FolderPlacement {
    private let foldersById: [UUID: SQLFavoriteFolder]
    private let cyclicIds: Set<UUID>

    init(folders: [SQLFavoriteFolder]) {
        let byId = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.foldersById = byId
        self.cyclicIds = Self.cyclicIds(in: byId)
    }

    func parentId(of id: UUID) -> UUID? {
        guard let parentId = foldersById[id]?.parentId,
              foldersById[parentId] != nil,
              !cyclicIds.contains(id)
        else {
            return nil
        }
        return parentId
    }

    func folderId(holding favorite: SQLFavorite) -> UUID? {
        guard let folderId = favorite.folderId, foldersById[folderId] != nil else { return nil }
        return folderId
    }

    /// Every folder standing on a parent chain that loops. Each one goes to the root, which is the
    /// only placement that terminates, and is what the connection library's own outline does with a
    /// looping group.
    private static func cyclicIds(in folders: [UUID: SQLFavoriteFolder]) -> Set<UUID> {
        var cyclic: Set<UUID> = []
        var acyclic: Set<UUID> = []

        for start in folders.keys {
            var path: [UUID] = []
            var onPath: Set<UUID> = []
            var cursor: UUID? = start

            while let id = cursor, let folder = folders[id] {
                if acyclic.contains(id) || cyclic.contains(id) { break }
                if onPath.contains(id) {
                    if let index = path.firstIndex(of: id) {
                        cyclic.formUnion(path[index...])
                    }
                    break
                }
                path.append(id)
                onPath.insert(id)
                cursor = folder.parentId
            }

            acyclic.formUnion(path.filter { !cyclic.contains($0) })
        }

        return cyclic
    }
}
