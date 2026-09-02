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
        let scope = tab.tableContext.scope(connectionId: connId)
        let storageKeys = ValueDisplayFormatColumnKey.storageKeys(for: tableRows.columns)
        let activeFormats = InspectorValueDisplayFormatResolver.activeFormats(
            from: coordinator.dataTabDelegate?.tableViewCoordinator,
            matching: tableRows.columns
        )
        let storedFormats = activeFormats == nil
            ? storageKeys.map { service.effectiveFormat(columnKey: $0, scope: scope) }
            : []

        for (i, col) in tableRows.columns.enumerated() {
            var value: String?
            let columnType = i < tableRows.columnTypes.count ? tableRows.columnTypes[i] : nil
            let format = InspectorValueDisplayFormatResolver.resolve(
                columnIndex: i,
                activeFormats: activeFormats,
                storedFormat: storedFormats.indices.contains(i) ? storedFormats[i] : .raw,
                columnType: columnType,
                databaseType: coordinator.connection.type
            )
            if i < row.count {
                switch row[i] {
                case .null:
                    value = nil
                case .text(let s):
                    value = format == .raw
                        ? s
                        : ValueDisplayFormatService.applyFormat(s, format: format, columnType: columnType) ?? s
                case .bytes(let bytes):
                    value = format.isApplicable(
                        to: columnType,
                        databaseType: coordinator.connection.type
                    ) ? ValueDisplayFormatService.applyFormat(bytes, format: format, columnType: columnType) : nil
                    value = value ?? BlobFormattingService.shared.format(bytes, for: .copy)
                }
            }
            let type = columnType?.displayName ?? "string"

            data.append((column: col, value: value, type: type))
        }

        return data
    }

    // MARK: - Selected Row for the JSON Tab

    /// The same selection the details tab reads, carried as raw cell values.
    ///
    /// The JSON tab decides from the column's own type whether a value prints quoted, which the
    /// formatted strings the details tab takes cannot answer. Only the data grid supplies it: the
    /// schema grid's rows are label and value pairs with no types and no foreign keys.
    var jsonRowSnapshotForSidebar: JSONRowSnapshot? {
        guard gridSelectionOwner == .dataGrid,
              let tab = coordinator.tabManager.selectedTab,
              let firstDisplayIndex = coordinator.selectionState.indices.min() else { return nil }
        let tableRows = coordinator.tabSessionRegistry.tableRows(for: tab.id)
        guard !tableRows.columns.isEmpty,
              let row = DisplayRowMapping.row(
                  forDisplay: firstDisplayIndex,
                  displayIDs: coordinator.activeGridDisplayIDs,
                  in: tableRows
              ) else { return nil }

        return JSONRowSnapshot(
            rowIdentity: "\(tab.id.uuidString)\u{001F}\(row.id)",
            columns: tableRows.columns,
            columnTypes: tableRows.columnTypes,
            values: Array(row.values),
            foreignKeys: tableRows.columnForeignKeys.mapValues(JSONForeignKeyRef.init),
            connectionId: coordinator.connection.id,
            databaseType: coordinator.connection.type
        )
    }

    // MARK: - Sidebar Edit State

    /// Determine if sidebar should be in editable mode
    var isSidebarEditable: Bool {
        if gridSelectionOwner == .schemaGrid {
            return selectedInspectorRow?.isEditable ?? false
        }
        guard gridSelectionOwner == .dataGrid,
              let tab = coordinator.tabManager.selectedTab,
              tab.tabType == .table || tab.tableContext.tableName != nil,
              coordinator.canEditActiveResult,
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
            inspectorRowSourceRevision: coordinator.inspectorRowSourceRevision,
            gridDisplayRevision: coordinator.gridDisplayRevision
        )
    }
}

struct InspectorTrigger: Equatable {
    let tableName: String?
    let schemaVersion: Int
    let metadataVersion: Int
    let resultsViewMode: ResultsViewMode
    let inspectorRowSourceRevision: Int
    let gridDisplayRevision: Int
}

enum InspectorValueDisplayFormatResolver {
    /// The window keeps one grid coordinator, so it can still be pointed at the previously
    /// selected tab. Its formats are only meaningful while it holds this tab's columns.
    @MainActor
    static func activeFormats(
        from grid: TableViewCoordinator?,
        matching columns: [String]
    ) -> [ValueDisplayFormat?]? {
        guard let grid, grid.tableRowsProvider().columns == columns else { return nil }
        return grid.columnDisplayFormats
    }

    static func resolve(
        columnIndex: Int,
        activeFormats: [ValueDisplayFormat?]?,
        storedFormat: ValueDisplayFormat,
        columnType: ColumnType?,
        databaseType: DatabaseType
    ) -> ValueDisplayFormat {
        let candidate: ValueDisplayFormat
        if let activeFormats {
            candidate = activeFormats.indices.contains(columnIndex)
                ? activeFormats[columnIndex] ?? .raw
                : .raw
        } else {
            candidate = storedFormat
        }
        return candidate.isApplicable(to: columnType, databaseType: databaseType) ? candidate : .raw
    }
}

/// Lightweight equatable value combining all pending-change sources
/// for consolidated toolbar badge onChange observation.
struct PendingChangeTrigger: Equatable {
    let hasDataChanges: Bool
    let pendingTruncates: Set<DatabaseTreeTableRef>
    let pendingDeletes: Set<DatabaseTreeTableRef>
    let hasStructureChanges: Bool
    let isFileDirty: Bool
    let hasCreateTablePending: Bool
}
