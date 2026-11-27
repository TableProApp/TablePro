//
//  ConnectionEditorStore+Delete.swift
//  TablePro
//

import Combine
import Foundation
import TableProConnectionLibrary

struct ConnectionDeleteConfirmation: Equatable {
    let connectionName: String
    let deletesLinkedSavedQueries: Bool

    var title: String { String(localized: "Delete Connection") }

    var message: String {
        if deletesLinkedSavedQueries {
            return String(
                format: String(localized: "Are you sure you want to delete \"%@\"? Saved queries linked to this connection will also be deleted."),
                connectionName
            )
        }
        return String(format: String(localized: "Are you sure you want to delete \"%@\"?"), connectionName)
    }
}

enum ConnectionEditorDeleteError: Error, Equatable, LocalizedError {
    case notSaved
    case libraryUnreadable
    case recordMissing
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .notSaved:
            return String(localized: "This connection has not been saved yet.")
        case .libraryUnreadable:
            return String(localized: "TablePro could not read your saved connections, so it did not save over them.")
        case .recordMissing:
            return String(localized: "This connection was deleted on another device or window.")
        case .writeFailed:
            return String(localized: "The change could not be saved. Check disk space and permissions, then try again.")
        }
    }
}

extension ConnectionEditorStore {
    var canDelete: Bool { !isNew && !isRecordMissing }

    // The same warning Welcome gives: linked saved queries go with the connection.
    func deleteConfirmation() async -> ConnectionDeleteConfirmation {
        let name = baseline.name.isEmpty ? windowTitle : baseline.name
        let hasQueries = isNew ? false : await services.sqlFavoriteManager.hasFavorites(for: [connectionId])
        return ConnectionDeleteConfirmation(connectionName: name, deletesLinkedSavedQueries: hasQueries)
    }

    // Reports a failed write instead of closing over it, and cleans up what Welcome's delete cleans up.
    @discardableResult
    func delete() -> Result<Void, ConnectionEditorDeleteError> {
        let result = performDelete()
        if case .failure(let error) = result {
            deleteError = error
        } else {
            deleteError = nil
        }
        return result
    }

    private func performDelete() -> Result<Void, ConnectionEditorDeleteError> {
        guard !isNew else { return .failure(.notSaved) }
        guard !storage.isLibraryUnreadable else { return .failure(.libraryUnreadable) }
        guard let record = storage.loadConnection(id: connectionId) else { return .failure(.recordMissing) }
        guard storage.deleteConnection(record) else { return .failure(.writeFailed) }
        isClosing = true
        cancelTest()
        for receipt in Array(pendingTestReceipts.values) {
            cleanupTestSecrets(receipt)
        }
        recentConnections.remove([connectionId])
        listPreferences.setFavoritesOrder(
            LibraryOrdering.favoritesOrder(listPreferences.favoritesOrder, removing: [connectionId])
        )
        hasUnsavedChanges = false
        dismissAction?()
        services.appEvents.connectionUpdated.send(connectionId)
        return .success(())
    }
}
