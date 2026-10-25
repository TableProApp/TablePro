//
//  DataGridCommandTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

// The grid's owner as the commands see it: it records every request and writes each commit into its rows
// and change manager, the way the data tab does, then reports the change back.
@MainActor
final class CommandGridOwner: DataGridDataSource, DataGridActions {
    var tableRows: TableRows
    let changeManager: DataChangeManager
    let changeState: AnyChangeManager
    weak var model: DataGridModel?

    var exporter: RecordingSQLExporter?
    var copiesRowsItself = false
    var runsSetCellsToValue = false
    var pastesRows = false
    // The values a load fills in; nil refuses the load.
    var loadableValues: [RowID: [Int: PluginCellValue]]?
    // Holds each load until finishLoads(), the way a page fetch answers later.
    var defersLoads = false
    private var pendingLoads: [@MainActor () -> Void] = []
    // Titles rather than items: a menu item belongs to one menu, and every menu asks again.
    var rowMenuTitles: [String] = []
    var cellMenuTitles: [String] = []

    private(set) var commits: [(edits: [DataGridResolvedEdit], actionName: String)] = []
    private(set) var rowCopies: [[RowID]] = []
    private(set) var deletions: [[RowID]] = []
    private(set) var undoneDeletions: [[RowID]] = []
    private(set) var duplications: [[RowID]] = []
    private(set) var rowPastes = 0
    private(set) var addRowRequests = 0
    private(set) var setCellsToValueRequests: [[(rowID: RowID, column: String)]] = []
    private(set) var loadRequests: [[RowID]] = []
    private(set) var navigations: [(value: String, table: String, intent: ReferenceOpenIntent)] = []
    private(set) var hiddenColumns: [String] = []
    private(set) var showAllColumnsRequests = 0
    private(set) var rowsShownAsJSON: [[RowID]] = []
    private(set) var displayOrderRequests = 0

    init(_ tableRows: TableRows, changeManager: DataChangeManager = DataChangeManager()) {
        self.tableRows = tableRows
        self.changeManager = changeManager
        changeState = AnyChangeManager(changeManager)
    }

    var gridRows: TableRows { tableRows }
    var gridChangeState: AnyChangeManager { changeState }

    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool {
        commits.append((edits, actionName))
        var changed: Set<CellPosition> = []
        for edit in edits {
            guard let index = tableRows.index(of: edit.rowID) else { continue }
            _ = tableRows.edit(row: index, column: edit.dataIndex, value: edit.newValue, isAbsent: edit.absence.isAbsent)
            changeState.recordCellChange(
                rowID: edit.rowID,
                columnIndex: edit.dataIndex,
                columnName: edit.columnName,
                oldValue: edit.oldValue,
                newValue: edit.newValue,
                originalRow: edit.originalRow,
                absence: edit.absence,
                isExpression: edit.isExpression
            )
            changed.insert(CellPosition(row: index, column: edit.dataIndex))
        }
        model?.apply(.cellsChanged(changed))
        return true
    }

    func gridDeleteRows(_ rowIDs: [RowID]) {
        deletions.append(rowIDs)
    }

    func gridCopyRows(_ rowIDs: [RowID]) -> Bool {
        guard copiesRowsItself else { return false }
        rowCopies.append(rowIDs)
        return true
    }

    func gridSetCellsToValue(_ cells: [(rowID: RowID, column: DataGridColumn)]) -> Bool {
        guard runsSetCellsToValue else { return false }
        setCellsToValueRequests.append(cells.map { (rowID: $0.rowID, column: $0.column.name) })
        return true
    }

    func gridUndoDelete(_ rowIDs: [RowID]) {
        undoneDeletions.append(rowIDs)
    }

    func gridAddRow() {
        addRowRequests += 1
    }

    func gridDuplicateRows(_ rowIDs: [RowID]) {
        duplications.append(rowIDs)
    }

    func gridCanPasteRows() -> Bool {
        pastesRows
    }

    func gridPasteRows() {
        rowPastes += 1
    }

    func gridConfirmDisplayOrderChange(then apply: @escaping @MainActor () -> Void) {
        displayOrderRequests += 1
        apply()
    }

    func gridHideColumn(_ column: DataGridColumn) {
        hiddenColumns.append(column.name)
    }

    func gridShowAllColumns() {
        showAllColumnsRequests += 1
    }

    func gridNavigateForeignKey(value: String, info: ForeignKeyInfo, intent: ReferenceOpenIntent) {
        navigations.append((value, info.referencedTable, intent))
    }

    func gridShowRowsAsJSON(_ rowIDs: [RowID]) {
        rowsShownAsJSON.append(rowIDs)
    }

    func gridLoadUnloadedValues(rowIDs: [RowID], columns: IndexSet?, completion: @escaping @MainActor (Bool) -> Void) {
        loadRequests.append(rowIDs)
        let load = { @MainActor [self] in
            guard let loadableValues else {
                completion(false)
                return
            }
            let delta = tableRows.fillUnloaded(loadableValues)
            model?.apply(delta)
            completion(true)
        }
        guard defersLoads else {
            load()
            return
        }
        pendingLoads.append(load)
    }

    func finishLoads() {
        let loads = pendingLoads
        pendingLoads.removeAll()
        loads.forEach { $0() }
    }

    var gridSQLExporter: (any DataGridSQLExporting)? { exporter }

    func gridRowMenuItems(for rowIDs: [RowID], clickedRow: RowID) -> [NSMenuItem] {
        rowMenuTitles.map { NSMenuItem(title: $0, action: nil, keyEquivalent: "") }
    }

    func gridCellMenuItems(for rowID: RowID, column: DataGridColumn) -> [NSMenuItem] {
        cellMenuTitles.map { NSMenuItem(title: $0, action: nil, keyEquivalent: "") }
    }

    // The value the last commit wrote into a cell, and whether it was staged as SQL.
    func staged(_ row: Int, _ column: Int) -> (value: PluginCellValue, isExpression: Bool)? {
        for commit in commits.reversed() {
            if let edit = commit.edits.last(where: { $0.rowID == .existing(row) && $0.dataIndex == column }) {
                return (edit.newValue, edit.isExpression)
            }
        }
        return nil
    }

    var editCount: Int { commits.reduce(0) { $0 + $1.edits.count } }
}

// Hands back what it was given, so a test sees which rows and columns the grid asked statements for.
@MainActor
final class RecordingSQLExporter: DataGridSQLExporting {
    var allowsInsert = true
    var allowsUpdate = true
    private(set) var requests: [(update: Bool, rowIDs: [RowID], columns: [String])] = []

    func canCopyAsInsert(_ rows: TableRows) -> Bool { allowsInsert }
    func canCopyAsUpdate(_ rows: TableRows) -> Bool { allowsUpdate }

    func insertStatements(for rowIDs: [RowID], columns: [DataGridColumn], in rows: TableRows) -> String? {
        requests.append((false, rowIDs, columns.map { $0.name }))
        return "INSERT \(rowIDs.count)"
    }

    func updateStatements(for rowIDs: [RowID], columns: [DataGridColumn], in rows: TableRows) -> String? {
        requests.append((true, rowIDs, columns.map { $0.name }))
        return "UPDATE \(rowIDs.count)"
    }

    func inClause(values: [PluginCellValue], column: DataGridColumn) -> String? {
        "IN " + values.compactMap { $0.asText }.joined(separator: ",")
    }
}

// A model, its owner and a controller that has not been put in a window; host() mounts it when a test needs one.
@MainActor
final class CommandGrid {
    let owner: CommandGridOwner
    let model: DataGridModel
    let controller: DataGridViewController
    private(set) var window: NSWindow?

    init(
        _ rows: TableRows,
        configuration: DataGridConfiguration = CommandGrid.editable(),
        changeManager: DataChangeManager = DataChangeManager(),
        selectionSummary: SelectionSummaryState? = nil
    ) {
        owner = CommandGridOwner(rows, changeManager: changeManager)
        model = DataGridModel(configuration: configuration, selectionSummary: selectionSummary)
        model.dataSource = owner
        model.actions = owner
        owner.model = model
        model.reloadRows()
        controller = DataGridViewController(model: model)
    }

    static func editable(
        databaseType: DatabaseType? = .postgresql,
        commands: Set<DataGridCommand> = [.deleteRows, .duplicateRows, .undoDelete, .pasteRows, .loadUnloadedValues],
        appliesRowCopyFormat: Bool = true
    ) -> DataGridConfiguration {
        var configuration = DataGridConfiguration()
        configuration.isEditable = true
        configuration.appliesRowCopyFormat = appliesRowCopyFormat
        configuration.commands = commands
        configuration.traits = DataGridEngineTraits(databaseType: databaseType, cellWriterSupport: .host)
        return configuration
    }

    static func readOnly(appliesRowCopyFormat: Bool = true) -> DataGridConfiguration {
        var configuration = DataGridConfiguration()
        configuration.appliesRowCopyFormat = appliesRowCopyFormat
        return configuration
    }

    var commands: DataGridCommands { controller.gridCommands }

    func host(size: NSSize = NSSize(width: 900, height: 400)) {
        guard window == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        controller.view.frame = content.bounds
        controller.view.autoresizingMask = [.width, .height]
        content.addSubview(controller.view)
        content.layoutSubtreeIfNeeded()
        controller.container.layoutSubtreeIfNeeded()
        self.window = window
    }

    func close() {
        guard let window else { return }
        controller.dismantle()
        window.orderOut(nil)
        self.window = nil
    }

    func select(
        rows: ClosedRange<Int>,
        columns: ClosedRange<Int>,
        active: GridCoord? = nil,
        mode: GridSelection.Mode = .cells
    ) {
        let anchor = GridCoord(row: rows.lowerBound, displayColumn: columns.lowerBound)
        model.setSelection(GridSelection(
            rectangles: [GridRect(rows: rows, columns: columns)],
            activeCell: active ?? GridCoord(row: rows.upperBound, displayColumn: columns.upperBound),
            anchor: anchor,
            mode: mode
        ))
    }

    func selectCell(_ row: Int, _ column: Int) {
        model.setSelection(GridSelectionReducer.single(GridCoord(row: row, displayColumn: column)))
    }

    // What a row-number click leaves: whole rows picked, the cursor kept on a column.
    func selectRows(_ rows: ClosedRange<Int>, activeColumn: Int = 0) {
        select(
            rows: rows,
            columns: 0...(model.columns.count - 1),
            active: GridCoord(row: rows.upperBound, displayColumn: activeColumn),
            mode: .rows
        )
    }

    // The scope a right-click builds, carried by the item the way the menu carries it.
    func contextItem(row: Int, displayColumn: Int?, action: Selector? = nil) -> NSMenuItem {
        let scope = DataGridCommandScope.contextMenu(
            selection: model.selection,
            row: row,
            displayColumn: displayColumn,
            columnCount: model.columns.count
        )
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.representedObject = DataGridMenuContext(scope, model: model)
        return item
    }

    func rowMenu(row: Int, displayColumn: Int?) -> NSMenu? {
        controller.rowMenu(forRow: row, displayColumn: displayColumn, in: .main)
    }

    func headerMenu(_ name: String) -> NSMenu? {
        guard let column = model.columns.columns.first(where: { $0.name == name }) else { return nil }
        return controller.headerMenu(for: column)
    }

    func isEnabled(_ action: Selector, sender: NSMenuItem? = nil) -> Bool {
        let item = sender ?? NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.action = action
        return controller.validateMenuItem(item)
    }

    func perform(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        _ = NSApp.sendAction(action, to: item.target ?? controller, from: item)
    }
}

@MainActor
enum CommandRows {
    static let people = TableRows.from(
        queryRows: [[.text("1"), .text("Alice")], [.text("2"), .text("Bob")], [.text("3"), .text("Carol")]],
        columns: ["id", "name"],
        columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
    )

    static func titles(_ menu: NSMenu?) -> [String] {
        menu?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
    }

    static func item(_ title: String, in menu: NSMenu?) -> NSMenuItem? {
        menu?.items.first { $0.title == title }
    }
}

// MARK: - Row menu

@MainActor
struct DataGridRowMenuTests {
    @Test("A right-click outside the selection acts on the clicked cell and leaves the selection where it was")
    func clickOutsideTheSelectionTargetsTheClickedCell() {
        let grid = CommandGrid(CommandRows.people)
        grid.select(rows: 0...1, columns: 0...0)
        let before = grid.model.selection

        let outside = DataGridCommandScope.contextMenu(selection: before, row: 2, displayColumn: 1, columnCount: 2)
        let inside = DataGridCommandScope.contextMenu(selection: before, row: 1, displayColumn: 0, columnCount: 2)

        let clicked = grid.commands.cells(outside)
        #expect(clicked.map { $0.rowID } == [.existing(2)])
        #expect(clicked.map { $0.column.name } == ["name"])
        #expect(grid.commands.rowIDs(inside) == [.existing(0), .existing(1)])
        _ = grid.rowMenu(row: 2, displayColumn: 1)
        #expect(grid.model.selection == before)
    }

    @Test("A deleted row's menu offers only Undo Delete, which hands the row back to its owner")
    func deletedRowOffersUndoDelete() throws {
        let manager = DataChangeManager()
        let grid = CommandGrid(CommandRows.people, changeManager: manager)
        manager.recordRowDeletion(rowID: .existing(1), originalRow: [.text("2"), .text("Bob")])

        let menu = grid.rowMenu(row: 1, displayColumn: 1)

        #expect(CommandRows.titles(menu) == [String(localized: "Undo Delete")])
        grid.perform(try #require(menu?.items.first))
        #expect(grid.owner.undoneDeletions == [[.existing(1)]])
    }

    @Test("Commands the grid does not offer are left out of the menu")
    func unofferedCommandsAreHidden() {
        let grid = CommandGrid(CommandRows.people, configuration: CommandGrid.readOnly())
        let titles = CommandRows.titles(grid.rowMenu(row: 0, displayColumn: 1))

        #expect(titles.contains(String(localized: "Copy")))
        #expect(!titles.contains(String(localized: "Paste")))
        #expect(!titles.contains(String(localized: "Delete")))
        #expect(!titles.contains(String(localized: "Duplicate")))
        #expect(!titles.contains(String(localized: "Export Results…")))
        #expect(!titles.contains(String(localized: "Set Value")))
    }

    @Test("The row numbers get the row items only")
    func rowNumberMenuHasRowItems() {
        var configuration = CommandGrid.editable()
        configuration.commands.formUnion([.exportResults, .showRowsAsJSON])
        let grid = CommandGrid(CommandRows.people, configuration: configuration)
        let titles = CommandRows.titles(grid.rowMenu(row: 0, displayColumn: nil))

        #expect(titles.contains(String(localized: "Copy")))
        #expect(titles.contains(String(localized: "Copy as")))
        #expect(titles.contains(String(localized: "Show Row as JSON")))
        #expect(titles.contains(String(localized: "Delete")))
        #expect(!titles.contains(String(localized: "Copy Cell Value")))
        #expect(!titles.contains(String(localized: "Set Value")))
    }

    @Test("Owner items join the menu, row items for the rows and cell items for the clicked cell")
    func ownerItemsJoinTheMenu() {
        let grid = CommandGrid(CommandRows.people)
        grid.owner.rowMenuTitles = ["Insert Document…"]
        grid.owner.cellMenuTitles = ["Filter by Value"]

        let cellTitles = CommandRows.titles(grid.rowMenu(row: 0, displayColumn: 1))
        let rowTitles = CommandRows.titles(grid.rowMenu(row: 0, displayColumn: nil))

        #expect(cellTitles.contains("Insert Document…"))
        #expect(cellTitles.contains("Filter by Value"))
        #expect(rowTitles.contains("Insert Document…"))
        #expect(!rowTitles.contains("Filter by Value"))
    }

    @Test("Delete and Duplicate from the menu take every row the selection touches")
    func rowCommandsTakeTheSelectedRows() throws {
        let grid = CommandGrid(CommandRows.people)
        grid.select(rows: 0...1, columns: 0...1)
        let menu = grid.rowMenu(row: 1, displayColumn: 0)

        grid.perform(try #require(CommandRows.item(String(localized: "Delete"), in: menu)))
        grid.perform(try #require(CommandRows.item(String(localized: "Duplicate"), in: menu)))

        #expect(grid.owner.deletions == [[.existing(0), .existing(1)]])
        #expect(grid.owner.duplications == [[.existing(0), .existing(1)]])
    }

    @Test("Delete and Forward Delete mark the rows a range touches; a grid that deletes nothing asks nothing")
    func deleteKeyDeletesTheRangeRows() {
        let grid = CommandGrid(CommandRows.people)
        grid.select(rows: 1...2, columns: 1...1)

        grid.controller.performDeleteCommand()

        #expect(grid.owner.deletions == [[.existing(1), .existing(2)]])

        let readOnly = CommandGrid(CommandRows.people, configuration: CommandGrid.readOnly())
        readOnly.select(rows: 0...0, columns: 0...1)
        readOnly.controller.performDeleteCommand()
        #expect(readOnly.owner.deletions.isEmpty)
        #expect(!readOnly.isEnabled(#selector(DataGridViewController.delete(_:))))
    }

    @Test("Show Row as JSON hands the owner the rows the menu acts on")
    func showRowAsJSONHandsTheRows() throws {
        var configuration = CommandGrid.editable()
        configuration.commands.insert(.showRowsAsJSON)
        let grid = CommandGrid(CommandRows.people, configuration: configuration)

        let menu = grid.rowMenu(row: 2, displayColumn: 1)
        grid.perform(try #require(CommandRows.item(String(localized: "Show Row as JSON"), in: menu)))

        #expect(grid.owner.rowsShownAsJSON == [[.existing(2)]])
    }

    @Test("A double-click below the last row adds one only where the grid offers it")
    func doubleClickBelowRowsAddsARow() {
        var configuration = CommandGrid.editable()
        configuration.commands.insert(.addRow)
        let grid = CommandGrid(CommandRows.people, configuration: configuration)
        grid.controller.handleDoubleClickBelowRows()
        #expect(grid.owner.addRowRequests == 1)

        let without = CommandGrid(CommandRows.people)
        without.controller.handleDoubleClickBelowRows()
        #expect(without.owner.addRowRequests == 0)
    }

    // MARK: - Foreign keys

    private static let orders = TableRows.from(
        queryRows: [[.text("10"), .text("7")], [.text("11"), .null]],
        columns: ["id", "customer_id"],
        columnTypes: [.integer(rawType: "INT"), .integer(rawType: "INT")],
        columnForeignKeys: [
            "customer_id": ForeignKeyInfo(name: "fk", column: "customer_id", referencedTable: "customers", referencedColumn: "id")
        ]
    )

    @Test("A key with a value offers to choose, preview and follow its row; following hands the value to the owner")
    func foreignKeyItems() throws {
        var configuration = CommandGrid.editable()
        configuration.commands.insert(.navigateForeignKey)
        let grid = CommandGrid(Self.orders, configuration: configuration)

        let menu = grid.rowMenu(row: 0, displayColumn: 1)
        let titles = CommandRows.titles(menu)
        #expect(titles.contains(String(format: String(localized: "Choose %@ Row…"), "customers")))
        #expect(titles.contains(String(localized: "Preview Referenced Row")))

        grid.perform(try #require(CommandRows.item(String(format: String(localized: "Open %@"), "customers"), in: menu)))
        grid.perform(try #require(CommandRows.item(String(format: String(localized: "Open %@ in New Tab"), "customers"), in: menu)))

        let navigations = grid.owner.navigations
        #expect(navigations.map { $0.value } == ["7", "7"])
        #expect(navigations.map { $0.intent } == [.follow, .newTab])
    }

    @Test("An empty key offers only Choose, and a read-only grid nothing to follow without the command")
    func emptyForeignKeyOffersChooseOnly() {
        let grid = CommandGrid(Self.orders)
        let titles = CommandRows.titles(grid.rowMenu(row: 1, displayColumn: 1))

        #expect(titles.contains(String(format: String(localized: "Choose %@ Row…"), "customers")))
        #expect(!titles.contains(String(localized: "Preview Referenced Row")))

        let readOnly = CommandGrid(Self.orders, configuration: CommandGrid.readOnly())
        let readOnlyTitles = CommandRows.titles(readOnly.rowMenu(row: 0, displayColumn: 1))
        #expect(!readOnlyTitles.contains(String(format: String(localized: "Choose %@ Row…"), "customers")))
        #expect(!readOnlyTitles.contains(String(format: String(localized: "Open %@"), "customers")))
    }
}

// MARK: - Menu bar commands

@MainActor
struct DataGridResponderCommandTests {
    @Test("Copy Rows and Delete take every row of a range selection")
    func rowCommandsCoverTheRange() {
        let grid = CommandGrid(CommandRows.people)
        grid.owner.copiesRowsItself = true
        grid.select(rows: 0...1, columns: 1...1)

        grid.controller.copySelectedRows(nil)
        grid.controller.delete(nil)

        #expect(grid.owner.rowCopies == [[.existing(0), .existing(1)]])
        #expect(grid.owner.deletions == [[.existing(0), .existing(1)]])
    }

    @Test("Copy Rows is enabled over a range and dimmed with nothing selected")
    func copyRowsValidation() {
        let grid = CommandGrid(CommandRows.people)
        #expect(!grid.isEnabled(#selector(GridRowCopyCommandResponding.copySelectedRows(_:))))
        #expect(!grid.isEnabled(#selector(DataGridViewController.copy(_:))))

        grid.select(rows: 0...1, columns: 1...1)

        #expect(grid.isEnabled(#selector(GridRowCopyCommandResponding.copySelectedRows(_:))))
        #expect(grid.isEnabled(#selector(DataGridViewController.copy(_:))))
    }

    @Test("A grid of definitions dims the row formats and keeps Copy Rows for its owner")
    func definitionsGridDimsTheFormats() {
        let grid = CommandGrid(CommandRows.people, configuration: CommandGrid.editable(appliesRowCopyFormat: false))
        grid.selectRows(0...1)

        #expect(grid.isEnabled(#selector(GridRowCopyCommandResponding.copySelectedRows(_:))))
        #expect(!grid.isEnabled(#selector(GridRowCopyCommandResponding.copyRowsWithHeaders(_:))))
        #expect(!grid.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsCsv(_:))))
        #expect(!grid.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsMarkdown(_:))))
        #expect(!grid.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsInsertStatements(_:))))
    }

    @Test("Statements are offered only where the owner can write them")
    func statementsNeedTheExporter() {
        let grid = CommandGrid(CommandRows.people)
        grid.selectRows(0...1)
        #expect(!grid.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsInsertStatements(_:))))

        var configuration = CommandGrid.editable()
        configuration.commands.insert(.copyAsSQL)
        let table = CommandGrid(CommandRows.people, configuration: configuration)
        let exporter = RecordingSQLExporter()
        table.owner.exporter = exporter
        table.selectRows(0...1)
        #expect(table.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsInsertStatements(_:))))
        #expect(table.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsUpdateStatements(_:))))

        exporter.allowsUpdate = false
        #expect(!table.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsUpdateStatements(_:))))
        exporter.allowsInsert = false
        #expect(!table.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsInsertStatements(_:))))
    }

    @Test("Copy Cell Value needs a cell to read")
    func copyCellValueNeedsACell() {
        let grid = CommandGrid(CommandRows.people)
        #expect(!grid.isEnabled(#selector(GridCopyCommandResponding.copyCellValue(_:))))

        grid.selectRows(0...1, activeColumn: 1)
        #expect(grid.isEnabled(#selector(GridCopyCommandResponding.copyCellValue(_:))))
        #expect(!grid.isEnabled(
            #selector(GridCopyCommandResponding.copyCellValue(_:)),
            sender: grid.contextItem(row: 0, displayColumn: nil)
        ))
    }

    @Test("Select All selects every row and leaves no cell cursor; an empty grid has nothing to select")
    func selectAll() {
        let grid = CommandGrid(CommandRows.people)
        grid.selectCell(1, 1)

        grid.controller.performSelectAll(nil)

        let selection = grid.model.selection
        #expect(selection.affectedRows == IndexSet(integersIn: 0...2))
        #expect(selection.affectedColumns == IndexSet(integersIn: 0...1))
        #expect(selection.picksRows)
        #expect(selection.activeCell == nil)
        #expect(selection.columns.isEmpty)
        #expect(grid.isEnabled(#selector(NSTableView.selectAll(_:))))

        let empty = CommandGrid(TableRows.from(queryRows: [], columns: ["id"], columnTypes: [.integer(rawType: "INT")]))
        empty.controller.performSelectAll(nil)
        #expect(empty.model.selection.isEmpty)
        #expect(!empty.isEnabled(#selector(NSTableView.selectAll(_:))))
    }

    @Test("A row dragged out carries tab-separated text and an HTML table, and the reorder type only where rows reorder")
    func rowDragPasteboard() throws {
        let grid = CommandGrid(CommandRows.people)
        let item = try #require(grid.controller.rowDragPasteboardItem(forRow: 1))

        #expect(item.string(forType: .string) == "2\tBob")
        #expect(item.string(forType: .html)?.contains("Bob") == true)
        #expect(item.string(forType: DataGridViewController.rowDragType) == nil)
    }

    @Test("A focused grid answers Find itself; Find Next waits for a term")
    func findOpensTheGridsOwnBar() {
        let grid = CommandGrid(CommandRows.people)
        #expect(grid.isEnabled(#selector(DataGridViewController.performFind(_:))))
        #expect(!grid.isEnabled(#selector(DataGridViewController.findNext(_:))))
        #expect(!grid.isEnabled(#selector(DataGridViewController.useSelectionForFind(_:))))

        grid.controller.performFind(nil)
        #expect(grid.model.find.isVisible)
        #expect(!grid.isEnabled(#selector(DataGridViewController.findNext(_:))))

        grid.selectCell(1, 1)
        grid.controller.useSelectionForFind(nil)
        #expect(grid.model.find.term == "Bob")
        #expect(grid.isEnabled(#selector(DataGridViewController.findNext(_:))))
        #expect(grid.isEnabled(#selector(DataGridViewController.findPrevious(_:))))
    }

    @Test("Rows lift from the number of a selected row only")
    func dragStartsOnSelectedRows() {
        let grid = CommandGrid(CommandRows.people)
        grid.selectRows(0...1)

        #expect(grid.controller.canDragRows(fromRowNumberAt: 1))
        #expect(!grid.controller.canDragRows(fromRowNumberAt: 2))

        grid.selectCell(1, 1)
        #expect(!grid.controller.canDragRows(fromRowNumberAt: 1))
    }
}

// MARK: - Header menu

@MainActor
struct DataGridHeaderMenuTests {
    @Test("Select Column comes just before Copy Column Name and selects every row of that column")
    func selectColumn() throws {
        let grid = CommandGrid(CommandRows.people)
        grid.host()
        defer { grid.close() }
        let menu = grid.headerMenu("name")
        let titles = CommandRows.titles(menu)
        let select = try #require(titles.firstIndex(of: String(localized: "Select Column")))
        #expect(titles[select + 1] == String(localized: "Copy Column Name"))

        grid.perform(try #require(menu?.items[select]))

        #expect(grid.model.selection.columns == IndexSet(integer: 1))
        #expect(grid.model.selection.affectedRows == IndexSet(integersIn: 0...2))
    }

    @Test("Sort items replace the sort as the user's own, and Don't Sort shows only while a sort applies")
    func sortItems() throws {
        let grid = CommandGrid(CommandRows.people)
        #expect(!CommandRows.titles(grid.headerMenu("name")).contains(String(localized: "Don't Sort")))

        grid.perform(try #require(CommandRows.item(String(localized: "Sort Descending"), in: grid.headerMenu("name"))))

        let sort = grid.model.store.sortState
        #expect(sort.columns.map { $0.columnIndex } == [1])
        #expect(sort.columns.first?.direction == .descending)
        #expect(sort.source == .user)

        grid.perform(try #require(CommandRows.item(String(localized: "Don't Sort"), in: grid.headerMenu("name"))))
        #expect(grid.model.store.sortState == SortState(columns: [], source: .user))
    }

    @Test("A grid that cannot sort offers no sort items")
    func noSortItemsWithoutSort() {
        var configuration = CommandGrid.editable()
        configuration.supportsColumnSort = false
        let grid = CommandGrid(CommandRows.people, configuration: configuration)

        #expect(!CommandRows.titles(grid.headerMenu("name")).contains(String(localized: "Sort Ascending")))
    }

    @Test("Display As checks the current format and sets the chosen one, confirming first under a value filter")
    func displayAs() throws {
        var configuration = CommandGrid.editable()
        configuration.commands.formUnion([.displayAs, .valueFilter])
        let rows = TableRows.from(
            queryRows: [[.bytes(Data(repeating: 0xAB, count: 16))]],
            columns: ["payload"],
            columnTypes: [.blob(rawType: "BYTEA")]
        )
        let grid = CommandGrid(rows, configuration: configuration)
        let displayAs = try #require(CommandRows.item(String(localized: "Display As"), in: grid.headerMenu("payload"))?.submenu)
        #expect(displayAs.items.first { $0.state == .on }?.title == ValueDisplayFormat.raw.displayName)

        let uuid = try #require(displayAs.items.first { $0.title == ValueDisplayFormat.uuid.displayName })
        grid.perform(uuid)
        #expect(grid.model.store.displayFormats.first == .uuid)
        #expect(grid.owner.displayOrderRequests == 0)

        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: ["x"], includesNull: true), columnName: "payload", forColumn: 0)
        grid.model.setValueFilter(filter)
        let requests = grid.owner.displayOrderRequests
        let menu = try #require(CommandRows.item(String(localized: "Display As"), in: grid.headerMenu("payload"))?.submenu)
        grid.perform(try #require(menu.items.first { $0.title == ValueDisplayFormat.raw.displayName }))
        #expect(grid.owner.displayOrderRequests == requests + 1)
        #expect(grid.model.store.displayFormats.first == .raw)
    }

    @Test("Hide Column hands the column to the owner; Show All Columns appears once a column is hidden")
    func hideAndShowColumns() throws {
        var configuration = CommandGrid.editable()
        configuration.commands.insert(.hideColumns)
        let grid = CommandGrid(CommandRows.people, configuration: configuration)
        #expect(!CommandRows.titles(grid.headerMenu("id")).contains(String(localized: "Show All Columns")))

        grid.perform(try #require(CommandRows.item(String(localized: "Hide Column"), in: grid.headerMenu("id"))))
        #expect(grid.owner.hiddenColumns == ["id"])

        grid.model.updateColumnLayout { $0.hiddenColumns = ["id"] }
        grid.perform(try #require(CommandRows.item(String(localized: "Show All Columns"), in: grid.headerMenu("name"))))
        #expect(grid.owner.showAllColumnsRequests == 1)
    }

    @Test("Value filter items follow the command, and Clear Value Filter clears that column")
    func valueFilterItems() throws {
        let plain = CommandGrid(CommandRows.people)
        #expect(!CommandRows.titles(plain.headerMenu("name")).contains(String(localized: "Filter Values…")))

        var configuration = CommandGrid.editable()
        configuration.commands.insert(.valueFilter)
        let grid = CommandGrid(CommandRows.people, configuration: configuration)
        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: ["Bob"], includesNull: false), columnName: "name", forColumn: 1)
        grid.model.setValueFilter(filter)
        let titles = CommandRows.titles(grid.headerMenu("name"))
        #expect(titles.contains(String(localized: "Filter Values…")))
        #expect(titles.contains(String(localized: "Clear All Value Filters")))

        grid.perform(try #require(CommandRows.item(String(localized: "Clear Value Filter"), in: grid.headerMenu("name"))))

        #expect(!grid.model.store.valueFilter.isActive)
        #expect(grid.model.rowCount == 3)
    }

    @Test("Filter Values lists each shown value once with its count, NULL first")
    func distinctValues() {
        let rows = TableRows.from(
            queryRows: [[.text("b")], [.text("a")], [.null], [.text("b")]],
            columns: ["status"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let grid = CommandGrid(rows)
        let column = grid.model.columns.columns[0]

        let values = grid.commands.distinctValues(for: column)

        #expect(values == [
            ColumnDistinctValue(display: "", isNull: true, count: 1),
            ColumnDistinctValue(display: "a", isNull: false, count: 1),
            ColumnDistinctValue(display: "b", isNull: false, count: 2),
        ])
    }

    @Test("Fill Column is offered on a writable column that is not a key")
    func fillColumnOffer() {
        var configuration = CommandGrid.editable()
        configuration.primaryKeyColumns = ["id"]
        let grid = CommandGrid(CommandRows.people, configuration: configuration)

        #expect(!CommandRows.titles(grid.headerMenu("id")).contains(String(localized: "Fill Column…")))
        #expect(CommandRows.titles(grid.headerMenu("name")).contains(String(localized: "Fill Column…")))

        let readOnly = CommandGrid(CommandRows.people, configuration: CommandGrid.readOnly())
        #expect(!CommandRows.titles(readOnly.headerMenu("name")).contains(String(localized: "Fill Column…")))
    }

    // A filter applied while the values load must not move the fill onto other records.
    @Test("A fill that waits for values writes the rows it was started on")
    func fillKeepsItsRowsAcrossALoad() throws {
        let grid = CommandGrid(TableRows.from(
            queryRows: [[.text("1"), .null], [.text("2"), .null], [.text("3"), .text("c")]],
            columns: ["id", "body"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)],
            unloadedCells: [0: [1: 2_000_000], 1: [1: 2_000_000]]
        ))
        grid.owner.loadableValues = [.existing(0): [1: .text("a")], .existing(1): [1: .text("b")]]
        grid.owner.defersLoads = true
        let body = try #require(grid.model.columns.column(at: 1))

        grid.commands.applyFillColumn(body, content: .value(.text("x")))
        try #require(grid.owner.commits.isEmpty)
        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: ["2", "3"], includesNull: false), columnName: "id", forColumn: 0)
        grid.model.setValueFilter(filter)
        grid.owner.finishLoads()

        #expect(grid.owner.staged(0, 1)?.value == .text("x"))
        #expect(grid.owner.staged(1, 1)?.value == .text("x"))
        #expect(grid.owner.staged(2, 1)?.value == .text("x"))
    }

    @Test("Freeze Up to This Column and Unfreeze Columns write the frozen count")
    func freezeColumns() throws {
        var configuration = CommandGrid.editable()
        configuration.commands.insert(.freezeColumns)
        let grid = CommandGrid(CommandRows.people, configuration: configuration)
        grid.host()
        defer { grid.close() }

        grid.perform(try #require(CommandRows.item(String(localized: "Freeze Up to This Column"), in: grid.headerMenu("id"))))
        #expect(grid.model.store.columnLayout.frozenColumnCount == 1)
        #expect(!CommandRows.titles(grid.headerMenu("id")).contains(String(localized: "Freeze Up to This Column")))

        grid.perform(try #require(CommandRows.item(String(localized: "Unfreeze Columns"), in: grid.headerMenu("id"))))
        #expect(grid.model.store.columnLayout.frozenColumnCount == 0)
    }

    @Test("Size All Columns to Fit records every column's width as the user's own")
    func sizeAllColumnsToFit() throws {
        let grid = CommandGrid(CommandRows.people)
        grid.host()
        defer { grid.close() }

        grid.perform(try #require(CommandRows.item(String(localized: "Size All Columns to Fit"), in: grid.headerMenu("id"))))

        let layout = grid.model.store.columnLayout
        #expect(Set(layout.columnWidths.keys) == ["id", "name"])
        #expect(Set(layout.columnContentWidths.map { Array($0.keys) } ?? []) == ["id", "name"])
    }
}

// MARK: - Selection summary

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct DataGridSelectionSummaryMenuTests {
        private static let numbers = TableRows.from(
            queryRows: [[.text("1"), .text("a")], [.text("2"), .text("b")], [.text("3"), .text("c")]],
            columns: ["n", "s"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
        )

        private func summarized(column: Int) async throws -> CommandGrid {
            let grid = CommandGrid(Self.numbers, selectionSummary: SelectionSummaryState())
            grid.host()
            try await waitUntil { grid.controller.selectionSummaryTracker.state != nil }
            grid.select(rows: 0...2, columns: column...column)
            try await waitUntil { grid.controller.selectionSummaryTracker.currentSummary != nil }
            return grid
        }

        @Test("The cell menu offers Copy Sum and Copy Average right after Copy as, as plain text")
        func cellMenuCopiesTheSummary() async throws {
            let grid = try await summarized(column: 0)
            defer { grid.close() }
            let menu = grid.rowMenu(row: 0, displayColumn: 0)
            let titles = CommandRows.titles(menu)
            let copyAs = try #require(titles.firstIndex(of: String(localized: "Copy as")))
            #expect(Array(titles.dropFirst(copyAs + 1).prefix(2)) == [
                String(localized: "Copy Sum"),
                String(localized: "Copy Average"),
            ])

            let clipboard = try #require(RecordingClipboard.current)
            grid.perform(try #require(menu?.items[copyAs + 1]))
            #expect(clipboard.text == "6")
            grid.perform(try #require(menu?.items[copyAs + 2]))
            #expect(clipboard.text == "2")
        }

        @Test("No summary copies for a selection holding no numbers, nor for a menu opened outside the selection")
        func noSummaryCopies() async throws {
            let text = try await summarized(column: 1)
            defer { text.close() }
            #expect(!CommandRows.titles(text.rowMenu(row: 0, displayColumn: 1)).contains(String(localized: "Copy Sum")))

            let numbers = try await summarized(column: 0)
            defer { numbers.close() }
            #expect(!CommandRows.titles(numbers.rowMenu(row: 0, displayColumn: 1)).contains(String(localized: "Copy Sum")))
        }
    }
}

// MARK: - Cell and range copy

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct DataGridCopyCommandTests {
        private static let uuidBytes = Data([
            0xAF, 0x49, 0x45, 0x3B, 0x7F, 0x2F, 0xFB, 0x58,
            0xFC, 0xD3, 0x2B, 0xD3, 0x99, 0x59, 0x9F, 0xA5,
        ])

        private func binaryGrid(_ rows: [[PluginCellValue]], types: [ColumnType], databaseType: DatabaseType? = nil) -> CommandGrid {
            let columns = (0..<types.count).map { "c\($0)" }
            return CommandGrid(
                TableRows.from(queryRows: rows, columns: columns, columnTypes: types),
                configuration: CommandGrid.editable(databaseType: databaseType)
            )
        }

        @Test("One cell copies its value, with its display format applied, and carries no row payload")
        func cellCopyAppliesTheDisplayFormat() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = binaryGrid([[.text("1"), .bytes(Self.uuidBytes)]], types: [.integer(rawType: "INT"), .blob(rawType: "BYTEA")])
            grid.model.setDisplayFormat(.uuid, for: grid.model.columns.columns[1])
            grid.selectCell(0, 1)

            grid.controller.copy(nil)

            #expect(clipboard.text == "af49453b-7f2f-fb58-fcd3-2bd399599fa5")
            #expect(clipboard.hasGridRows == false)
        }

        @Test("Copy does not guess MongoDB legacy UUID byte order")
        func copyKeepsUndecodedMongoUuidAsHex() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let javaLegacyBytes = Data([
                0x24, 0x43, 0x25, 0x4A, 0xEB, 0x03, 0xD0, 0x8C,
                0x1A, 0x0D, 0xDA, 0xE2, 0xFC, 0x88, 0x32, 0x93,
            ])
            let grid = binaryGrid([[.bytes(javaLegacyBytes)]], types: [.blob(rawType: "BLOB(3)")], databaseType: .mongodb)
            grid.model.setDisplayFormat(.uuid, for: grid.model.columns.columns[0])
            grid.selectCell(0, 0)

            grid.controller.copy(nil)

            #expect(clipboard.text == "0x2443254AEB03D08C1A0DDAE2FC883293")
        }

        @Test("Copy reads the record a display position shows under a value filter")
        func copyUsesTheDisplayedRows() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = CommandGrid(CommandRows.people)
            var filter = GridValueFilterState()
            filter.set(ColumnValueFilter(selectedValues: ["Bob", "Carol"], includesNull: false), columnName: "name", forColumn: 1)
            grid.model.setValueFilter(filter)
            grid.selectCell(0, 1)

            grid.controller.copy(nil)

            #expect(clipboard.text == "Bob")
        }

        @Test("A multi-cell range keeps raw bytes rather than a display format")
        func rangeCopyKeepsRawBytes() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let first = Data(repeating: 0xAA, count: 16)
            let second = Data(repeating: 0xBB, count: 16)
            let grid = binaryGrid(
                [[.bytes(first), .bytes(second), .text("x")]],
                types: [.blob(rawType: "BYTEA"), .blob(rawType: "BYTEA"), .text(rawType: "TEXT")]
            )
            grid.model.setDisplayFormat(.uuid, for: grid.model.columns.columns[0])
            grid.select(rows: 0...0, columns: 0...1)

            grid.controller.copy(nil)

            #expect(clipboard.text == "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\t0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
        }

        @Test("A range copies as typed fields, NULL kept, in display order")
        func rangeCopiesTypedFields() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = CommandGrid(TableRows.from(
                queryRows: [[.text("1"), .text("Alice"), .null], [.text("2"), .text("Bob"), .text("x")]],
                columns: ["id", "name", "note"],
                columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT"), .text(rawType: "TEXT")]
            ))
            grid.select(rows: 0...1, columns: 1...2)

            grid.controller.copy(nil)

            #expect(clipboard.text == "Alice\tNULL\nBob\tx")
            #expect(clipboard.gridCells?.fields == [["Alice", nil], ["Bob", "x"]])
        }

        @Test("The context menu's Copy outside a range copies the clicked cell, not the range (interaction 6)")
        func contextCopyOutsideTheRangeTakesTheClickedCell() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = CommandGrid(CommandRows.people)
            grid.select(rows: 0...1, columns: 0...0)

            grid.controller.copy(grid.contextItem(row: 0, displayColumn: 1))
            #expect(clipboard.text == "Alice")

            grid.controller.copy(grid.contextItem(row: 1, displayColumn: 0))
            #expect(clipboard.text == "1\n2")
        }

        @Test("Copy from the row numbers copies the row even with a cell selected", .appSettings { $0.dataGrid.rowCopyFormat = .rows })
        func rowNumberCopyCopiesTheRow() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = CommandGrid(CommandRows.people)
            grid.selectCell(0, 1)

            grid.controller.copy(grid.contextItem(row: 0, displayColumn: nil))

            #expect(clipboard.text == "1\tAlice")
            #expect(clipboard.gridRows?.rows.count == 1)
        }

        @Test("A value the page left on the server loads before it is copied")
        func unloadedValueLoadsFirst() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = CommandGrid(TableRows.from(
                queryRows: [[.text("1"), .null]],
                columns: ["id", "body"],
                columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")],
                unloadedCells: [0: [1: 2_000_000]]
            ))
            grid.owner.loadableValues = [.existing(0): [1: .text("the whole body")]]
            grid.selectCell(0, 1)

            grid.controller.copy(nil)

            #expect(grid.owner.loadRequests == [[.existing(0)]])
            #expect(clipboard.text == "the whole body")
        }

        @Test("A load the owner refuses copies nothing")
        func refusedLoadCopiesNothing() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = CommandGrid(TableRows.from(
                queryRows: [[.text("1"), .null]],
                columns: ["id", "body"],
                columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")],
                unloadedCells: [0: [1: 2_000_000]]
            ))
            grid.selectCell(0, 1)

            grid.controller.copy(nil)

            #expect(grid.owner.loadRequests.count == 1)
            #expect(clipboard.text == nil)
        }

        @Test("Copy Column Values copies every displayed value of the column, NULL spelled out")
        func copyColumnValues() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = CommandGrid(TableRows.from(
                queryRows: [[.text("a")], [.null], [.text("c")]],
                columns: ["v"],
                columnTypes: [.text(rawType: "TEXT")]
            ))

            grid.perform(try #require(CommandRows.item(String(localized: "Copy Column Values"), in: grid.headerMenu("v"))))

            #expect(clipboard.text == "a\nNULL\nc")
        }
    }
}
