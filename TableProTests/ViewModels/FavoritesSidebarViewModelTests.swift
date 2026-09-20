//
//  FavoritesSidebarViewModelTests.swift
//  TableProTests
//

import Combine
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("FavoriteNode")
struct FavoriteNodeTests {
    // MARK: - Helpers

    private func makeFavorite(
        id: UUID = UUID(),
        name: String = "Test",
        query: String = "SELECT 1",
        keyword: String? = nil,
        folderId: UUID? = nil
    ) -> SQLFavorite {
        SQLFavorite(id: id, name: name, query: query, keyword: keyword, folderId: folderId)
    }

    private func makeFolder(
        id: UUID = UUID(),
        name: String = "Folder",
        parentId: UUID? = nil
    ) -> SQLFavoriteFolder {
        SQLFavoriteFolder(id: id, name: name, parentId: parentId)
    }

    // MARK: - Tree Node IDs

    @Test("Favorite node ID has 'fav-' prefix")
    func favoriteNodeId() {
        let fav = makeFavorite()
        let node = FavoriteNode.favorite(fav)
        #expect(node.id == "fav-\(fav.id)")
    }

    @Test("Folder node ID has 'folder-' prefix")
    func folderNodeId() {
        let folder = makeFolder()
        let node = FavoriteNode.folder(folder, children: [])
        #expect(node.id == "folder-\(folder.id)")
    }

    // MARK: - Disabled linked folders

    @Test("A disabled linked folder keeps a row so its Enable command stays reachable")
    func disabledLinkedFolderIsALeafRow() {
        let folder = LinkedSQLFolder(path: "~/queries")
        let node = FavoriteNode.disabledLinkedFolder(folder)

        #expect(node.asLinkedFolder?.id == folder.id)
        #expect(node.isFolder == false)
    }

    @Test("Enabling a linked folder does not change its node ID")
    func disabledLinkedFolderKeepsItsIdentity() {
        var folder = LinkedSQLFolder(path: "~/queries")
        folder.isEnabled = false
        let disabled = FavoriteNode.disabledLinkedFolder(folder)

        folder.isEnabled = true
        let enabled = FavoriteNode.linkedFolder(folder, children: [])

        #expect(disabled.id == enabled.id)
    }

    // MARK: - collectFavorites

    @Test("collectFavorites from flat list")
    func collectFromFlat() {
        let fav1 = makeFavorite(name: "A")
        let fav2 = makeFavorite(name: "B")
        let nodes: [FavoriteNode] = [.favorite(fav1), .favorite(fav2)]

        let collected = nodes.collectFavorites()
        #expect(collected.count == 2)
        #expect(collected.contains { $0.id == fav1.id })
        #expect(collected.contains { $0.id == fav2.id })
    }

    @Test("collectFavorites from nested folders")
    func collectFromNested() {
        let fav1 = makeFavorite(name: "Root Fav")
        let fav2 = makeFavorite(name: "In Folder")
        let fav3 = makeFavorite(name: "In Subfolder")

        let subfolder = FavoriteNode.folder(
            makeFolder(name: "Sub"),
            children: [.favorite(fav3)]
        )
        let folder = FavoriteNode.folder(
            makeFolder(name: "Parent"),
            children: [.favorite(fav2), subfolder]
        )
        let nodes: [FavoriteNode] = [.favorite(fav1), folder]

        let collected = nodes.collectFavorites()
        #expect(collected.count == 3)
        #expect(collected.contains { $0.id == fav1.id })
        #expect(collected.contains { $0.id == fav2.id })
        #expect(collected.contains { $0.id == fav3.id })
    }

    @Test("collectFavorites from empty tree")
    func collectFromEmpty() {
        let collected = [FavoriteNode]().collectFavorites()
        #expect(collected.isEmpty)
    }

    @Test("collectFavorites from folders only (no favorites)")
    func collectFromFoldersOnly() {
        let folder = FavoriteNode.folder(makeFolder(), children: [])
        let collected = [folder].collectFavorites()
        #expect(collected.isEmpty)
    }

    // MARK: - Delete Selection Matching

    @Test("Selected favorite IDs match collectFavorites output")
    func selectionMatching() {
        let fav1 = makeFavorite(name: "A")
        let fav2 = makeFavorite(name: "B")
        let fav3 = makeFavorite(name: "C")

        let folder = FavoriteNode.folder(
            makeFolder(),
            children: [.favorite(fav2)]
        )
        let nodes: [FavoriteNode] = [.favorite(fav1), folder, .favorite(fav3)]

        let selectedIds: Set<String> = ["fav-\(fav1.id)", "fav-\(fav2.id)"]

        let allFavorites = nodes.collectFavorites()
        let toDelete = allFavorites.filter { selectedIds.contains("fav-\($0.id)") }

        #expect(toDelete.count == 2)
        #expect(toDelete.contains { $0.id == fav1.id })
        #expect(toDelete.contains { $0.id == fav2.id })
        #expect(!toDelete.contains { $0.id == fav3.id })
    }

    @Test("Folder selection IDs are excluded from favorite deletion")
    func folderSelectionExcluded() {
        let fav = makeFavorite()
        let folder = makeFolder()
        let nodes: [FavoriteNode] = [
            .favorite(fav),
            .folder(folder, children: [])
        ]

        let selectedIds: Set<String> = ["folder-\(folder.id)"]

        let allFavorites = nodes.collectFavorites()
        let toDelete = allFavorites.filter { selectedIds.contains("fav-\($0.id)") }

        #expect(toDelete.isEmpty)
    }

    @Test("Mixed selection of favorites and folders only deletes favorites")
    func mixedSelection() {
        let fav1 = makeFavorite(name: "A")
        let fav2 = makeFavorite(name: "B")
        let folder = makeFolder()

        let nodes: [FavoriteNode] = [
            .favorite(fav1),
            .folder(folder, children: [.favorite(fav2)])
        ]

        let selectedIds: Set<String> = [
            "fav-\(fav1.id)",
            "folder-\(folder.id)",
            "fav-\(fav2.id)"
        ]

        let allFavorites = nodes.collectFavorites()
        let toDelete = allFavorites.filter { selectedIds.contains("fav-\($0.id)") }

        #expect(toDelete.count == 2)
        #expect(toDelete.contains { $0.id == fav1.id })
        #expect(toDelete.contains { $0.id == fav2.id })
    }

    // MARK: - Filtering

    @Test("Filter tree by name")
    func filterByName() {
        let fav1 = makeFavorite(name: "User Report")
        let fav2 = makeFavorite(name: "Sales Data")
        let nodes: [FavoriteNode] = [.favorite(fav1), .favorite(fav2)]

        let filtered = FavoritesTreeFilter.filterTree(nodes, searchText: "user")
        #expect(filtered.count == 1)
        if let first = filtered.first?.asFavorite {
            #expect(first.id == fav1.id)
        }
    }

    @Test("Filter tree by keyword")
    func filterByKeyword() {
        let fav1 = makeFavorite(name: "A", keyword: "usr")
        let fav2 = makeFavorite(name: "B", keyword: "sls")
        let nodes: [FavoriteNode] = [.favorite(fav1), .favorite(fav2)]

        let filtered = FavoritesTreeFilter.filterTree(nodes, searchText: "usr")
        #expect(filtered.count == 1)
    }

    @Test("Filter tree by query text")
    func filterByQuery() {
        let fav1 = makeFavorite(name: "A", query: "SELECT * FROM large_table")
        let fav2 = makeFavorite(name: "B", query: "INSERT INTO logs")
        let nodes: [FavoriteNode] = [.favorite(fav1), .favorite(fav2)]

        let filtered = FavoritesTreeFilter.filterTree(nodes, searchText: "large_table")
        #expect(filtered.count == 1)
    }

    @Test("Filter tree preserves folder with matching children")
    func filterPreservesFolder() {
        let fav = makeFavorite(name: "Matching Item")
        let folder = makeFolder(name: "Unrelated Folder")
        let nodes: [FavoriteNode] = [
            .folder(folder, children: [.favorite(fav)])
        ]

        let filtered = FavoritesTreeFilter.filterTree(nodes, searchText: "matching")
        #expect(filtered.count == 1)
        if let first = filtered.first, let children = first.children {
            #expect(children.count == 1)
        }
    }

    // MARK: - autoName

    @Test("autoName extracts comment text")
    func autoNameFromComment() {
        let name = SQLFavorite.autoName(from: "-- Get active users\nSELECT * FROM users WHERE active = 1")
        #expect(name == "Get active users")
    }

    @Test("autoName uses first non-empty line when no comment")
    func autoNameFromFirstLine() {
        let name = SQLFavorite.autoName(from: "SELECT * FROM orders")
        #expect(name == "SELECT * FROM orders")
    }

    @Test("autoName truncates to 50 characters")
    func autoNameTruncation() {
        let longQuery = String(repeating: "A", count: 100)
        let name = SQLFavorite.autoName(from: longQuery)
        #expect((name as NSString).length == 50)
    }

    @Test("autoName returns Untitled for empty input")
    func autoNameEmpty() {
        let name = SQLFavorite.autoName(from: "")
        #expect(name == String(localized: "Untitled"))
    }

    @Test("autoName skips empty comment lines")
    func autoNameSkipsEmptyComment() {
        let name = SQLFavorite.autoName(from: "--\nSELECT 1")
        #expect(name == "SELECT 1")
    }

    // MARK: - collectFolders

    @Test("collectFolders gathers all folders from tree")
    func collectFoldersFromTree() {
        let folder1 = makeFolder(name: "A")
        let folder2 = makeFolder(name: "B")
        let fav = makeFavorite()

        let nodes: [FavoriteNode] = [
            .folder(folder1, children: [
                .folder(folder2, children: []),
                .favorite(fav)
            ])
        ]

        let folders = nodes.collectFolders()
        #expect(folders.count == 2)
        #expect(folders.contains { $0.id == folder1.id })
        #expect(folders.contains { $0.id == folder2.id })
    }
}

/// Issue #3016. The view model publishes the Favorites tab's whole Queries tree, but that tree
/// lives in a cache of its own, and SwiftUI hears only the object a property wrapper names.
@Suite("Favorites sidebar cache observation")
@MainActor
struct FavoritesSidebarCacheObservationTests {
    private func waitForEmission(from counter: EmissionCounter, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while counter.emissions.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor
    private final class EmissionCounter {
        private(set) var emissions: [Void] = []
        private var cancellable: AnyCancellable?

        init(watching viewModel: FavoritesSidebarViewModel) {
            cancellable = viewModel.objectWillChange.sink { [weak self] _ in
                self?.emissions.append(())
            }
        }
    }

    @Test("The view model republishes when its cache finishes loading")
    func republishesWhenTheInitialLoadLands() async {
        let connectionId = UUID()
        defer { ConnectionDataCache.removeConnection(connectionId) }
        let viewModel = FavoritesSidebarViewModel(connectionId: connectionId)
        let counter = EmissionCounter(watching: viewModel)

        await waitForEmission(from: counter)

        #expect(viewModel.isInitialLoadComplete)
        #expect(counter.emissions.isEmpty == false, "The tab renders from this signal, so a finished load has to send one")
    }

    @Test("The view model republishes when favorites change elsewhere in the app")
    func republishesWhenFavoritesChange() async {
        let connectionId = UUID()
        defer { ConnectionDataCache.removeConnection(connectionId) }
        let viewModel = FavoritesSidebarViewModel(connectionId: connectionId)
        let cache = ConnectionDataCache.shared(for: connectionId)
        let counter = EmissionCounter(watching: viewModel)
        cache.commit(ConnectionFavoritesSnapshot(), generation: cache.nextRefreshGeneration())

        #expect(counter.emissions.isEmpty == false, "Saving a favorite from the editor has to reach an open sidebar")
    }

    @Test("A cache change invalidates the tree the next read rebuilds")
    func aCacheChangeInvalidatesTheTree() {
        let connectionId = UUID()
        defer { ConnectionDataCache.removeConnection(connectionId) }
        let viewModel = FavoritesSidebarViewModel(connectionId: connectionId)
        let cache = ConnectionDataCache.shared(for: connectionId)
        cache.commit(
            ConnectionFavoritesSnapshot(folders: [SQLFavoriteFolder(name: "Reports")]),
            generation: cache.nextRefreshGeneration()
        )
        #expect(viewModel.nodes.count == 1)

        cache.commit(ConnectionFavoritesSnapshot(), generation: cache.nextRefreshGeneration())

        #expect(viewModel.nodes.isEmpty)
    }
}
