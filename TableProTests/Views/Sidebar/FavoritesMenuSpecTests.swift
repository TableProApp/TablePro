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

    private func commands(_ sections: [FavoritesMenuSection]) -> [FavoritesMenuCommand] {
        commands(sections.flatMap(\.items))
    }

    private func commands(_ items: [FavoritesMenuItem]) -> [FavoritesMenuCommand] {
        items.flatMap { item -> [FavoritesMenuCommand] in
            switch item {
            case .command(let entry): return [entry.command]
            case .submenu(_, let nested): return commands(nested)
            }
        }
    }

    private func favorite(folderId: UUID? = nil, connectionId: UUID? = nil) -> SQLFavorite {
        SQLFavorite(
            id: UUID(),
            name: "Report",
            query: "SELECT 1",
            keyword: nil,
            folderId: folderId,
            connectionId: connectionId
        )
    }

    private func isOnStates(_ sections: [FavoritesMenuSection], for command: FavoritesMenuCommand) -> [Bool?] {
        entries(sections.flatMap(\.items))
            .filter { $0.command == command }
            .map(\.isOn)
    }

    private func entries(_ items: [FavoritesMenuItem]) -> [SidebarMenuEntry<FavoritesMenuCommand>] {
        items.flatMap { item -> [SidebarMenuEntry<FavoritesMenuCommand>] in
            switch item {
            case .command(let entry): return [entry]
            case .submenu(_, let nested): return entries(nested.flatMap(\.items))
            }
        }
    }

    private func table() -> TableInfo {
        TableInfo(name: "orders", type: .table, rowCount: nil, schema: "public")
    }

    private func database() -> FavoriteDatabaseEntry {
        FavoriteDatabaseEntry(connectionId: UUID(), database: "analytics", environment: .development)
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
            .databaseEnvironment(FavoriteDatabaseGroup(environment: .development, entries: [database()])),
            .database(database()),
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
            #expect(!FavoritesMenuSpec.sections(for: context(clicked: kind)).isEmpty)
        }
    }

    /// The HIG asks for about three groups. Placing the separators is the builder's job now, so
    /// what this can still get wrong is the number of groups it asks for.
    @Test("No menu carries more than four groups")
    func menusStayWithinFourGroups() {
        let kinds: [FavoritesOutlineNode.Kind?] = [
            nil,
            .database(database()),
            .table(table()),
            .query(.favorite(favorite())),
            .query(.folder(SQLFavoriteFolder(name: "Reports"), children: []))
        ]

        for kind in kinds {
            let sections = FavoritesMenuSpec.sections(for: context(clicked: kind)).nonEmptySections()
            #expect(sections.count <= 4, "\(String(describing: kind)) produced \(sections.count) groups")
        }
    }

    /// These moved out of the bar at the bottom of the sidebar.
    @Test("The empty area carries the commands the bottom bar used to")
    func backgroundOffersCreation() {
        let issued = commands(FavoritesMenuSpec.sections(for: context(clicked: nil)))

        #expect(issued.contains(.newQuery))
        #expect(issued.contains(.newFavorite(folderId: nil)))
        #expect(issued.contains(.newFolder(parentId: nil)))
        #expect(issued.contains(.addLinkedFolder))
    }

    @Test("Publishing to the team appears only when the licence allows it")
    func teamPublishIsGated() {
        let with = commands(FavoritesMenuSpec.sections(for: context(clicked: nil, teamLibraryAvailable: true)))
        let without = commands(FavoritesMenuSpec.sections(for: context(clicked: nil, teamLibraryAvailable: false)))

        #expect(with.contains(.publishSavedQueriesToTeam))
        #expect(!without.contains(.publishSavedQueriesToTeam))
    }

    @Test("A database favorite can switch, change environment, or be removed")
    func databaseFavoriteCommands() {
        let entry = database()
        let issued = commands(FavoritesMenuSpec.sections(for: FavoritesMenuContext(
            clicked: .database(entry),
            databaseEntityName: "Database",
            activeDatabase: "other"
        )))

        #expect(issued.contains(.useDatabase(entry)))
        #expect(issued.contains(.setDatabaseEnvironment(entry, .production)))
        #expect(issued.contains(.removeDatabaseFavorite(entry)))
    }

    @Test("The active database omits a redundant switch command")
    func activeDatabaseOmitsSwitch() {
        let entry = database()
        let issued = commands(FavoritesMenuSpec.sections(for: FavoritesMenuContext(
            clicked: .database(entry),
            databaseEntityName: "Database",
            activeDatabase: entry.database
        )))

        #expect(!issued.contains(.useDatabase(entry)))
    }

    @Test("Move to lists every folder except the one the favourite is already in")
    func moveToSkipsTheCurrentFolder() {
        let home = SQLFavoriteFolder(name: "Home")
        let other = SQLFavoriteFolder(name: "Other")
        let issued = commands(FavoritesMenuSpec.sections(
            for: context(clicked: .query(.favorite(favorite(folderId: home.id))), allFolders: [home, other])
        ))

        #expect(moveTargets(issued).contains(other.id))
        #expect(!moveTargets(issued).contains(home.id))
    }

    /// Issue #3045. A folder belonging to one connection cannot hold a query every connection is
    /// meant to see: the folder is absent everywhere else, and the query was drawn nowhere.
    @Test("A global favourite is not offered a folder belonging to one connection")
    func moveToHidesScopedFoldersFromAGlobalFavourite() {
        let connectionId = UUID()
        let scoped = SQLFavoriteFolder(name: "This connection", connectionId: connectionId)
        let global = SQLFavoriteFolder(name: "Everywhere", connectionId: nil)
        let issued = commands(FavoritesMenuSpec.sections(
            for: context(
                clicked: .query(.favorite(favorite(connectionId: nil))),
                allFolders: [scoped, global]
            )
        ))

        #expect(moveTargets(issued).contains(global.id))
        #expect(!moveTargets(issued).contains(scoped.id))
    }

    /// A container is allowed to be the wider of the two, so a query belonging to one connection
    /// can go in a global folder.
    @Test("A favourite belonging to one connection is offered both its own folders and global ones")
    func moveToOffersEveryFolderAScopedFavouriteCanUse() {
        let connectionId = UUID()
        let scoped = SQLFavoriteFolder(name: "This connection", connectionId: connectionId)
        let global = SQLFavoriteFolder(name: "Everywhere", connectionId: nil)
        let issued = commands(FavoritesMenuSpec.sections(
            for: context(
                clicked: .query(.favorite(favorite(connectionId: connectionId))),
                allFolders: [scoped, global]
            )
        ))

        #expect(moveTargets(issued).contains(scoped.id))
        #expect(moveTargets(issued).contains(global.id))
    }

    /// A query re-homed to the root because its folder belongs to another connection still names
    /// that folder. On a connection holding no folders of its own there was nothing to detach it
    /// with, because the submenu was skipped whenever the folder list was empty.
    @Test("A favourite still naming an unreachable folder is offered Root Level with no folders present")
    func moveToOffersRootLevelWithNoFolders() {
        let issued = commands(FavoritesMenuSpec.sections(
            for: context(clicked: .query(.favorite(favorite(folderId: UUID(), connectionId: nil))), allFolders: [])
        ))

        #expect(moveTargets(issued).contains(nil))
    }

    // MARK: - Folder scope

    @Test("A folder belonging to one connection offers to become global")
    func aScopedFolderOffersGlobal() {
        let folder = SQLFavoriteFolder(name: "Reports", connectionId: UUID())
        let sections = FavoritesMenuSpec.sections(for: context(clicked: .query(.folder(folder, children: []))))

        #expect(isOnStates(sections, for: .setFolderGlobal(folder, true)) == [false])
    }

    @Test("A global folder shows a checked item that turns it off")
    func aGlobalFolderShowsItsStateChecked() {
        let folder = SQLFavoriteFolder(name: "Reports", connectionId: nil)
        let sections = FavoritesMenuSpec.sections(for: context(clicked: .query(.folder(folder, children: []))))

        #expect(isOnStates(sections, for: .setFolderGlobal(folder, false)) == [true])
    }

    @Test("A favourite in a folder can be moved back to the root")
    func rootLevelOfferedFromInsideAFolder() {
        let home = SQLFavoriteFolder(name: "Home")
        let issued = commands(FavoritesMenuSpec.sections(
            for: context(clicked: .query(.favorite(favorite(folderId: home.id))), allFolders: [home])
        ))

        #expect(moveTargets(issued).contains(nil))
    }

    @Test("A favourite already at the root is not offered Root Level again")
    func rootLevelOnlyWhenInAFolder() {
        let folder = SQLFavoriteFolder(name: "Home")
        let issued = commands(FavoritesMenuSpec.sections(
            for: context(clicked: .query(.favorite(favorite(folderId: nil))), allFolders: [folder])
        ))

        #expect(!moveTargets(issued).contains(nil))
    }

    @Test("A linked folder offers Enable when it is disabled and Disable when it is not")
    func linkedFolderTogglesByState() {
        var folder = LinkedSQLFolder(path: "~/queries")
        let enabled = commands(FavoritesMenuSpec.sections(
            for: context(clicked: .query(.linkedFolder(folder, children: [])))
        ))
        folder.isEnabled = false
        let disabled = commands(FavoritesMenuSpec.sections(
            for: context(clicked: .query(.linkedFolder(folder, children: [])))
        ))

        #expect(enabled.contains(.setLinkedFolderEnabled(folder, false)) == false)
        #expect(disabled.contains(.setLinkedFolderEnabled(folder, true)))
    }
}
