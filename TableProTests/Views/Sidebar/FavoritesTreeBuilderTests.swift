//
//  FavoritesTreeBuilderTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Issue #3045. A connection reads its own folders and favorites plus every global one, and the two
/// tables are read separately, so a favorite can arrive naming a folder that did not. Placing one
/// by `folderId == parentId` alone put it at no level at all.
struct FavoritesTreeBuilderTests {
    private func folder(
        id: UUID = UUID(),
        name: String = "Folder",
        parentId: UUID? = nil,
        connectionId: UUID? = nil,
        sortOrder: Int = 0
    ) -> SQLFavoriteFolder {
        SQLFavoriteFolder(id: id, name: name, parentId: parentId, connectionId: connectionId, sortOrder: sortOrder)
    }

    private func favorite(
        id: UUID = UUID(),
        name: String = "Query",
        folderId: UUID? = nil,
        connectionId: UUID? = nil,
        sortOrder: Int = 0
    ) -> SQLFavorite {
        SQLFavorite(
            id: id,
            name: name,
            query: "SELECT 1",
            folderId: folderId,
            connectionId: connectionId,
            sortOrder: sortOrder
        )
    }

    private func favoriteIds(_ nodes: [FavoriteNode]) -> [UUID] {
        nodes.compactMap { $0.asFavorite?.id }
    }

    private func folderIds(_ nodes: [FavoriteNode]) -> [UUID] {
        nodes.compactMap { $0.asFolder?.id }
    }

    private func children(of node: FavoriteNode?) -> [FavoriteNode] {
        node.flatMap { $0.children } ?? []
    }

    // MARK: - The reported defect

    @Test("A global favorite whose folder belongs to another connection is drawn at the root")
    func aFavoriteWithoutItsFolderGoesToTheRoot() {
        let otherConnectionsFolder = UUID()
        let stranded = favorite(name: "Daily counts", folderId: otherConnectionsFolder, connectionId: nil)

        let roots = FavoritesTreeBuilder.build(folders: [], favorites: [stranded])

        #expect(favoriteIds(roots) == [stranded.id])
    }

    @Test("A favorite whose folder is present is still drawn inside it")
    func aFavoriteKeepsItsFolderWhenTheFolderIsThere() {
        let reports = folder(name: "Reports")
        let nested = favorite(name: "Daily counts", folderId: reports.id)

        let roots = FavoritesTreeBuilder.build(folders: [reports], favorites: [nested])

        #expect(folderIds(roots) == [reports.id])
        #expect(favoriteIds(roots).isEmpty)
        #expect(favoriteIds(children(of: roots.first)) == [nested.id])
    }

    @Test("A folder whose parent belongs to another connection is drawn at the root")
    func aFolderWithoutItsParentGoesToTheRoot() {
        let orphan = folder(name: "Nested", parentId: UUID())

        let roots = FavoritesTreeBuilder.build(folders: [orphan], favorites: [])

        #expect(folderIds(roots) == [orphan.id])
    }

    /// The re-homed folder is still a folder, so what it holds travels with it rather than being
    /// scattered to the root one level at a time.
    @Test("A re-homed folder keeps its own children")
    func aReHomedFolderKeepsItsChildren() {
        let orphan = folder(name: "Nested", parentId: UUID())
        let child = folder(name: "Deeper", parentId: orphan.id)
        let leaf = favorite(name: "Daily counts", folderId: child.id)

        let roots = FavoritesTreeBuilder.build(folders: [orphan, child], favorites: [leaf])

        #expect(folderIds(roots) == [orphan.id])
        let orphanChildren = roots[0].children ?? []
        #expect(folderIds(orphanChildren) == [child.id])
        #expect(favoriteIds(orphanChildren[0].children ?? []) == [leaf.id])
    }

    // MARK: - Cycles

    /// `parent_id` carries no foreign key and no check constraint, so a chain that loops is
    /// representable. Every folder on it goes to the root, which is the only placement that ends.
    @Test("Two folders naming each other as parent are both drawn at the root")
    func aMutualCycleUnwindsToTheRoot() {
        let firstId = UUID()
        let secondId = UUID()
        let first = folder(id: firstId, name: "First", parentId: secondId)
        let second = folder(id: secondId, name: "Second", parentId: firstId)

        let roots = FavoritesTreeBuilder.build(folders: [first, second], favorites: [])

        #expect(Set(folderIds(roots)) == Set([firstId, secondId]))
    }

    @Test("A folder that is its own parent is drawn at the root")
    func aSelfCycleUnwindsToTheRoot() {
        let id = UUID()
        let looped = folder(id: id, name: "Looped", parentId: id)

        let roots = FavoritesTreeBuilder.build(folders: [looped], favorites: [])

        #expect(folderIds(roots) == [id])
    }

    @Test("A folder hanging off a cycle is not dragged to the root with it")
    func anAcyclicChildOfACycleKeepsItsParent() {
        let firstId = UUID()
        let secondId = UUID()
        let first = folder(id: firstId, name: "First", parentId: secondId)
        let second = folder(id: secondId, name: "Second", parentId: firstId)
        let child = folder(name: "Child", parentId: firstId)

        let roots = FavoritesTreeBuilder.build(folders: [first, second, child], favorites: [])

        #expect(Set(folderIds(roots)) == Set([firstId, secondId]))
        let firstNode = roots.first { $0.asFolder?.id == firstId }
        #expect(folderIds(children(of: firstNode)) == [child.id])
    }

    // MARK: - Order

    @Test("A deep chain of folders nests all the way down")
    func aDeepChainNests() {
        let first = folder(name: "One")
        let second = folder(name: "Two", parentId: first.id)
        let third = folder(name: "Three", parentId: second.id)

        let roots = FavoritesTreeBuilder.build(folders: [first, second, third], favorites: [])

        #expect(folderIds(roots) == [first.id])
        #expect(folderIds(roots[0].children ?? []) == [second.id])
        #expect(folderIds(roots[0].children?[0].children ?? []) == [third.id])
    }

    @Test("Folders come before favorites, each ordered by sort order then name")
    func levelOrderIsFoldersThenFavorites() {
        let later = folder(name: "Beta", sortOrder: 1)
        let earlier = folder(name: "Alpha", sortOrder: 0)
        let secondQuery = favorite(name: "Zulu", sortOrder: 0)
        let firstQuery = favorite(name: "Alpha", sortOrder: 0)

        let roots = FavoritesTreeBuilder.build(
            folders: [later, earlier],
            favorites: [secondQuery, firstQuery]
        )

        #expect(folderIds(roots) == [earlier.id, later.id])
        #expect(favoriteIds(roots) == [firstQuery.id, secondQuery.id])
    }

    /// A re-homed favorite is sorted in with the root's own, not appended after them.
    @Test("A re-homed favorite takes its place in the root's order")
    func aReHomedFavoriteSortsWithTheRest() {
        let atRoot = favorite(name: "Beta", folderId: nil, sortOrder: 1)
        let stranded = favorite(name: "Alpha", folderId: UUID(), sortOrder: 0)

        let roots = FavoritesTreeBuilder.build(folders: [], favorites: [atRoot, stranded])

        #expect(favoriteIds(roots) == [stranded.id, atRoot.id])
    }

    @Test("A tree with nothing missing is unchanged")
    func anIntactTreeIsUnchanged() {
        let reports = folder(name: "Reports")
        let nested = folder(name: "Weekly", parentId: reports.id)
        let inNested = favorite(name: "Counts", folderId: nested.id)
        let atRoot = favorite(name: "Scratch", folderId: nil)

        let roots = FavoritesTreeBuilder.build(
            folders: [reports, nested],
            favorites: [inNested, atRoot]
        )

        #expect(folderIds(roots) == [reports.id])
        #expect(favoriteIds(roots) == [atRoot.id])
        #expect(folderIds(roots[0].children ?? []) == [nested.id])
        #expect(favoriteIds(roots[0].children?[0].children ?? []) == [inNested.id])
    }
}
