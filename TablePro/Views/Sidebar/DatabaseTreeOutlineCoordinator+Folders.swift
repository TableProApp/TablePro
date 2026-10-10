//
//  DatabaseTreeOutlineCoordinator+Folders.swift
//  TablePro
//

import AppKit

/// Creating, filing, renaming and deleting table folders.
///
/// Every edit goes on the connection's undo stack, the one `TabWindowController` hands the window,
/// so Cmd+Z takes back a folder change the way it takes back a grid edit. The undo restores only the
/// folders and placements the edit touched, so a rename or a pull that landed in between survives it.
extension DatabaseTreeOutlineCoordinator {
    /// Only the flat list's folders belong to the browsed database and schema.
    internal var offersBrowsedFolders: Bool {
        rootShape == .flat && viewModel != nil
    }

    internal var canCreateBrowsedFolder: Bool {
        offersBrowsedFolders && folderScope(for: .browsed) != nil
    }

    internal func perform(_ command: TableFolderCommand) {
        switch command {
        case .create(let container):
            createFolder(in: container)
        case .createHolding(let refs):
            guard let first = refs.first, let scope = folderScope(of: first) else { return }
            createFolder(in: .scope(scope), containing: refs)
        case .move(let refs, let folder):
            fileObjects(refs, into: folder)
        case .remove(let refs):
            unfileObjects(refs)
        case .rename(let folder):
            beginRename(.folder(folder))
        case .delete(let folder):
            deleteFolder(folder)
        }
    }

    /// The new folder opens with its name selected in the row, the way Finder names a new folder.
    /// The tree is rebuilt at once rather than on the next change notification, because the field
    /// can only open on a row that exists.
    internal func createFolder(in container: TableFolderContainer, containing refs: [DatabaseTreeTableRef] = []) {
        guard let scope = folderScope(for: container) else { return }
        let names = names(of: refs, in: scope)
        let id = UUID()
        let name = tableFolderStorage.availableFolderName(in: scope)
        recordFolderEdit(
            String(localized: "New Folder"),
            connectionId: scope.connectionId,
            folderIds: [id],
            itemKeys: itemKeys(names, in: scope)
        ) {
            tableFolderStorage.createFolder(id: id, named: name, in: scope, containing: names)
        }
        guard let folder = tableFolderStorage.folder(id: id, connectionId: scope.connectionId) else { return }
        viewModel?.isFoldersExpanded = true
        windowState?.collapsedTableFolders.remove(id)
        revealedFolderId = id
        defer { revealedFolderId = nil }
        refresh()
        beginRename(.folder(folder))
    }

    /// The destination opens, and so does the Folders section above it, or the rows the user just
    /// moved would vanish into a closed folder along with the highlight on the table the open tab
    /// shows.
    internal func fileObjects(_ refs: [DatabaseTreeTableRef], into folder: TableFolder) {
        fileObjects(named: names(of: refs, in: folder.scope), into: folder)
    }

    internal func fileObjects(named names: [String], into folder: TableFolder) {
        guard !names.isEmpty else { return }
        viewModel?.isFoldersExpanded = true
        windowState?.collapsedTableFolders.remove(folder.id)
        recordFolderEdit(
            String(localized: "Move to Folder"),
            connectionId: folder.scope.connectionId,
            folderIds: [],
            itemKeys: itemKeys(names, in: folder.scope)
        ) {
            tableFolderStorage.fileObjects(names, in: folder.scope, into: folder.id)
        }
    }

    internal func unfileObjects(_ refs: [DatabaseTreeTableRef]) {
        guard let first = refs.first, let scope = folderScope(of: first) else { return }
        unfileObjects(named: names(of: refs, in: scope), in: scope)
    }

    internal func unfileObjects(named names: [String], in scope: DatabaseScope) {
        guard !names.isEmpty else { return }
        recordFolderEdit(
            String(localized: "Remove from Folder"),
            connectionId: scope.connectionId,
            folderIds: [],
            itemKeys: itemKeys(names, in: scope)
        ) {
            tableFolderStorage.unfileObjects(names, in: scope)
        }
    }

    internal func renameFolder(_ folder: TableFolder, to name: String) {
        recordFolderEdit(
            String(localized: "Rename Folder"),
            connectionId: folder.scope.connectionId,
            folderIds: [folder.id],
            itemKeys: []
        ) {
            tableFolderStorage.renameFolder(id: folder.id, connectionId: folder.scope.connectionId, to: name)
        }
    }

    /// No confirmation: the objects go back to their sections, nothing leaves the database, and
    /// Undo puts the folder back with everything it held.
    internal func deleteFolder(_ folder: TableFolder) {
        let members = tableFolderStorage.layout(in: folder.scope).placements
            .filter { $0.value == folder.id }
            .map(\.key)
        recordFolderEdit(
            String(localized: "Delete Folder"),
            connectionId: folder.scope.connectionId,
            folderIds: [folder.id],
            itemKeys: itemKeys(members, in: folder.scope)
        ) {
            tableFolderStorage.deleteFolder(id: folder.id, connectionId: folder.scope.connectionId)
        }
    }

    private func names(of refs: [DatabaseTreeTableRef], in scope: DatabaseScope) -> [String] {
        refs.filter { folderScope(of: $0) == scope }.map(\.table.name)
    }

    private func itemKeys(_ names: [String], in scope: DatabaseScope) -> Set<TableFolderItemKey> {
        Set(names.map { TableFolderItemKey(scope: scope, name: $0) })
    }

    private func recordFolderEdit(
        _ actionName: String,
        connectionId: UUID,
        folderIds: Set<UUID>,
        itemKeys: Set<TableFolderItemKey>,
        _ edit: () -> Void
    ) {
        let storage = tableFolderStorage
        let before = storage.capture(folderIds: folderIds, itemKeys: itemKeys, connectionId: connectionId)
        edit()
        guard let undoManager = outlineView?.undoManager,
              storage.capture(folderIds: folderIds, itemKeys: itemKeys, connectionId: connectionId) != before
        else { return }
        Self.registerFolderRestore(before, storage: storage, actionName: actionName, undoManager: undoManager)
    }

    private static func registerFolderRestore(
        _ revision: TableFolderRevision,
        storage: TableFolderStorage,
        actionName: String,
        undoManager: UndoManager
    ) {
        undoManager.registerUndo(withTarget: storage) { storage in
            let inverse = storage.restore(revision)
            registerFolderRestore(inverse, storage: storage, actionName: actionName, undoManager: undoManager)
        }
        undoManager.setActionName(actionName)
    }
}
