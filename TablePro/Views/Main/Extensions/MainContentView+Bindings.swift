//
//  MainContentView+Bindings.swift
//  TablePro
//
//  Extension containing computed bindings for MainContentView.
//  Extracted to reduce main view complexity.
//

import SwiftUI

extension MainContentView {
    // MARK: - Selected Row Data for Sidebar

    /// Compute selected row data for right sidebar display
    var selectedRowDataForSidebar: [(column: String, value: String?, type: String)]? {
        guard let tab = coordinator.tabManager.selectedTab,
              !selectedRowIndices.isEmpty,
              let firstIndex = selectedRowIndices.min(),
              firstIndex < tab.resultRows.count else { return nil }

        let row = tab.resultRows[firstIndex]
        var data: [(column: String, value: String?, type: String)] = []

        for (i, col) in tab.resultColumns.enumerated() {
            let value = i < row.count ? row[i] : nil
            let type = i < tab.columnTypes.count ? tab.columnTypes[i].displayName : "string"
            data.append((column: col, value: value, type: type))
        }

        return data
    }

    // MARK: - Sidebar Edit State

    /// Determine if sidebar should be in editable mode
    var isSidebarEditable: Bool {
        guard !coordinator.safeModeLevel.blocksAllWrites,
              let tab = coordinator.tabManager.selectedTab,
              tab.tabType == .table || tab.tableName != nil,
              !selectedRowIndices.isEmpty else {
            return false
        }
        return true
    }

    /// Check if selected row is deleted
    var isSelectedRowDeleted: Bool {
        guard let firstIndex = selectedRowIndices.min() else { return false }
        return coordinator.changeManager.isRowDeleted(firstIndex)
    }

    // MARK: - Sort State Binding

    /// Binding for the current tab's sort state
    var sortStateBinding: Binding<SortState> {
        Binding(
            get: {
                guard let tab = coordinator.tabManager.selectedTab else {
                    return SortState()
                }
                return tab.sortState
            },
            set: { newValue in
                if let index = coordinator.tabManager.selectedTabIndex {
                    coordinator.tabManager.tabs[index].sortState = newValue
                }
            }
        )
    }

    // MARK: - Show Structure Binding

    /// Binding for showStructure state
    var showStructureBinding: Binding<Bool> {
        Binding(
            get: { coordinator.tabManager.selectedTab?.showStructure ?? false },
            set: { newValue in
                if let index = coordinator.tabManager.selectedTabIndex {
                    coordinator.tabManager.tabs[index].showStructure = newValue
                }
            }
        )
    }

    // MARK: - Current Tab Accessor

    /// Current selected tab for convenience
    var currentTab: QueryTab? {
        coordinator.tabManager.selectedTab
    }

    // MARK: - Consolidated onChange Triggers

    /// Trigger for inspector updates — combines result version and table metadata name.
    /// Replaces separate handlers for `currentTab?.resultRows` and
    /// `coordinator.tableMetadata?.tableName` that both only called `scheduleInspectorUpdate()`.
    /// Uses `resultVersion` instead of the full `resultRows` array to avoid deep equality checks.
    var inspectorTrigger: InspectorTrigger {
        InspectorTrigger(
            tableName: currentTab?.tableName,
            resultVersion: currentTab?.resultVersion ?? -1,
            metadataVersion: currentTab?.metadataVersion ?? -1,
            metadataTableName: coordinator.tableMetadata?.tableName
        )
    }
}

// MARK: - Equatable Trigger Types

/// Lightweight equatable value combining tab table name, result version, and metadata table name
/// for consolidated inspector onChange observation. Folding `tableName` here avoids a separate
/// `onChange(of: currentTab?.tableName)` handler that would cascade with this trigger.
struct InspectorTrigger: Equatable {
    let tableName: String?
    let resultVersion: Int
    let metadataVersion: Int
    let metadataTableName: String?
}

/// Lightweight equatable value combining all pending-change sources
/// for consolidated toolbar badge onChange observation.
struct PendingChangeTrigger: Equatable {
    let hasDataChanges: Bool
    let pendingTruncates: Set<String>
    let pendingDeletes: Set<String>
    let hasStructureChanges: Bool
    let isFileDirty: Bool
}
