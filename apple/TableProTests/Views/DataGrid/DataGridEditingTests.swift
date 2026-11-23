//
//  DataGridEditingTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTheme
import Testing

@MainActor
final class EditingGridOwner: DataGridDataSource, DataGridActions {
    var tableRows: TableRows
    let changeState = AnyChangeManager(DataChangeManager())
    weak var model: DataGridModel?
    private(set) var commits: [(edits: [DataGridResolvedEdit], actionName: String)] = []
    private(set) var loadRequests: [[RowID]] = []
    var loadsValue: ((inout TableRows) -> Void)?

    init(_ tableRows: TableRows) {
        self.tableRows = tableRows
    }

    var gridRows: TableRows { tableRows }
    var gridChangeState: AnyChangeManager { changeState }

    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool {
        commits.append((edits, actionName))
        var positions = Set<CellPosition>()
        for edit in edits {
            guard let index = tableRows.index(of: edit.rowID) else { continue }
            _ = tableRows.edit(row: index, column: edit.dataIndex, value: edit.newValue, isAbsent: edit.absence.isAbsent)
            positions.insert(CellPosition(row: index, column: edit.dataIndex))
        }
        model?.apply(.cellsChanged(positions))
        return true
    }

    func gridLoadUnloadedValues(rowIDs: [RowID], columns: IndexSet?, completion: @escaping @MainActor (Bool) -> Void) {
        loadRequests.append(rowIDs)
        guard let loadsValue else {
            completion(false)
            return
        }
        loadsValue(&tableRows)
        model?.reloadRows()
        completion(true)
    }

    var committedValues: [PluginCellValue] {
        commits.flatMap { $0.edits.map(\.newValue) }
    }
}

// A real controller in a window, with the edit cell mounted the way AppKit mounts it.
@MainActor
struct EditingGrid {
    let window: NSWindow
    let controller: DataGridViewController
    let model: DataGridModel
    let owner: EditingGridOwner

    static let people = TableRows.from(
        queryRows: [
            [.text("0"), .text("ann")],
            [.text("1"), .text("bob")],
            [.text("2"), .text("cid")],
        ],
        columns: ["id", "name"],
        columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
    )

    static var editable: DataGridConfiguration {
        var configuration = DataGridConfiguration()
        configuration.isEditable = true
        configuration.showRowNumbers = true
        return configuration
    }

    init(
        rows: TableRows = EditingGrid.people,
        configuration: DataGridConfiguration = EditingGrid.editable,
        store: any DataGridStateStore = InMemoryDataGridStateStore(),
        themeScope: ThemeScope = .live
    ) {
        let owner = EditingGridOwner(rows)
        let model = DataGridModel(store: store, configuration: configuration, themeScope: themeScope)
        model.dataSource = owner
        model.actions = owner
        owner.model = model
        model.reloadRows()
        let controller = DataGridViewController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 800, height: 400))
        controller.view.layoutSubtreeIfNeeded()
        self.owner = owner
        self.model = model
        self.controller = controller
        self.window = window
    }

    var cellView: DataGridEditingCellView { controller.editingState.editingCellView }

    var fieldEditor: NSTextView? {
        cellView.field.currentEditor() as? NSTextView
    }

    func type(_ text: String) {
        fieldEditor?.string = text
    }

    @discardableResult
    func send(_ selector: Selector) -> Bool {
        guard let fieldEditor else { return false }
        return controller.fieldEditor(fieldEditor, doCommandBy: selector)
    }

    func mountedEditCell(in pane: DataGridPane, row: Int, displayColumn: Int) -> DataGridEditingCellView? {
        guard let index = pane.tableIndex(forDisplayPosition: displayColumn, columns: model.columns),
              row < pane.tableView.numberOfRows else { return nil }
        return pane.tableView.view(atColumn: index, row: row, makeIfNecessary: false) as? DataGridEditingCellView
    }

    func select(_ row: Int, _ column: Int) {
        model.setSelection(GridSelectionReducer.single(GridCoord(row: row, displayColumn: column)))
    }

    func tearDown() {
        controller.discardCellEditing()
        controller.dismantle()
        window.orderOut(nil)
    }
}

@MainActor
struct DataGridEditingTests {
    // MARK: - Field lifecycle

    @Test("Beginning an edit mounts the field in that one cell and hands it the field editor")
    func beginMountsTheField() throws {
        let grid = EditingGrid()
        defer { grid.tearDown() }

        #expect(grid.controller.beginEditingCell(row: 1, displayColumn: 1))

        #expect(grid.controller.editedCell == GridCoord(row: 1, displayColumn: 1))
        #expect(grid.model.isEditing)
        #expect(grid.mountedEditCell(in: grid.controller.main, row: 1, displayColumn: 1) === grid.cellView)
        #expect(grid.mountedEditCell(in: grid.controller.main, row: 0, displayColumn: 1) == nil)
        #expect(grid.fieldEditor?.string == "bob")
    }

    @Test("Return commits once, by the record the edit opened on, and unmounts the field")
    func returnCommitsByRowID() throws {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 1, displayColumn: 1)
        grid.type("zed")

        #expect(grid.send(#selector(NSResponder.insertNewline(_:))))

        let edit = try #require(grid.owner.commits.first?.edits.first)
        #expect(grid.owner.commits.count == 1)
        #expect(grid.owner.commits.first?.actionName == "Edit Cell")
        #expect(edit.rowID == .existing(1))
        #expect(edit.dataIndex == 1)
        #expect(edit.newValue == .text("zed"))
        #expect(grid.controller.editedCell == nil)
        #expect(!grid.model.isEditing)
        #expect(grid.mountedEditCell(in: grid.controller.main, row: 1, displayColumn: 1) == nil)
    }

    @Test("Return on text the editor opened with commits nothing, even over a NULL that reads as empty")
    func unchangedTextCommitsNothing() {
        let rows = TableRows.from(
            queryRows: [[.text("0"), .null]],
            columns: ["id", "note"],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
        )
        let grid = EditingGrid(rows: rows)
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 0, displayColumn: 1)

        grid.send(#selector(NSResponder.insertNewline(_:)))

        #expect(grid.owner.commits.isEmpty)
    }

    @Test("Escape drops what was typed and ends the edit")
    func escapeDiscards() {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 0, displayColumn: 1)
        grid.type("zed")

        #expect(grid.send(#selector(NSResponder.cancelOperation(_:))))

        #expect(grid.owner.commits.isEmpty)
        #expect(!grid.model.isEditing)
        #expect(grid.controller.editedCell == nil)
    }

    @Test("The owner's commitEditing keeps the text and discardEditing drops it")
    func ownerCommitAndDiscard() {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 0, displayColumn: 1)
        grid.type("one")

        #expect(grid.model.commitEditing())
        #expect(grid.owner.committedValues == [.text("one")])

        grid.controller.beginEditingCell(row: 1, displayColumn: 1)
        grid.type("two")
        grid.model.discardEditing()

        #expect(grid.owner.committedValues == [.text("one")])
        #expect(!grid.model.isEditing)
    }

    @Test("An owner waiting for the edit hears once that it ended")
    func editingEndedIsReportedOnce() {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        var ended = 0
        grid.model.onEditingEnded = { ended += 1 }
        grid.controller.beginEditingCell(row: 0, displayColumn: 1)
        grid.type("zed")

        grid.send(#selector(NSResponder.insertNewline(_:)))

        #expect(ended == 1)
    }

    @Test("A locked column refuses the edit")
    func lockedColumnRefuses() {
        var configuration = EditingGrid.editable
        configuration.lockedColumns = ["name"]
        let grid = EditingGrid(configuration: configuration)
        defer { grid.tearDown() }

        #expect(!grid.controller.beginEditingCell(row: 0, displayColumn: 1))
        #expect(!grid.model.isEditing)
    }

    // MARK: - Moving between cells

    @Test("Tab commits and edits the next cell, wrapping onto the next row")
    func tabMovesAndWraps() {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.select(0, 1)
        grid.controller.beginEditingCell(row: 0, displayColumn: 1)
        grid.type("zed")

        grid.send(#selector(NSResponder.insertTab(_:)))

        #expect(grid.owner.committedValues == [.text("zed")])
        #expect(grid.model.selection.activeCell == GridCoord(row: 1, displayColumn: 0))
        #expect(grid.controller.editedCell == GridCoord(row: 1, displayColumn: 0))
        #expect(grid.fieldEditor?.string == "1")
    }

    @Test("Shift-Tab walks back onto the previous row's last column")
    func backtabWrapsBack() {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 1, displayColumn: 0)

        grid.send(#selector(NSResponder.insertBacktab(_:)))

        #expect(grid.controller.editedCell == GridCoord(row: 0, displayColumn: 1))
    }

    @Test("Tab at the last cell commits and stays there")
    func tabStopsAtTheLastCell() {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 2, displayColumn: 1)
        grid.type("zed")

        grid.send(#selector(NSResponder.insertTab(_:)))

        #expect(grid.owner.committedValues == [.text("zed")])
        #expect(grid.controller.editedCell == nil)
        #expect(grid.model.selection.activeCell == GridCoord(row: 2, displayColumn: 1))
    }

    @Test("Down commits and edits the same column a row below; it stops at the last row")
    func downHoldsTheColumn() {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 1, displayColumn: 1)

        grid.send(#selector(NSResponder.moveDown(_:)))
        #expect(grid.controller.editedCell == GridCoord(row: 2, displayColumn: 1))

        grid.send(#selector(NSResponder.moveDown(_:)))
        #expect(grid.controller.editedCell == nil)
        #expect(grid.model.selection.activeCell == GridCoord(row: 2, displayColumn: 1))
    }

    @Test("Up on the first row commits and does not wrap")
    func upStopsAtTheFirstRow() {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 0, displayColumn: 1)

        grid.send(#selector(NSResponder.moveUp(_:)))

        #expect(grid.controller.editedCell == nil)
    }

    // Reaching for a cell's accessibility element marks the grid active, which mounts a view per visible cell (#2381).
    @Test("Moving the editor leaves the accessibility layout alone")
    func movingLeavesAccessibilityAlone() {
        let wasActive = DataGridAccessibility.isActive
        DataGridAccessibility.isActive = false
        defer { DataGridAccessibility.isActive = wasActive }
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 0, displayColumn: 0)

        grid.send(#selector(NSResponder.insertTab(_:)))

        #expect(!DataGridAccessibility.isActive)
    }

    // MARK: - Identity across changes (H2)

    @Test("A reorder under an open editor moves it with its record, and the commit lands there")
    func editFollowsItsRecordAcrossAReorder() throws {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 1, displayColumn: 1)
        grid.type("zed")

        let reversed = ContiguousArray(grid.owner.tableRows.rows.reversed())
        grid.owner.tableRows.reorderRows(reversed)
        grid.model.reloadRows()

        #expect(grid.controller.editedCell == GridCoord(row: 1, displayColumn: 1))
        #expect(grid.fieldEditor?.string == "zed")
        let current = grid.owner.tableRows
        grid.owner.tableRows.reorderRows(ContiguousArray([2, 0, 1].compactMap { current.row(withID: .existing($0)) }))
        grid.model.reloadRows()
        #expect(grid.controller.editedCell == GridCoord(row: 2, displayColumn: 1))

        grid.send(#selector(NSResponder.insertNewline(_:)))
        let edit = try #require(grid.owner.commits.first?.edits.first)
        #expect(edit.rowID == .existing(1))
        #expect(grid.owner.tableRows.row(withID: .existing(1))?.values[1] == .text("zed"))
    }

    @Test("A new result that reuses the RowID for another record drops the edit instead of writing into it")
    func replacedRecordDropsTheEdit() {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 1, displayColumn: 1)
        grid.type("zed")

        grid.owner.tableRows = TableRows.from(
            queryRows: [[.text("7"), .text("gus")], [.text("8"), .text("hal")]],
            columns: ["id", "name"],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
        )
        grid.model.reloadRows()

        #expect(!grid.model.isEditing)
        #expect(grid.owner.commits.isEmpty)
    }

    @Test("A value filter that hides the edited row keeps what was typed")
    func filterHidingTheRowCommits() throws {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 1, displayColumn: 1)
        grid.type("zed")

        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: ["ann"], includesNull: false), columnName: "name", forColumn: 1)
        grid.model.setValueFilter(filter)

        let edit = try #require(grid.owner.commits.first?.edits.first)
        #expect(edit.rowID == .existing(1))
        #expect(!grid.model.isEditing)
    }

    // MARK: - Panes

    @Test("A frozen cell edits in the frozen pane, over its home in the main table")
    func frozenCellEditsInTheFrozenPane() {
        var layout = ColumnLayoutState()
        layout.frozenColumnCount = 1
        let grid = EditingGrid(store: InMemoryDataGridStateStore(columnLayout: layout))
        defer { grid.tearDown() }
        grid.controller.containerDidLayout()
        guard grid.controller.effectiveFrozenCount == 1 else {
            Issue.record("the frozen pane did not take the column")
            return
        }

        #expect(grid.controller.beginEditingCell(row: 0, displayColumn: 0))

        #expect(grid.controller.editingState.session?.pane == .frozen)
        #expect(grid.mountedEditCell(in: grid.controller.frozen, row: 0, displayColumn: 0) === grid.cellView)
        #expect(grid.mountedEditCell(in: grid.controller.main, row: 0, displayColumn: 0) == nil)
        #expect(grid.fieldEditor != nil)
    }

    // MARK: - The popover editor

    @Test("Option-Return hands the text to the popover editor with the line break where the caret was")
    func optionReturnMovesToThePopover() throws {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 0, displayColumn: 1)
        grid.type("ab")
        grid.fieldEditor?.setSelectedRange(NSRange(location: 1, length: 0))

        grid.send(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))

        let popover = try #require(grid.controller.editingState.textPopover)
        #expect(popover.isEditable)
        #expect(popover.textView.string == "a\nb")
        #expect(grid.controller.editingState.session?.editor == .textPopover)
        #expect(grid.controller.editedCell == nil)

        #expect(grid.model.commitEditing())
        #expect(grid.owner.committedValues == [.text("a\nb")])
    }

    // Single-line mode drops a pasted line break, so only text that has one leaves the field.
    @Test("Pasting text with a line break hands the edit to the popover editor with the text in place")
    func multiLinePasteMovesToThePopover() throws {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 0, displayColumn: 1)
        grid.type("ab")
        let editor = try #require(grid.fieldEditor)
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.TablePro.tests.grid.paste"))
        pasteboard.clearContents()
        pasteboard.setString("z", forType: .string)

        #expect(editor.readSelection(from: pasteboard, type: .string))
        #expect(grid.controller.editedCell != nil)
        #expect(grid.controller.editingState.textPopover == nil)

        pasteboard.clearContents()
        pasteboard.setString("x\ny", forType: .string)
        #expect(editor.readSelection(from: pasteboard, type: .string))

        let popover = try #require(grid.controller.editingState.textPopover)
        #expect(popover.textView.string == "azx\nyb")
        #expect(grid.controller.editingState.session?.editor == .textPopover)
        #expect(grid.controller.editedCell == nil)

        #expect(grid.model.commitEditing())
        #expect(grid.owner.committedValues == [.text("azx\nyb")])
    }

    @Test("A value with a line break opens the popover editor instead of the field")
    func multiLineValueOpensThePopover() throws {
        let rows = TableRows.from(
            queryRows: [[.text("0"), .text("line1\nline2")]],
            columns: ["id", "note"],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
        )
        let grid = EditingGrid(rows: rows)
        defer { grid.tearDown() }

        grid.controller.openEditor(at: GridCoord(row: 0, displayColumn: 1))

        let popover = try #require(grid.controller.editingState.textPopover)
        #expect(popover.isEditable)
        #expect(grid.controller.editedCell == nil)
        #expect(grid.model.isEditing)
    }

    @Test("A read-only cell opens the viewer, which edits nothing")
    func readOnlyCellOpensTheViewer() throws {
        var configuration = EditingGrid.editable
        configuration.isEditable = false
        let grid = EditingGrid(configuration: configuration)
        defer { grid.tearDown() }

        grid.controller.openEditor(at: GridCoord(row: 0, displayColumn: 1))

        let viewer = try #require(grid.controller.editingState.textPopover)
        #expect(!viewer.isEditable)
        #expect(!viewer.textView.isEditable)
        #expect(viewer.textView.string == "ann")
        #expect(!grid.model.isEditing)
    }

    // MARK: - Unloaded values (#3758)

    @Test("Editing a value the page left on the server loads it first, then edits the loaded value")
    func unloadedValueLoadsFirst() {
        let rows = TableRows.from(
            queryRows: [[.text("0"), .null]],
            columns: ["id", "body"],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")],
            unloadedCells: [0: [1: 4_096]]
        )
        let grid = EditingGrid(rows: rows)
        defer { grid.tearDown() }
        grid.owner.loadsValue = { rows in
            rows = TableRows.from(
                queryRows: [[.text("0"), .text("loaded")]],
                columns: ["id", "body"],
                columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
            )
        }

        grid.controller.beginEditingCell(row: 0, displayColumn: 1)

        #expect(grid.owner.loadRequests == [[.existing(0)]])
        #expect(grid.controller.editedCell == GridCoord(row: 0, displayColumn: 1))
        #expect(grid.fieldEditor?.string == "loaded")
    }

    @Test("A value that fails to load opens no editor")
    func unloadedValueThatFailsOpensNothing() {
        let rows = TableRows.from(
            queryRows: [[.text("0"), .null]],
            columns: ["id", "body"],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")],
            unloadedCells: [0: [1: 4_096]]
        )
        let grid = EditingGrid(rows: rows)
        defer { grid.tearDown() }

        #expect(!grid.controller.beginEditingCell(row: 0, displayColumn: 1))
        #expect(grid.owner.loadRequests.count == 1)
        #expect(!grid.model.isEditing)
    }

    // MARK: - Typed popovers

    @Test("commitEditing and discardEditing close a typed editor and the detached JSON window")
    func commitClosesTypedEditors() throws {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        let state = grid.controller.editingState
        let cell = try #require(grid.controller.editCell(at: GridCoord(row: 0, displayColumn: 1)))

        let popover = EditingCloseCountingPopover()
        state.typedPopover = popover
        state.typedPopoverRow = grid.controller.heldRow(cell)
        state.typedPopoverEdits = true
        let window = JSONViewerWindowController()
        state.poppedOutEditor = window
        state.poppedOutRow = grid.controller.heldRow(cell)
        #expect(grid.model.isEditing)

        #expect(grid.model.commitEditing())
        #expect(popover.closeCount == 1)
        #expect(state.typedPopover == nil)
        #expect(state.poppedOutEditor == nil)
        #expect(!grid.model.isEditing)

        let second = EditingCloseCountingPopover()
        state.typedPopover = second
        grid.model.discardEditing()
        #expect(second.closeCount == 1)
        #expect(state.typedPopover == nil)
    }

    // An .applicationDefined editor stays until something closes it; forgetting it would strand it on screen.
    @Test("Opening another typed editor closes the first instead of forgetting it")
    func secondTypedEditorClosesTheFirst() {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        let first = EditingCloseCountingPopover()
        first.behavior = .applicationDefined
        grid.controller.editingState.typedPopover = first

        grid.controller.closeTypedPopover()

        #expect(first.closeCount == 1)
        #expect(grid.controller.editingState.typedPopover == nil)
    }

    // AppKit posts a closed popover's didClose once it finishes animating out, after the next one is shown.
    @Test("The replaced typed editor closing late leaves the open one tracked")
    func lateCloseOfTheReplacedEditorKeepsTheOpenOne() throws {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        let state = grid.controller.editingState
        let first = try #require(grid.controller.editCell(at: GridCoord(row: 0, displayColumn: 1)))
        let second = try #require(grid.controller.editCell(at: GridCoord(row: 1, displayColumn: 1)))
        let replaced = try #require(grid.controller.presentTypedPopover(for: first, edits: true) { _ in EmptyView() })
        let open = try #require(grid.controller.presentTypedPopover(for: second, edits: true) { _ in EmptyView() })

        state.typedPopoverObserver.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: replaced))

        #expect(state.typedPopover === open)
        #expect(state.typedPopoverRow?.target.rowID == .existing(1))
        #expect(grid.model.isEditing)

        state.typedPopoverObserver.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: open))

        #expect(state.typedPopover == nil)
        #expect(!grid.model.isEditing)
    }

    @Test("A reload that keeps the record keeps its typed editor; one that replaces it closes the editor")
    func reloadKeepsOrClosesTypedEditor() throws {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        let state = grid.controller.editingState
        let cell = try #require(grid.controller.editCell(at: GridCoord(row: 1, displayColumn: 1)))
        let popover = EditingCloseCountingPopover()
        state.typedPopover = popover
        state.typedPopoverRow = grid.controller.heldRow(cell)

        let reversed = ContiguousArray(grid.owner.tableRows.rows.reversed())
        grid.owner.tableRows.reorderRows(reversed)
        grid.model.reloadRows()
        #expect(state.typedPopover === popover)
        #expect(popover.closeCount == 0)

        grid.owner.tableRows = TableRows.from(
            queryRows: [[.text("7"), .text("gus")], [.text("8"), .text("hal")]],
            columns: ["id", "name"],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
        )
        grid.model.reloadRows()
        #expect(state.typedPopover == nil)
        #expect(popover.closeCount == 1)
    }

    @Test("The detached JSON window stays while its record does and closes once it is gone")
    func poppedOutWindowFollowsItsRecord() throws {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        let state = grid.controller.editingState
        let cell = try #require(grid.controller.editCell(at: GridCoord(row: 2, displayColumn: 1)))
        let window = JSONViewerWindowController()
        state.poppedOutEditor = window
        state.poppedOutRow = grid.controller.heldRow(cell)

        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: ["ann"], includesNull: false), columnName: "name", forColumn: 1)
        grid.model.setValueFilter(filter)
        #expect(state.poppedOutEditor === window)

        _ = grid.owner.tableRows.remove(at: IndexSet(integer: 2))
        grid.model.apply(.rowsRemoved(IndexSet(integer: 2)))
        #expect(state.poppedOutEditor == nil)
    }

    // MARK: - SET picker (interaction 1)

    @Test("Picking a SET value commits from the item itself, keeping the declared order")
    func setPickCommitsFromTheItem() throws {
        var committed: [String] = []
        let menu = EnumMenuPicker.makeSetMenu(allowedValues: ["a", "b", "c"], currentCsv: "c") { committed.append($0) }

        menu.performActionForItem(at: 0)

        #expect(committed == ["a,c"])
    }

    @Test("Unticking the only SET value commits the empty set, and a value outside the declaration stays last")
    func setUntickAndDrift() {
        var committed: [String] = []
        let menu = EnumMenuPicker.makeSetMenu(allowedValues: ["a", "b"], currentCsv: "a, zz") { committed.append($0) }

        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 0)

        #expect(committed == ["a,b,zz", "zz"])
    }

    // MARK: - Accessibility

    // A text field's element is its cell, which reads nothing set on the control (measured on macOS 27).
    @Test("The edit field's element is named for its column")
    func fieldIsNamedForItsColumn() throws {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 0, displayColumn: 1)
        let element = try #require(grid.cellView.field.cell)

        #expect(element.isAccessibilityElement())
        #expect(element.accessibilityRole() == .textField)
        #expect(element.accessibilityLabel() == "name")
        #expect(element.accessibilityIdentifier() == "data-grid-edit-field")
    }
}

// The popover editor reads the four movement selectors a field editor would turn into an NSTextMovement (#2569).
@MainActor
struct DataGridTextEditorPopoverTests {
    private struct Outcome {
        let handled: Bool
        let ending: DataGridTextEditorPopover.Ending?
        let text: String?
    }

    private func makePopover(_ value: String, selection: NSRange, isEditable: Bool = true) -> DataGridTextEditorPopover {
        let popover = DataGridTextEditorPopover(text: value, isEditable: isEditable, cellWidth: 120, scope: .live)
        popover.textView.setSelectedRange(selection)
        return popover
    }

    private func send(_ selector: Selector, to popover: DataGridTextEditorPopover) -> Outcome {
        var ending: DataGridTextEditorPopover.Ending?
        var text: String?
        popover.onEnd = { reported, reportedText in
            ending = reported
            text = reportedText
        }
        let handled = popover.textView(popover.textView, doCommandBy: selector)
        return Outcome(handled: handled, ending: ending, text: text)
    }

    @Test("Return commits what was typed and Escape cancels it")
    func returnCommitsEscapeCancels() {
        let committed = makePopover("a\nb", selection: NSRange(location: 0, length: 0))
        committed.textView.string = "a\nbc"
        let returned = send(#selector(NSResponder.insertNewline(_:)), to: committed)
        #expect(returned.handled)
        #expect(returned.ending == .commit(nil))
        #expect(returned.text == "a\nbc")

        let cancelled = send(#selector(NSResponder.cancelOperation(_:)), to: makePopover("a\nb", selection: NSRange(location: 0, length: 0)))
        #expect(cancelled.handled)
        #expect(cancelled.ending == .cancel)
    }

    // Option-Return is insertNewlineIgnoringFieldEditor:, which a plain text view answers with a line break.
    @Test("Option-Return is left to the text view, which inserts the line break")
    func optionReturnInsertsALineBreak() {
        let result = send(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: makePopover("ab", selection: NSRange(location: 1, length: 0)))

        #expect(!result.handled)
        #expect(result.ending == nil)
    }

    @Test("Down leaves a single-line value for the row below, Up for the row above")
    func arrowsLeaveASingleLine() {
        let down = send(#selector(NSResponder.moveDown(_:)), to: makePopover("alpha", selection: NSRange(location: 0, length: 5)))
        let up = send(#selector(NSResponder.moveUp(_:)), to: makePopover("alpha", selection: NSRange(location: 2, length: 0)))

        #expect(down.handled)
        #expect(down.ending == .commit(.down))
        #expect(up.handled)
        #expect(up.ending == .commit(.up))
    }

    @Test("Down inside a multi-line value stays in the text, and leaves from its last line")
    func downFollowsTheValuesLines() {
        let inside = send(#selector(NSResponder.moveDown(_:)), to: makePopover("a\nb\nc", selection: NSRange(location: 0, length: 0)))
        let last = send(#selector(NSResponder.moveDown(_:)), to: makePopover("a\nb\nc", selection: NSRange(location: 5, length: 0)))

        #expect(!inside.handled)
        #expect(inside.ending == nil)
        #expect(last.handled)
        #expect(last.ending == .commit(.down))
    }

    @Test("A selection-extending arrow is left to the text view")
    func extendingArrowIsLeftAlone() {
        let result = send(#selector(NSResponder.moveDownAndModifySelection(_:)), to: makePopover("alpha", selection: NSRange(location: 0, length: 0)))

        #expect(!result.handled)
        #expect(result.ending == nil)
    }

    @Test("Tab and Shift-Tab commit and report their own movements")
    func tabAndBacktabMove() {
        let forward = send(#selector(NSResponder.insertTab(_:)), to: makePopover("alpha", selection: NSRange(location: 0, length: 0)))
        let backward = send(#selector(NSResponder.insertBacktab(_:)), to: makePopover("alpha", selection: NSRange(location: 0, length: 0)))

        #expect(forward.ending == .commit(.tab))
        #expect(backward.ending == .commit(.backtab))
    }

    // Until the input method commits, the text view holds provisional text a movement would save.
    @Test("During an IME composition an arrow moves through it and Tab is swallowed")
    func compositionOwnsTheKeys() {
        func composing() -> DataGridTextEditorPopover {
            let popover = makePopover("", selection: NSRange(location: 0, length: 0))
            popover.textView.setMarkedText(
                "\u{304B}",
                selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: 0, length: 0)
            )
            return popover
        }
        let arrow = send(#selector(NSResponder.moveDown(_:)), to: composing())
        let tab = send(#selector(NSResponder.insertTab(_:)), to: composing())

        #expect(!arrow.handled)
        #expect(arrow.ending == nil)
        #expect(tab.handled)
        #expect(tab.ending == nil)
    }

    @Test("The viewer closes on Return, Escape and Tab and never commits; its arrows move through the text")
    func viewerKeys() {
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertTab(_:))] {
            let result = send(selector, to: makePopover("3", selection: NSRange(location: 0, length: 0), isEditable: false))
            #expect(result.ending == .cancel)
        }
        let arrow = send(#selector(NSResponder.moveDown(_:)), to: makePopover("3", selection: NSRange(location: 0, length: 0), isEditable: false))
        #expect(!arrow.handled)
    }

    @Test("The viewer is a text area holding the value")
    func viewerAccessibility() {
        let viewer = makePopover("3", selection: NSRange(location: 0, length: 0), isEditable: false)

        #expect(viewer.textView.accessibilityRole() == .textArea)
        #expect(viewer.textView.accessibilityValue() as? String == "3")
    }

    @Test("A popover reports its ending once")
    func endsOnce() {
        let popover = makePopover("x", selection: NSRange(location: 0, length: 0))
        var endings: [DataGridTextEditorPopover.Ending] = []
        popover.onEnd = { ending, _ in endings.append(ending) }

        popover.end(.commit(nil))
        popover.end(.cancel)
        popover.popoverDidClose(Notification(name: NSPopover.didCloseNotification))

        #expect(endings == [.commit(nil)])
    }

    // MARK: - Layout

    // Wrapping lays a paragraph out whole before the popover appears (#2381), so only a value under the limit wraps.
    @Test("A value under the limit wraps to the popover's width; one past it scrolls sideways")
    func wrapsUnderTheLimit() throws {
        let short = NSTextView(usingTextLayoutManager: true)
        DataGridTextEditorPopover.applyLayout(to: short, for: "some text", width: 300)
        let shortContainer = try #require(short.textContainer)
        #expect(shortContainer.widthTracksTextView)
        #expect(!short.isHorizontallyResizable)

        let long = String(repeating: "some cell value ", count: DataGridTextEditorPopover.wrapLimit / 16 + 1)
        let wide = NSTextView(usingTextLayoutManager: true)
        DataGridTextEditorPopover.applyLayout(to: wide, for: long, width: 300)
        let wideContainer = try #require(wide.textContainer)
        #expect(!wideContainer.widthTracksTextView)
        #expect(wide.isHorizontallyResizable)
        #expect(wide.maxSize.width == CGFloat.greatestFiniteMagnitude)
    }

    // A text view grows only as far as maxSize, so a value past the limit would be clipped at the popover's edge.
    @Test("A value past the limit makes the editor scrollable rather than clipping it")
    func longValueScrolls() throws {
        let long = String(repeating: "some cell value ", count: DataGridTextEditorPopover.wrapLimit / 16 + 1)
        let popover = DataGridTextEditorPopover(text: long, isEditable: true, cellWidth: 120, scope: .live)
        let layoutManager = try #require(popover.textView.textLayoutManager, "the editor has to be on TextKit 2")
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        popover.textView.layout()

        #expect(popover.textView.frame.width > 1_000)
    }

    @Test("The edit field holds one line that scrolls rather than wraps")
    func fieldIsOneLine() throws {
        let field = DataGridEditingTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let cell = try #require(field.cell)

        #expect(field.usesSingleLineMode)
        #expect(!cell.wraps)
        #expect(cell.isScrollable)
        #expect(field.isEditable)
    }

    // MARK: - Appearance

    @Test("Under the default theme the field and its field editor keep the system colors")
    func defaultThemeIsNative() {
        let grid = EditingGrid(themeScope: .fixed(BuiltInThemes.light))
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 0, displayColumn: 1)

        #expect(ThemeTestFixture.hex(grid.cellView.field.textColor) == ThemeTestFixture.hex(.textColor))
        #expect(ThemeTestFixture.hex(grid.cellView.field.backgroundColor) == ThemeTestFixture.hex(.textBackgroundColor))
        #expect(grid.fieldEditor === grid.cellView.field.ownFieldEditor)
    }

    @Test("Under a theme the field, its field editor and the popover take the editor colors, and give them back")
    func themeReachesTheEditors() throws {
        var theme = try ThemeTestFixture.theme(.light, [
            .editorBackground: "#282A36",
            .editorText: "#F8F8F2",
            .editorCursor: "#FF79C6",
            .editorSelection: "#44475A",
        ])
        theme.id = "test.grid-editor"
        let scope = ThemeScope.fixed(theme)
        let grid = EditingGrid(themeScope: scope)
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 0, displayColumn: 1)
        let editor = try #require(grid.fieldEditor)

        #expect(ThemeTestFixture.hex(grid.cellView.field.textColor) == "#F8F8F2")
        #expect(ThemeTestFixture.hex(grid.cellView.field.backgroundColor) == "#282A36")
        #expect(ThemeTestFixture.hex(editor.insertionPointColor) == "#FF79C6")
        #expect(ThemeTestFixture.hex(editor.selectedTextAttributes[.backgroundColor] as? NSColor) == "#44475A")

        // Its own field editor, so the caret color never stays on the window's shared one.
        #expect(editor === grid.cellView.field.ownFieldEditor)
        #expect(editor !== grid.window.fieldEditor(false, for: nil))

        let popover = DataGridTextEditorPopover(text: "value", isEditable: true, cellWidth: 120, scope: scope)
        #expect(ThemeTestFixture.hex(popover.textView.backgroundColor) == "#282A36")
        #expect(ThemeTestFixture.hex(popover.textView.textColor) == "#F8F8F2")
    }

    // MARK: - Accessibility

    // The old overlay sat outside the table, where NSTableView could not publish it; the field lives in its cell.
    // A field outside a table hangs off the window; inside one, NSTableView parents it to its own cell element.
    @Test("The open edit field is part of the table's accessibility tree")
    func fieldIsInsideTheTable() throws {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.controller.beginEditingCell(row: 0, displayColumn: 1)
        let element = try #require(grid.cellView.field.cell)

        let parent = try #require(element.accessibilityParent())
        #expect(!(parent is NSWindow))
        #expect(!(parent is NSView))
    }
}

final class EditingCloseCountingPopover: NSPopover {
    private(set) var closeCount = 0

    override func close() {
        closeCount += 1
        super.close()
    }
}
