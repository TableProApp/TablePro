//
//  MainContentView+Bindings.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

extension MainContentView {
    // MARK: - Inspector Selection

    // Whose rows the active grid model's selection indexes: the data tab's, a schema grid's, or nobody's. A schema
    // grid's selection is drawn by the structure inspector, which observes its editor itself.
    var gridSelectionOwner: GridSelectionOwner {
        GridSelectionOwner.resolve(
            tabType: coordinator.tabManager.selectedTab?.tabType,
            resultsViewMode: coordinator.tabManager.selectedTab?.display.resultsViewMode
        )
    }

    private var dataGridModel: DataGridModel? {
        gridSelectionOwner == .dataGrid ? coordinator.activeGridModel : nil
    }

    var structureInspectorSource: StructureInspectorSource? {
        if let session = coordinator.activeStructureSession { return .table(session) }
        if let draft = coordinator.activeCreateTableDraft { return .createTable(draft) }
        return nil
    }

    // MARK: - Inspector Subject

    var hasInspectableRow: Bool {
        guard gridSelectionOwner == .dataGrid else { return false }
        return dataGridModel?.selection.isEmpty == false
    }

    var inspectorSubject: InspectorSubject {
        switch gridSelectionOwner {
        case .dataGrid:
            guard let table = qualifiedTableName else {
                return dataRowSubject(table: String(localized: "Result")) ?? .empty
            }
            return dataRowSubject(table: table) ?? .tableOnly(table: table)
        case .schemaGrid, .none:
            // A chart, a dashboard or a diagram owns no grid; the table is still the subject of its statistics.
            guard let table = qualifiedTableName else { return .empty }
            return .tableOnly(table: table)
        }
    }

    private func dataRowSubject(table: String) -> InspectorSubject? {
        guard let model = dataGridModel else { return nil }
        let rows = model.selection.affectedRows
        guard let first = rows.first else { return nil }
        if rows.count > 1 {
            return .multipleRows(table: table, count: rows.count)
        }
        let total = model.rowCount
        guard total > 0 else { return .tableRow(table: table, position: nil) }
        return .tableRow(table: table, position: InspectorSubject.RowPosition(index: first + 1, total: total))
    }

    private var qualifiedTableName: String? {
        guard let table = currentTab?.tableContext.tableName else { return nil }
        guard let schema = currentTab?.tableContext.schemaName, !schema.isEmpty else { return table }
        return "\(schema).\(table)"
    }

    // MARK: - Selected Row for the JSON Tab

    // Raw cell values, so the JSON tab can quote by the column's own type. Only the data grid has types.
    var jsonRowSnapshotForSidebar: JSONRowSnapshot? {
        guard let model = dataGridModel,
              let tab = coordinator.tabManager.selectedTab,
              let firstDisplayIndex = model.selection.affectedRows.first,
              let scope = coordinator.scope(for: tab),
              let row = model.row(at: firstDisplayIndex) else { return nil }
        let tableRows = model.rows
        guard !tableRows.columns.isEmpty else { return nil }

        return JSONRowSnapshot(
            rowIdentity: "\(tab.id.uuidString)\u{001F}\(row.id)",
            columns: tableRows.columns,
            columnTypes: tableRows.columnTypes,
            values: Array(row.values),
            foreignKeys: tableRows.columnForeignKeys.mapValues(JSONForeignKeyRef.init),
            scope: scope,
            databaseType: coordinator.connection.type
        )
    }

    // MARK: - Sidebar Edit State

    var isSidebarEditable: Bool {
        guard let model = dataGridModel,
              let tab = coordinator.tabManager.selectedTab,
              tab.tabType == .table || tab.tableContext.tableName != nil,
              coordinator.canEditActiveResult,
              !model.selection.isEmpty else {
            return false
        }
        return true
    }

    var isSelectedRowDeleted: Bool {
        guard let model = dataGridModel,
              let first = model.selection.affectedRows.first,
              let rowID = model.rowID(at: first) else { return false }
        return coordinator.changeManager.isRowDeleted(rowID)
    }

    // MARK: - Sort State Binding

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

    var resultsViewModeBinding: Binding<ResultsViewMode> {
        Binding(
            get: { coordinator.tabManager.selectedTab?.display.resultsViewMode ?? .data },
            set: { newValue in
                if let index = coordinator.tabManager.selectedTabIndex {
                    coordinator.commitActiveGridEdit()
                    coordinator.tabManager.mutate(at: index) { $0.display.resultsViewMode = newValue }
                }
            }
        )
    }

    // MARK: - Current Tab Accessor

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
            gridDisplayRevision: coordinator.gridDisplayRevision,
            structureEditor: coordinator.activeStructureEditor.map { ObjectIdentifier($0) }
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
    // A structure session or Create Table draft appears after its view first mounts, which moves nothing else here.
    var structureEditor: ObjectIdentifier?
}

enum InspectorValueDisplayFormatResolver {
    // The model's formats include a Display As the grid applied without a table to save it under.
    @MainActor
    static func activeFormats(
        from model: DataGridModel?,
        matching columns: [String]
    ) -> [ValueDisplayFormat?]? {
        guard let model, model.rows.columns == columns else { return nil }
        return model.store.displayFormats
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

// One value so a single `onChange` drives the toolbar badge across every pending-change source.
struct PendingChangeTrigger: Equatable {
    let hasDataChanges: Bool
    let pendingTruncates: Set<DatabaseTreeTableRef>
    let pendingDeletes: Set<DatabaseTreeTableRef>
    let hasStructureChanges: Bool
    // A diagram's edits are read from the selected tab's model, so a tab switch has to recompute too.
    var diagramEditsRevision = 0
    var selectedTabId: UUID?
    let isFileDirty: Bool
    let hasCreateTablePending: Bool
    // Without it a staged principal edit never re-runs `updateToolbarPendingState()`, so the commit control stays dim.
    let hasPrincipalChanges: Bool
    let hasTypeChanges: Bool
}
