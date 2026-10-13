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

/// Selected row ids held by reference: a read made during a SwiftUI update gets a `State` or `Binding` snapshot.
@MainActor
internal final class StructureListSelection<ID: Hashable>: ObservableObject {
    @Published internal var ids: Set<ID> = []
}

/// A read-only Structure list drawn by `DataGridView`. Its configuration names only the database type,
/// so `columnLayoutKey` stays nil and the list never writes into the table's saved column widths.
@MainActor
internal final class StructureListGridModel<ID: Hashable>: ObservableObject, DataGridViewDelegate {
    internal let changeManager = AnyChangeManager(DataChangeManager())
    internal var onSortStateChanged: ((SortState) -> Void)?
    private let accessibilityLabel: String?

    internal private(set) var tableRows = TableRows()
    internal private(set) var rowIDs: [ID] = []
    private var loadedKey: Int?
    private weak var coordinator: TableViewCoordinator?

    internal init(accessibilityLabel: String? = nil) {
        self.accessibilityLabel = accessibilityLabel
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

    /// The grid's row selection kept by row identity, so a sort, a filter or a refresh moves it with its rows.
    /// Build it after `ensureLoaded`: the grid reads the positions it held when the binding was built.
    internal func selection(
        get selectedIDs: @escaping () -> Set<ID>,
        set select: @escaping (Set<ID>) -> Void
    ) -> Binding<Set<Int>> {
        Binding(
            get: { self.displayRows(of: selectedIDs()) },
            set: { rows in
                // Until the grid puts the selection back after a reload, what it publishes names the rows it showed before.
                guard self.coordinator?.hasRestoredSelection != false else { return }
                let current = selectedIDs()
                guard rows != self.displayRows(of: current) else { return }
                let selected = self.ids(atDisplayRows: rows)
                guard selected != current else { return }
                select(selected)
            }
        )
    }

    internal func dataGridAttach(tableViewCoordinator: TableViewCoordinator) {
        coordinator = tableViewCoordinator
        if let accessibilityLabel {
            tableViewCoordinator.tableView?.setAccessibilityLabel(accessibilityLabel)
        }
        // A reload drops the table view's selection without a notification, so the selection kept by identity is put back after each one.
        tableViewCoordinator.hasRestoredSelection = false
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

/// A nil `sortState` turns header sorting off. `defaultWidths` follows `columns` by index.
internal struct StructureListGrid<ID: Hashable>: View {
    internal let model: StructureListGridModel<ID>
    internal let columns: [String]
    internal var defaultWidths: [CGFloat] = []
    internal let contentKey: Int
    internal let rows: () -> [StructureListRow<ID>]
    internal let databaseType: DatabaseType
    internal let selectedIDs: () -> Set<ID>
    internal let select: (Set<ID>) -> Void
    internal var sortState: Binding<SortState>?
    @Binding internal var columnLayout: ColumnLayoutState

    internal static func layout(
        _ layout: ColumnLayoutState,
        columns: [String],
        defaultWidths: [CGFloat]
    ) -> ColumnLayoutState {
        var filled = layout
        for (column, width) in zip(columns, defaultWidths) where filled.columnWidths[column] == nil {
            filled.columnWidths[column] = width
        }
        return filled
    }

    internal var body: some View {
        let model = model
        let columns = columns
        let defaultWidths = defaultWidths
        let sortState = sortState
        let tableRows = model.ensureLoaded(key: contentKey, columns: columns, rows: rows)
        let storedLayout = $columnLayout
        let layout = Binding(
            get: { Self.layout(storedLayout.wrappedValue, columns: columns, defaultWidths: defaultWidths) },
            set: { storedLayout.wrappedValue = $0 }
        )
        return DataGridView(
            tableRowsProvider: { tableRows },
            changeManager: model.changeManager,
            isEditable: false,
            configuration: DataGridConfiguration(
                databaseType: databaseType,
                supportsColumnCommands: false,
                supportsValueFilter: false,
                supportsColumnSort: sortState != nil
            ),
            delegate: model,
            selectedRowIndices: model.selection(get: selectedIDs, set: select),
            sortState: sortState ?? .constant(SortState()),
            columnLayout: layout,
            contentRevision: contentKey
        )
        .onAppear {
            guard let sortState else { return }
            model.onSortStateChanged = { sortState.wrappedValue = $0 }
        }
    }
}
