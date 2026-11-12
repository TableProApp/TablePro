import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct RowOperationsManagerPasteTests {
    private static let columns = ["id", "name", "email"]

    private func makeManager() -> RowOperationsManager {
        let changeManager = DataChangeManager()
        changeManager.configureForTable(
            tableName: "users",
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        return RowOperationsManager(changeManager: changeManager)
    }

    // `id` is AUTO_INCREMENT, so the server fills it.
    private func emptyRows() -> TableRows {
        let types: [ColumnType] = Array(repeating: .text(rawType: nil), count: Self.columns.count)
        return TableRows.from(queryRows: [], columns: Self.columns, columnTypes: types, columnIdentity: ["id": .byDefault])
    }

    private func pasteRows(_ clipboard: RecordingClipboard, manager: RowOperationsManager) -> [[PluginCellValue]] {
        var rows = emptyRows()
        let result = manager.pasteRowsFromClipboard(
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            tableRows: &rows,
            clipboard: clipboard
        )
        return result.pastedRows.map { $0.values }
    }

    private func pasteValues(_ clipboard: RecordingClipboard, manager: RowOperationsManager) -> [PluginCellValue] {
        pasteRows(clipboard, manager: manager).first ?? []
    }

    @Test("Structured grid rows preserve comma-containing values")
    func structuredPreservesCommas() {
        let clipboard = RecordingClipboard()
        clipboard.gridRows = GridRowsClipboardPayload(
            columns: Self.columns,
            rows: [[.text("7"), .text("Smith, John"), .text("a@test.com")]]
        )

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values.count == 3)
        #expect(values[0] == .columnDefault)
        #expect(values[1] == .text("Smith, John"))
        #expect(values[2] == .text("a@test.com"))
    }

    @Test("Structured grid rows distinguish a real NULL from the literal string NULL")
    func structuredDistinguishesNull() {
        let clipboard = RecordingClipboard()
        clipboard.gridRows = GridRowsClipboardPayload(
            columns: Self.columns,
            rows: [[.text("7"), .text("NULL"), .null]]
        )

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values[1] == .text("NULL"))
        #expect(values[2] == .null)
    }

    @Test("Cells the grid copied as wide as the table paste field by field, NULL and line breaks kept")
    func copiedCellsPasteFieldByField() {
        let clipboard = RecordingClipboard()
        clipboard.writeCells(GridCellsClipboardPayload(
            text: "7\tSmith\nJohn\tNULL",
            fields: [["7", "Smith\nJohn", nil]]
        ))

        let rows = pasteRows(clipboard, manager: makeManager())

        #expect(rows.count == 1)
        #expect(rows.first?[1] == .text("Smith\nJohn"))
        #expect(rows.first?[2] == .null)
    }

    @Test("A binary column takes back the bytes a copy wrote as hex, from the grid's cells and from text")
    func copiedHexPastesAsBytes() {
        var types: [ColumnType] = Array(repeating: .text(rawType: nil), count: Self.columns.count)
        types[2] = .blob(rawType: "varbinary(16)")
        let manager = makeManager()

        let cells = RecordingClipboard()
        cells.writeCells(GridCellsClipboardPayload(text: "7\tAnn\t0x4142", fields: [["7", "Ann", "0x4142"]]))
        var rows = TableRows.from(queryRows: [], columns: Self.columns, columnTypes: types)
        let fromCells = manager.pasteRowsFromClipboard(
            columns: Self.columns, primaryKeyColumns: ["id"], tableRows: &rows, clipboard: cells
        )
        #expect(fromCells.pastedRows.first?.values[2] == .bytes(Data([0x41, 0x42])))

        let text = RecordingClipboard()
        text.text = "7\t0x41\t0x00FF\n8\tBo\t0x"
        let fromText = manager.pasteRowsFromClipboard(
            columns: Self.columns, primaryKeyColumns: ["id"], tableRows: &rows, clipboard: text
        )
        #expect(fromText.pastedRows.map { $0.values[1] } == [.text("0x41"), .text("Bo")])
        #expect(fromText.pastedRows.map { $0.values[2] } == [.bytes(Data([0x00, 0xFF])), .bytes(Data())])
    }

    @Test("A binary field that starts with 0x but is not hex, such as a copy cut short, pastes nothing")
    func brokenHexRefusesThePaste() {
        var types: [ColumnType] = Array(repeating: .text(rawType: nil), count: Self.columns.count)
        types[2] = .blob(rawType: "varbinary(16)")
        var rows = TableRows.from(queryRows: [], columns: Self.columns, columnTypes: types)
        let clipboard = RecordingClipboard()
        clipboard.text = "7\tAnn\t0x4142\n8\tBo\t0x41…"

        let result = makeManager().pasteRowsFromClipboard(
            columns: Self.columns, primaryKeyColumns: ["id"], tableRows: &rows, clipboard: clipboard
        )

        #expect(result.pastedRows.isEmpty)
        #expect(rows.count == 0)
    }

    @Test("Copied cells stale against the clipboard's text are not used")
    func staleCopiedCellsAreIgnored() {
        let clipboard = RecordingClipboard()
        clipboard.text = "7\tAnn\tann@test.com"
        clipboard.gridCells = GridCellsClipboardPayload(text: "other", fields: [["7", "Bob", nil]])

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values[1] == .text("Ann"))
    }

    @Test("Structured payload wins over plain text when both are present")
    func structuredPreferredOverText() {
        let clipboard = RecordingClipboard()
        clipboard.gridRows = GridRowsClipboardPayload(
            columns: Self.columns,
            rows: [[.text("7"), .text("structured"), .text("x@test.com")]]
        )
        clipboard.text = "7\twrong\twrong@test.com"

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values[1] == .text("structured"))
    }

    @Test("Structured grid rows map source columns to destination by name when reordered")
    func structuredMapsByColumnName() {
        let clipboard = RecordingClipboard()
        clipboard.gridRows = GridRowsClipboardPayload(
            columns: ["email", "id", "name"],
            rows: [[.text("e@x.com"), .text("9"), .text("Jo")]]
        )

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values[0] == .columnDefault)
        #expect(values[1] == .text("Jo"))
        #expect(values[2] == .text("e@x.com"))
    }

    @Test("Destination columns absent from the source fill with NULL (e.g. a hidden column copy)")
    func structuredFillsMissingColumnsWithNull() {
        let clipboard = RecordingClipboard()
        clipboard.gridRows = GridRowsClipboardPayload(
            columns: ["name", "email"],
            rows: [[.text("Jo"), .text("e@x.com")]]
        )

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values.count == 3)
        #expect(values[0] == .columnDefault)
        #expect(values[1] == .text("Jo"))
        #expect(values[2] == .text("e@x.com"))
    }

    @Test("Unrelated source columns fall back to positional mapping")
    func structuredFallsBackToPositional() {
        let clipboard = RecordingClipboard()
        clipboard.gridRows = GridRowsClipboardPayload(
            columns: ["a", "b", "c"],
            rows: [[.text("1"), .text("2"), .text("3")]]
        )

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values[0] == .columnDefault)
        #expect(values[1] == .text("2"))
        #expect(values[2] == .text("3"))
    }

    @Test("Structured payload pastes multiple rows")
    func structuredPastesMultipleRows() {
        let clipboard = RecordingClipboard()
        clipboard.gridRows = GridRowsClipboardPayload(
            columns: Self.columns,
            rows: [
                [.text("1"), .text("Alice"), .text("a@test.com")],
                [.text("2"), .text("Bob"), .null],
            ]
        )

        let rows = pasteRows(clipboard, manager: makeManager())

        #expect(rows.count == 2)
        #expect(rows[0] == [.columnDefault, .text("Alice"), .text("a@test.com")])
        #expect(rows[1] == [.columnDefault, .text("Bob"), .null])
    }

    @Test("Plain-text TSV with commas inside a value parses as TSV, not CSV")
    func textTSVWithCommasParsesAsTSV() {
        let clipboard = RecordingClipboard()
        clipboard.text = "7\tMozilla/5.0 (KHTML, like Gecko) Safari\ta@test.com"

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values.count == 3)
        #expect(values[0] == .columnDefault)
        #expect(values[1] == .text("Mozilla/5.0 (KHTML, like Gecko) Safari"))
        #expect(values[2] == .text("a@test.com"))
    }

    @Test("detectParser picks TSV when a tab is present even alongside commas")
    func detectParserTabWins() {
        #expect(RowOperationsManager.detectParser(for: "a\tb,c") is TSVRowParser)
        #expect(RowOperationsManager.detectParser(for: "a,b\tc") is TSVRowParser)
    }

    @Test("detectParser picks CSV only when commas appear without tabs")
    func detectParserCsvWhenNoTabs() {
        #expect(RowOperationsManager.detectParser(for: "a,b,c") is CSVRowParser)
    }

    @Test("detectParser defaults to TSV for single-column text")
    func detectParserDefaultsToTSV() {
        #expect(RowOperationsManager.detectParser(for: "single") is TSVRowParser)
    }
}

// A key the server cannot fill keeps the pasted value: reset to DEFAULT it went out as NULL.
@MainActor
struct RowOperationsManagerPasteKeyTests {
    private static let columns = ["sku", "name"]

    private func paste(
        _ clipboard: RecordingClipboard,
        databaseType: DatabaseType = .postgresql,
        declaredTypes: [String: String] = [:],
        defaults: [String: String?] = [:],
        uuidKeyForms: [Int: UUIDCellForm] = [:]
    ) -> [[PluginCellValue]] {
        let changeManager = DataChangeManager()
        changeManager.configureForTable(
            tableName: "products",
            columns: Self.columns,
            primaryKeyColumns: ["sku"],
            databaseType: databaseType,
            generatedColumns: []
        )
        var rows = TableRows.from(
            queryRows: [],
            columns: Self.columns,
            columnTypes: Array(repeating: .text(rawType: "VARCHAR"), count: Self.columns.count),
            columnDefaults: defaults,
            columnNullable: ["sku": false],
            columnDeclaredTypes: declaredTypes
        )
        let result = RowOperationsManager(changeManager: changeManager).pasteRowsFromClipboard(
            columns: Self.columns,
            primaryKeyColumns: ["sku"],
            tableRows: &rows,
            uuidKeyForms: uuidKeyForms,
            clipboard: clipboard
        )
        return result.pastedRows.map(\.values)
    }

    @Test("Pasted text keeps a natural key")
    func textKeepsNaturalKey() {
        let clipboard = RecordingClipboard()
        clipboard.text = "SKU-1\tLamp\nSKU-2\tDesk"

        let keys = paste(clipboard).map { $0.first }

        #expect(keys == [PluginCellValue.text("SKU-1"), PluginCellValue.text("SKU-2")])
    }

    @Test("Pasted CSV keeps a natural key")
    func csvKeepsNaturalKey() {
        let clipboard = RecordingClipboard()
        clipboard.text = "SKU-1,Lamp"

        #expect(paste(clipboard).first?.first == .text("SKU-1"))
    }

    @Test("Structured rows keep a natural key")
    func structuredKeepsNaturalKey() {
        let clipboard = RecordingClipboard()
        clipboard.gridRows = GridRowsClipboardPayload(columns: Self.columns, rows: [[.text("SKU-1"), .text("Lamp")]])

        #expect(paste(clipboard).first == [.text("SKU-1"), .text("Lamp")])
    }

    @Test("Copied cells keep a natural key")
    func copiedCellsKeepNaturalKey() {
        let clipboard = RecordingClipboard()
        clipboard.writeCells(GridCellsClipboardPayload(text: "SKU-1\tLamp", fields: [["SKU-1", "Lamp"]]))

        #expect(paste(clipboard).first?.first == .text("SKU-1"))
    }

    @Test("A SQLite INTEGER PRIMARY KEY is the rowid, so the server fills it")
    func sqliteRowidKeyGoesToTheServer() {
        let clipboard = RecordingClipboard()
        clipboard.text = "7\tLamp"

        let rows = paste(clipboard, databaseType: .sqlite, declaredTypes: ["sku": "INTEGER"])

        #expect(rows.first?.first == .columnDefault)
    }

    @Test("A SQLite TEXT key is not the rowid and keeps the pasted value")
    func sqliteTextKeyIsKept() {
        let clipboard = RecordingClipboard()
        clipboard.text = "SKU-1\tLamp"

        let rows = paste(clipboard, databaseType: .sqlite, declaredTypes: ["sku": "TEXT"])

        #expect(rows.first?.first == .text("SKU-1"))
    }

    @Test("A key whose default calls a function goes to the server; a constant default does not replace the pasted key")
    func onlyAFunctionDefaultFillsTheKey() {
        let clipboard = RecordingClipboard()
        clipboard.text = "SKU-1\tLamp"

        #expect(paste(clipboard, defaults: ["sku": "gen_random_uuid()"]).first?.first == .columnDefault)
        #expect(paste(clipboard, defaults: ["sku": "(newid())"]).first?.first == .columnDefault)
        #expect(paste(clipboard, defaults: ["sku": "'X'::text"]).first?.first == .text("SKU-1"))
        #expect(paste(clipboard, defaults: ["sku": "((1))"]).first?.first == .text("SKU-1"))
        #expect(paste(clipboard, defaults: ["sku": "(NEXT VALUE FOR [sku_seq])"]).first?.first == .columnDefault)
        #expect(paste(clipboard, defaults: ["sku": "\"SKU_SEQ\".\"NEXTVAL\""]).first?.first == .columnDefault)
        #expect(paste(clipboard, defaults: ["sku": "now()"]).first?.first == .text("SKU-1"))
        #expect(paste(clipboard, defaults: ["sku": "(getdate())"]).first?.first == .text("SKU-1"))
        #expect(paste(clipboard, defaults: ["sku": "timezone('utc'::text, now())"]).first?.first == .text("SKU-1"))
    }

    @Test("A blank key that refuses NULL stays NULL rather than an empty string")
    func blankKeyIsNotEmptyText() {
        let clipboard = RecordingClipboard()
        clipboard.text = "\tLamp"

        #expect(paste(clipboard).first?.first == .null)
    }

    @Test("A UUID key the server does not fill takes a fresh UUID on every pasted row")
    func uuidKeyTakesAFreshUUID() {
        let clipboard = RecordingClipboard()
        clipboard.text = "\tLamp\n6f1c2b0e-3c1a-4d0e-9a7b-1f2e3d4c5b6a\tDesk"

        let rows = paste(clipboard, uuidKeyForms: [0: .hyphenated])

        let keys = rows.compactMap { $0.first?.asText }
        #expect(keys.count == 2)
        #expect(keys.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(!keys.contains("6f1c2b0e-3c1a-4d0e-9a7b-1f2e3d4c5b6a"))
    }

    @Test("CSV keeps the spaces inside a quoted field")
    func csvKeepsQuotedSpaces() {
        let clipboard = RecordingClipboard()
        clipboard.text = "SKU-1,\"  indented note  \""

        #expect(paste(clipboard).first?.last == .text("  indented note  "))
    }
}

@MainActor
struct RowOperationsManagerDuplicateRowsTests {
    @Test("Duplicating several rows copies each of them in one undo step")
    func duplicatesEverySelectedRow() {
        let changeManager = DataChangeManager()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        changeManager.undoManagerProvider = { undoManager }
        changeManager.configureForTable(
            tableName: "t",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: []
        )
        var rows = TableRows.from(
            queryRows: [[.text("1"), .text("a")], [.text("2"), .text("b")], [.text("3"), .text("c")]],
            columns: ["id", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )

        let result = RowOperationsManager(changeManager: changeManager)
            .duplicateRows(sourceRowIndices: [0, 1, 2], tableRows: &rows)

        #expect(result.rows.count == 3)
        #expect(result.rows.map { $0.values[1] } == [.text("a"), .text("b"), .text("c")])
        #expect(result.rows.allSatisfy { $0.values[0] == .columnDefault })
        #expect(rows.count == 6)
        #expect(changeManager.insertedRowIDs.count == 3)

        undoManager.undo()
        #expect(changeManager.insertedRowIDs.isEmpty)
        #expect(!undoManager.canUndo)
    }
}

/// A pasted row arrives whole, so it carries values for columns the server owns. Those never reach
/// the cell-edit boundary that refuses them, and `SQLStatementGenerator` drops them without a word,
/// so the grid showed a pasted identity value the row was never saved with.
@MainActor
struct RowOperationsManagerPasteServerOwnedTests {
    private static let columns = ["id", "code", "name"]

    private func makeManager() -> RowOperationsManager {
        let changeManager = DataChangeManager()
        changeManager.configureForTable(
            tableName: "t",
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: []
        )
        return RowOperationsManager(changeManager: changeManager)
    }

    private func paste(
        _ payload: GridRowsClipboardPayload,
        columnIdentity: [String: IdentityKind] = [:],
        generatedColumns: Set<String> = []
    ) -> [PluginCellValue] {
        let clipboard = RecordingClipboard()
        clipboard.gridRows = payload
        var rows = TableRows.from(
            queryRows: [],
            columns: Self.columns,
            columnTypes: Array(repeating: .text(rawType: nil), count: Self.columns.count),
            columnIdentity: columnIdentity,
            generatedColumns: generatedColumns
        )
        let result = makeManager().pasteRowsFromClipboard(
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            tableRows: &rows,
            clipboard: clipboard
        )
        return result.pastedRows.first?.values ?? []
    }

    private var payload: GridRowsClipboardPayload {
        GridRowsClipboardPayload(
            columns: Self.columns,
            rows: [[.text("7"), .text("42"), .text("Ada")]]
        )
    }

    @Test("A pasted identity column that is not the primary key is reset to DEFAULT")
    func resetsNonKeyIdentity() {
        let values = paste(payload, columnIdentity: ["code": .always])

        #expect(values[1] == .columnDefault)
        #expect(values[2] == .text("Ada"))
    }

    @Test("A pasted generated column is reset to DEFAULT")
    func resetsGeneratedColumn() {
        let values = paste(payload, generatedColumns: ["code"])

        #expect(values[1] == .columnDefault)
        #expect(values[2] == .text("Ada"))
    }

    @Test("An ordinary column keeps the pasted value")
    func keepsOrdinaryColumn() {
        let values = paste(payload)

        #expect(values[1] == .text("42"))
        #expect(values[2] == .text("Ada"))
    }
}
