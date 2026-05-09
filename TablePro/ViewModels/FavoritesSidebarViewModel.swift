//
//  FavoritesSidebarViewModel.swift
//  TablePro
//

import Foundation
import Observation

internal struct FavoriteEditItem: Identifiable {
    let id = UUID()
    let favorite: SQLFavorite?
    let query: String?
    let folderId: UUID?
}

internal struct FavoriteNode: Identifiable, Hashable {
    enum Content: Hashable {
        case folder(SQLFavoriteFolder)
        case favorite(SQLFavorite)
        case linkedFolder(LinkedSQLFolder)
        case linkedSubfolder(folderId: UUID, displayName: String, pathPrefix: String)
        case linkedFavorite(LinkedSQLFavorite)
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

    var asLinkedFavorite: LinkedSQLFavorite? {
        if case .linkedFavorite(let fav) = content { return fav }
        return nil
    }

    var asLinkedFolder: LinkedSQLFolder? {
        if case .linkedFolder(let folder) = content { return folder }
        return nil
    }

    var isLinked: Bool {
        switch content {
        case .linkedFolder, .linkedSubfolder, .linkedFavorite: return true
        case .folder, .favorite: return false
        }
    }

    static func folder(_ folder: SQLFavoriteFolder, children: [FavoriteNode]) -> FavoriteNode {
        FavoriteNode(id: "folder-\(folder.id)", content: .folder(folder), children: children)
    }

    static func favorite(_ fav: SQLFavorite) -> FavoriteNode {
        FavoriteNode(id: "fav-\(fav.id)", content: .favorite(fav), children: nil)
    }

    static func linkedFolder(_ folder: LinkedSQLFolder, children: [FavoriteNode]) -> FavoriteNode {
        FavoriteNode(id: "linked-folder-\(folder.id)", content: .linkedFolder(folder), children: children)
    }

    static func linkedSubfolder(
        folderId: UUID,
        displayName: String,
        pathPrefix: String,
        children: [FavoriteNode]
    ) -> FavoriteNode {
        FavoriteNode(
            id: "linked-subfolder-\(folderId)-\(pathPrefix)",
            content: .linkedSubfolder(folderId: folderId, displayName: displayName, pathPrefix: pathPrefix),
            children: children
        )
    }

    static func linkedFavorite(_ fav: LinkedSQLFavorite) -> FavoriteNode {
        FavoriteNode(id: "linked-fav-\(fav.id)", content: .linkedFavorite(fav), children: nil)
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

@MainActor @Observable
internal final class FavoritesSidebarViewModel {
    var editDialogItem: FavoriteEditItem?
    var renamingFolderId: UUID?
    var renamingFolderName: String = ""
    var showDeleteConfirmation = false
    var favoritesToDelete: [SQLFavorite] = []

    @ObservationIgnored private let connectionId: UUID
    @ObservationIgnored private let cache: ConnectionDataCache
    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var manager: SQLFavoriteManager { services.sqlFavoriteManager }

    var isInitialLoadComplete: Bool { cache.isInitialLoadComplete }

    var nodes: [FavoriteNode] {
        var roots = buildNodes(folders: cache.folders, favorites: cache.favorites, parentId: nil)
        for folder in cache.linkedFolders {
            let files = cache.linkedFilesByFolderId[folder.id] ?? []
            let children = buildLinkedTree(files: files, folderId: folder.id)
            roots.append(.linkedFolder(folder, children: children))
        }
        return roots
    }

    init(connectionId: UUID, services: AppServices = .live) {
        self.connectionId = connectionId
        self.services = services
        self.cache = ConnectionDataCache.shared(for: connectionId)
        cache.ensureLoaded()
    }

    private func buildLinkedTree(files: [LinkedSQLFavorite], folderId: UUID) -> [FavoriteNode] {
        let entries = files.map { (file: $0, components: $0.relativePath.split(separator: "/").map(String.init)) }
        return groupLinkedFiles(entries: entries, folderId: folderId, prefix: "", depth: 0)
    }

    private func groupLinkedFiles(
        entries: [(file: LinkedSQLFavorite, components: [String])],
        folderId: UUID,
        prefix: String,
        depth: Int
    ) -> [FavoriteNode] {
        var subfolderBuckets: [String: [(file: LinkedSQLFavorite, components: [String])]] = [:]
        var leaves: [LinkedSQLFavorite] = []

        for entry in entries {
            guard entry.components.count > depth else { continue }
            if entry.components.count == depth + 1 {
                leaves.append(entry.file)
            } else {
                let bucket = entry.components[depth]
                subfolderBuckets[bucket, default: []].append(entry)
            }
        }

        let sortedFolderNames = subfolderBuckets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var subfolderNodes: [FavoriteNode] = []
        for name in sortedFolderNames {
            let nestedPrefix = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let children = groupLinkedFiles(
                entries: subfolderBuckets[name] ?? [],
                folderId: folderId,
                prefix: nestedPrefix,
                depth: depth + 1
            )
            subfolderNodes.append(.linkedSubfolder(
                folderId: folderId,
                displayName: name,
                pathPrefix: nestedPrefix,
                children: children
            ))
        }

        let sortedLeaves = leaves
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { FavoriteNode.linkedFavorite($0) }

        return subfolderNodes + sortedLeaves
    }

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

    func createFavorite(query: String? = nil, folderId: UUID? = nil) {
        if let folderId {
            services.favoritesExpansionState.setFolderExpanded(folderId, expanded: true, for: connectionId)
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
            services.favoritesExpansionState.setFolderExpanded(parentId, expanded: true, for: connectionId)
        }
        Task {
            let folder = SQLFavoriteFolder(
                name: String(localized: "New Folder"),
                parentId: parentId,
                connectionId: connectionId
            )
            let success = await manager.addFolder(folder)
            if success {
                services.favoritesExpansionState.setFolderExpanded(folder.id, expanded: true, for: connectionId)
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

    func filteredNodes(searchText: String) -> [FavoriteNode] {
        let allNodes = nodes
        guard !searchText.isEmpty else { return allNodes }
        return filterTree(allNodes, searchText: searchText)
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
            case .linkedFavorite(let linked):
                if linked.name.localizedCaseInsensitiveContains(searchText) ||
                    (linked.keyword?.localizedCaseInsensitiveContains(searchText) == true) ||
                    linked.relativePath.localizedCaseInsensitiveContains(searchText) {
                    return node
                }
                return nil
            case .linkedFolder(let folder):
                let filteredChildren = filterTree(node.children ?? [], searchText: searchText)
                if !filteredChildren.isEmpty || folder.name.localizedCaseInsensitiveContains(searchText) {
                    return .linkedFolder(folder, children: filteredChildren)
                }
                return nil
            case .linkedSubfolder(let folderId, let displayName, let pathPrefix):
                let filteredChildren = filterTree(node.children ?? [], searchText: searchText)
                if !filteredChildren.isEmpty || displayName.localizedCaseInsensitiveContains(searchText) {
                    return .linkedSubfolder(
                        folderId: folderId,
                        displayName: displayName,
                        pathPrefix: pathPrefix,
                        children: filteredChildren
                    )
                }
                return nil
            }
        }
    }

    func favoriteForNodeId(_ id: String) -> SQLFavorite? {
        findNode(nodes, id: id, extract: \.asFavorite)
    }

    func linkedFavoriteForNodeId(_ id: String) -> LinkedSQLFavorite? {
        findNode(nodes, id: id, extract: \.asLinkedFavorite)
    }

    func folderForNodeId(_ id: String) -> SQLFavoriteFolder? {
        findNode(nodes, id: id, extract: \.asFolder)
    }

    func linkedFolderForNodeId(_ id: String) -> LinkedSQLFolder? {
        findNode(nodes, id: id, extract: \.asLinkedFolder)
    }

    private func findNode<T>(
        _ items: [FavoriteNode],
        id: String,
        extract: (FavoriteNode) -> T?
    ) -> T? {
        for node in items {
            if node.id == id, let value = extract(node) {
                return value
            }
            if let children = node.children, let found = findNode(children, id: id, extract: extract) {
                return found
            }
        }
        return nil
    }
}
