//
//  FavoritesMenuSpecTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct FavoritesMenuSpecTests {
    private func context(
        clicked: FavoritesOutlineNode.Kind?,
        allFolders: [SQLFavoriteFolder] = [],
        teamLibraryAvailable: Bool = false,
        activeDatabase: String? = "shop"
    ) -> FavoritesMenuContext {
        FavoritesMenuContext(
            clicked: clicked,
            allFolders: allFolders,
            teamLibraryAvailable: teamLibraryAvailable,
            activeDatabase: activeDatabase
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

    private func table(schema: String = "public", otherSchema: String? = nil) -> FavoriteTableRow {
        FavoriteTableRow(
            entry: FavoriteTablesStorage.FavoriteEntry(
                connectionId: UUID(), database: "shop", schema: schema, name: "orders"
            ),
            listedTable: TableInfo(name: "orders", type: .table, rowCount: nil, schema: schema),
            isVerified: true,
            otherSchema: otherSchema
        )
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
                folderId: linked.id,
                displayName: "reports",
                pathPrefix: "reports",
                url: URL(fileURLWithPath: "/tmp/queries/reports", isDirectory: true),
                children: []
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

    @Test("A table row opens, diagrams and removes the favorite it was built from")
    func tableRowCommandsCarryTheRow() {
        let row = table()
        let issued = commands(FavoritesMenuSpec.sections(for: context(clicked: .table(row))))

        #expect(issued == [.openTable(row), .showERDiagram(schema: nil), .removeTableFavorite(row.entry)])
    }

    @Test("A table outside the browsed schema diagrams its own schema")
    func otherSchemaRowDiagramsItsSchema() {
        let row = table(schema: "sales", otherSchema: "sales")
        let issued = commands(FavoritesMenuSpec.sections(for: context(clicked: .table(row))))

        #expect(issued.contains(.showERDiagram(schema: "sales")))
        #expect(issued.contains(.removeTableFavorite(row.entry)))
    }

    @Test("A diagram the tab could not tell apart from the browsed schema's is not offered")
    func unrepresentableDiagramIsNotOffered() {
        let noDatabase = commands(FavoritesMenuSpec.sections(for: context(
            clicked: .table(table(schema: "sales", otherSchema: "sales")),
            activeDatabase: nil
        )))
        let markerSchema = commands(FavoritesMenuSpec.sections(for: context(
            clicked: .table(table(schema: "default", otherSchema: "default"))
        )))
        let browsedSchema = commands(FavoritesMenuSpec.sections(for: context(
            clicked: .table(table()),
            activeDatabase: nil
        )))

        #expect(!noDatabase.contains { if case .showERDiagram = $0 { true } else { false } })
        #expect(!markerSchema.contains { if case .showERDiagram = $0 { true } else { false } })
        #expect(browsedSchema.contains(.showERDiagram(schema: nil)))
    }

    @Test("The empty area carries the creation commands")
    func backgroundOffersCreation() {
        let issued = commands(FavoritesMenuSpec.sections(for: context(clicked: nil)))

        #expect(issued.contains(.newQuery))
        #expect(issued.contains(.newFavorite(folderId: nil)))
        #expect(issued.contains(.newFolder(parentId: nil)))
        #expect(issued.contains(.addLinkedFolder))
    }

    @Test("The add button's list is the empty area's first two groups, without Publish")
    func addButtonMatchesTheEmptyArea() {
        let creation = FavoritesMenuSpec.creationSections()
        for teamLibraryAvailable in [false, true] {
            let background = FavoritesMenuSpec.sections(for: context(
                clicked: nil,
                teamLibraryAvailable: teamLibraryAvailable
            ))
            #expect(Array(background.prefix(2)) == creation)
        }

        #expect(creation.count == 2)
        #expect(commands(creation) == [
            .newQuery,
            .newFavorite(folderId: nil),
            .newFolder(parentId: nil),
            .addLinkedFolder
        ])
        #expect(!commands(creation).contains(.publishSavedQueriesToTeam))
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

    @Test("A saved query offers its history")
    func savedQueryOffersHistory() {
        let query = favorite()
        let issued = commands(FavoritesMenuSpec.sections(for: context(clicked: .query(.favorite(query)))))
        #expect(issued.contains(.showFavoriteHistory(query)))
    }

    private func linkedFile() -> LinkedSQLFavorite {
        LinkedSQLFavorite(
            folderId: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/queries/orders.sql"),
            relativePath: "orders.sql",
            name: "orders",
            mtime: Date(),
            fileSize: 10
        )
    }

    private func linkedCommands(_ file: LinkedSQLFavorite, gitState: LinkedFileGitState?) -> [FavoritesMenuCommand] {
        let states = gitState.map { [file.id: $0] } ?? [:]
        return commands(FavoritesMenuSpec.sections(for: FavoritesMenuContext(
            clicked: .query(.linkedFavorite(file)),
            linkedFileGitStates: states
        )))
    }

    @Test("A linked file outside a repository offers no Git commands")
    func linkedFileOutsideRepository() {
        let file = linkedFile()
        let issued = linkedCommands(file, gitState: nil)
        #expect(!issued.contains(.showLinkedFileHistory(file)))
        #expect(!issued.contains(.discardLinkedFileChanges(file)))
        #expect(issued.contains(.openLinkedFavorite(file)))
    }

    @Test("A clean tracked file offers history but nothing to discard")
    func cleanTrackedFile() {
        let file = linkedFile()
        let issued = linkedCommands(file, gitState: .clean)
        #expect(issued.contains(.showLinkedFileHistory(file)))
        #expect(!issued.contains(.discardLinkedFileChanges(file)))
    }

    @Test("A modified file offers history and Discard Changes")
    func modifiedFile() {
        let file = linkedFile()
        let issued = linkedCommands(file, gitState: .changed(GitFileStatus(staged: .unmodified, unstaged: .modified)))
        #expect(issued.contains(.showLinkedFileHistory(file)))
        #expect(issued.contains(.discardLinkedFileChanges(file)))
    }

    private func items(_ sections: [FavoritesMenuSection]) -> [[FavoritesMenuCommand]] {
        sections.nonEmptySections().map { commands($0.items) }
    }

    @Test("A linked file copies its absolute and relative paths between Copy Query and Show in Finder")
    func linkedFileOffersBothPaths() {
        let file = LinkedSQLFavorite(
            folderId: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/queries/reports/daily.sql"),
            relativePath: "reports/daily.sql",
            name: "daily",
            mtime: Date(),
            fileSize: 10
        )
        let groups = items(FavoritesMenuSpec.sections(for: FavoritesMenuContext(clicked: .query(.linkedFavorite(file)))))

        #expect(groups.contains([
            .copyLinkedFavoriteQuery(file),
            .copyPath("/tmp/queries/reports/daily.sql"),
            .copyRelativePath("reports/daily.sql"),
            .revealLinkedFavorite(file)
        ]))
    }

    @Test("A linked folder copies its absolute path and has no relative one")
    func linkedFolderOffersAbsolutePathOnly() {
        let folder = LinkedSQLFolder(path: "/tmp/queries")
        let groups = items(FavoritesMenuSpec.sections(for: context(clicked: .query(.linkedFolder(folder, children: [])))))

        #expect(groups.first == [.revealLinkedFolder(folder), .copyPath("/tmp/queries")])
        #expect(!groups.joined().contains { if case .copyRelativePath = $0 { true } else { false } })
    }

    @Test("A linked subfolder reveals and copies its own paths instead of the background menu")
    func linkedSubfolderOffersItsPaths() {
        let url = URL(fileURLWithPath: "/tmp/queries/reports/2026", isDirectory: true)
        let subfolder = FavoriteNode.linkedSubfolder(
            folderId: UUID(),
            displayName: "2026",
            pathPrefix: "reports/2026",
            url: url,
            children: []
        )
        let groups = items(FavoritesMenuSpec.sections(for: context(clicked: .query(subfolder))))

        #expect(groups == [[
            .revealLinkedSubfolder(url),
            .copyPath("/tmp/queries/reports/2026"),
            .copyRelativePath("reports/2026")
        ]])
    }

    @Test("A saved query and its folder live in the database, so they offer no path")
    func storedRowsOfferNoPath() {
        let kinds: [FavoritesOutlineNode.Kind] = [
            .query(.favorite(favorite())),
            .query(.folder(SQLFavoriteFolder(name: "Reports"), children: []))
        ]

        for kind in kinds {
            let issued = commands(FavoritesMenuSpec.sections(for: context(clicked: kind)))
            #expect(!issued.contains { command in
                switch command {
                case .copyPath, .copyRelativePath: true
                default: false
                }
            })
        }
    }

    @Test("The path commands show the File menu's shortcuts")
    func pathCommandsShareTheMenuBarShortcuts() {
        #expect(FavoritesMenuCommand.copyPath("/tmp/a.sql").shortcutAction == .copyPath)
        #expect(FavoritesMenuCommand.copyRelativePath("a.sql").shortcutAction == .copyRelativePath)
        #expect(FavoritesMenuCommand.copyText("SELECT 1").shortcutAction == nil)
    }

    @Test("An untracked file offers neither history nor Discard Changes")
    func untrackedFile() {
        let file = linkedFile()
        let issued = linkedCommands(file, gitState: .changed(.untracked))
        #expect(!issued.contains(.showLinkedFileHistory(file)))
        #expect(!issued.contains(.discardLinkedFileChanges(file)))
        #expect(issued.contains(.trashLinkedFavorite(file)))
    }

    private func folderCommands(
        _ folder: LinkedSQLFolder,
        gitState: LinkedFolderGitMenuState?
    ) -> [[FavoritesMenuCommand]] {
        items(FavoritesMenuSpec.sections(for: FavoritesMenuContext(
            clicked: .query(.linkedFolder(folder, children: [])),
            linkedFolderGitStates: gitState.map { [folder.id: $0] } ?? [:]
        )))
    }

    @Test("A linked folder in a repository offers Commit, Pull and Push as one group after its paths")
    func linkedFolderGitGroup() {
        let folder = LinkedSQLFolder(path: "/tmp/queries")
        let groups = folderCommands(folder, gitState: LinkedFolderGitMenuState(hasChanges: true, isBusy: false))

        #expect(groups.count == 4)
        #expect(groups[1] == [.commitLinkedFolder(folder), .pullLinkedFolder(folder), .pushLinkedFolder(folder)])
    }

    @Test("A clean linked folder offers Pull and Push but nothing to commit")
    func cleanLinkedFolder() {
        let folder = LinkedSQLFolder(path: "/tmp/queries")
        let issued = folderCommands(folder, gitState: LinkedFolderGitMenuState(hasChanges: false, isBusy: false)).joined()

        #expect(!issued.contains(.commitLinkedFolder(folder)))
        #expect(issued.contains(.pullLinkedFolder(folder)))
        #expect(issued.contains(.pushLinkedFolder(folder)))
    }

    @Test("A linked folder outside a repository, or one whose repository is busy, offers no Git commands")
    func linkedFolderWithoutGit() {
        let folder = LinkedSQLFolder(path: "/tmp/queries")
        for state in [nil, LinkedFolderGitMenuState(hasChanges: true, isBusy: true)] {
            let issued = folderCommands(folder, gitState: state).joined()
            #expect(!issued.contains(.commitLinkedFolder(folder)))
            #expect(!issued.contains(.pullLinkedFolder(folder)))
            #expect(!issued.contains(.pushLinkedFolder(folder)))
            #expect(issued.contains(.removeLinkedFolder(folder)))
        }
    }

    private func linkedCommands(
        _ file: LinkedSQLFavorite,
        gitState: LinkedFileGitState,
        folderState: LinkedFolderGitMenuState
    ) -> [FavoritesMenuCommand] {
        commands(FavoritesMenuSpec.sections(for: FavoritesMenuContext(
            clicked: .query(.linkedFavorite(file)),
            linkedFileGitStates: [file.id: gitState],
            linkedFolderGitStates: [file.folderId: folderState]
        )))
    }

    @Test("A changed linked file offers Commit first in its Git group, unless it is conflicted or its repository is busy")
    func changedFileOffersCommit() {
        let file = linkedFile()
        let idle = LinkedFolderGitMenuState(hasChanges: true, isBusy: false)
        let modified = GitFileStatus(staged: .unmodified, unstaged: .modified)

        let issued = linkedCommands(file, gitState: .changed(modified), folderState: idle)
        #expect(issued.firstIndex(of: .commitLinkedFile(file)) == issued.firstIndex(of: .showLinkedFileHistory(file)).map { $0 - 1 })
        #expect(linkedCommands(file, gitState: .changed(.untracked), folderState: idle).contains(.commitLinkedFile(file)))
        #expect(!linkedCommands(file, gitState: .clean, folderState: idle).contains(.commitLinkedFile(file)))
        let conflicted = GitFileStatus(staged: .unmerged, unstaged: .unmerged, isUnmergedEntry: true)
        #expect(!linkedCommands(file, gitState: .changed(conflicted), folderState: idle).contains(.commitLinkedFile(file)))
        let busy = LinkedFolderGitMenuState(hasChanges: true, isBusy: true)
        #expect(!linkedCommands(file, gitState: .changed(modified), folderState: busy).contains(.commitLinkedFile(file)))
    }
}
