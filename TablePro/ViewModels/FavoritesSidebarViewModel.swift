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

/// Tree node for displaying favorites and folders in a hierarchy
internal enum FavoriteTreeItem: Identifiable, Hashable {
    case folder(SQLFavoriteFolder, children: [FavoriteTreeItem])
    case favorite(SQLFavorite)

    var id: String {
        switch self {
        case .folder(let folder, _): return "folder-\(folder.id)"
        case .favorite(let fav): return "fav-\(fav.id)"
        }
    }
}

/// ViewModel for the favorites sidebar section
@MainActor @Observable
internal final class FavoritesSidebarViewModel {
    // MARK: - State

    var treeItems: [FavoriteTreeItem] = []
    var isLoading = false
    var editDialogItem: FavoriteEditItem?
    var editingFavorite: SQLFavorite?
    var editingQuery: String?
    var editingFolderId: UUID?
    var renamingFolderId: UUID?
    var renamingFolderName: String = ""
    var expandedFolderIds: Set<UUID> = []

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

        treeItems = buildTree(folders: folders, favorites: favorites, parentId: nil)
    }

    // MARK: - Tree Building

    private func buildTree(
        folders: [SQLFavoriteFolder],
        favorites: [SQLFavorite],
        parentId: UUID?
    ) -> [FavoriteTreeItem] {
        var items: [FavoriteTreeItem] = []

        let levelFolders = folders
            .filter { $0.parentId == parentId }
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for folder in levelFolders {
            let children = buildTree(folders: folders, favorites: favorites, parentId: folder.id)
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
        Task {
            _ = await manager.deleteFavorite(id: favorite.id)
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
        Task {
            await manager.deleteFavorites(ids: favorites.map(\.id))
        }
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
                await loadFavorites()
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

    func filteredItems(searchText: String) -> [FavoriteTreeItem] {
        guard !searchText.isEmpty else { return treeItems }
        return filterTree(treeItems, searchText: searchText)
    }

    private func filterTree(_ items: [FavoriteTreeItem], searchText: String) -> [FavoriteTreeItem] {
        items.compactMap { item in
            switch item {
            case .favorite(let fav):
                if fav.name.localizedCaseInsensitiveContains(searchText) ||
                    (fav.keyword?.localizedCaseInsensitiveContains(searchText) == true) ||
                    fav.query.localizedCaseInsensitiveContains(searchText) {
                    return item
                }
                return nil
            case .folder(let folder, let children):
                let filteredChildren = filterTree(children, searchText: searchText)
                if !filteredChildren.isEmpty ||
                    folder.name.localizedCaseInsensitiveContains(searchText) {
                    return .folder(folder, children: filteredChildren)
                }
                return nil
            }
        }
    }
}
