//
//  StructureListGrid.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProPluginKit

internal struct StructureListRow<ID: Hashable>: Hashable {
    internal let id: ID
    internal let values: [String]
}

/// A read-only Structure list drawn by `DataGridView`. Its configuration names only the database type,
/// so `columnLayoutKey` stays nil and the list never writes into the table's saved column widths.
@MainActor
internal final class StructureListGridModel<ID: Hashable>: ObservableObject, DataGridViewDelegate {
    internal let changeManager = AnyChangeManager(DataChangeManager())
    internal let restoresSelectionAfterReload: Bool
    internal var onSortStateChanged: ((SortState) -> Void)?
    private let accessibilityLabel: String?

    internal private(set) var tableRows = TableRows()
    internal private(set) var rowIDs: [ID] = []
    private var loadedKey: Int?
    private weak var coordinator: TableViewCoordinator?

    internal init(accessibilityLabel: String? = nil, restoresSelectionAfterReload: Bool = false) {
        self.accessibilityLabel = accessibilityLabel
        self.restoresSelectionAfterReload = restoresSelectionAfterReload
    }

    internal func ensureLoaded(key: Int, columns: [String], rows: () -> [StructureListRow<ID>]) -> TableRows {
        var hasher = Hasher()
        hasher.combine(key)
        hasher.combine(columns)
        let combined = hasher.finalize()
        guard loadedKey != combined else { return tableRows }
        loadedKey = combined

        let listed = rows()
        rowIDs = listed.map(\.id)
        tableRows = TableRows.from(
            queryRows: listed.map { $0.values.map(PluginCellValue.text) },
            columns: columns,
            columnTypes: Array(repeating: .text(rawType: nil), count: columns.count),
            columnNullable: Dictionary(columns.map { ($0, false) }, uniquingKeysWith: { first, _ in first })
        )
        return tableRows
    }

    internal func rowIndex(forDisplayRow row: Int) -> Int? {
        guard let index = DisplayRowMapping.rowIndex(forDisplay: row, displayIDs: coordinator?.displayIDs, in: tableRows),
              rowIDs.indices.contains(index) else { return nil }
        return index
    }

    internal func id(atDisplayRow row: Int) -> ID? {
        rowIndex(forDisplayRow: row).map { rowIDs[$0] }
    }

    internal func ids(atDisplayRows rows: Set<Int>) -> Set<ID> {
        Set(rows.compactMap { id(atDisplayRow: $0) })
    }

    internal func displayRows(of ids: Set<ID>) -> Set<Int> {
        guard !ids.isEmpty else { return [] }
        let displayIDs = coordinator?.displayIDs
        return Set(rowIDs.indices.compactMap { index -> Int? in
            guard ids.contains(rowIDs[index]), tableRows.rows.indices.contains(index) else { return nil }
            return DisplayRowMapping.displayIndex(forRowID: tableRows.rows[index].id, displayIDs: displayIDs, in: tableRows)
        })
    }

    internal func dataGridAttach(tableViewCoordinator: TableViewCoordinator) {
        coordinator = tableViewCoordinator
        if let accessibilityLabel {
            tableViewCoordinator.tableView?.setAccessibilityLabel(accessibilityLabel)
        }
        // A reload drops the table view's selection without a notification, so a selection kept by identity is put back after each one.
        if restoresSelectionAfterReload {
            tableViewCoordinator.hasRestoredSelection = false
        }
    }

    internal func dataGridSortStateChanged(_ state: SortState) {
        onSortStateChanged?(state)
    }

    internal func dataGridCopyRows(_ indices: Set<Int>) {
        let lines = indices.sorted().compactMap { row -> String? in
            guard let index = rowIndex(forDisplayRow: row) else { return nil }
            return tableRows.rows[index].values.map { $0.asText ?? "" }.joined(separator: "\t")
        }
        guard !lines.isEmpty else { return }
        ClipboardService.shared.writeText(lines.joined(separator: "\n"))
    }
}

/// A nil `sortState` turns header sorting off.
internal struct StructureListGrid<ID: Hashable>: View {
    internal let model: StructureListGridModel<ID>
    internal let columns: [String]
    internal let contentKey: Int
    internal let rows: () -> [StructureListRow<ID>]
    internal let databaseType: DatabaseType
    @Binding internal var selectedRows: Set<Int>
    internal var sortState: Binding<SortState>?
    @Binding internal var columnLayout: ColumnLayoutState

    internal var body: some View {
        let model = model
        let columns = columns
        let rows = rows
        let key = contentKey
        let sortState = sortState
        return DataGridView(
            tableRowsProvider: { model.ensureLoaded(key: key, columns: columns, rows: rows) },
            changeManager: model.changeManager,
            isEditable: false,
            configuration: DataGridConfiguration(
                databaseType: databaseType,
                supportsColumnCommands: false,
                supportsValueFilter: false,
                supportsColumnSort: sortState != nil
            ),
            delegate: model,
            selectedRowIndices: $selectedRows,
            sortState: sortState ?? .constant(SortState()),
            columnLayout: $columnLayout,
            contentRevision: key
        )
        .onAppear {
            guard let sortState else { return }
            model.onSortStateChanged = { sortState.wrappedValue = $0 }
        }
    }
}
