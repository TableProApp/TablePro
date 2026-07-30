//
//  MainContentView+Bindings.swift
//  TablePro
//
//  Extension containing computed bindings for MainContentView.
//  Extracted to reduce main view complexity.
//

import SwiftUI
import TableProPluginKit

extension MainContentView {
    // MARK: - Inspector Selection

    /// Which grid owns the current selection. `GridSelectionState` is shared by the data
    /// grid, the structure grid, and the new-table grid, so its indices only address the
    /// data tab's rows when the data grid is the one on screen.
    var gridSelectionOwner: GridSelectionOwner {
        GridSelectionOwner.resolve(
            tabType: coordinator.tabManager.selectedTab?.tabType,
            resultsViewMode: coordinator.tabManager.selectedTab?.display.resultsViewMode
        )
    }

    var selectedInspectorRow: InspectorRow? {
        guard gridSelectionOwner == .schemaGrid,
              let displayRow = coordinator.selectionState.indices.min() else { return nil }
        return coordinator.inspectorRowSource?.inspectorRow(atDisplayRow: displayRow)
    }

    // MARK: - Selected Row Data for Sidebar

    /// Compute selected row data for right sidebar display
    var selectedRowDataForSidebar: [(column: String, value: String?, type: String)]? {
        if gridSelectionOwner == .schemaGrid {
            guard let row = selectedInspectorRow else { return nil }
            return row.fields.map { (column: $0.name, value: $0.value, type: "string") }
        }
        guard gridSelectionOwner == .dataGrid,
              let tab = coordinator.tabManager.selectedTab,
              !coordinator.selectionState.indices.isEmpty,
              let firstDisplayIndex = coordinator.selectionState.indices.min() else { return nil }
        let tableRows = coordinator.tabSessionRegistry.tableRows(for: tab.id)
        guard let row = DisplayRowMapping.row(
            forDisplay: firstDisplayIndex,
            displayIDs: coordinator.activeGridDisplayIDs,
            in: tableRows
        )?.values else { return nil }
        var data: [(column: String, value: String?, type: String)] = []

        let service = ValueDisplayFormatService.shared
        let connId = coordinator.connection.id

        for (i, col) in tableRows.columns.enumerated() {
            var value: String?
            if i < row.count {
                switch row[i] {
                case .null:
                    value = nil
                case .text(let s):
                    value = s
                case .bytes(let data):
                    value = BlobFormattingService.shared.format(data, for: .copy)
                }
            }
            let type = i < tableRows.columnTypes.count ? tableRows.columnTypes[i].displayName : "string"

            if let rawValue = value {
                let format = service.effectiveFormat(columnName: col, scope: tab.tableContext.scope(connectionId: connId))
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
        if gridSelectionOwner == .schemaGrid {
            return selectedInspectorRow?.isEditable ?? false
        }
        guard gridSelectionOwner == .dataGrid,
              !coordinator.safeModeLevel.blocksAllWrites,
              let tab = coordinator.tabManager.selectedTab,
              tab.tabType == .table || tab.tableContext.tableName != nil,
              !coordinator.selectionState.indices.isEmpty else {
            return false
        }
        return true
    }

    var isSelectedRowDeleted: Bool {
        guard gridSelectionOwner == .dataGrid,
              let firstIndex = coordinator.selectionState.indices.min() else { return false }
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
            metadataVersion: currentTab?.metadataVersion ?? -1,
            resultsViewMode: currentTab?.display.resultsViewMode ?? .data,
            inspectorRowSourceRevision: coordinator.inspectorRowSourceRevision
        )
    }
}

struct InspectorTrigger: Equatable {
    let tableName: String?
    let schemaVersion: Int
    let metadataVersion: Int
    let resultsViewMode: ResultsViewMode
    let inspectorRowSourceRevision: Int
}

/// Lightweight equatable value combining all pending-change sources
/// for consolidated toolbar badge onChange observation.
struct PendingChangeTrigger: Equatable {
    let hasDataChanges: Bool
    let pendingTruncates: Set<String>
    let pendingDeletes: Set<String>
    let hasStructureChanges: Bool
    let isFileDirty: Bool
    let hasCreateTablePending: Bool
}
