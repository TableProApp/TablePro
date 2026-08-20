//
//  FavoritesMenuSpecTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Favorites contextual menu")
struct FavoritesMenuSpecTests {
    private func context(
        clicked: FavoritesOutlineNode.Kind?,
        allFolders: [SQLFavoriteFolder] = [],
        teamLibraryAvailable: Bool = false
    ) -> FavoritesMenuContext {
        FavoritesMenuContext(
            clicked: clicked,
            allFolders: allFolders,
            teamLibraryAvailable: teamLibraryAvailable
        )
    }

    private func commands(_ items: [FavoritesMenuItem]) -> [FavoritesMenuCommand] {
        items.flatMap { item -> [FavoritesMenuCommand] in
            switch item {
            case .separator: return []
            case .command(let entry): return [entry.command]
            case .submenu(_, let nested): return commands(nested)
            }
        }
    }

    private func favorite(folderId: UUID? = nil) -> SQLFavorite {
        SQLFavorite(id: UUID(), name: "Report", query: "SELECT 1", keyword: nil, folderId: folderId)
    }

    private func table() -> TableInfo {
        TableInfo(name: "orders", type: .table, rowCount: nil, schema: "public")
    }

    private func moveTargets(_ issued: [FavoritesMenuCommand]) -> [UUID?] {
        issued.compactMap { command in
            guard case .moveFavorite(_, let target) = command else { return nil }
            return target
        }
    }

    /// A menu that updates to nothing still opens as a small empty frame, so every row has to
    /// produce something. A linked subfolder shipped as exactly that empty frame.
    @Test("Every row kind produces a menu with at least one item")
    func everyRowHasAMenu() {
        let folder = SQLFavoriteFolder(name: "Reports")
        let linked = LinkedSQLFolder(path: "~/queries")
        let kinds: [FavoritesOutlineNode.Kind?] = [
            nil,
            .header("Queries"),
            .table(table()),
            .teamQuery(id: "1", name: "Shared", publishedBy: "Sam"),
            .query(.favorite(favorite())),
            .query(.folder(folder, children: [])),
            .query(.linkedFolder(linked, children: [])),
            .query(.linkedSubfolder(
                folderId: linked.id, displayName: "reports", pathPrefix: "reports", children: []
            ))
        ]

        for kind in kinds {
            #expect(!FavoritesMenuSpec.items(for: context(clicked: kind)).isEmpty)
        }
    }

    @Test("A menu never opens or closes on a separator, and never doubles one")
    func separatorsAreCollapsed() {
        let kinds: [FavoritesOutlineNode.Kind?] = [
            nil,
            .table(table()),
            .query(.favorite(favorite())),
            .query(.folder(SQLFavoriteFolder(name: "Reports"), children: []))
        ]

        for kind in kinds {
            let items = FavoritesMenuSpec.items(for: context(clicked: kind))
            #expect(items.first != .separator)
            #expect(items.last != .separator)
            for (previous, next) in zip(items, items.dropFirst()) {
                #expect(!(previous == .separator && next == .separator))
            }
        }
    }

    /// These moved out of the bar at the bottom of the sidebar.
    @Test("The empty area carries the commands the bottom bar used to")
    func backgroundOffersCreation() {
        let issued = commands(FavoritesMenuSpec.items(for: context(clicked: nil)))

        #expect(issued.contains(.newQuery))
        #expect(issued.contains(.newFavorite(folderId: nil)))
        #expect(issued.contains(.newFolder(parentId: nil)))
        #expect(issued.contains(.addLinkedFolder))
    }

    @Test("Publishing to the team appears only when the licence allows it")
    func teamPublishIsGated() {
        let with = commands(FavoritesMenuSpec.items(for: context(clicked: nil, teamLibraryAvailable: true)))
        let without = commands(FavoritesMenuSpec.items(for: context(clicked: nil, teamLibraryAvailable: false)))

        #expect(with.contains(.publishSavedQueriesToTeam))
        #expect(!without.contains(.publishSavedQueriesToTeam))
    }

    @Test("Move to lists every folder except the one the favourite is already in")
    func moveToSkipsTheCurrentFolder() {
        let home = SQLFavoriteFolder(name: "Home")
        let other = SQLFavoriteFolder(name: "Other")
        let issued = commands(FavoritesMenuSpec.items(
            for: context(clicked: .query(.favorite(favorite(folderId: home.id))), allFolders: [home, other])
        ))

        #expect(moveTargets(issued).contains(other.id))
        #expect(!moveTargets(issued).contains(home.id))
    }

    @Test("A favourite in a folder can be moved back to the root")
    func rootLevelOfferedFromInsideAFolder() {
        let home = SQLFavoriteFolder(name: "Home")
        let issued = commands(FavoritesMenuSpec.items(
            for: context(clicked: .query(.favorite(favorite(folderId: home.id))), allFolders: [home])
        ))

        #expect(moveTargets(issued).contains(nil))
    }

    @Test("A favourite already at the root is not offered Root Level again")
    func rootLevelOnlyWhenInAFolder() {
        let folder = SQLFavoriteFolder(name: "Home")
        let issued = commands(FavoritesMenuSpec.items(
            for: context(clicked: .query(.favorite(favorite(folderId: nil))), allFolders: [folder])
        ))

        #expect(!moveTargets(issued).contains(nil))
    }

    @Test("A linked folder offers Enable when it is disabled and Disable when it is not")
    func linkedFolderTogglesByState() {
        var folder = LinkedSQLFolder(path: "~/queries")
        let enabled = commands(FavoritesMenuSpec.items(
            for: context(clicked: .query(.linkedFolder(folder, children: [])))
        ))
        folder.isEnabled = false
        let disabled = commands(FavoritesMenuSpec.items(
            for: context(clicked: .query(.linkedFolder(folder, children: [])))
        ))

        #expect(enabled.contains(.setLinkedFolderEnabled(folder, false)) == false)
        #expect(disabled.contains(.setLinkedFolderEnabled(folder, true)))
    }
}
