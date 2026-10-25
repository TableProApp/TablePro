import AppKit
import TableProPluginKit

enum DataGridCommand: Hashable, CaseIterable {
    case addRow
    case duplicateRows
    case deleteRows
    case undoDelete
    case pasteRows
    case moveRows
    case filterWithColumn
    case hideColumns
    case showRowsAsJSON
    case exportResults
    case clearResults
    case searchAllRows
    case navigateForeignKey
    case highlightValues
    case displayAs
    case freezeColumns
    case valueFilter
    case copyAsSQL
    case loadUnloadedValues
}

enum DataGridLayoutScope: Equatable {
    case table(ColumnLayoutTableKey)
    case ephemeral
}

struct DataGridEngineTraits: Equatable {
    var databaseType: DatabaseType?
    var immutableColumns: Set<String> = []
    var usesTrueFalseBooleans = false
    var stringLiteralPrefix: String = ""
    var cellWriterSupport: CellWriterSupport = .none
    var supportsFieldRemoval = false
    // The database the rows came from, for the editors that read it (FK picker and preview, escaping).
    var connectionScope: DatabaseScope?
    // The Structure and Create Table type pickers list the connection's own types.
    var looksUpUserDefinedTypes = false

    static let none = DataGridEngineTraits()
}

@MainActor
protocol DataGridDataSource: AnyObject {
    var gridRows: TableRows { get }
    var gridChangeState: AnyChangeManager { get }
    var gridRowNumberOffset: Int { get }
    var gridHighlightRules: [HighlightRule] { get }
    // The rows are one page of more, so Find counts what this page holds.
    var gridHasUnloadedRows: Bool { get }

    func gridVisualState(for rowID: RowID) -> RowVisualState?
    func gridTextTone(for rowID: RowID, column: DataGridColumn) -> NSColor?
    func gridAccessibilityText(for rowID: RowID, column: DataGridColumn) -> String?
    func gridCheckboxState(for rowID: RowID, column: DataGridColumn) -> Bool?
    func gridMenuOptions(for rowID: RowID, column: DataGridColumn) -> [GridMenuOption]?
    func gridSummaryColumnPolicy() -> SelectionSummaryColumnPolicy?
}

extension DataGridDataSource {
    var gridRowNumberOffset: Int { 0 }
    var gridHighlightRules: [HighlightRule] { [] }
    var gridHasUnloadedRows: Bool { false }
    func gridVisualState(for rowID: RowID) -> RowVisualState? { nil }
    func gridTextTone(for rowID: RowID, column: DataGridColumn) -> NSColor? { nil }
    func gridAccessibilityText(for rowID: RowID, column: DataGridColumn) -> String? { nil }
    func gridCheckboxState(for rowID: RowID, column: DataGridColumn) -> Bool? { nil }
    func gridMenuOptions(for rowID: RowID, column: DataGridColumn) -> [GridMenuOption]? { nil }
    func gridSummaryColumnPolicy() -> SelectionSummaryColumnPolicy? { nil }
}

@MainActor
protocol DataGridActions: AnyObject {
    // The owner records one undoable step, updates its rows and reports back through model.apply(_:).
    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool
    func gridDeleteRows(_ rowIDs: [RowID])
    // True when the owner wrote the pasteboard itself (a format only it knows); false lets the grid copy.
    func gridCopyRows(_ rowIDs: [RowID]) -> Bool
    // True when the owner ran its own Set Cells to Value over these cells (beyond the loaded page).
    func gridSetCellsToValue(_ cells: [(rowID: RowID, column: DataGridColumn)]) -> Bool
    func gridUndoDelete(_ rowIDs: [RowID])
    func gridAddRow()
    func gridDuplicateRows(_ rowIDs: [RowID])
    func gridCanPasteRows() -> Bool
    func gridPasteRows()
    func gridMoveRow(from source: RowID, toDisplayIndex destination: Int)
    func gridSortDidChange(_ sort: SortState)
    func gridConfirmDisplayOrderChange(then apply: @escaping @MainActor () -> Void)
    func gridFilterWithColumn(_ column: DataGridColumn)
    func gridHideColumn(_ column: DataGridColumn)
    func gridShowAllColumns()
    func gridNavigateForeignKey(value: String, info: ForeignKeyInfo, intent: ReferenceOpenIntent)
    func gridShowRowsAsJSON(_ rowIDs: [RowID])
    func gridExportResults()
    func gridClearResults()
    func gridSearchAllRows(term: String)
    func gridSetCheckbox(_ isOn: Bool, rowIDs: [RowID], column: DataGridColumn)
    func gridLoadUnloadedValues(rowIDs: [RowID], columns: IndexSet?, completion: @escaping @MainActor (Bool) -> Void)
    var gridSQLExporter: (any DataGridSQLExporting)? { get }

    func gridColumnMenuItems(for column: DataGridColumn) -> [NSMenuItem]
    func gridRowMenuItems(for rowIDs: [RowID]) -> [NSMenuItem]
    func gridCellMenuItems(for rowID: RowID, column: DataGridColumn) -> [NSMenuItem]
    func gridEmptySpaceMenu() -> NSMenu?
    func gridHighlightValuesMenuItem(for column: DataGridColumn) -> NSMenuItem?
}

extension DataGridActions {
    func gridDeleteRows(_ rowIDs: [RowID]) {}
    func gridCopyRows(_ rowIDs: [RowID]) -> Bool { false }
    func gridSetCellsToValue(_ cells: [(rowID: RowID, column: DataGridColumn)]) -> Bool { false }
    func gridUndoDelete(_ rowIDs: [RowID]) {}
    func gridAddRow() {}
    func gridDuplicateRows(_ rowIDs: [RowID]) {}
    func gridCanPasteRows() -> Bool { false }
    func gridPasteRows() {}
    func gridMoveRow(from source: RowID, toDisplayIndex destination: Int) {}
    func gridSortDidChange(_ sort: SortState) {}
    func gridConfirmDisplayOrderChange(then apply: @escaping @MainActor () -> Void) { apply() }
    func gridFilterWithColumn(_ column: DataGridColumn) {}
    func gridHideColumn(_ column: DataGridColumn) {}
    func gridShowAllColumns() {}
    func gridNavigateForeignKey(value: String, info: ForeignKeyInfo, intent: ReferenceOpenIntent) {}
    func gridShowRowsAsJSON(_ rowIDs: [RowID]) {}
    func gridExportResults() {}
    func gridClearResults() {}
    func gridSearchAllRows(term: String) {}
    func gridSetCheckbox(_ isOn: Bool, rowIDs: [RowID], column: DataGridColumn) {}
    func gridLoadUnloadedValues(rowIDs: [RowID], columns: IndexSet?, completion: @escaping @MainActor (Bool) -> Void) {
        completion(false)
    }
    var gridSQLExporter: (any DataGridSQLExporting)? { nil }
    func gridColumnMenuItems(for column: DataGridColumn) -> [NSMenuItem] { [] }
    func gridRowMenuItems(for rowIDs: [RowID]) -> [NSMenuItem] { [] }
    func gridCellMenuItems(for rowID: RowID, column: DataGridColumn) -> [NSMenuItem] { [] }
    func gridEmptySpaceMenu() -> NSMenu? { nil }
    func gridHighlightValuesMenuItem(for column: DataGridColumn) -> NSMenuItem? { nil }
}

@MainActor
protocol DataGridSQLExporting: AnyObject {
    func canCopyAsInsert(_ rows: TableRows) -> Bool
    func canCopyAsUpdate(_ rows: TableRows) -> Bool
    func insertStatements(for rowIDs: [RowID], columns: [DataGridColumn], in rows: TableRows) -> String?
    func updateStatements(for rowIDs: [RowID], columns: [DataGridColumn], in rows: TableRows) -> String?
    func inClause(values: [PluginCellValue], column: DataGridColumn) -> String?
}

@MainActor
protocol DataGridStateStore: AnyObject {
    var sortState: SortState { get set }
    var valueFilter: GridValueFilterState { get set }
    var columnLayout: ColumnLayoutState { get set }
    var displayFormats: [ValueDisplayFormat?] { get set }
    var selectionSnapshot: GridSelectionSnapshot { get set }
    var viewportAnchor: GridViewportPlacement? { get set }
    var layoutScope: DataGridLayoutScope { get }
}

@MainActor
final class InMemoryDataGridStateStore: DataGridStateStore {
    var sortState = SortState()
    var valueFilter = GridValueFilterState()
    var columnLayout = ColumnLayoutState()
    var displayFormats: [ValueDisplayFormat?] = []
    var selectionSnapshot = GridSelectionSnapshot.empty
    var viewportAnchor: GridViewportPlacement?
    let layoutScope: DataGridLayoutScope = .ephemeral

    init(columnLayout: ColumnLayoutState = ColumnLayoutState(), sortState: SortState = SortState()) {
        self.columnLayout = columnLayout
        self.sortState = sortState
    }
}
