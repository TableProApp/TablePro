//
//  DataGridValueEditorTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

struct DataGridValueEditorResolutionTests {
    private func resolve(
        _ mode: CellInteractionMode,
        chevron: DataGridChevronEditor? = nil,
        isJsonColumn: Bool = false,
        isNull: Bool = false,
        isUnloaded: Bool = false,
        isWritable: Bool = true,
        isCheckbox: Bool = false
    ) -> DataGridValueEditor? {
        DataGridValueEditor.resolve(
            mode: mode,
            chevron: chevron,
            isJsonColumn: isJsonColumn,
            isNull: isNull,
            isUnloaded: isUnloaded,
            isWritable: isWritable,
            isCheckbox: isCheckbox
        )
    }

    @Test("A cell that only edits inline, picks a referenced row or shows short text opens nothing")
    func plainCellsOpenNothing() {
        #expect(resolve(.editInline(value: "ann")) == nil)
        #expect(resolve(.editForeignKey) == nil)
        #expect(resolve(.viewText(value: "ann"), isWritable: false) == nil)
        #expect(resolve(.viewText(value: "NULL"), isWritable: false) == nil)
        #expect(resolve(.editInline(value: "2026-01-01"), chevron: .inlineText) == nil)
    }

    @Test("Long or multi-line text opens its popover, editable or not")
    func longTextOpensThePopover() {
        let long = String(repeating: "x", count: CellInteractionResolver.inlineLengthLimit + 1)
        #expect(resolve(.editText(value: long)) == .mode(.editText(value: long)))
        #expect(resolve(.viewText(value: "a\nb"), isWritable: false) == .mode(.viewText(value: "a\nb")))
    }

    @Test("A writable typed column opens its chevron editor")
    func typedColumnOpensTheChevronEditor() {
        #expect(resolve(.editInline(value: "{}"), chevron: .json, isJsonColumn: true) == .chevron(.json))
        #expect(resolve(.editInline(value: "1"), chevron: .boolean) == .chevron(.boolean))
        #expect(resolve(.editForeignKey, chevron: .dropdown) == .chevron(.dropdown))
    }

    @Test("A JSON column the grid cannot write opens the JSON viewer")
    func readOnlyJsonColumnOpensTheViewer() {
        let editor = resolve(.viewText(value: "{}"), isJsonColumn: true, isWritable: false)
        #expect(editor == .jsonViewer)
        #expect(editor?.edits == false)
    }

    @Test("A Display As choice wins over the column's chevron editor")
    func displayFormatWinsOverTheChevron() {
        #expect(resolve(.viewBinaryValue(.messagePack), chevron: .blob) == .mode(.viewBinaryValue(.messagePack)))
        #expect(resolve(.editJson, chevron: .enumeration) == .mode(.editJson))
    }

    @Test("A NULL offers no viewer, and still offers the editor that puts a value into it")
    func nullOffersOnlyAnEditor() {
        #expect(resolve(.viewText(value: "NULL"), isJsonColumn: true, isNull: true, isWritable: false) == nil)
        #expect(resolve(.viewBlob, isNull: true, isWritable: false) == nil)
        #expect(resolve(.editInline(value: ""), chevron: .json, isJsonColumn: true, isNull: true) == .chevron(.json))
        #expect(resolve(.editBlob, chevron: .blob, isNull: true) == .mode(.editBlob))
    }

    @Test("A deleted row and a checkbox cell open nothing")
    func blockedCellsOpenNothing() {
        #expect(resolve(.blocked, chevron: .json, isJsonColumn: true) == nil)
        #expect(resolve(.editInline(value: "1"), isCheckbox: true) == nil)
        #expect(resolve(.viewText(value: "a\nb"), isWritable: false, isCheckbox: true) == nil)
    }

    @Test("A value left on the server is offered before it loads, as an editor only where the cell can be written")
    func unloadedValueIsOffered() {
        #expect(resolve(.editInline(value: ""), isUnloaded: true) == .unloaded(edits: true))
        #expect(resolve(.viewText(value: "NULL"), isUnloaded: true, isWritable: false)?.edits == false)
    }
}

@MainActor
struct DataGridValueEditorTests {
    private static let documents = TableRows.from(
        queryRows: [[.text("1"), .text(#"{"a":[1,2]}"#), .text("ann")]],
        columns: ["id", "body", "name"],
        columnTypes: [.integer(rawType: "INT"), .json(rawType: "JSON"), .text(rawType: "TEXT")]
    )

    private static var readOnly: DataGridConfiguration {
        var configuration = EditingGrid.editable
        configuration.isEditable = false
        return configuration
    }

    @Test("The command opens the JSON viewer on a JSON column of a read-only grid")
    func readOnlyJsonColumnOpensTheViewer() {
        let grid = EditingGrid(rows: Self.documents, configuration: Self.readOnly)
        defer { grid.tearDown() }

        grid.controller.openValueEditor(at: GridCoord(row: 0, displayColumn: 1))

        #expect(grid.controller.editingState.typedPopover != nil)
        #expect(!grid.controller.editingState.typedPopoverEdits)
        #expect(grid.controller.editingState.textPopover == nil)
    }

    @Test("The command opens the JSON editor on a writable JSON column, where Return edits inline")
    func writableJsonColumnOpensTheEditor() {
        let grid = EditingGrid(rows: Self.documents)
        defer { grid.tearDown() }

        grid.controller.openValueEditor(at: GridCoord(row: 0, displayColumn: 1))

        #expect(grid.controller.editingState.typedPopover != nil)
        #expect(grid.controller.editingState.typedPopoverEdits)
        #expect(grid.controller.editedCell == nil)
    }

    @Test("An open editor is never replaced: the command is off until it closes")
    func openEditorIsNotReplaced() {
        let grid = EditingGrid(rows: Self.documents)
        defer { grid.tearDown() }
        let json = GridCoord(row: 0, displayColumn: 1)
        grid.controller.openValueEditor(at: json)
        let open = grid.controller.editingState.typedPopover

        #expect(grid.controller.valueEditor(at: json) == nil)
        grid.controller.openValueEditor(at: json)

        #expect(grid.controller.editingState.typedPopover === open)
    }

    @Test("A dropdown column with no list for the row offers nothing")
    func dropdownWithoutOptionsOffersNothing() {
        var configuration = EditingGrid.editable
        configuration.dropdownColumns = [2]
        let grid = EditingGrid(rows: Self.documents, configuration: configuration)
        defer { grid.tearDown() }

        #expect(grid.controller.valueEditor(at: GridCoord(row: 0, displayColumn: 2)) == nil)
    }

    @Test("A locked JSON column views its value instead of refusing")
    func lockedColumnViews() {
        var configuration = EditingGrid.editable
        configuration.lockedColumns = ["body"]
        let grid = EditingGrid(rows: Self.documents, configuration: configuration)
        defer { grid.tearDown() }

        let editor = grid.controller.valueEditor(at: GridCoord(row: 0, displayColumn: 1))

        #expect(editor == .jsonViewer)
    }

    @Test("The menu bar command follows the active cell and yields while a cell field is open")
    func menuBarCommandFollowsTheActiveCell() {
        let grid = EditingGrid(rows: Self.documents)
        defer { grid.tearDown() }
        let item = NSMenuItem(title: "", action: #selector(DataGridViewController.openValueEditor(_:)), keyEquivalent: "")

        #expect(!grid.controller.validateMenuItem(item))

        grid.model.selectCell(GridCoord(row: 0, displayColumn: 2))
        #expect(!grid.controller.validateMenuItem(item))

        grid.model.selectCell(GridCoord(row: 0, displayColumn: 1))
        #expect(grid.controller.validateMenuItem(item))

        grid.controller.openEditor(at: GridCoord(row: 0, displayColumn: 1))
        #expect(grid.controller.editedCell != nil)
        #expect(!grid.controller.validateMenuItem(item))
    }

    @Test("The grid reads the shortcut from the key press, so the menu item never takes Option-Return from a text field")
    func shortcutIsReadByTheGrid() throws {
        let keyboard = KeyboardSettings.default
        #expect(keyboard.shortcut(for: .openValueEditor) == .special(.return, option: true))
        #expect(keyboard.menuKeyEquivalent(for: .openValueEditor) == nil)
        #expect(keyboard.keyboardShortcut(for: .openValueEditor) == nil)

        let grid = EditingGrid(rows: Self.documents)
        defer { grid.tearDown() }
        let optionReturn = try #require(Self.keyDown(.return, modifiers: .option))
        let plainReturn = try #require(Self.keyDown(.return, modifiers: []))

        grid.model.selectCell(GridCoord(row: 0, displayColumn: 2))
        #expect(!grid.controller.handleGridKey(optionReturn))

        grid.model.selectCell(GridCoord(row: 0, displayColumn: 1))
        #expect(!grid.controller.handleGridKey(plainReturn))
        #expect(grid.controller.handleGridKey(optionReturn))
        #expect(grid.controller.editingState.typedPopover != nil)
    }

    private static func keyDown(_ key: KeyCode, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: key.rawValue
        )
    }

    @Test("Typing, Return and a double-click open no field on a checkbox cell")
    func checkboxCellOpensNoField() {
        var configuration = EditingGrid.editable
        configuration.checkboxColumns = [2]
        let grid = EditingGrid(rows: Self.documents, configuration: configuration)
        defer { grid.tearDown() }

        grid.controller.openEditor(at: GridCoord(row: 0, displayColumn: 2))

        #expect(grid.controller.editedCell == nil)
        #expect(grid.controller.editingState.textPopover == nil)
        #expect(!grid.model.isEditing)
        let cell = DataGridCommandCell(rowID: .existing(0), row: 0, column: grid.model.columns.columns[2])
        #expect(!grid.controller.gridCommands.typingCanEdit(cell))
        #expect(grid.controller.gridCommands.typingCanEdit(
            DataGridCommandCell(rowID: .existing(0), row: 0, column: grid.model.columns.columns[1])
        ))
    }
}

@MainActor
struct DataGridValueEditorMenuTests {
    private static let documents = TableRows.from(
        queryRows: [
            [.text("1"), .text(#"{"a":[1,2]}"#), .text("ann")],
            [.text("2"), .text("{}"), .text("line1\nline2")],
        ],
        columns: ["id", "body", "name"],
        columnTypes: [.integer(rawType: "INT"), .json(rawType: "JSON"), .text(rawType: "TEXT")]
    )

    private let open = String(localized: "Open Value Editor")
    private let view = String(localized: "View Value")

    @Test("A writable cell with an editor offers Open Value Editor; one that only edits inline offers nothing")
    func writableGridOffersTheEditor() {
        let grid = CommandGrid(Self.documents)

        #expect(CommandRows.titles(grid.rowMenu(row: 0, displayColumn: 1)).contains(open))
        #expect(CommandRows.titles(grid.rowMenu(row: 1, displayColumn: 2)).contains(open))
        let plain = CommandRows.titles(grid.rowMenu(row: 0, displayColumn: 2))
        #expect(!plain.contains(open))
        #expect(!plain.contains(view))
    }

    @Test("A read-only grid offers View Value on a JSON cell and on long text, and nothing on short text")
    func readOnlyGridOffersTheViewer() {
        let grid = CommandGrid(Self.documents, configuration: CommandGrid.readOnly())

        #expect(CommandRows.titles(grid.rowMenu(row: 0, displayColumn: 1)).contains(view))
        #expect(CommandRows.titles(grid.rowMenu(row: 1, displayColumn: 2)).contains(view))
        let plain = CommandRows.titles(grid.rowMenu(row: 0, displayColumn: 2))
        #expect(!plain.contains(view))
        #expect(!plain.contains(open))
    }

    @Test("The row numbers and a deleted row offer neither title")
    func rowNumbersAndDeletedRowsOfferNothing() {
        let manager = DataChangeManager()
        let grid = CommandGrid(Self.documents, changeManager: manager)

        let overNumbers = CommandRows.titles(grid.rowMenu(row: 0, displayColumn: nil))
        #expect(!overNumbers.contains(open))

        manager.recordRowDeletion(rowID: .existing(0), originalRow: [.text("1"), .text(#"{"a":[1,2]}"#), .text("ann")])
        #expect(CommandRows.titles(grid.rowMenu(row: 0, displayColumn: 1)) == [String(localized: "Undo Delete")])
    }

    @Test("Choosing the item opens the clicked cell's editor and leaves the selection where it was")
    func choosingTheItemKeepsTheSelection() throws {
        let grid = CommandGrid(Self.documents)
        grid.host()
        defer { grid.close() }
        grid.selectCell(1, 0)
        let before = grid.model.selection

        let menu = grid.rowMenu(row: 0, displayColumn: 1)
        grid.perform(try #require(CommandRows.item(open, in: menu)))

        #expect(grid.controller.editingState.typedPopover != nil)
        #expect(grid.model.selection == before)
    }
}
