//
//  InspectorSubject.swift
//  TablePro
//

import Foundation

/// What the inspector is currently inspecting, and the two lines its header draws for it.
///
/// The pane had no subject at all before: it multiplexed three unrelated tabs, so there was nothing
/// one title could name and the header carried a picker instead. Naming the subject is what lets
/// the header say which row of which table is on screen, which is the first thing a reader of an
/// inspector needs and the thing the old pane never showed.
///
/// A schema grid is a first-class case rather than an afterthought. The structure and create-table
/// editors feed the same pane through `InspectorRowSource`, and their selection is a column
/// definition, not a row of data: it has no position in a result and no row identity, so a subject
/// that assumed one would render "Row 0 of 0" over a perfectly good column.
internal enum InspectorSubject: Equatable {
    case empty
    case tableRow(table: String, position: RowPosition?)
    case multipleRows(table: String, count: Int)
    case columnDefinition(column: String, table: String?)
    case tableOnly(table: String)

    internal struct RowPosition: Equatable {
        internal let index: Int
        internal let total: Int

        internal init(index: Int, total: Int) {
            self.index = index
            self.total = total
        }
    }

    /// The bold first line: the thing being inspected.
    internal var title: String? {
        switch self {
        case .empty:
            return nil
        case .tableRow(let table, _), .multipleRows(let table, _), .tableOnly(let table):
            return table
        case .columnDefinition(let column, _):
            return column
        }
    }

    /// The secondary second line: where the thing sits. Nil where there is nothing useful to add,
    /// so the header collapses to one line rather than drawing an empty one.
    internal var subtitle: String? {
        switch self {
        case .empty:
            return nil
        case .tableRow(_, let position):
            guard let position else { return nil }
            return String(
                format: String(localized: "Row %@ of %@"),
                position.index.formatted(.number),
                position.total.formatted(.number)
            )
        case .multipleRows(_, let count):
            return String(format: String(localized: "%d rows selected"), count)
        case .columnDefinition(_, let table):
            guard let table else { return String(localized: "Column") }
            return String(format: String(localized: "Column of %@"), table)
        case .tableOnly:
            return String(localized: "Table")
        }
    }
}
