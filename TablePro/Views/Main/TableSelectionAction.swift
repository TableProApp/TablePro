//
//  TableSelectionAction.swift
//  TablePro
//
//  Pure logic for deciding whether a sidebar selection change should trigger
//  navigation. Extracted so it can be unit-tested without any SwiftUI state.
//

import Foundation

/// Describes what should happen when the sidebar selection set changes.
enum TableSelectionAction: Equatable {
    /// Selection changed but no single table was added — skip navigation.
    /// Covers: Cmd+A (multi-select), Shift+click range, deselection.
    case noNavigation
    /// Exactly one table was added — navigate to it.
    case navigate(table: TableInfo)

    static func resolve(
        oldTables: Set<TableInfo>,
        newTables: Set<TableInfo>
    ) -> TableSelectionAction {
        guard let table = SelectionDelta.singleAddition(old: oldTables, new: newTables) else {
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
