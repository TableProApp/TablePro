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

    internal init(
        clicked: FavoritesOutlineNode.Kind?,
        allFolders: [SQLFavoriteFolder] = [],
        teamLibraryAvailable: Bool = false
    ) {
        self.clicked = clicked
        self.allFolders = allFolders
        self.teamLibraryAvailable = teamLibraryAvailable
    }
}

internal enum FavoritesMenuSpec {
    internal static func items(for context: FavoritesMenuContext) -> [FavoritesMenuItem] {
        SidebarMenuItem.collapsingSeparators(rawItems(for: context))
    }

    private static func rawItems(for context: FavoritesMenuContext) -> [FavoritesMenuItem] {
        guard let clicked = context.clicked else { return backgroundItems(context) }
        switch clicked {
        case .table(let table):
            return tableItems(table)
        case .query(let node):
            return queryItems(node, context: context)
        case .header, .teamQuery:
            return backgroundItems(context)
        }
    }

    private static func tableItems(_ table: TableInfo) -> [FavoritesMenuItem] {
        [
            .command(String(localized: "Open Table"), .openTable(table)),
            .command(String(localized: "Show ER Diagram"), .showERDiagram),
            .separator,
            .destructive(String(localized: "Remove from Favorites"), .removeTableFavorite(table))
        ]
    }

    private static func queryItems(
        _ node: FavoriteNode,
        context: FavoritesMenuContext
    ) -> [FavoritesMenuItem] {
        switch node.content {
        case .favorite(let favorite):
            return favoriteItems(favorite, context: context)
        case .linkedFavorite(let linked):
            return linkedFavoriteItems(linked)
        case .folder(let folder):
            return folderItems(folder)
        case .linkedFolder(let folder):
            return linkedFolderItems(folder)
        case .linkedSubfolder:
            /// A subfolder mirrors a directory, so it owns no command of its own. It still gets the
            /// background menu rather than an empty frame.
            return backgroundItems(context)
        }
    }

    private static func favoriteItems(
        _ favorite: SQLFavorite,
        context: FavoritesMenuContext
    ) -> [FavoritesMenuItem] {
        var items: [FavoritesMenuItem] = [
            .command(String(localized: "Insert in Editor"), .insertFavorite(favorite)),
            .command(String(localized: "Run in New Tab"), .runFavoriteInNewTab(favorite)),
            .separator,
            .command(String(localized: "Copy Query"), .copyText(favorite.query)),
            .command(String(localized: "Edit…"), .editFavorite(favorite))
        ]
        if let moveTo = moveToSubmenu(favorite, folders: context.allFolders) {
            items.append(moveTo)
        }
        items.append(.separator)
        items.append(.destructive(String(localized: "Delete"), .deleteFavorite(favorite)))
        return items
    }

    private static func moveToSubmenu(
        _ favorite: SQLFavorite,
        folders: [SQLFavoriteFolder]
    ) -> FavoritesMenuItem? {
        guard !folders.isEmpty else { return nil }
        var nested: [FavoritesMenuItem] = []
        if favorite.folderId != nil {
            nested.append(.command(
                String(localized: "Root Level"),
                .moveFavorite(id: favorite.id, toFolder: nil)
            ))
            nested.append(.separator)
        }
        nested += folders
            .filter { $0.id != favorite.folderId }
            .map { .command($0.name, .moveFavorite(id: favorite.id, toFolder: $0.id)) }
        guard nested.contains(where: { if case .command = $0 { return true } else { return false } })
        else { return nil }
        return .submenu(title: String(localized: "Move to"), items: SidebarMenuItem.collapsingSeparators(nested))
    }

    private static func linkedFavoriteItems(_ favorite: LinkedSQLFavorite) -> [FavoritesMenuItem] {
        [
            .command(String(localized: "Open in Editor"), .openLinkedFavorite(favorite)),
            .command(String(localized: "Edit Metadata…"), .editLinkedMetadata(favorite)),
            .separator,
            .command(String(localized: "Copy Query"), .copyLinkedFavoriteQuery(favorite)),
            .command(String(localized: "Show in Finder"), .revealLinkedFavorite(favorite)),
            .separator,
            .destructive(String(localized: "Move File to Trash"), .trashLinkedFavorite(favorite))
        ]
    }

    private static func linkedFolderItems(_ folder: LinkedSQLFolder) -> [FavoritesMenuItem] {
        [
            .command(String(localized: "Show in Finder"), .revealLinkedFolder(folder)),
            .command(String(localized: "Copy Path"), .copyText(folder.expandedURL.path)),
            .separator,
            .command(
                folder.isEnabled ? String(localized: "Disable") : String(localized: "Enable"),
                .setLinkedFolderEnabled(folder, !folder.isEnabled)
            ),
            .command(String(localized: "Reload"), .reloadLinkedFolders),
            .separator,
            .command(String(localized: "Add Another SQL Folder…"), .addLinkedFolder),
            .separator,
            .destructive(String(localized: "Remove from Sidebar"), .removeLinkedFolder(folder))
        ]
    }

    private static func folderItems(_ folder: SQLFavoriteFolder) -> [FavoritesMenuItem] {
        [
            .command(String(localized: "Rename"), .renameFolder(folder)),
            .command(String(localized: "New Favorite…"), .newFavorite(folderId: folder.id)),
            .command(String(localized: "New Subfolder"), .newFolder(parentId: folder.id)),
            .separator,
            .destructive(String(localized: "Delete Folder"), .deleteFolder(folder))
        ]
    }

    /// The empty area below the last row, a header, and a Team Library row all land here. It is the
    /// same list the bottom bar's plus button used to carry, which is where those commands go now
    /// that the sidebar has no bottom bar.
    internal static func backgroundItems(_ context: FavoritesMenuContext) -> [FavoritesMenuItem] {
        var items: [FavoritesMenuItem] = [
            .command(String(localized: "New Query"), .newQuery),
            .separator,
            .command(String(localized: "New Favorite…"), .newFavorite(folderId: nil)),
            .command(String(localized: "New Folder"), .newFolder(parentId: nil)),
            .separator,
            .command(String(localized: "Add Linked SQL Folder…"), .addLinkedFolder)
        ]
        guard context.teamLibraryAvailable else { return items }
        items.append(.separator)
        items.append(.command(
            String(localized: "Publish Saved Queries to Team…"),
            .publishSavedQueriesToTeam
        ))
        return items
    }
}
