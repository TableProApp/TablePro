//
//  FavoritesSidebarViewModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("FavoriteTreeItem")
struct FavoriteTreeItemTests {
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

    // MARK: - Tree Item IDs

    @Test("Favorite tree item ID has 'fav-' prefix")
    func favoriteItemId() {
        let fav = makeFavorite()
        let item = FavoriteTreeItem.favorite(fav)
        #expect(item.id == "fav-\(fav.id)")
    }

    @Test("Folder tree item ID has 'folder-' prefix")
    func folderItemId() {
        let folder = makeFolder()
        let item = FavoriteTreeItem.folder(folder, children: [])
        #expect(item.id == "folder-\(folder.id)")
    }

    // MARK: - collectFavorites

    @Test("collectFavorites from flat list")
    func collectFromFlat() {
        let fav1 = makeFavorite(name: "A")
        let fav2 = makeFavorite(name: "B")
        let items: [FavoriteTreeItem] = [.favorite(fav1), .favorite(fav2)]

        let collected = collectFavorites(from: items)
        #expect(collected.count == 2)
        #expect(collected.contains { $0.id == fav1.id })
        #expect(collected.contains { $0.id == fav2.id })
    }

    @Test("collectFavorites from nested folders")
    func collectFromNested() {
        let fav1 = makeFavorite(name: "Root Fav")
        let fav2 = makeFavorite(name: "In Folder")
        let fav3 = makeFavorite(name: "In Subfolder")

        let subfolder = FavoriteTreeItem.folder(
            makeFolder(name: "Sub"),
            children: [.favorite(fav3)]
        )
        let folder = FavoriteTreeItem.folder(
            makeFolder(name: "Parent"),
            children: [.favorite(fav2), subfolder]
        )
        let items: [FavoriteTreeItem] = [.favorite(fav1), folder]

        let collected = collectFavorites(from: items)
        #expect(collected.count == 3)
        #expect(collected.contains { $0.id == fav1.id })
        #expect(collected.contains { $0.id == fav2.id })
        #expect(collected.contains { $0.id == fav3.id })
    }

    @Test("collectFavorites from empty tree")
    func collectFromEmpty() {
        let collected = collectFavorites(from: [])
        #expect(collected.isEmpty)
    }

    @Test("collectFavorites from folders only (no favorites)")
    func collectFromFoldersOnly() {
        let folder = FavoriteTreeItem.folder(makeFolder(), children: [])
        let collected = collectFavorites(from: [folder])
        #expect(collected.isEmpty)
    }

    // MARK: - Delete Selection Matching

    @Test("Selected favorite IDs match collectFavorites output")
    func selectionMatching() {
        let fav1 = makeFavorite(name: "A")
        let fav2 = makeFavorite(name: "B")
        let fav3 = makeFavorite(name: "C")

        let folder = FavoriteTreeItem.folder(
            makeFolder(),
            children: [.favorite(fav2)]
        )
        let items: [FavoriteTreeItem] = [.favorite(fav1), folder, .favorite(fav3)]

        // Simulate selecting fav1 and fav2 (one at root, one in folder)
        let selectedIds: Set<String> = ["fav-\(fav1.id)", "fav-\(fav2.id)"]

        let allFavorites = collectFavorites(from: items)
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
        let items: [FavoriteTreeItem] = [
            .favorite(fav),
            .folder(folder, children: [])
        ]

        // Only the folder is selected
        let selectedIds: Set<String> = ["folder-\(folder.id)"]

        let allFavorites = collectFavorites(from: items)
        let toDelete = allFavorites.filter { selectedIds.contains("fav-\($0.id)") }

        #expect(toDelete.isEmpty)
    }

    @Test("Mixed selection of favorites and folders only deletes favorites")
    func mixedSelection() {
        let fav1 = makeFavorite(name: "A")
        let fav2 = makeFavorite(name: "B")
        let folder = makeFolder()

        let items: [FavoriteTreeItem] = [
            .favorite(fav1),
            .folder(folder, children: [.favorite(fav2)])
        ]

        let selectedIds: Set<String> = [
            "fav-\(fav1.id)",
            "folder-\(folder.id)",
            "fav-\(fav2.id)"
        ]

        let allFavorites = collectFavorites(from: items)
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
        let items: [FavoriteTreeItem] = [.favorite(fav1), .favorite(fav2)]

        let filtered = filterTree(items, searchText: "user")
        #expect(filtered.count == 1)
        if case .favorite(let f) = filtered.first {
            #expect(f.id == fav1.id)
        }
    }

    @Test("Filter tree by keyword")
    func filterByKeyword() {
        let fav1 = makeFavorite(name: "A", keyword: "usr")
        let fav2 = makeFavorite(name: "B", keyword: "sls")
        let items: [FavoriteTreeItem] = [.favorite(fav1), .favorite(fav2)]

        let filtered = filterTree(items, searchText: "usr")
        #expect(filtered.count == 1)
    }

    @Test("Filter tree by query text")
    func filterByQuery() {
        let fav1 = makeFavorite(name: "A", query: "SELECT * FROM large_table")
        let fav2 = makeFavorite(name: "B", query: "INSERT INTO logs")
        let items: [FavoriteTreeItem] = [.favorite(fav1), .favorite(fav2)]

        let filtered = filterTree(items, searchText: "large_table")
        #expect(filtered.count == 1)
    }

    @Test("Filter tree preserves folder with matching children")
    func filterPreservesFolder() {
        let fav = makeFavorite(name: "Matching Item")
        let folder = makeFolder(name: "Unrelated Folder")
        let items: [FavoriteTreeItem] = [
            .folder(folder, children: [.favorite(fav)])
        ]

        let filtered = filterTree(items, searchText: "matching")
        #expect(filtered.count == 1)
        if case .folder(_, let children) = filtered.first {
            #expect(children.count == 1)
        }
    }

    // MARK: - Private helpers (duplicated from ViewModel for testing)

    private func collectFavorites(from items: [FavoriteTreeItem]) -> [SQLFavorite] {
        var result: [SQLFavorite] = []
        for item in items {
            switch item {
            case .favorite(let fav):
                result.append(fav)
            case .folder(_, let children):
                result.append(contentsOf: collectFavorites(from: children))
            }
        }
        return result
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
