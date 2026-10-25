//
//  DataGridSetValueTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private enum SetValueFixture {
    static let columns = ["id", "ref", "note", "label", "seen"]
    static let id = 0
    static let ref = 1
    static let note = 2
    static let label = 3
    static let seen = 4

    static func grid(rowCount: Int = 3, isEditable: Bool = true) -> CommandGrid {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "things",
            columns: columns,
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: []
        )
        let rows: [[PluginCellValue]] = (0..<rowCount).map { row in
            [.null, .null, .text("n\(row)"), .text("l\(row)"), .text("2024-01-0\(row + 1) 10:00:00+00")]
        }
        return CommandGrid(
            TableRows.from(
                queryRows: rows,
                columns: columns,
                columnTypes: [
                    .text(rawType: "uuid"),
                    .text(rawType: "uuid"),
                    .text(rawType: "text"),
                    .text(rawType: "text"),
                    .timestamp(rawType: "timestamptz"),
                ],
                columnNullable: ["id": false, "ref": true, "note": true, "label": false, "seen": true]
            ),
            configuration: isEditable ? CommandGrid.editable() : CommandGrid.readOnly(),
            changeManager: manager
        )
    }

    static func cells(_ grid: CommandGrid, _ pairs: [(Int, Int)]) -> [DataGridCommandCell] {
        pairs.compactMap { row, column in
            guard let rowID = grid.model.rowID(at: row), let column = grid.model.columns.column(at: column) else { return nil }
            return DataGridCommandCell(rowID: rowID, row: row, column: column)
        }
    }

    static func now() throws -> CellExpression {
        try #require(
            CellExpressionVocabulary.expressions(for: .postgresql, columnType: .timestamp(rawType: "timestamptz"))
                .first { $0.sql == "now()" }
        )
    }
}

@MainActor
struct DataGridSetValueTests {
    private typealias Fixture = SetValueFixture

    @Test("Generate UUID over a cell selection writes a different lowercase UUID into every cell")
    func uuidPerSelectedCell() throws {
        let grid = Fixture.grid()
        grid.select(rows: 0...2, columns: Fixture.id...Fixture.ref)

        grid.commands.applySetValue(.uuid(.v4), to: grid.commands.cells(.current(grid.model.selection)))

        var written: [String] = []
        for row in 0..<3 {
            for column in [Fixture.id, Fixture.ref] {
                let text = try #require(grid.owner.staged(row, column)?.value.asText)
                #expect(UUID(uuidString: text) != nil)
                #expect(text == text.lowercased())
                written.append(text)
            }
        }
        #expect(Set(written).count == 6)
    }

    @Test("Generate UUID on an empty CHAR column the UUID format marks takes the length its schema declares")
    func uuidTakesTheSchemaLength() throws {
        let grid = Fixture.grid()
        grid.owner.tableRows.columnTypes[Fixture.ref] = .text(rawType: "CHAR")
        grid.owner.tableRows.columnDeclaredTypes = ["ref": "CHAR(32)"]
        grid.model.reloadRows()
        grid.model.setDisplayFormat(.uuid, for: grid.model.columns.columns[Fixture.ref])

        grid.commands.applySetValue(.uuid(.v4), to: Fixture.cells(grid, [(0, Fixture.ref)]))

        let text = try #require(grid.owner.staged(0, Fixture.ref)?.value.asText)
        #expect(text.count == 32)
        #expect(text.allSatisfy { $0.isHexDigit })
    }

    @Test("A Set Value over many cells is one commit, named for the command")
    func oneCommit() {
        let grid = Fixture.grid()

        grid.commands.applySetValue(.uuid(.v7), to: Fixture.cells(grid, [(0, Fixture.id), (1, Fixture.id), (2, Fixture.id)]))
        grid.commands.applySetValue(.null, to: Fixture.cells(grid, [(0, Fixture.note), (1, Fixture.note)]))

        #expect(grid.owner.commits.map { $0.actionName } == [String(localized: "Generate UUIDv7"), String(localized: "Set Value")])
        #expect(grid.owner.commits.map { $0.edits.count } == [3, 2])
    }

    @Test("Over whole rows the clicked column is written on every selected row; a click on another row writes that cell")
    func clickedColumnAcrossSelectedRows() {
        let grid = Fixture.grid()
        grid.model.setSelection(GridSelection(
            rectangles: [GridRect(rows: 0...0, columns: 0...4), GridRect(rows: 2...2, columns: 0...4)],
            activeCell: GridCoord(row: 2, displayColumn: 0),
            anchor: GridCoord(row: 0, displayColumn: 0),
            mode: .rows
        ))
        let selection = grid.model.selection

        let onSelectedRow = grid.commands.cells(.contextMenu(selection: selection, row: 2, displayColumn: Fixture.note, columnCount: 5))
        let onOtherRow = grid.commands.cells(.contextMenu(selection: selection, row: 1, displayColumn: Fixture.note, columnCount: 5))

        #expect(onSelectedRow == Fixture.cells(grid, [(0, Fixture.note), (2, Fixture.note)]))
        #expect(onOtherRow == Fixture.cells(grid, [(1, Fixture.note)]))
    }

    @Test("A click inside the cell selection acts on the selection, a click outside it on the clicked cell")
    func clickInsideOrOutsideSelection() {
        let grid = Fixture.grid()
        grid.select(rows: 0...1, columns: Fixture.note...Fixture.note)
        let selection = grid.model.selection

        let inside = grid.commands.cells(.contextMenu(selection: selection, row: 1, displayColumn: Fixture.note, columnCount: 5))
        let outside = grid.commands.cells(.contextMenu(selection: selection, row: 2, displayColumn: Fixture.label, columnCount: 5))

        #expect(inside == Fixture.cells(grid, [(0, Fixture.note), (1, Fixture.note)]))
        #expect(outside == Fixture.cells(grid, [(2, Fixture.label)]))
    }

    @Test("Cells that do not take the command, and deleted rows, are left as they were")
    func skipsCellsTheCommandDoesNotFit() {
        let grid = Fixture.grid()
        grid.owner.changeManager.recordRowDeletion(rowID: .existing(1), originalRow: Array(grid.owner.tableRows.rows[1].values))
        grid.select(rows: 0...2, columns: Fixture.note...Fixture.label)

        grid.commands.applySetValue(.null, to: grid.commands.cells(.current(grid.model.selection)))

        #expect(grid.owner.staged(0, Fixture.note)?.value == .null)
        #expect(grid.owner.staged(2, Fixture.note)?.value == .null)
        #expect(grid.owner.staged(0, Fixture.label) == nil)
        #expect(grid.owner.staged(1, Fixture.note) == nil)
    }

    @Test("A selection offers every command one of its cells takes, in menu order")
    func offeredCommandsAreTheUnion() {
        let grid = Fixture.grid()
        grid.select(rows: 0...0, columns: Fixture.id...Fixture.note)
        let cells = grid.commands.cells(.current(grid.model.selection))

        #expect(grid.commands.setValueCommands(for: cells) == [.empty, .null, .uuid(.v4), .uuid(.v7)])
        #expect(grid.commands.isSetValueOffered(.uuid(.v4), for: cells))
        #expect(!grid.commands.isSetValueOffered(.defaultValue, for: cells))
    }

    @Test("A function chosen from Set Value is staged as SQL, not as text")
    func expressionIsMarked() throws {
        let grid = Fixture.grid()

        grid.commands.applySetValue(.expression(try Fixture.now()), to: Fixture.cells(grid, [(0, Fixture.seen)]))

        #expect(grid.owner.staged(0, Fixture.seen)?.value == .text("now()"))
        #expect(grid.owner.staged(0, Fixture.seen)?.isExpression == true)
    }

    @Test("Typing a function into a timestamp stages its SQL, and the same text in a text cell stays text")
    func typedFunctionIsPromotedOnlyWhereItFits() {
        let grid = Fixture.grid()
        let seen = grid.model.columns.columns[Fixture.seen].id
        let note = grid.model.columns.columns[Fixture.note].id

        grid.model.commit(
            [
                DataGridCellEdit(rowID: .existing(0), columnID: seen, value: .enteredText(" NOW() ")),
                DataGridCellEdit(rowID: .existing(0), columnID: note, value: .enteredText("NOW()")),
            ],
            actionName: "Edit Cell"
        )

        #expect(grid.owner.staged(0, Fixture.seen)?.value == .text("now()"))
        #expect(grid.owner.staged(0, Fixture.seen)?.isExpression == true)
        #expect(grid.owner.staged(0, Fixture.note)?.value == .text("NOW()"))
        #expect(grid.owner.staged(0, Fixture.note)?.isExpression == false)
    }

    @Test("A writer that takes no SQL in cells gets typed text as it was typed, and that literal over a staged function is an edit")
    func typedFunctionStaysLiteralForAnOldWriter() {
        let grid = Fixture.grid()
        let seen = grid.model.columns.columns[Fixture.seen].id
        grid.model.commit([DataGridCellEdit(rowID: .existing(0), columnID: seen, value: .enteredText("now()"))], actionName: "Edit Cell")
        #expect(grid.owner.staged(0, Fixture.seen)?.isExpression == true)

        grid.model.configuration.traits.cellWriterSupport = .none
        grid.model.commit([DataGridCellEdit(rowID: .existing(0), columnID: seen, value: .enteredText("now()"))], actionName: "Edit Cell")

        #expect(grid.owner.commits.count == 2)
        #expect(grid.owner.staged(0, Fixture.seen)?.value == .text("now()"))
        #expect(grid.owner.staged(0, Fixture.seen)?.isExpression == false)
    }

    // MARK: - Menu bar

    private func isEnabled(_ action: Selector, in grid: CommandGrid) -> Bool {
        grid.isEnabled(action)
    }

    private static let empty = #selector(SetValueCommandResponding.setValueEmpty(_:))
    private static let null = #selector(SetValueCommandResponding.setValueNull(_:))
    private static let defaultValue = #selector(SetValueCommandResponding.setValueDefault(_:))
    private static let uuidV4 = #selector(SetValueCommandResponding.generateUUIDv4(_:))
    private static let uuidV7 = #selector(SetValueCommandResponding.generateUUIDv7(_:))
    private static let cellsToValue = #selector(SetValueCommandResponding.setCellsToValue(_:))

    @Test("On the cursor's uuid key only the UUID items are enabled")
    func uuidKeyEnablesTheUUIDs() {
        let grid = Fixture.grid()
        grid.selectCell(0, Fixture.id)

        #expect(isEnabled(Self.uuidV4, in: grid))
        #expect(isEnabled(Self.uuidV7, in: grid))
        #expect(!isEnabled(Self.null, in: grid))
        #expect(!isEnabled(Self.defaultValue, in: grid))
    }

    @Test("On a nullable text cell Empty, NULL and Set Cells to Value are enabled and the UUIDs are not")
    func textCellEnablesItsCommands() {
        let grid = Fixture.grid()
        grid.selectCell(0, Fixture.note)

        #expect(isEnabled(Self.empty, in: grid))
        #expect(isEnabled(Self.null, in: grid))
        #expect(isEnabled(Self.cellsToValue, in: grid))
        #expect(!isEnabled(Self.uuidV4, in: grid))
    }

    @Test("With nothing selected, or a read-only grid, every item is dimmed")
    func everythingDimsWithoutATarget() {
        let grid = Fixture.grid()
        let readOnly = Fixture.grid(isEditable: false)
        readOnly.selectCell(0, Fixture.note)

        for action in [Self.empty, Self.null, Self.defaultValue, Self.uuidV4, Self.uuidV7, Self.cellsToValue] {
            #expect(!isEnabled(action, in: grid))
            #expect(!isEnabled(action, in: readOnly))
        }
    }

    @Test("A selection across both columns enables what either takes, and writes each only where it fits")
    func mixedSelection() {
        let grid = Fixture.grid()
        grid.model.setSelection(GridSelection(
            rectangles: [GridRect(cell: GridCoord(row: 0, displayColumn: Fixture.id)), GridRect(cell: GridCoord(row: 0, displayColumn: Fixture.note))],
            activeCell: GridCoord(row: 0, displayColumn: Fixture.note),
            anchor: GridCoord(row: 0, displayColumn: Fixture.id)
        ))

        #expect(isEnabled(Self.null, in: grid))
        #expect(isEnabled(Self.uuidV4, in: grid))

        grid.controller.setValueNull(nil)

        #expect(grid.owner.staged(0, Fixture.note)?.value == .null)
        #expect(grid.owner.staged(0, Fixture.id) == nil)
    }

    @Test("Set Value NULL from the menu bar writes the cursor's cell")
    func menuBarWritesTheCursorCell() {
        let grid = Fixture.grid()
        grid.selectCell(1, Fixture.note)

        grid.controller.setValueNull(nil)

        #expect(grid.owner.staged(1, Fixture.note)?.value == .null)
        #expect(grid.owner.editCount == 1)
    }

    // MARK: - Context menu

    private func setValueTitles(_ grid: CommandGrid, row: Int = 0, column: Int) -> [String] {
        let menu = grid.rowMenu(row: row, displayColumn: column)
        return CommandRows.titles(CommandRows.item(String(localized: "Set Value"), in: menu)?.submenu)
    }

    private func menuGrid(
        columns: [String],
        columnTypes: [ColumnType],
        rows: [[PluginCellValue]],
        columnNullable: [String: Bool] = [:],
        columnDefaults: [String: String?] = [:],
        columnForeignKeys: [String: ForeignKeyInfo] = [:],
        databaseType: DatabaseType = .postgresql
    ) -> CommandGrid {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "t",
            columns: columns,
            primaryKeyColumns: [columns[0]],
            databaseType: databaseType,
            generatedColumns: []
        )
        return CommandGrid(
            TableRows.from(
                queryRows: rows,
                columns: columns,
                columnTypes: columnTypes,
                columnDefaults: columnDefaults,
                columnForeignKeys: columnForeignKeys,
                columnNullable: columnNullable
            ),
            configuration: CommandGrid.editable(databaseType: databaseType),
            changeManager: manager
        )
    }

    private func uuidKeyGrid() -> CommandGrid {
        menuGrid(
            columns: ["id", "name"],
            columnTypes: [.text(rawType: "uuid"), .text(rawType: "text")],
            rows: [[.null, .text("a")]],
            columnNullable: ["id": false, "name": true]
        )
    }

    @Test("A PostgreSQL uuid key, NOT NULL with no default, offers the two UUIDs and Set Cells to Value")
    func uuidKeyMenu() {
        #expect(setValueTitles(uuidKeyGrid(), column: 0) == ["Generate UUID", "Generate UUIDv7", "-", "Set Cells to Value…"])
    }

    @Test("A date column lists the engine's functions after the placeholders, behind a separator")
    func dateColumnFunctions() {
        let grid = menuGrid(
            columns: ["id", "born"],
            columnTypes: [.integer(rawType: "INT"), .date(rawType: "DATE")],
            rows: [[.text("1"), .text("2024-01-01")]],
            columnNullable: ["born": true],
            databaseType: .mysql
        )

        #expect(setValueTitles(grid, column: 1) == ["NULL", "-", "CURDATE()", "UTC_DATE()", "-", "Set Cells to Value…"])
    }

    @Test("A nullable uuid column with a default keeps NULL and Default apart from the UUIDs")
    func uuidWithDefaultGroups() {
        let grid = menuGrid(
            columns: ["id", "ref"],
            columnTypes: [.integer(rawType: "int4"), .text(rawType: "uuid")],
            rows: [[.text("1"), .null]],
            columnNullable: ["ref": true],
            columnDefaults: ["ref": "gen_random_uuid()"]
        )

        #expect(setValueTitles(grid, column: 1) == [
            "NULL", "Default", "-", "Generate UUID", "Generate UUIDv7", "-", "Set Cells to Value…",
        ])
    }

    @Test("A uuid foreign key offers no new UUID, which would point at no row")
    func foreignKeyOffersNoUUID() {
        let grid = menuGrid(
            columns: ["id", "owner"],
            columnTypes: [.integer(rawType: "int4"), .text(rawType: "uuid")],
            rows: [[.text("1"), .null]],
            columnNullable: ["owner": true],
            columnForeignKeys: [
                "owner": ForeignKeyInfo(name: "fk", column: "owner", referencedTable: "users", referencedColumn: "id")
            ]
        )

        #expect(setValueTitles(grid, column: 1) == ["NULL", "-", "Set Cells to Value…"])
    }

    @Test("Choosing Generate UUID writes a new lowercase UUID into the clicked cell")
    func choosingGenerateUUIDWritesIt() throws {
        let grid = uuidKeyGrid()
        let menu = grid.rowMenu(row: 0, displayColumn: 0)
        let submenu = try #require(CommandRows.item(String(localized: "Set Value"), in: menu)?.submenu)

        grid.perform(try #require(CommandRows.item("Generate UUID", in: submenu)))

        let staged = try #require(grid.owner.staged(0, 0)?.value.asText)
        #expect(staged == staged.lowercased())
        #expect(UUID(uuidString: staged) != nil)
        #expect(grid.owner.tableRows.rows[0].values[0] == .text(staged))
    }

    @Test("A NOT NULL number with no default still offers Set Cells to Value, alone")
    func typedValueIsTheOnlyItemOnANotNullNumber() {
        let grid = menuGrid(
            columns: ["id", "qty"],
            columnTypes: [.integer(rawType: "int4"), .integer(rawType: "int4")],
            rows: [[.text("1"), .text("5")]],
            columnNullable: ["id": false, "qty": false]
        )

        #expect(setValueTitles(grid, column: 1) == ["Set Cells to Value…"])
    }

    @Test("A read-only grid has no Set Value at all")
    func readOnlyGridOffersNothing() {
        let grid = uuidKeyGrid()
        grid.model.configuration.isEditable = false

        #expect(CommandRows.item(String(localized: "Set Value"), in: grid.rowMenu(row: 0, displayColumn: 1)) == nil)
    }
}

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct DataGridSetValuePasteTests {
        private typealias Fixture = SetValueFixture

        private func paste(into grid: CommandGrid, row: Int, column: Int) {
            grid.selectCell(row, column)
            grid.controller.paste(nil)
        }

        @Test("A function name pasted into a timestamp cell stages its SQL")
        func pastedFunctionIsPromoted() throws {
            try #require(RecordingClipboard.current).text = "current_timestamp"
            let grid = Fixture.grid()

            paste(into: grid, row: 1, column: Fixture.seen)

            #expect(grid.owner.staged(1, Fixture.seen)?.value == .text("CURRENT_TIMESTAMP"))
            #expect(grid.owner.staged(1, Fixture.seen)?.isExpression == true)
        }

        @Test("A staged function copied from the grid pastes as SQL, whichever column it lands in")
        func copiedExpressionPastesAsSQL() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = Fixture.grid()
            grid.commands.applySetValue(.expression(try Fixture.now()), to: Fixture.cells(grid, [(0, Fixture.seen)]))

            grid.selectCell(0, Fixture.seen)
            grid.controller.copy(nil)
            #expect(clipboard.gridCells?.expressionFields == [0: [0]])
            paste(into: grid, row: 1, column: Fixture.note)

            #expect(grid.owner.staged(1, Fixture.note)?.value == .text("now()"))
            #expect(grid.owner.staged(1, Fixture.note)?.isExpression == true)
        }

        @Test("Stored text that spells a function, copied from the grid, pastes as the same text")
        func copiedLiteralIsNotPromoted() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = Fixture.grid()
            _ = grid.owner.tableRows.edit(row: 0, column: Fixture.seen, value: .text("CURRENT_TIMESTAMP"))
            grid.model.reloadRows()

            grid.selectCell(0, Fixture.seen)
            grid.controller.copy(nil)
            #expect(clipboard.gridCells?.expressionFields == nil)
            paste(into: grid, row: 1, column: Fixture.seen)

            #expect(grid.owner.staged(1, Fixture.seen)?.value == .text("CURRENT_TIMESTAMP"))
            #expect(grid.owner.staged(1, Fixture.seen)?.isExpression == false)
        }

        @Test("A copied block marks only the fields that held staged SQL")
        func copiedBlockMarksEachField() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = Fixture.grid()
            grid.commands.applySetValue(.expression(try Fixture.now()), to: Fixture.cells(grid, [(0, Fixture.seen)]))
            grid.select(rows: 0...0, columns: Fixture.note...Fixture.seen, active: GridCoord(row: 0, displayColumn: Fixture.note))

            grid.controller.copy(nil)
            #expect(clipboard.gridCells?.fields == [["n0", "l0", "now()"]])
            #expect(clipboard.gridCells?.expressionFields == [0: [2]])
            paste(into: grid, row: 2, column: Fixture.note)

            #expect(grid.owner.staged(2, Fixture.seen)?.isExpression == true)
            #expect(grid.owner.staged(2, Fixture.note)?.isExpression == false)
        }
    }
}
