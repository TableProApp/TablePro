//
//  DatabaseTreeDoubleClickIntent.swift
//  TablePro
//

import Foundation

/// What a double-click, or a Return press, on a tree row means.
///
/// The tree opens whatever the selection lands on, so by the time a second click arrives the table
/// is already showing in a preview tab. The gesture therefore cannot mean "open"; it means "keep
/// this one", which is the promotion the preview-tab model presumes and which nothing else in the
/// app supplies.
internal enum DatabaseTreeDoubleClickIntent: Equatable {
    /// Open the table in a tab the next sidebar click will not replace.
    case openPermanently(DatabaseTreeTableRef)
    /// Expand or collapse a container row.
    case toggleDisclosure
    case ignore
}

internal enum DatabaseTreeDoubleClickResolver {
    /// Being a table wins over being expandable. A partitioned table is both, and the HIG puts
    /// disclosure on the triangle and the Right and Left arrows, so the row's own double-click is
    /// free to mean what it means everywhere else: open the thing you clicked.
    internal static func resolve(node: DatabaseTreeNode) -> DatabaseTreeDoubleClickIntent {
        if let ref = DatabaseTreeSelection.tableRef(of: node) {
            return .openPermanently(ref)
        }
        return node.isExpandable ? .toggleDisclosure : .ignore
    }
}
