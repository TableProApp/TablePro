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
              !coordinator.selectionState.indices.isEmpty,
              let firstIndex = coordinator.selectionState.indices.min() else { return nil }
        let tableRows = coordinator.tabSessionRegistry.tableRows(for: tab.id)
        guard firstIndex < tableRows.rows.count else { return nil }

        let row = tableRows.rows[firstIndex].values
        var data: [(column: String, value: String?, type: String)] = []

        let service = ValueDisplayFormatService.shared
        let connId = coordinator.connection.id
        let tblName = tab.tableContext.tableName

        for (i, col) in tableRows.columns.enumerated() {
            var value = i < row.count ? row[i] : nil
            let type = i < tableRows.columnTypes.count ? tableRows.columnTypes[i].displayName : "string"

            // Apply display format if active
            if let rawValue = value {
                let format = service.effectiveFormat(columnName: col, connectionId: connId, tableName: tblName)
                if format != .raw {
                    value = ValueDisplayFormatService.applyFormat(rawValue, format: format)
                }
            }

            data.append((column: col, value: value, type: type))
        }

        return data
    }

    // MARK: - Sidebar Edit State

    /// Determine if sidebar should be in editable mode
    var isSidebarEditable: Bool {
        guard !coordinator.safeModeLevel.blocksAllWrites,
              let tab = coordinator.tabManager.selectedTab,
              tab.tabType == .table || tab.tableContext.tableName != nil,
              !coordinator.selectionState.indices.isEmpty else {
            return false
        }
        return true
    }

    var isSelectedRowDeleted: Bool {
        guard let firstIndex = coordinator.selectionState.indices.min() else { return false }
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
                    coordinator.tabManager.mutate(at: index) { $0.sortState = newValue }
                }
            }
        )
    }

    // MARK: - Results View Mode Binding

    /// Binding for resultsViewMode state
    var resultsViewModeBinding: Binding<ResultsViewMode> {
        Binding(
            get: { coordinator.tabManager.selectedTab?.display.resultsViewMode ?? .data },
            set: { newValue in
                if let index = coordinator.tabManager.selectedTabIndex {
                    coordinator.tabManager.mutate(at: index) { $0.display.resultsViewMode = newValue }
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

    var inspectorTrigger: InspectorTrigger {
        InspectorTrigger(
            tableName: currentTab?.tableContext.tableName,
            schemaVersion: currentTab?.schemaVersion ?? -1,
            metadataVersion: currentTab?.metadataVersion ?? -1
        )
    }
}

struct InspectorTrigger: Equatable {
    let tableName: String?
    let schemaVersion: Int
    let metadataVersion: Int
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
