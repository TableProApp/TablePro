//
//  FavoritesOutlineSelection.swift
//  TablePro
//

import Foundation

/// What a Favorites row can be selected for, and how that maps onto the selection the app persists.
internal enum FavoritesOutlineSelection {
    /// Section titles stand for nothing, so they refuse selection. Everything else is a real object,
    /// including Team Library rows, which used to be plain buttons the keyboard could never reach.
    internal static func isSelectable(_ kind: FavoritesOutlineNode.Kind) -> Bool {
        guard case .header = kind else { return true }
        return false
    }

    internal static func selection(
        for kind: FavoritesOutlineNode.Kind,
        database: String?
    ) -> FavoriteSelection? {
        switch kind {
        case .header:
            return nil
        case .table(let table):
            return .table(database: database, schema: table.schema, name: table.name)
        case .query(let node):
            return .node(id: node.id)
        case .teamQuery(let id, _, _):
            return .node(id: FavoritesOutlineNode.teamQueryId(id))
        }
    }

    /// The id a persisted selection points at, so a reload can find the row again.
    internal static func nodeId(for selection: FavoriteSelection) -> String {
        switch selection {
        case .table(let database, let schema, let name):
            return FavoritesOutlineNode.tableId(database: database, schema: schema, name: name)
        case .node(let id):
            return id
        }
    }

    /// Type-select needs the name a user would actually type. A section title is not one.
    internal static func matchString(for kind: FavoritesOutlineNode.Kind) -> String? {
        switch kind {
        case .header:
            return nil
        case .table(let table):
            return table.name
        case .teamQuery(_, let name, _):
            return name
        case .query(let node):
            switch node.content {
            case .favorite(let favorite): return favorite.name
            case .folder(let folder): return folder.name
            case .linkedFolder(let folder): return folder.name
            case .linkedSubfolder(_, let displayName, _): return displayName
            case .linkedFavorite(let linked): return linked.name
            }
        }
    }
}
