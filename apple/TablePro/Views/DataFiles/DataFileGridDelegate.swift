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
        controller.setCell(pageRow: row, column: column, text: newValue)
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
        // Rows copied as CSV, JSON or Markdown carry their values, which the tab-separated parser cannot read back.
        if let copied = ClipboardService.shared.readGridRows() {
            controller.pasteRows(DataFilePasteParser.rows(from: copied, into: controller.columnNames.displayNames))
            return
        }
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
        controller.gridCoordinator?.cellFilterMenuItem(forRow: displayRow, dataColumn: dataColumn) { [weak controller] filter in
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

    func dataGridSummaryColumnPolicy() -> SelectionSummaryColumnPolicy? {
        SelectionSummaryColumnPolicy(
            rules: controller.columnNames.ids.map { DataFileColumnTypes.summaryRule(for: controller.kind(of: $0)) },
            emptyTextIsEmpty: true
        )
    }
}

enum DataFilePasteParser {
    static func rows(from text: String) -> [[String]] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { line in line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            .filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    // By name when every copied column is one of the file's, once, so rows copied with columns reordered or
    // hidden land where they came from. Anything else pastes in order, as its text would.
    @MainActor
    static func rows(from copied: GridRowsClipboardPayload, into columns: [String]) -> [[String]] {
        let fileColumns = Set(columns)
        guard Set(copied.columns).count == copied.columns.count, copied.columns.allSatisfy(fileColumns.contains) else {
            return copied.rows.map { $0.map(text(of:)) }
        }
        let sources = columns.map { copied.columns.firstIndex(of: $0) }
        return copied.rows.map { row in
            sources.map { source in
                guard let source, row.indices.contains(source) else { return "" }
                return text(of: row[source])
            }
        }
    }

    // NULL pastes as the empty value this grid's own row copy writes for it.
    @MainActor
    static func text(of cell: PluginCellValue) -> String {
        switch cell {
        case .text(let text): return text
        case .null: return ""
        case .bytes(let data): return BlobFormattingService.shared.format(data, for: .copy) ?? ""
        }
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

    static func summaryRule(for kind: TabularInferredKind) -> SelectionSummaryColumnRule {
        switch kind {
        case .integer, .decimal: return .numeric
        case .boolean, .date, .text: return .countOnly
        }
    }
}
