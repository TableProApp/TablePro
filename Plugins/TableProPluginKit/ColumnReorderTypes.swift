//
//  ColumnReorderTypes.swift
//  TableProPluginKit
//

import Foundation

/// What running a column reorder costs, which is what decides whether the user is asked first.
///
/// The line is not how many statements there are. A positional `ALTER` and Oracle's
/// invisible/visible cycle both touch catalog rows alone, so they run on the drop the way every
/// other direct manipulation does. A rebuild copies every row into a new table and drops the
/// original, so it is presented for review and confirmed before anything runs.
public enum PluginColumnReorderCost: Sendable, Equatable {
    case metadataOnly
    case tableRebuild
}

/// The statements that put a table's columns into a wanted order.
public struct PluginColumnReorderPlan: Sendable, Equatable {
    public let statements: [String]

    /// Run in order, best effort, when a statement fails part way through. A rebuild opens a
    /// transaction across several statements, and a failure that leaves it open would strand the
    /// session; this is what closes it.
    public let rollbackStatements: [String]

    public let cost: PluginColumnReorderCost

    /// What the plan does not carry over, phrased for the user and shown before a rebuild runs.
    /// A rebuild reproduces the table from what the server will describe, so anything the server
    /// does not describe is named here rather than lost quietly.
    public let caveats: [String]

    /// Whether TablePro may run this itself.
    ///
    /// False where the engine's catalog cannot describe enough of a table to reproduce it, so the
    /// script is handed over for the user to read and run instead of being offered behind a button
    /// that would report success over a lost grant or a broken sequence. SQLite reproduces a table
    /// from its own stored DDL verbatim and is runnable; PostgreSQL and SQL Server rebuild from
    /// reconstructed definitions and are not.
    public let isRunnable: Bool

    public init(
        statements: [String],
        rollbackStatements: [String] = [],
        cost: PluginColumnReorderCost,
        caveats: [String] = [],
        isRunnable: Bool = true
    ) {
        self.statements = statements
        self.rollbackStatements = rollbackStatements
        self.cost = cost
        self.caveats = caveats
        self.isRunnable = isRunnable
    }
}

/// Turns a wanted column order into the moves an engine's positional primitive can actually make.
///
/// Kept here rather than in each driver because the arithmetic is the same everywhere and getting
/// it wrong is silent: a plan that produces the wrong order still runs and still reports success.
public enum PluginColumnReorderPlanner {
    public struct Move: Sendable, Equatable {
        public let column: String
        /// The column this one follows once the move has run. Nil places it first.
        public let afterColumn: String?

        public init(column: String, afterColumn: String?) {
            self.column = column
            self.afterColumn = afterColumn
        }
    }

    /// The fewest `FIRST` / `AFTER` moves that turn `currentOrder` into `desiredOrder`.
    ///
    /// A column that is not moved keeps its position relative to the others that are not moved, so
    /// the largest set worth leaving alone is the longest subsequence common to both orders, and
    /// everything outside it has to move exactly once. Walking the wanted order and fixing each
    /// position that disagrees looks equivalent and is not: dragging a column down one place makes
    /// every column it passed disagree, so it emits one statement per column passed instead of one
    /// for the column the user actually dragged.
    ///
    /// Each move is anchored on the column that precedes it in the wanted order, which by then is
    /// already in its final position, whether it was moved or left alone.
    ///
    /// Empty when the two orders are not permutations of each other, which is the only shape this
    /// can be asked for that has no answer.
    public static func moves(from currentOrder: [String], to desiredOrder: [String]) -> [Move] {
        guard isPermutation(currentOrder, desiredOrder) else { return [] }
        let stationary = longestCommonSubsequence(currentOrder, desiredOrder)
        return desiredOrder.enumerated()
            .filter { !stationary.contains($0.element) }
            .map { Move(column: $0.element, afterColumn: $0.offset == 0 ? nil : desiredOrder[$0.offset - 1]) }
    }

    private static func longestCommonSubsequence(_ lhs: [String], _ rhs: [String]) -> Set<String> {
        var lengths = Array(repeating: Array(repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        for i in stride(from: lhs.count - 1, through: 0, by: -1) {
            for j in stride(from: rhs.count - 1, through: 0, by: -1) {
                lengths[i][j] = lhs[i] == rhs[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var common: Set<String> = []
        var i = 0
        var j = 0
        while i < lhs.count, j < rhs.count {
            if lhs[i] == rhs[j] {
                common.insert(lhs[i])
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return common
    }

    /// The columns to send to the end, in order, for an engine whose only positional primitive
    /// appends. Oracle's invisible/visible cycle is the case: it moves a column to the end and
    /// nothing else, so any order is reachable by appending the right suffix in the right order.
    ///
    /// The columns left alone have to be a prefix of the wanted order and keep their current
    /// relative order, so the longest such prefix is exactly the set worth not touching.
    public static func appendCycle(from currentOrder: [String], to desiredOrder: [String]) -> [String] {
        guard isPermutation(currentOrder, desiredOrder) else { return [] }
        var kept = 0
        var cursor = currentOrder.startIndex
        for name in desiredOrder {
            guard let found = currentOrder[cursor...].firstIndex(of: name) else { break }
            cursor = currentOrder.index(after: found)
            kept += 1
        }
        return Array(desiredOrder.dropFirst(kept))
    }

    private static func isPermutation(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && lhs.sorted() == rhs.sorted()
    }
}
