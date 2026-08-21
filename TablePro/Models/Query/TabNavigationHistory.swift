//
//  TabNavigationHistory.swift
//  TablePro
//

import Foundation

/// One browse location a tab has shown.
///
/// A location is the table plus the view state that made it that location rather than a bare
/// `SELECT *`: the filters, the sort, the page. Retargeting a tab throws all of that away
/// (`QueryTabManager.replaceTabContent`), so it has to be captured before the jump or there is
/// nothing to come back to.
///
/// The row is held as its primary-key values, never as a row index. Selection indices are display
/// positions and stop meaning anything the moment the rows are re-fetched or a value filter
/// narrows them.
///
/// The per-column value filter is deliberately absent. It holds the displayed strings the reader
/// picked out of the rows being replaced, and `resetSelectionForNewResult` clears it on every
/// replacement for that reason, so an entry carrying one would only look like it worked.
struct TabNavigationEntry: Equatable {
    var tableName: String
    var databaseName: String
    var schemaName: String?
    var isView: Bool
    var resultsViewMode: ResultsViewMode
    var filterState: TabFilterState
    var sortColumns: [PersistedSortColumn]
    var page: Int
    var pageSize: Int
    var anchorRowKey: [String: String]?
}

/// A tab's browse history, in the shape a browser tab uses: a back stack, a forward stack, and a
/// new location truncating the forward stack.
///
/// One history per tab, so a jump that opens a new tab starts that tab with nothing to go back to,
/// the way Command-clicking a link does. Nothing here is persisted: an entry describes rows that
/// may not exist by the next launch, and a Back that silently lands somewhere else is worse than
/// a Back that is simply unavailable.
struct TabNavigationHistory: Equatable {
    /// Deep enough that a real chain of foreign keys never runs out, shallow enough that the
    /// entries stay a rounding error next to the row buffer they sit beside.
    static let maxDepth = 50

    private(set) var backEntries: [TabNavigationEntry] = []
    private(set) var forwardEntries: [TabNavigationEntry] = []

    var canGoBack: Bool { !backEntries.isEmpty }
    var canGoForward: Bool { !forwardEntries.isEmpty }

    /// Records the location being left. A new location invalidates whatever Forward pointed at,
    /// exactly as following a link does in a browser.
    mutating func record(_ entry: TabNavigationEntry) {
        forwardEntries.removeAll()
        Self.push(entry, onto: &backEntries)
    }

    mutating func stepBack(from current: TabNavigationEntry) -> TabNavigationEntry? {
        guard let entry = backEntries.popLast() else { return nil }
        Self.push(current, onto: &forwardEntries)
        return entry
    }

    mutating func stepForward(from current: TabNavigationEntry) -> TabNavigationEntry? {
        guard let entry = forwardEntries.popLast() else { return nil }
        Self.push(current, onto: &backEntries)
        return entry
    }

    private static func push(_ entry: TabNavigationEntry, onto stack: inout [TabNavigationEntry]) {
        stack.append(entry)
        guard stack.count > maxDepth else { return }
        stack.removeFirst(stack.count - maxDepth)
    }
}
