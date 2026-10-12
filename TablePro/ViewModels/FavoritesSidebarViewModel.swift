//
//  FavoritesSidebarViewModel.swift
//  TablePro
//

import Combine
import Foundation

internal struct FavoriteEditItem: Identifiable {
    let id = UUID()
    let favorite: SQLFavorite?
    let query: String?
    let folderId: UUID?
}

internal enum FavoriteSelection: Hashable {
    case table(database: String?, schema: String?, name: String)
    case node(id: String)
}

extension FavoriteSelection: RawRepresentable {
    private static let separator = "\u{1}"

    init?(rawValue: String) {
        let parts = rawValue.components(separatedBy: Self.separator)
        switch parts.first {
        case "table" where parts.count == 4:
            self = .table(
                database: parts[1].isEmpty ? nil : parts[1],
                schema: parts[2].isEmpty ? nil : parts[2],
                name: parts[3]
            )
        case "node" where parts.count >= 2:
            self = .node(id: parts.dropFirst().joined(separator: Self.separator))
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .table(let database, let schema, let name):
            return ["table", database ?? "", schema ?? "", name].joined(separator: Self.separator)
        case .node(let id):
            return ["node", id].joined(separator: Self.separator)
        }
    }
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

    /// A disabled folder is not watched, so it has no files to disclose. It keeps its row and its id
    /// so the contextual menu that re-enables it stays reachable and its expansion survives the round trip.
    static func disabledLinkedFolder(_ folder: LinkedSQLFolder) -> FavoriteNode {
        FavoriteNode(id: "linked-folder-\(folder.id)", content: .linkedFolder(folder), children: nil)
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

@MainActor
internal final class FavoritesSidebarViewModel: ObservableObject {
    @Published var editDialogItem: FavoriteEditItem?
    @Published var renamingFolderId: UUID?
    @Published var showDeleteConfirmation = false
    @Published var favoritesToDelete: [SQLFavorite] = []

    internal let connectionId: UUID
    private let cache: ConnectionDataCache
    private let services: AppServices
    private var cacheCancellable: AnyCancellable?
    private var cachedNodes: (revision: Int, roots: [FavoriteNode])?
    private var manager: SQLFavoriteManager { services.sqlFavoriteManager }

    var isInitialLoadComplete: Bool { cache.isInitialLoadComplete }

    /// Built once per committed snapshot rather than once per read. `FavoritesTabView` asks for the
    /// tree three times in a single pass, to filter it, to test it for emptiness and to list its
    /// folders for the edit dialog, and every one of those used to walk the whole thing again.
    ///
    /// Keyed on the cache's revision rather than cleared from the change signal, so the tree can
    /// never outlive the content it was built from whatever order the cache publishes in.
    var nodes: [FavoriteNode] {
        if let cachedNodes, cachedNodes.revision == cache.contentRevision { return cachedNodes.roots }
        let roots = buildRootNodes()
        cachedNodes = (cache.contentRevision, roots)
        return roots
    }

    private func buildRootNodes() -> [FavoriteNode] {
        var roots = FavoritesTreeBuilder.build(folders: cache.folders, favorites: cache.favorites)
        for folder in cache.linkedFolders {
            guard folder.isEnabled else {
                roots.append(.disabledLinkedFolder(folder))
                continue
            }
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
        observeCache()
        cache.ensureLoaded()
    }

    /// The tab reads the whole Queries tree out of `cache`, which is an observable object of its
    /// own, and SwiftUI subscribes only to the one a property wrapper names. Without this relay the
    /// load that finishes after the first render reaches no subscriber, so the tab kept the empty
    /// tree it was built with until something unrelated happened to redraw it.
    ///
    /// No hop onto the next run-loop turn: `objectWillChange` is the signal SwiftUI wants, and the
    /// cache commits its properties in one synchronous burst, so the redraw that follows reads the
    /// finished snapshot.
    private func observeCache() {
        cacheCancellable = cache.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
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
            _ = await manager.setFavoriteFolder(id: id, folderId: folderId)
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
                /// No wait for the row to appear. The rename request is held until the outline
                /// actually has that row, which it reports itself.
                startRenameFolder(folder)
            }
        }
    }

    func deleteFolder(_ folder: SQLFavoriteFolder) {
        Task {
            _ = await manager.deleteFolder(id: folder.id)
        }
    }

    /// The editor seeds itself from the folder, so there is no buffer to prime here.
    func startRenameFolder(_ folder: SQLFavoriteFolder) {
        renamingFolderId = folder.id
    }

    /// The name arrives from the editor rather than through observable state, so a keystroke no
    /// longer round-trips through the view model on its way to the field.
    ///
    /// It renames by id rather than writing back the record the tree was holding. That record
    /// carries a `connectionId` read when the row was built, and writing it whole would put that
    /// scope back over one another window had set in the meantime.
    func commitRenameFolder(_ folder: SQLFavoriteFolder, to proposedName: String) {
        let newName = proposedName.trimmingCharacters(in: .whitespaces)
        renamingFolderId = nil
        guard !newName.isEmpty, newName != folder.name else { return }
        Task {
            _ = await manager.renameFolder(id: folder.id, name: newName)
        }
    }

    /// Whether the folder itself is available in every connection. The queries inside keep the
    /// scope they already had, and a query the other connections cannot see is simply not drawn
    /// there, so the folder can arrive empty until those queries are made global too.
    func setFolderGlobal(_ folder: SQLFavoriteFolder, _ isGlobal: Bool) {
        Task {
            _ = await manager.setFolderScope(id: folder.id, connectionId: isGlobal ? nil : connectionId)
        }
    }

    func filteredNodes(searchText: String) -> [FavoriteNode] {
        let allNodes = nodes
        guard !searchText.isEmpty else { return allNodes }
        return FavoritesTreeFilter.filterTree(allNodes, searchText: searchText)
    }
}
