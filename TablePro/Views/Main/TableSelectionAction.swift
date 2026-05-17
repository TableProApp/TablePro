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
        let added = newTables.subtracting(oldTables)
        guard added.count == 1, let table = added.first else {
            return .noNavigation
        }
        return .navigate(table: table)
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
        // Only sync when tables just loaded and sidebar has no selection
        guard !newTables.isEmpty, selectedTables.isEmpty,
              let tabTableName = currentTabTableName,
              newTables.contains(where: { $0.name == tabTableName })
        else {
            return .noSync
        }
        return .select(tableName: tabTableName)
    }
}
