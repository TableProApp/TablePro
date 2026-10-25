//
//  HeldRowsGridAdapter.swift
//  TablePro
//

import AppKit
import Combine
import TableProTheme

// A read-only grid over rows its owner holds in full: the Structure lists, agent results, table
// listings, both comparisons and the theme preview. Nothing here can reach a table's saved layout.
@MainActor
final class HeldRowsGridAdapter: ObservableObject {
    let model: DataGridModel

    // Sorts the held rows itself when no owner re-orders them.
    var sortsHeldRows: Bool
    var onSortChange: ((SortState) -> Void)?
    var onSelectionChange: (([RowID]) -> Void)?

    var visualStates: [RowID: RowVisualState] = [:]
    var textTones: [RowID: [Int: NSColor]] = [:]
    var spokenTexts: [RowID: [Int: String]] = [:]
    var checkboxState: ((RowID, DataGridColumn) -> Bool?)?
    var checkboxChange: ((Bool, [RowID], DataGridColumn) -> Void)?

    private(set) var heldRows = TableRows()
    private var displayedRows = TableRows()
    private let changeState = AnyChangeManager(DataChangeManager())
    private var selectionSubscription: AnyCancellable?

    init(
        configuration: DataGridConfiguration,
        sortsHeldRows: Bool = false,
        columnLayout: ColumnLayoutState = ColumnLayoutState(),
        sortState: SortState = SortState(),
        themeScope: ThemeScope = .live
    ) {
        self.sortsHeldRows = sortsHeldRows
        self.model = DataGridModel(
            store: InMemoryDataGridStateStore(columnLayout: columnLayout, sortState: sortState),
            configuration: configuration,
            themeScope: themeScope
        )
        model.dataSource = self
        model.actions = self
        selectionSubscription = model.$selectionRevision
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.onSelectionChange?(self.model.selectedRowIDs)
            }
    }

    // The rows were replaced.
    func setRows(_ rows: TableRows) {
        let previousColumns = displayedRows.columns
        heldRows = rows
        displayedRows = sortsHeldRows ? TableRowsSorting.sorted(rows, by: model.store.sortState) : rows
        model.reloadHeldRows(columnsChanged: previousColumns != rows.columns || model.columns.isEmpty)
    }

    // The same rows with some cells drawn differently, as a checkbox after a toggle.
    func redrawCells(_ cells: Set<CellPosition>) {
        guard !cells.isEmpty else { return }
        model.apply(.cellsChanged(cells))
    }

    // An owner that sorts its rows itself reports the sort it applied, so the header shows it.
    func showSort(_ sort: SortState) {
        guard model.store.sortState != sort else { return }
        model.store.sortState = sort
        guard sortsHeldRows else { return }
        displayedRows = TableRowsSorting.sorted(heldRows, by: sort)
        model.reloadRows()
    }

    func storageIndex(of rowID: RowID) -> Int? {
        displayedRows.index(of: rowID)
    }
}

extension HeldRowsGridAdapter: DataGridDataSource {
    var gridRows: TableRows { displayedRows }
    var gridChangeState: AnyChangeManager { changeState }

    func gridVisualState(for rowID: RowID) -> RowVisualState? {
        visualStates[rowID]
    }

    func gridTextTone(for rowID: RowID, column: DataGridColumn) -> NSColor? {
        textTones[rowID]?[column.dataIndex]
    }

    func gridAccessibilityText(for rowID: RowID, column: DataGridColumn) -> String? {
        spokenTexts[rowID]?[column.dataIndex]
    }

    func gridCheckboxState(for rowID: RowID, column: DataGridColumn) -> Bool? {
        checkboxState?(rowID, column)
    }
}

extension HeldRowsGridAdapter: DataGridActions {
    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool {
        false
    }

    func gridSortDidChange(_ sort: SortState) {
        if sortsHeldRows {
            displayedRows = TableRowsSorting.sorted(heldRows, by: sort)
            model.reloadRows()
        }
        onSortChange?(sort)
    }

    func gridSetCheckbox(_ isOn: Bool, rowIDs: [RowID], column: DataGridColumn) {
        checkboxChange?(isOn, rowIDs, column)
    }
}

extension DataGridModel {
    // Rows an owner holds were replaced; another column set rebuilds the view's columns before the reload.
    func reloadHeldRows(columnsChanged: Bool) {
        if columnsChanged {
            apply(.columnsReplaced)
        }
        reloadRows()
    }
}
