//
//  FavoritesExpansion.swift
//  TablePro
//

import Foundation

/// Which store a favorites row's expansion belongs in. User folders are keyed by their identifier,
/// anything mirrored from disk by its node id, and the two stores are not interchangeable.
@MainActor
internal enum FavoritesExpansion {
    internal static func isExpanded(_ node: FavoriteNode, connectionId: UUID) -> Bool {
        switch node.content {
        case .folder(let folder):
            return FavoritesExpansionState.shared.isFolderExpanded(folder.id, for: connectionId)
        case .linkedFolder, .linkedSubfolder:
            return FavoritesExpansionState.shared.isLinkedNodeExpanded(node.id, for: connectionId)
        case .favorite, .linkedFavorite:
            return false
        }
    }

    internal static func setExpanded(_ node: FavoriteNode, expanded: Bool, connectionId: UUID) {
        switch node.content {
        case .folder(let folder):
            FavoritesExpansionState.shared.setFolderExpanded(folder.id, expanded: expanded, for: connectionId)
        case .linkedFolder, .linkedSubfolder:
            FavoritesExpansionState.shared.setLinkedNodeExpanded(node.id, expanded: expanded, for: connectionId)
        case .favorite, .linkedFavorite:
            break
        }
    }
}
