//
//  FavoritesSidebarViewModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

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

        let filtered = filterTree(nodes, searchText: "user")
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

        let filtered = filterTree(nodes, searchText: "usr")
        #expect(filtered.count == 1)
    }

    @Test("Filter tree by query text")
    func filterByQuery() {
        let fav1 = makeFavorite(name: "A", query: "SELECT * FROM large_table")
        let fav2 = makeFavorite(name: "B", query: "INSERT INTO logs")
        let nodes: [FavoriteNode] = [.favorite(fav1), .favorite(fav2)]

        let filtered = filterTree(nodes, searchText: "large_table")
        #expect(filtered.count == 1)
    }

    @Test("Filter tree preserves folder with matching children")
    func filterPreservesFolder() {
        let fav = makeFavorite(name: "Matching Item")
        let folder = makeFolder(name: "Unrelated Folder")
        let nodes: [FavoriteNode] = [
            .folder(folder, children: [.favorite(fav)])
        ]

        let filtered = filterTree(nodes, searchText: "matching")
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

    // MARK: - Private helpers (duplicated from ViewModel for testing)

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
}
