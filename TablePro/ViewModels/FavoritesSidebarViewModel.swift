//
//  FavoritesSidebarViewModel.swift
//  TablePro
//

import Foundation
import Observation

/// Identity wrapper for presenting the favorite edit dialog via `.sheet(item:)`
internal struct FavoriteEditItem: Identifiable {
    let id = UUID()
    let favorite: SQLFavorite?
    let query: String?
    let folderId: UUID?
}

/// Tree node for displaying favorites and folders in a hierarchy.
/// Works with `List(children:)` for native macOS outline rendering.
internal struct FavoriteNode: Identifiable, Hashable {
    enum Content: Hashable {
        case folder(SQLFavoriteFolder)
        case favorite(SQLFavorite)
    }

    let id: String
    let content: Content
    var children: [FavoriteNode]?

    var isFolder: Bool { children != nil }

    var asFavorite: SQLFavorite? {
        if case .favorite(let fav) = content { return fav }
        return nil
    }

    var asFolder: SQLFavoriteFolder? {
        if case .folder(let folder) = content { return folder }
        return nil
    }

    static func folder(_ folder: SQLFavoriteFolder, children: [FavoriteNode]) -> FavoriteNode {
        FavoriteNode(id: "folder-\(folder.id)", content: .folder(folder), children: children)
    }

    static func favorite(_ fav: SQLFavorite) -> FavoriteNode {
        FavoriteNode(id: "fav-\(fav.id)", content: .favorite(fav), children: nil)
    }
}

internal extension [FavoriteNode] {
    func collectFavorites() -> [SQLFavorite] {
        var result: [SQLFavorite] = []
        for node in self {
            if let fav = node.asFavorite {
                result.append(fav)
            }
            if let children = node.children {
                result.append(contentsOf: children.collectFavorites())
            }
        }
        return result
    }

    func collectFolders() -> [SQLFavoriteFolder] {
        var result: [SQLFavoriteFolder] = []
        for node in self {
            if let folder = node.asFolder {
                result.append(folder)
                if let children = node.children {
                    result.append(contentsOf: children.collectFolders())
                }
            }
        }
        return result
    }
}

/// ViewModel for the favorites sidebar section
@MainActor @Observable
internal final class FavoritesSidebarViewModel {
    // MARK: - State

    var nodes: [FavoriteNode] = []
    var isLoading = false
    var editDialogItem: FavoriteEditItem?
    var renamingFolderId: UUID?
    var renamingFolderName: String = ""
    var expandedFolderIds: Set<UUID> = []
    var showDeleteConfirmation = false
    var favoritesToDelete: [SQLFavorite] = []

    // MARK: - Dependencies

    private let connectionId: UUID
    private let manager = SQLFavoriteManager.shared
    @ObservationIgnored private var notificationObserver: NSObjectProtocol?

    init(connectionId: UUID) {
        self.connectionId = connectionId

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .sqlFavoritesDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.loadFavorites()
            }
        }
    }

    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Loading

    func loadFavorites() async {
        isLoading = true
        defer { isLoading = false }

        async let favoritesResult = manager.fetchFavorites(connectionId: connectionId)
        async let foldersResult = manager.fetchFolders(connectionId: connectionId)

        let favorites = await favoritesResult
        let folders = await foldersResult

        nodes = buildNodes(folders: folders, favorites: favorites, parentId: nil)
    }

    // MARK: - Tree Building

    private func buildNodes(
        folders: [SQLFavoriteFolder],
        favorites: [SQLFavorite],
        parentId: UUID?
    ) -> [FavoriteNode] {
        var items: [FavoriteNode] = []

        let levelFolders = folders
            .filter { $0.parentId == parentId }
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for folder in levelFolders {
            let children = buildNodes(folders: folders, favorites: favorites, parentId: folder.id)
            items.append(.folder(folder, children: children))
        }

        let levelFavorites = favorites
            .filter { $0.folderId == parentId }
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for fav in levelFavorites {
            items.append(.favorite(fav))
        }

        return items
    }

    // MARK: - Actions

    func createFavorite(query: String? = nil, folderId: UUID? = nil) {
        if let folderId {
            expandedFolderIds.insert(folderId)
        }
        editDialogItem = FavoriteEditItem(favorite: nil, query: query, folderId: folderId)
    }

    func editFavorite(_ favorite: SQLFavorite) {
        editDialogItem = FavoriteEditItem(favorite: favorite, query: nil, folderId: favorite.folderId)
    }

    func deleteFavorite(_ favorite: SQLFavorite) {
        favoritesToDelete = [favorite]
        showDeleteConfirmation = true
    }

    func confirmDeleteFavorites() {
        let ids = favoritesToDelete.map(\.id)
        favoritesToDelete = []
        Task {
            await manager.deleteFavorites(ids: ids)
        }
    }

    func moveFavorite(id: UUID, toFolder folderId: UUID?) {
        Task {
            let allFavorites = await manager.fetchFavorites(connectionId: connectionId)
            guard var favorite = allFavorites.first(where: { $0.id == id }) else { return }
            favorite.folderId = folderId
            favorite.updatedAt = Date()
            _ = await manager.updateFavorite(favorite)
        }
    }

    func deleteFavorites(_ favorites: [SQLFavorite]) {
        favoritesToDelete = favorites
        showDeleteConfirmation = true
    }

    func createFolder(parentId: UUID? = nil) {
        if let parentId {
            expandedFolderIds.insert(parentId)
        }
        Task {
            let folder = SQLFavoriteFolder(
                name: String(localized: "New Folder"),
                parentId: parentId,
                connectionId: connectionId
            )
            let success = await manager.addFolder(folder)
            if success {
                expandedFolderIds.insert(folder.id)
                try? await Task.sleep(for: .milliseconds(100))
                startRenameFolder(folder)
            }
        }
    }

    func deleteFolder(_ folder: SQLFavoriteFolder) {
        Task {
            _ = await manager.deleteFolder(id: folder.id)
        }
    }

    func startRenameFolder(_ folder: SQLFavoriteFolder) {
        renamingFolderId = folder.id
        renamingFolderName = folder.name
    }

    func commitRenameFolder(_ folder: SQLFavoriteFolder) {
        let newName = renamingFolderName.trimmingCharacters(in: .whitespaces)
        renamingFolderId = nil
        guard !newName.isEmpty, newName != folder.name else { return }
        Task {
            var updated = folder
            updated.name = newName
            updated.updatedAt = Date()
            _ = await manager.updateFolder(updated)
        }
    }

    // MARK: - Filtering

    func filteredNodes(searchText: String) -> [FavoriteNode] {
        guard !searchText.isEmpty else { return nodes }
        return filterTree(nodes, searchText: searchText)
    }

    private func filterTree(_ items: [FavoriteNode], searchText: String) -> [FavoriteNode] {
        items.compactMap { node in
            switch node.content {
            case .favorite(let fav):
                if fav.name.localizedCaseInsensitiveContains(searchText) ||
                    (fav.keyword?.localizedCaseInsensitiveContains(searchText) == true) ||
                    fav.query.localizedCaseInsensitiveContains(searchText) {
                    return node
                }
                return nil
            case .folder(let folder):
                let filteredChildren = filterTree(node.children ?? [], searchText: searchText)
                if !filteredChildren.isEmpty ||
                    folder.name.localizedCaseInsensitiveContains(searchText) {
                    return .folder(folder, children: filteredChildren)
                }
                return nil
            }
        }
    }

    // MARK: - Helpers

    func favoriteForNodeId(_ id: String) -> SQLFavorite? {
        searchNodes(nodes, forId: id)
    }

    private func searchNodes(_ items: [FavoriteNode], forId id: String) -> SQLFavorite? {
        for node in items {
            if node.id == id, let fav = node.asFavorite {
                return fav
            }
            if let children = node.children, let found = searchNodes(children, forId: id) {
                return found
            }
        }
        return nil
    }
}
