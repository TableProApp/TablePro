//
//  DatabaseTreeSelection.swift
//  TablePro
//

import Foundation

/// What a row in the object tree can be selected for.
///
/// Refusing selection was how the tree said "this row is not an object". That put routines and
/// Recent entries, which are objects, outside the selection model entirely: arrows skipped them,
/// type-select could not land on them even though the tree publishes a match string for both, and
/// clicking a Recent entry opened one table while the highlight stayed on another. Only the rows
/// that genuinely stand for nothing refuse now.
internal enum DatabaseTreeSelection {
    internal static func isSelectable(_ kind: DatabaseTreeNode.Kind) -> Bool {
        switch kind {
        case .status, .recentSection, .objectKindSection, .hierarchicalSchemaSection, .redisKeysSection:
            return false
        case .database, .schema, .table, .routine, .recentTable, .redisNode:
            return true
        }
    }

    /// A Recent entry is a second row for a table the tree already lists, so it resolves to the
    /// same reference and opens through the same selection-driven path as the table itself.
    internal static func tableRef(of node: DatabaseTreeNode) -> DatabaseTreeTableRef? {
        node.tableRef ?? node.recentTableRef
    }

    internal static func tableRefs(of nodes: [DatabaseTreeNode]) -> [DatabaseTreeTableRef] {
        nodes.compactMap(tableRef)
    }

    /// What the Table menu acts on. The tree never published its selection, so Truncate, Copy Name
    /// and Delete read an always-empty set and did nothing at all in tree layout while the sidebar
    /// plainly showed rows selected.
    ///
    /// A table reachable from two rows, its own and its Recent entry, is one table, so the set
    /// collapses them.
    internal static func tableInfos(of nodes: [DatabaseTreeNode]) -> Set<TableInfo> {
        Set(tableRefs(of: nodes).map(\.table))
    }
}
