//
//  FavoritesOutlineNode.swift
//  TablePro
//

import Foundation

/// One row of the Favorites outline.
///
/// A reference type because `NSOutlineView` tracks rows by object identity, which is what lets a
/// reload keep the expansion and selection a user set. The coordinator caches these by `id` and
/// mutates the cached instance rather than building a new one, exactly as the object tree does.
internal final class FavoritesOutlineNode: SidebarOutlineNode {
    internal enum Kind {
        case header(String)
        case table(TableInfo)
        case query(FavoriteNode)
        case teamQuery(id: String, name: String, publishedBy: String?)
    }

    internal let id: String
    internal var kind: Kind

    internal init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    internal var isExpandable: Bool {
        guard case .query(let node) = kind else { return false }
        return node.isFolder
    }

    /// Tables, Queries and Team Library are buckets rather than objects, so AppKit draws them as
    /// source list group rows. See `DatabaseTreeNode.isGroupRow` for why that matters beyond styling.
    internal var isGroupRow: Bool {
        guard case .header = kind else { return false }
        return true
    }

    internal static let tablesHeaderId = "favorites\u{1}header\u{1}tables"
    internal static let queriesHeaderId = "favorites\u{1}header\u{1}queries"
    internal static let teamHeaderId = "favorites\u{1}header\u{1}team"

    /// Built from the three plain strings the persisted selection carries, so a selection can be
    /// restored without a live `TableInfo` to hand.
    internal static func tableId(database: String?, schema: String?, name: String) -> String {
        ["favtable", database ?? "", schema ?? "", name].joined(separator: "\u{1}")
    }

    internal static func teamQueryId(_ clientId: String) -> String { "favteam\u{1}\(clientId)" }
}
