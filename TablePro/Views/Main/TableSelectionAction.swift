//
//  TableSelectionAction.swift
//  TablePro
//
//  Pure logic for deciding whether a sidebar selection change should trigger
//  navigation. Extracted so it can be unit-tested without any SwiftUI state.
//

import Foundation

/// Describes what should happen when the sidebar selection set changes.
///
/// Navigation follows a selection of one. Extending a selection is how a source list builds a batch
/// for Truncate, Delete or Export, so it must not also open a table, switch the session's database
/// and run a query. Requiring the resulting selection to be a single table keeps Cmd-click and
/// Shift-arrow out of the navigating path, which a delta on its own cannot do: adding one row to a
/// selection is still exactly one addition.
enum TableSelectionAction: Equatable {
    case noNavigation
    case navigate(table: TableInfo)

    /// `selectedRowCount` is how many rows the sidebar has selected, which the table set alone
    /// cannot tell: a table Cmd-clicked alongside a schema yields one table and is still an
    /// extension. Callers that can only ever select tables pass the table count.
    static func resolve(
        oldTables: Set<TableInfo>,
        newTables: Set<TableInfo>,
        selectedRowCount: Int
    ) -> TableSelectionAction {
        guard selectedRowCount == 1,
              newTables.count == 1,
              let table = SelectionDelta.singleAddition(old: oldTables, new: newTables)
        else {
            return .noNavigation
        }
        return .navigate(table: table)
    }
}

enum SelectionDelta {
    static func singleAddition<Element: Hashable>(
        old: Set<Element>,
        new: Set<Element>
    ) -> Element? {
        let added = new.subtracting(old)
        guard added.count == 1 else { return nil }
        return added.first
    }
}

/// Determines which table (if any) to select when the table list loads in a new window.
enum SidebarSyncAction: Equatable {
    case noSync
    case select(tableName: String)

    /// Called when `tables` array changes. Returns which table to sync to, if any.
    static func resolveOnTablesLoad(
        newTables: [TableInfo],
        selectedTables: Set<TableInfo>,
        currentTabTableName: String?
    ) -> SidebarSyncAction {
        guard !newTables.isEmpty, selectedTables.isEmpty,
              let tabTableName = currentTabTableName,
              newTables.contains(where: { $0.name == tabTableName })
        else {
            return .noSync
        }
        return .select(tableName: tabTableName)
    }
}
