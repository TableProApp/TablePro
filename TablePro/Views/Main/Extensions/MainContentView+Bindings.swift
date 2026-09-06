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

    // MARK: - Inspector Subject

    /// Whether anything is selected for the inspector to show.
    var hasInspectableRow: Bool {
        switch gridSelectionOwner {
        case .schemaGrid: return selectedInspectorRow != nil
        case .dataGrid: return !coordinator.selectionState.indices.isEmpty
        case .none: return false
        }
    }

    /// What the inspector's header names.
    ///
    /// A schema grid's selection is a column definition, not a row of a result: it has no position
    /// and no identity, so it gets its own case rather than being rendered as "Row 0 of 0".
    var inspectorSubject: InspectorSubject {
        switch gridSelectionOwner {
        case .schemaGrid:
            guard let row = selectedInspectorRow else {
                guard let table = currentTab?.tableContext.tableName else { return .empty }
                return .tableOnly(table: table)
            }
            let name = row.fields.first?.value ?? ""
            return .columnDefinition(
                column: name.isEmpty ? String(localized: "Column") : name,
                table: currentTab?.tableContext.tableName
            )
        case .dataGrid:
            guard let table = qualifiedTableName else {
                return dataRowSubject(table: String(localized: "Result")) ?? .empty
            }
            return dataRowSubject(table: table) ?? .tableOnly(table: table)
        case .none:
            /// A chart, a dashboard or an ER diagram owns no grid, so there is no row to name. The
            /// table still is the subject when the tab has one, which is what the table statistics
            /// are shown under.
            guard let table = qualifiedTableName else { return .empty }
            return .tableOnly(table: table)
        }
    }

    private func dataRowSubject(table: String) -> InspectorSubject? {
        let indices = coordinator.selectionState.indices
        guard !indices.isEmpty else { return nil }
        if indices.count > 1 {
            return .multipleRows(table: table, count: indices.count)
        }
        guard let tab = coordinator.tabManager.selectedTab, let first = indices.min() else {
            return .tableRow(table: table, position: nil)
        }
        let total = coordinator.activeGridDisplayIDs?.count
            ?? coordinator.tabSessionRegistry.tableRows(for: tab.id).count
        guard total > 0 else { return .tableRow(table: table, position: nil) }
        return .tableRow(
            table: table,
            position: InspectorSubject.RowPosition(index: first + 1, total: total)
        )
    }

    /// Schema-qualified where the engine has schemas, so two tables of the same name in different
    /// schemas do not read identically in the header.
    private var qualifiedTableName: String? {
        guard let table = currentTab?.tableContext.tableName else { return nil }
        guard let schema = currentTab?.tableContext.schemaName, !schema.isEmpty else { return table }
        return "\(schema).\(table)"
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
