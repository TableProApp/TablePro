//
//  FavoritesSidebarViewModel+LinkedFolders.swift
//  TablePro
//

import AppKit
import Foundation
import TableProImport
import TableProPluginKit

/// Linked SQL folders are files on disk, so managing them is storage work rather than view work.
/// It lived in `FavoritesTabView` alongside the rows it drew, which meant the view owned an
/// `NSOpenPanel`, two storage classes and the folder watcher.
extension FavoritesSidebarViewModel {
    internal enum AddFolderOutcome: Equatable {
        case added
        case reEnabled
        case alreadyLinked(name: String)
    }

    internal func startWatchingLinkedFolders() {
        SQLFolderWatcher.shared.start()
    }

    internal func reloadLinkedFolders() {
        SQLFolderWatcher.shared.reload()
    }

    internal func setLinkedFolder(_ folder: LinkedSQLFolder, enabled: Bool) {
        var updated = folder
        updated.isEnabled = enabled
        LinkedSQLFolderStorage.shared.updateFolder(updated)
        SQLFolderWatcher.shared.reload()
    }

    internal func removeLinkedFolder(_ folder: LinkedSQLFolder) {
        LinkedSQLFolderStorage.shared.removeFolder(folder)
        SQLFolderWatcher.shared.reload()
    }

    /// Choosing a folder that is already linked but disabled re-enables it. Refusing it outright,
    /// which is what happened before, pointed the user at a list the folder was invisible in.
    @discardableResult
    internal func addLinkedFolder(at url: URL) -> AddFolderOutcome {
        let path = PathPortability.contractHome(url.path)
        guard let existing = LinkedSQLFolderStorage.shared.loadFolders().first(where: { $0.path == path }) else {
            LinkedSQLFolderStorage.shared.addFolder(LinkedSQLFolder(path: path))
            SQLFolderWatcher.shared.reload()
            return .added
        }
        guard existing.isEnabled else {
            setLinkedFolder(existing, enabled: true)
            return .reEnabled
        }
        return .alreadyLinked(name: url.lastPathComponent)
    }

    internal func revealLinkedFolder(_ folder: LinkedSQLFolder) {
        NSWorkspace.shared.activateFileViewerSelecting([folder.expandedURL])
    }

    internal func favoriteTables(for connectionId: UUID) -> [FavoriteTablesStorage.FavoriteEntry] {
        FavoriteTablesStorage.shared.favorites(for: connectionId).sorted { $0.name < $1.name }
    }

    internal func removeTableFavorite(_ table: TableInfo, database: String?) {
        FavoriteTablesStorage.shared.removeFavorite(
            name: table.name, schema: table.schema, database: database, connectionId: connectionId
        )
    }
}
