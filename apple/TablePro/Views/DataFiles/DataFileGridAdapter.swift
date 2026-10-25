//
//  DataFileGridAdapter.swift
//  TablePro
//

import AppKit
import TableProPluginKit
import TableProTabular

// The data file grid's rows are the controller's current page; every edit, sort and column command goes
// through the controller, which owns the file and its undo.
@MainActor
final class DataFileGridAdapter {
    let model: DataGridModel
    weak var controller: DataFileController?
    weak var owner: DataFileSplitViewController?
    private let detachedChangeState = AnyChangeManager(DataFileChangeManager())

    init(model: DataGridModel) {
        self.model = model
        model.dataSource = self
        model.actions = self
        model.datasetFinder = self
    }

    private func pageRows(of rowIDs: [RowID]) -> Set<Int> {
        Set(rowIDs.compactMap { model.displayIndex(of: $0) })
    }

    private func columnID(for column: DataGridColumn) -> TabularColumnID? {
        guard let controller, controller.columnNames.ids.indices.contains(column.dataIndex) else { return nil }
        return controller.columnNames.ids[column.dataIndex]
    }
}

extension DataFileGridAdapter: DataGridDataSource {
    var gridRows: TableRows { controller?.tableRows ?? TableRows() }
    var gridChangeState: AnyChangeManager { controller?.anyChangeManager ?? detachedChangeState }
    var gridRowNumberOffset: Int { controller?.pageOffset ?? 0 }

    func gridSummaryColumnPolicy() -> SelectionSummaryColumnPolicy? {
        guard let controller else { return nil }
        return SelectionSummaryColumnPolicy(
            rules: controller.columnNames.ids.map { DataFileColumnTypes.summaryRule(for: controller.kind(of: $0)) },
            emptyTextIsEmpty: true
        )
    }
}

extension DataFileGridAdapter: DataGridActions {
    // One command is one commit: the controller writes the table once and registers one undo step.
    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool {
        guard let controller, controller.isEditable, !edits.isEmpty else { return false }
        var applied = false
        controller.batchCellEdits(actionName: actionName) {
            for edit in edits {
                guard case .existing(let key) = edit.rowID else { continue }
                controller.setCell(key: key, column: edit.dataIndex, text: edit.newValue.isNull ? nil : edit.newValue.asText ?? "")
                applied = true
            }
        }
        return applied
    }

    func gridDeleteRows(_ rowIDs: [RowID]) {
        owner?.deleteRows(pageRows(of: rowIDs))
    }

    func gridAddRow() {
        controller?.appendRow()
    }

    func gridCanPasteRows() -> Bool {
        guard let controller else { return false }
        return controller.isEditable && ClipboardService.shared.hasText
    }

    // Rows copied as CSV, JSON or Markdown carry their values, which the tab-separated parser cannot read back.
    func gridPasteRows() {
        guard let controller else { return }
        if let copied = ClipboardService.shared.readGridRows() {
            controller.pasteRows(DataFilePasteParser.rows(from: copied, into: controller.columnNames.displayNames))
            return
        }
        guard let raw = ClipboardService.shared.readText(), !raw.isEmpty else { return }
        controller.pasteRows(DataFilePasteParser.rows(from: raw))
    }

    // The cells the command names, except that picked columns cover every visible row of the file, not only the page.
    func gridSetCellsToValue(_ cells: [(rowID: RowID, column: DataGridColumn)]) -> Bool {
        guard let owner, let controller else { return false }
        let named = cells.compactMap { cell -> (column: TabularColumnID, key: Int)? in
            guard case .existing(let key) = cell.rowID, let column = columnID(for: cell.column) else { return nil }
            return (column: column, key: key)
        }
        let picked = controller.selectedColumnIDs()
        let coversPickedColumns = !picked.isEmpty && Set(named.map(\.column)) == Set(picked)
        guard let target = coversPickedColumns ? controller.cellTarget() : controller.cellTarget(cells: named) else {
            return false
        }
        owner.presentSetCellsToValue(target)
        return true
    }

    func gridSortDidChange(_ sort: SortState) {
        controller?.updateSort(sort)
    }

    func gridShowRowsAsJSON(_ rowIDs: [RowID]) {
        controller?.isInspectorVisible = true
    }

    func gridExportResults() {
        owner?.presentExport()
    }

    func gridHideColumn(_ column: DataGridColumn) {
        controller?.columnLayout.hiddenColumns.insert(column.name)
    }

    func gridShowAllColumns() {
        controller?.columnLayout.hiddenColumns.removeAll()
    }

    func gridFilterWithColumn(_ column: DataGridColumn) {
        guard let controller, controller.columnNames.id(forName: column.name) != nil else { return }
        controller.addBlankFilter(columnName: column.name)
    }

    func gridCellMenuItems(for rowID: RowID, column: DataGridColumn) -> [NSMenuItem] {
        guard let controller, let id = columnID(for: column),
              let row = controller.tableRows.row(withID: rowID), column.dataIndex < row.values.count else { return [] }
        let item = CellFilterMenuBuilder.menuItem(
            columnName: column.name,
            columnType: DataFileColumnTypes.filterType(for: controller.kind(of: id)),
            value: row.values[column.dataIndex]
        ) { [weak controller] filter in
            controller?.addFilter(filter)
        }
        return item.map { [$0] } ?? []
    }

    func gridColumnMenuItems(for column: DataGridColumn) -> [NSMenuItem] {
        guard let controller, let id = columnID(for: column) else { return [] }
        return DataFileColumnMenuBuilder.items(
            for: id,
            controller: controller,
            selectedColumns: controller.selectedColumnIDs()
        )
    }

    func gridRowMenuItems(for rowIDs: [RowID]) -> [NSMenuItem] {
        guard let controller, controller.isEditable, let pageRow = pageRows(of: rowIDs).min() else { return [] }
        return DataFileColumnMenuBuilder.rowItems(forPageRow: pageRow)
    }
}

// Find covers every row of the file: a page row's ID is `.existing(key)`, the key a match carries.
extension DataFileGridAdapter: DataGridDatasetFinding {
    func gridFindAll(_ query: GridDatasetFindQuery) async throws -> [GridFindState.Match] {
        guard let controller else { return [] }
        return try await controller.findMatches(query)
    }

    func gridDisplayPosition(of rowID: RowID) -> Int? {
        guard case .existing(let key) = rowID else { return nil }
        return controller?.displayPosition(ofKey: key)
    }

    func gridLoadRow(_ rowID: RowID) -> Bool {
        guard let controller, case .existing(let key) = rowID, controller.displayPosition(ofKey: key) != nil else {
            return false
        }
        controller.reveal(key: key, selecting: false)
        return true
    }

    func gridReplace(_ match: GridFindState.Match, query: GridDatasetFindQuery, with template: String) -> Bool {
        controller?.replaceMatch(match, query: query, with: template) ?? false
    }

    func gridReplaceAll(_ query: GridDatasetFindQuery, with template: String) {
        controller?.replaceAll(query, with: template)
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
