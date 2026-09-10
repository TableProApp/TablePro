//
//  ColumnReorderSupport.swift
//  TablePro
//

import Foundation

/// How an engine changes the order of a table's columns, if it can at all.
///
/// Curated per database type rather than asked of a driver, because the drag has to be offered or
/// withheld before the gesture starts and a capability the app only learns from a live connection
/// is too late for that.
enum ColumnReorderSupport: Sendable, Equatable {
    /// Positional DDL: the catalog is rewritten and no row is read or written. MySQL, MariaDB and
    /// ClickHouse have `MODIFY COLUMN … FIRST | AFTER`; Oracle has no positional clause but its
    /// invisible/visible cycle moves a column to the end, which composes into any order.
    case alter

    /// No positional DDL at all, so the order changes by recreating the table and copying its rows.
    /// The script is reviewed and confirmed before anything runs.
    case rebuild

    case unsupported
}

/// Whether a reorder can be started right now, and what to tell the user when it cannot.
enum ColumnReorderAvailability: Sendable, Equatable {
    case available(ColumnReorderSupport)

    /// Reordering is not a gesture this list offers at all, so its absence needs no explaining.
    /// An index or foreign key list has no order to change.
    case notApplicable

    /// Withheld where the user would reasonably expect to be able to drag, so the reason is shown.
    case unavailable(reason: String)

    var support: ColumnReorderSupport? {
        if case .available(let support) = self { return support }
        return nil
    }

    var isAvailable: Bool { support != nil }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Moving a column one place, as the same drop a drag would have produced.
///
/// The commands and the drag share one route into `StructureColumnReorderHandler.desiredOrder`,
/// which speaks NSTableView's drop index: the row the moved column is inserted *above*, so it
/// counts the column in its old place and moving down by one lands two rows on. Kept here rather
/// than in the row view so the arithmetic is a pure function with tests rather than two magic
/// numbers in an AppKit subclass.
enum ColumnMove {
    enum Direction {
        case up
        case down
    }

    static func dropIndex(movingRow row: Int, _ direction: Direction) -> Int {
        switch direction {
        case .up: return row - 1
        case .down: return row + 2
        }
    }

    static func isPossible(movingRow row: Int, _ direction: Direction, columnCount: Int) -> Bool {
        switch direction {
        case .up: return row > 0 && row < columnCount
        case .down: return row >= 0 && row < columnCount - 1
        }
    }
}

/// The single answer to "may this column be dragged, and if not why not".
///
/// Pure and exhaustive so both the affordance and its explanation come from one place. Splitting
/// them is what shipped the reported bug: the engine gate decided whether anything would happen on
/// the drop, while the drag itself was offered unconditionally, so 30 engines lifted the row,
/// opened the insertion gap, took the drop and did nothing.
enum ColumnReorderPolicy {
    static func resolve(
        support: ColumnReorderSupport,
        engineName: String,
        isColumnsTab: Bool,
        isTable: Bool,
        canEditSchema: Bool,
        hasStagedChanges: Bool,
        isRearranged: Bool
    ) -> ColumnReorderAvailability {
        guard isColumnsTab else { return .notApplicable }
        /// Every mechanism emits table DDL, and the SQLite one looks the table up by
        /// `sqlite_master.type = 'table'`, so a view drag would end in an error rather than an
        /// explanation. A view's column order comes from its own `SELECT`.
        guard isTable else {
            return .unavailable(
                reason: String(localized: "A view's column order comes from its query. Edit the view to change it.")
            )
        }
        guard canEditSchema else {
            return .unavailable(
                reason: String(format: String(localized: "%@ cannot edit a table's structure."), engineName)
            )
        }
        switch support {
        case .unsupported:
            return .unavailable(
                reason: String(
                    format: String(localized: "%@ cannot change the order of a table's columns."),
                    engineName
                )
            )
        case .alter, .rebuild:
            guard !hasStagedChanges else {
                return .unavailable(
                    reason: String(localized: "Save or discard the pending structure changes before reordering columns.")
                )
            }
            /// A drop reports the row's position in what is on screen, and a filtered or sorted
            /// list is not the table's order, so "third from the top" names a different column in
            /// each. There is nothing to map it back to either: the wanted order is a statement
            /// about every column, and a filtered list is not showing every column.
            guard !isRearranged else {
                return .unavailable(
                    reason: String(localized: "Clear the filter and the sort to reorder columns.")
                )
            }
            return .available(support)
        }
    }
}
