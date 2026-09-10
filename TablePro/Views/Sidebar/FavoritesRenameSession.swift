//
//  FavoritesRenameSession.swift
//  TablePro
//

import Foundation

/// A rename in progress, held as identity only.
///
/// No cell and no field: `reloadData()` drops every row and cell view, so a stored reference is a
/// reference to a view that is no longer the row being edited. The cell is re-resolved from the node
/// id on every pass instead.
internal struct FavoritesRenameSession: Equatable {
    internal let folderId: UUID
    internal let nodeId: String
    internal var pendingName: String?
}

internal enum FavoritesRenameDecision: Equatable {
    case begin(nodeId: String)
    case keep
    case cancel
}

internal enum FavoritesRenameResolver {
    /// A new folder is asked to rename itself the moment it is created, which is before the cache
    /// has published it, so its row does not exist yet. Waiting for the row to appear is what
    /// replaces sleeping for a fixed interval and hoping.
    internal static func decide(
        session: FavoritesRenameSession?,
        requestedFolderId: UUID?,
        nodeIds: Set<String>
    ) -> FavoritesRenameDecision {
        guard let requestedFolderId else {
            return session == nil ? .keep : .cancel
        }
        let nodeId = Self.nodeId(forFolder: requestedFolderId)
        guard let session else {
            return nodeIds.contains(nodeId) ? .begin(nodeId: nodeId) : .keep
        }
        guard session.folderId == requestedFolderId else {
            return .cancel
        }
        return nodeIds.contains(session.nodeId) ? .keep : .cancel
    }

    internal static func nodeId(forFolder folderId: UUID) -> String {
        "folder-\(folderId)"
    }
}
