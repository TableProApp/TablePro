//
//  DataFileGridDelegate.swift
//  TablePro
//

import AppKit
import TableProPluginKit
import TableProTabular

@MainActor
final class DataFileGridDelegate: DataGridViewDelegate {
    weak var owner: DataFileSplitViewController?
    private let controller: DataFileController

    init(controller: DataFileController) {
        self.controller = controller
    }

    func dataGridAttach(tableViewCoordinator: TableViewCoordinator) {
        controller.gridCoordinator = tableViewCoordinator
    }

    func dataGridDidEditCell(row: Int, column: Int, newValue: String?) {
        controller.setCell(pageRow: row, column: column, text: newValue ?? "")
    }

    func dataGridDeleteRows(_ indices: Set<Int>) {
        owner?.deleteRows(indices)
    }

    func dataGridAddRow() {
        controller.appendRow()
    }

    func dataGridCopyRows(_ indices: Set<Int>) {
        let lines = indices.sorted().compactMap { row -> String? in
            guard controller.tableRows.rows.indices.contains(row) else { return nil }
            return controller.tableRows.rows[row].values.map { value -> String in
                guard case .text(let text) = value else { return "" }
                return text
                    .replacingOccurrences(of: "\t", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
            }.joined(separator: "\t")
        }
        guard !lines.isEmpty else { return }
        ClipboardService.shared.writeText(lines.joined(separator: "\n"))
    }

    func dataGridPasteRows() {
        guard let raw = ClipboardService.shared.readText(), !raw.isEmpty else { return }
        let rows = DataFilePasteParser.rows(from: raw)
        controller.pasteRows(rows)
    }

    func dataGridCanPasteRows() -> Bool {
        controller.isEditable && ClipboardService.shared.hasText
    }

    func dataGridSortStateChanged(_ state: SortState) {
        controller.updateSort(state)
    }

    func dataGridUndo() {
        controller.undoManager?.undo()
    }

    func dataGridRedo() {
        controller.undoManager?.redo()
    }

    func dataGridShowRowAsJSON() {
        controller.isInspectorVisible = true
    }

    func dataGridExportResults() {
        owner?.presentExport()
    }

    func dataGridHideColumn(_ columnName: String) {
        controller.columnLayout.hiddenColumns.insert(columnName)
    }

    func dataGridShowAllColumns() {
        controller.columnLayout.hiddenColumns.removeAll()
    }

    func dataGridFilterColumn(_ columnName: String) {
        guard controller.columnNames.id(forName: columnName) != nil else { return }
        controller.addBlankFilter(columnName: columnName)
    }

    func dataGridFilterMenuItem(forRow displayRow: Int, dataColumn: Int) -> NSMenuItem? {
        guard controller.tableRows.rows.indices.contains(displayRow),
              controller.columnNames.ids.indices.contains(dataColumn) else { return nil }
        let row = controller.tableRows.rows[displayRow]
        guard dataColumn < row.values.count else { return nil }
        let id = controller.columnNames.ids[dataColumn]
        return CellFilterMenuBuilder.menuItem(
            columnName: controller.columnNames.displayNames[dataColumn],
            columnType: DataFileColumnTypes.filterType(for: controller.kind(of: id)),
            value: row.values[dataColumn]
        ) { [weak controller] filter in
            controller?.addFilter(filter)
        }
    }

    func dataGridColumnStructureMenuItems(forColumn dataColumnIndex: Int) -> [NSMenuItem] {
        guard controller.columnNames.ids.indices.contains(dataColumnIndex) else { return [] }
        return DataFileColumnMenuBuilder.items(
            for: controller.columnNames.ids[dataColumnIndex],
            controller: controller,
            selectedColumns: controller.selectedColumnIDs()
        )
    }

    func dataGridRowStructureMenuItems(forRow displayRow: Int) -> [NSMenuItem] {
        guard controller.isEditable else { return [] }
        return DataFileColumnMenuBuilder.rowItems(forPageRow: displayRow)
    }
}

enum DataFilePasteParser {
    static func rows(from text: String) -> [[String]] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { line in line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            .filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}

enum DataFileColumnTypes {
    static func filterType(for kind: TabularInferredKind) -> ColumnType {
        switch kind {
        case .integer: return .integer(rawType: "INTEGER")
        case .decimal: return .decimal(rawType: "DECIMAL")
        case .boolean: return .boolean(rawType: "BOOLEAN")
        case .date: return .date(rawType: "DATE")
        case .text: return .text(rawType: "TEXT")
        }
    }
}
