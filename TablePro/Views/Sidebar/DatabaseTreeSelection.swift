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
        case .database, .schema, .table, .routine, .trigger, .userType, .recentTable,
             .containerObjectKindSection, .redisNode:
            return true
        }
    }

    /// A Recent entry is a second row for a table the tree already lists, so it resolves to the
    /// same reference and opens through the same selection-driven path as the table itself.
    internal static func tableRef(of node: DatabaseTreeNode) -> DatabaseTreeTableRef? {
        node.tableRef ?? node.recentTableRef
    }

    /// What the Table menu acts on, and what a queued Truncate or Drop is keyed by. The tree
    /// never published its selection at all, so those commands read an always-empty set and did
    /// nothing in tree layout while the sidebar plainly showed rows selected.
    ///
    /// A table reachable from two rows, its own and its Recent entry, is one table, so a set built
    /// from these collapses them.
    internal static func tableRefs(of nodes: [DatabaseTreeNode]) -> [DatabaseTreeTableRef] {
        nodes.compactMap(tableRef)
    }

    /// The one table a selection change should open, if any.
    ///
    /// Navigation follows a selection of one. Cmd-clicking a second table, or Shift-arrowing onto
    /// the next row, extends a selection so the user can Truncate, Delete or Export a batch; it must
    /// not also run a SELECT and move the session's active database. A delta cannot express that on
    /// its own, because adding one row to a selection is still exactly one addition. The row count
    /// covers the rows that are not tables too: a table Cmd-clicked alongside a schema is an
    /// extension, not a pick.
    internal static func navigationTarget(
        selectedNodes: [DatabaseTreeNode],
        previousRefs: Set<DatabaseTreeTableRef>,
        newRefs: Set<DatabaseTreeTableRef>
    ) -> DatabaseTreeTableRef? {
        guard selectedNodes.count == 1 else { return nil }
        return SelectionDelta.singleAddition(old: previousRefs, new: newRefs)
    }
}
