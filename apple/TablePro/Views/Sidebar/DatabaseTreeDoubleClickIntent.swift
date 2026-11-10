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
    /// Open a routine's, trigger's or type's source. Selection alone does not open one, because
    /// fetching a definition is a round trip, and arrowing through a section would fire one per row.
    case openObjectSource(DatabaseObjectRef)
    /// A column, index, foreign key or check is read in its table's Structure tab.
    case showStructure(DatabaseTreeTableRef)
    /// Switch to or open a saved connection other than the tree's own.
    case activateConnection(DatabaseTreeSavedConnectionRef)
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
        switch node.kind {
        case .routine(let ref):
            return .openObjectSource(ref.objectRef)
        case .trigger(let ref):
            return .openObjectSource(ref.objectRef)
        case .userType(let ref):
            return .openObjectSource(ref.objectRef)
        case .tableDetail(let ref):
            return .showStructure(ref.table)
        case .savedConnection(let ref) where !ref.ownsTree:
            return .activateConnection(ref)
        default:
            return node.isExpandable ? .toggleDisclosure : .ignore
        }
    }
}
