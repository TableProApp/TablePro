//
//  FavoritesMenuSpec.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct FavoritesMenuContext {
    internal let clicked: FavoritesOutlineNode.Kind?
    internal let allFolders: [SQLFavoriteFolder]
    internal let teamLibraryAvailable: Bool
    internal let databaseEntityName: String
    internal let activeDatabase: String?

    internal init(
        clicked: FavoritesOutlineNode.Kind?,
        allFolders: [SQLFavoriteFolder] = [],
        teamLibraryAvailable: Bool = false,
        databaseEntityName: String = "Database",
        activeDatabase: String? = nil
    ) {
        self.clicked = clicked
        self.allFolders = allFolders
        self.teamLibraryAvailable = teamLibraryAvailable
        self.databaseEntityName = databaseEntityName
        self.activeDatabase = activeDatabase
    }
}

internal enum FavoritesMenuSpec {
    internal static func sections(for context: FavoritesMenuContext) -> [FavoritesMenuSection] {
        guard let clicked = context.clicked else { return backgroundSections(context) }
        switch clicked {
        case .databaseEnvironment:
            return backgroundSections(context)
        case .database(let entry):
            return databaseSections(entry, context: context)
        case .table(let table):
            return tableSections(table)
        case .query(let node):
            return querySections(node, context: context)
        case .header, .teamQuery:
            return backgroundSections(context)
        }
    }

    private static func databaseSections(
        _ entry: FavoriteDatabaseEntry,
        context: FavoritesMenuContext
    ) -> [FavoritesMenuSection] {
        var items: [FavoritesMenuItem] = []
        if entry.database != context.activeDatabase {
            items.append(.command(
                String(
                    format: String(localized: "Use as Active %@"),
                    context.databaseEntityName
                ),
                .useDatabase(entry)
            ))
        }
        let state = FavoriteDatabaseSelectionState(environments: [entry.environment])
        items.append(.submenu(
            title: FavoriteDatabaseMenu.submenuTitle(for: state),
            items: FavoriteDatabaseMenu.environmentItems(for: state).map { item in
                .command(SidebarMenuEntry(
                    title: item.title,
                    command: .setDatabaseEnvironment(entry, item.environment),
                    isOn: item.isOn
                ))
            }
        ))
        return [
            FavoritesMenuSection(items),
            FavoritesMenuSection([
                .command(FavoriteDatabaseMenu.removeTitle, .removeDatabaseFavorite(entry))
            ])
        ]
    }

    /// Spelled as the Database menu and the object tree spell it. It read "Show ER Diagram" here
    /// and "View ER Diagram" everywhere else, which is one command reading as two.
    private static func tableSections(_ table: TableInfo) -> [FavoritesMenuSection] {
        [
            FavoritesMenuSection([
                .command(String(localized: "Open Table"), .openTable(table)),
                .command(String(localized: "View ER Diagram"), .showERDiagram)
            ]),
            FavoritesMenuSection([
                .command(String(localized: "Remove from Favorites"), .removeTableFavorite(table))
            ])
        ]
    }

    private static func querySections(
        _ node: FavoriteNode,
        context: FavoritesMenuContext
    ) -> [FavoritesMenuSection] {
        switch node.content {
        case .favorite(let favorite):
            return favoriteSections(favorite, context: context)
        case .linkedFavorite(let linked):
            return linkedFavoriteSections(linked)
        case .folder(let folder):
            return folderSections(folder)
        case .linkedFolder(let folder):
            return linkedFolderSections(folder)
        case .linkedSubfolder:
            /// A subfolder mirrors a directory, so it owns no command of its own. It still gets the
            /// background menu rather than an empty frame.
            return backgroundSections(context)
        }
    }

    private static func favoriteSections(
        _ favorite: SQLFavorite,
        context: FavoritesMenuContext
    ) -> [FavoritesMenuSection] {
        var edits: [FavoritesMenuItem] = [
            .command(String(localized: "Copy Query"), .copyText(favorite.query)),
            .command(String(localized: "Edit…"), .editFavorite(favorite))
        ]
        if let moveTo = moveToSubmenu(favorite, folders: context.allFolders) {
            edits.append(moveTo)
        }
        return [
            FavoritesMenuSection([
                .command(String(localized: "Insert in Editor"), .insertFavorite(favorite)),
                .command(String(localized: "Run in New Tab"), .runFavoriteInNewTab(favorite))
            ]),
            FavoritesMenuSection(edits),
            FavoritesMenuSection([.command(String(localized: "Delete"), .deleteFavorite(favorite))])
        ]
    }

    private static func moveToSubmenu(
        _ favorite: SQLFavorite,
        folders: [SQLFavoriteFolder]
    ) -> FavoritesMenuItem? {
        guard !folders.isEmpty else { return nil }
        var root: [FavoritesMenuItem] = []
        if favorite.folderId != nil {
            root.append(.command(
                String(localized: "Root Level"),
                .moveFavorite(id: favorite.id, toFolder: nil)
            ))
        }
        let targets: [FavoritesMenuItem] = folders
            .filter { $0.id != favorite.folderId }
            .map { .command($0.name, .moveFavorite(id: favorite.id, toFolder: $0.id)) }
        guard !root.isEmpty || !targets.isEmpty else { return nil }
        return .submenu(
            title: String(localized: "Move to"),
            sections: [FavoritesMenuSection(root), FavoritesMenuSection(targets)]
        )
    }

    private static func linkedFavoriteSections(_ favorite: LinkedSQLFavorite) -> [FavoritesMenuSection] {
        [
            FavoritesMenuSection([
                .command(String(localized: "Open in Editor"), .openLinkedFavorite(favorite)),
                .command(String(localized: "Edit Metadata…"), .editLinkedMetadata(favorite))
            ]),
            FavoritesMenuSection([
                .command(String(localized: "Copy Query"), .copyLinkedFavoriteQuery(favorite)),
                .command(String(localized: "Show in Finder"), .revealLinkedFavorite(favorite))
            ]),
            FavoritesMenuSection([
                .command(String(localized: "Move File to Trash"), .trashLinkedFavorite(favorite))
            ])
        ]
    }

    private static func linkedFolderSections(_ folder: LinkedSQLFolder) -> [FavoritesMenuSection] {
        [
            FavoritesMenuSection([
                .command(String(localized: "Show in Finder"), .revealLinkedFolder(folder)),
                .command(String(localized: "Copy Path"), .copyText(folder.expandedURL.path))
            ]),
            FavoritesMenuSection([
                .command(
                    folder.isEnabled ? String(localized: "Disable") : String(localized: "Enable"),
                    .setLinkedFolderEnabled(folder, !folder.isEnabled)
                ),
                .command(String(localized: "Reload"), .reloadLinkedFolders),
                .command(String(localized: "Add Another SQL Folder…"), .addLinkedFolder)
            ]),
            FavoritesMenuSection([
                .command(String(localized: "Remove from Sidebar"), .removeLinkedFolder(folder))
            ])
        ]
    }

    private static func folderSections(_ folder: SQLFavoriteFolder) -> [FavoritesMenuSection] {
        [
            FavoritesMenuSection([
                .command(String(localized: "New Favorite…"), .newFavorite(folderId: folder.id)),
                .command(String(localized: "New Subfolder"), .newFolder(parentId: folder.id))
            ]),
            FavoritesMenuSection([.command(String(localized: "Rename"), .renameFolder(folder))]),
            FavoritesMenuSection([.command(String(localized: "Delete Folder"), .deleteFolder(folder))])
        ]
    }

    /// The empty area below the last row, a header, and a Team Library row all land here. It is the
    /// same list the bottom bar's plus button used to carry, which is where those commands go now
    /// that the sidebar has no bottom bar.
    internal static func backgroundSections(_ context: FavoritesMenuContext) -> [FavoritesMenuSection] {
        var team: [FavoritesMenuItem] = []
        if context.teamLibraryAvailable {
            team.append(.command(
                String(localized: "Publish Saved Queries to Team…"),
                .publishSavedQueriesToTeam
            ))
        }
        return [
            FavoritesMenuSection([.command(String(localized: "New Query"), .newQuery)]),
            FavoritesMenuSection([
                .command(String(localized: "New Favorite…"), .newFavorite(folderId: nil)),
                .command(String(localized: "New Folder"), .newFolder(parentId: nil)),
                .command(String(localized: "Add Linked SQL Folder…"), .addLinkedFolder)
            ]),
            FavoritesMenuSection(team)
        ]
    }
}
