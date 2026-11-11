//
//  QuerySnippetMenu.swift
//  TablePro
//

import Foundation

/// An item of the two-row query bar's Snippets menu.
internal enum QuerySnippetMenuEntry: Identifiable, Equatable {
    case folder(SQLFavoriteFolder, children: [QuerySnippetMenuEntry])
    case savedQuery(SQLFavorite)
    /// Stands in for the saved queries when the connection has none, so the menu says why it is short.
    case empty
    case divider
    /// The bar's Save as Favorite, which the two-row layout keeps here beside what it adds to.
    case saveCurrentQuery

    internal var id: String {
        switch self {
        case .folder(let folder, _): return "folder-\(folder.id)"
        case .savedQuery(let favorite): return "saved-query-\(favorite.id)"
        case .empty: return "empty"
        case .divider: return "divider"
        case .saveCurrentQuery: return "save-current-query"
        }
    }
}

/// The saved queries one connection can see, in the folders and order the Favorites sidebar shows,
/// because both come from `FavoritesTreeBuilder`.
internal enum QuerySnippetMenu {
    /// `folders` and `favorites` are what `ConnectionDataCache` holds for the connection: its own and
    /// every global one. A folder with no saved query anywhere under it is left out, since a submenu
    /// that opens on nothing is a dead end.
    internal static func entries(folders: [SQLFavoriteFolder], favorites: [SQLFavorite]) -> [QuerySnippetMenuEntry] {
        let saved = entries(from: FavoritesTreeBuilder.build(folders: folders, favorites: favorites))
        return (saved.isEmpty ? [.empty] : saved) + [.divider, .saveCurrentQuery]
    }

    private static func entries(from nodes: [FavoriteNode]) -> [QuerySnippetMenuEntry] {
        nodes.compactMap { node in
            switch node.content {
            case .folder(let folder):
                let children = entries(from: node.children ?? [])
                return children.isEmpty ? nil : .folder(folder, children: children)
            case .favorite(let favorite):
                return .savedQuery(favorite)
            case .linkedFolder, .linkedSubfolder, .linkedFavorite:
                return nil
            }
        }
    }
}
