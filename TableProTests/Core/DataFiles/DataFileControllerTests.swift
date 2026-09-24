//
//  DataFileControllerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTabular
import TableProTabularIO
import Testing

@MainActor
@Suite("Data file controller")
struct DataFileControllerTests {
    private let undoManager = UndoManager()

    private func loaded(_ text: String, fileExtension: String = "csv") async throws -> (DataFileController, URL) {
        try await loaded(data: Data(text.utf8), fileExtension: fileExtension)
    }

    private func loaded(data: Data, fileExtension: String) async throws -> (DataFileController, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataFileControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("people.\(fileExtension)")
        try data.write(to: url)
        let controller = DataFileController()
        controller.undoManager = undoManager
        let kind = try #require(DataFileKind.classify(url))
        controller.load(url: url, kind: kind)
        await controller.waitForPendingWork()
        #expect(controller.loadState == .loaded)
        return (controller, url)
    }

    private func loaded(workbook base64: String) async throws -> DataFileController {
        let data = try #require(Data(base64Encoded: base64))
        let (controller, _) = try await loaded(data: data, fileExtension: "xlsx")
        return controller
    }

    private func column(_ controller: DataFileController, _ index: Int) -> [String] {
        controller.tableRows.rows.map { row in
            guard case .text(let text) = row.values[index] else { return "" }
            return text
        }
    }

    @Test("Opening a CSV shows its header and rows")
    func opensCSV() async throws {
        let (controller, _) = try await loaded("name,age\nAlice,30\nBob,41\n")
        #expect(controller.columnNames.displayNames == ["name", "age"])
        #expect(column(controller, 0) == ["Alice", "Bob"])
        #expect(controller.inferredKinds[controller.columnNames.ids[1]] == .integer)
    }

    @Test("Duplicate and empty headers get unique display names")
    func uniqueDisplayNames() async throws {
        let (controller, _) = try await loaded("amount,amount,,name\n1,2,3,x\n")
        #expect(controller.columnNames.displayNames == ["amount", "amount (2)", "Column 3", "name"])
    }

    @Test("An edit under a filter lands on the row the user sees")
    func editUnderFilterTargetsTheVisibleRow() async throws {
        let (controller, _) = try await loaded("name,city\nA,Paris\nB,London\nC,Paris\n")
        controller.filterState.filters = [TableFilter(columnName: "city", filterOperator: .equal, value: "London")]
        controller.applyAllFilters()
        await controller.waitForPendingWork()
        #expect(column(controller, 0) == ["B"])
        controller.setCell(pageRow: 0, column: 1, text: "Rome")
        let table = try #require(controller.table)
        #expect(table.cells(row: 0).map(\.text) == ["A", "Paris"])
        #expect(table.cells(row: 1).map(\.text) == ["B", "Rome"])
        #expect(column(controller, 1) == ["Rome"])
    }

    @Test("Deleting a row under a sort removes that row and keeps the order")
    func deleteUnderSortTargetsTheVisibleRow() async throws {
        let (controller, _) = try await loaded("n\n3\n1\n2\n")
        controller.updateSort(SortState(columns: [SortColumn(columnIndex: 0, direction: .ascending)]))
        await controller.waitForPendingWork()
        #expect(column(controller, 0) == ["1", "2", "3"])
        _ = controller.deleteRows(pageRows: [1])
        #expect(column(controller, 0) == ["1", "3"])
        #expect(controller.table?.rowCount == 2)
    }

    @Test("Undo restores an edit and redo applies it again")
    func undoAndRedo() async throws {
        let (controller, _) = try await loaded("a\nx\n")
        controller.setCell(pageRow: 0, column: 0, text: "y")
        #expect(column(controller, 0) == ["y"])
        controller.undoManager?.undo()
        #expect(column(controller, 0) == ["x"])
        controller.undoManager?.redo()
        #expect(column(controller, 0) == ["y"])
    }

    @Test("Changing the query goes back to the first page")
    func queryChangeResetsPage() async throws {
        let rows = (1...30).map { "row\($0)" }.joined(separator: "\n")
        let (controller, _) = try await loaded("v\n" + rows + "\n")
        controller.pageSize = 10
        controller.goToPage(offsetBy: 2)
        #expect(controller.pageOffset == 20)
        controller.searchText = "row1"
        controller.runQuery()
        await controller.waitForPendingWork()
        #expect(controller.pageOffset == 0)
    }

    @Test("Pasting rows wider than the table adds columns")
    func pasteWiderAddsColumns() async throws {
        let (controller, _) = try await loaded("a,b\n1,2\n")
        controller.pasteRows([["3", "4", "5"]])
        #expect(controller.columnNames.count == 3)
        #expect(controller.table?.cells(row: 1).map(\.text) == ["3", "4", "5"])
    }

    @Test("Replace All is one undo step")
    func replaceAllIsOneUndoStep() async throws {
        let (controller, _) = try await loaded("a\nfoo\nfoo bar\nbaz\n")
        controller.find.text = "foo"
        controller.find.replacement = "qux"
        controller.replaceAll()
        await controller.waitForPendingWork()
        #expect(column(controller, 0) == ["qux", "qux bar", "baz"])
        controller.undoManager?.undo()
        #expect(column(controller, 0) == ["foo", "foo bar", "baz"])
    }

    @Test("Undoing Replace All finds the restored matches again")
    func undoRefreshesFind() async throws {
        let (controller, _) = try await loaded("a\nfoo\nfoo bar\nbaz\n")
        controller.showFind(replacing: true)
        controller.find.text = "foo"
        controller.runFind()
        await controller.waitForPendingWork()
        #expect(controller.find.matches.count == 2)
        controller.find.replacement = "qux"
        controller.replaceAll()
        await controller.waitForPendingWork()
        #expect(controller.find.matches.isEmpty)
        controller.undoManager?.undo()
        await controller.waitForPendingWork()
        #expect(controller.find.matches.count == 2)
    }

    @Test("Cancel stops a running find")
    func cancelStopsFind() async throws {
        let (controller, _) = try await loaded("a\nfoo\n")
        controller.showFind(replacing: false)
        controller.find.text = "foo"
        controller.runFind()
        let running = try #require(controller.findTask)
        controller.cancelActivity()
        #expect(running.isCancelled)
        await controller.waitForPendingWork()
    }

    @Test("Saving writes untouched rows byte for byte and the edited row once")
    func saveRoundTrip() async throws {
        let (controller, url) = try await loaded("id,name\r\n1,\"Doe, Jane\"\r\n2,x")
        controller.setCell(pageRow: 1, column: 1, text: "y")
        let output = url.deletingLastPathComponent().appendingPathComponent("out.csv")
        try controller.write(to: output, typeName: DataFileKind.commaSeparatedType)
        let written = try String(contentsOf: output, encoding: .utf8)
        #expect(written == "id,name\r\n1,\"Doe, Jane\"\r\n2,y")
    }

    @Test("Saving as TSV writes tabs")
    func saveAsTabSeparated() async throws {
        let (controller, url) = try await loaded("a,b\n1,\"x,y\"\n")
        let output = url.deletingLastPathComponent().appendingPathComponent("out.tsv")
        try controller.write(to: output, typeName: DataFileKind.tabSeparatedType)
        #expect(try String(contentsOf: output, encoding: .utf8) == "a\tb\n1\tx,y\n")
    }

    @Test("A TSV with commas in its values opens tab-delimited")
    func tsvOpensWithTabs() async throws {
        let (controller, _) = try await loaded("name\taddress\nAnn\t1 Main St, Apt 4\n", fileExtension: "tsv")
        #expect(controller.columnNames.displayNames == ["name", "address"])
        #expect(column(controller, 1) == ["1 Main St, Apt 4"])
    }

    @Test("Every filter operator maps to an engine comparison", arguments: FilterOperator.allCases)
    func everyOperatorMaps(_ filterOperator: FilterOperator) {
        #expect(DataFileFilterMapping.comparison(for: filterOperator).rawValue.isEmpty == false)
    }

    @Test("A CSV column is not nullable, so a NULL edit writes an empty value")
    func csvColumnIsNotNullable() async throws {
        let (controller, _) = try await loaded("a\nx\n")
        #expect(controller.tableRows.columnNullable["a"] == false)
        controller.setCell(pageRow: 0, column: 0, text: nil)
        #expect(controller.table?.cells(row: 0) == [.text("")])
    }

    @Test("CSV cells are never NULL")
    func nullSemantics() async throws {
        let (controller, _) = try await loaded("a\n\nNULL\n")
        controller.filterState.filters = [TableFilter(columnName: "a", filterOperator: .isNull)]
        controller.applyAllFilters()
        await controller.waitForPendingWork()
        #expect(controller.visibleRowCount == 0)
    }

    private func streamedRows(_ source: DataFileExportDataSource) async throws -> (PluginStreamHeader?, [[String]]) {
        var header: PluginStreamHeader?
        var rows: [[String]] = []
        for try await element in source.streamRows(table: "", databaseName: "") {
            switch element {
            case .header(let value):
                header = value
            case .rows(let batch):
                rows += batch.map { row in row.map { $0.asText ?? "NULL" } }
            }
        }
        return (header, rows)
    }

    @Test("Export offers filtered rows when a filter is on and streams them in display order")
    func exportFilteredRows() async throws {
        let (controller, _) = try await loaded("name,city\nA,Paris\nB,London\nC,Paris\n")
        controller.filterState.filters = [TableFilter(columnName: "city", filterOperator: .equal, value: "Paris")]
        controller.applyAllFilters()
        await controller.waitForPendingWork()
        controller.updateSort(SortState(columns: [SortColumn(columnIndex: 0, direction: .descending)]))
        await controller.waitForPendingWork()
        let request = try #require(controller.exportRequest(title: "people.csv", suggestedFileName: "people"))
        #expect(request.scopes.map(\.id) == [DataFileExportScopeID.all, DataFileExportScopeID.filtered])
        #expect(request.initialScope?.id == DataFileExportScopeID.filtered)
        #expect(request.initialScope?.rowCount == 2)
        let source = try #require(request.initialScope?.makeDataSource() as? DataFileExportDataSource)
        let (header, rows) = try await streamedRows(source)
        #expect(header?.columns == ["name", "city"])
        #expect(rows == [["C", "Paris"], ["A", "Paris"]])
    }

    @Test("Export of all rows includes unsaved edits and spans batches")
    func exportAllRowsAcrossBatches() async throws {
        let count = DataFileExportDataSource.batchSize + 5
        let body = (0..<count).map { "\($0)" }.joined(separator: "\n")
        let (controller, _) = try await loaded("n\n" + body + "\n")
        controller.setCell(pageRow: 0, column: 0, text: "edited")
        let request = try #require(controller.exportRequest(title: "n.csv", suggestedFileName: "n"))
        let source = try #require(request.scope(withId: DataFileExportScopeID.all)?.makeDataSource() as? DataFileExportDataSource)
        let (_, rows) = try await streamedRows(source)
        #expect(rows.count == count)
        #expect(rows.first == ["edited"])
        #expect(rows.last == ["\(count - 1)"])
    }

    @Test("The import snapshot is UTF-8 CSV with the display header and unsaved edits")
    func importSnapshotWritesCSV() async throws {
        let (controller, _) = try await loaded("amount;amount\n1;\"x;y\"\n", fileExtension: "csv")
        controller.setCell(pageRow: 0, column: 0, text: "2")
        let table = try #require(controller.table)
        let snapshot = try await DataFileController.writeImportSnapshot(
            table: table,
            columns: controller.columnNames.ids,
            names: controller.columnNames.displayNames,
            format: .csv,
            progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: snapshot.url) }
        #expect(snapshot.formatId == "csv")
        #expect(try String(contentsOf: snapshot.url, encoding: .utf8) == "amount,amount (2)\n2,x;y\n")
    }

    private static let twoSheetWorkbook = [
        "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"
    ].joined()

    @Test("A workbook opens read-only on its first sheet and reads another sheet when chosen")
    func workbookSheets() async throws {
        let controller = try await loaded(workbook: Self.twoSheetWorkbook)
        #expect(controller.sheets.map(\.name) == ["People", "Cities"])
        #expect(!controller.isEditable)
        #expect(controller.columnNames.displayNames == ["name", "age"])
        #expect(column(controller, 0) == ["Ann", "Bob", "Cy"])
        #expect(controller.sheets[1].table == nil)
        controller.selectSheet(1)
        await controller.waitForPendingWork()
        #expect(controller.loadState == .loaded)
        #expect(controller.columnNames.displayNames == ["city"])
        #expect(controller.totalRowCount == 5)
        controller.selectSheet(0)
        #expect(column(controller, 0) == ["Ann", "Bob", "Cy"])
    }

    @Test("A workbook sheet saves as CSV")
    func workbookSavesAsCSV() async throws {
        let data = try #require(Data(base64Encoded: Self.twoSheetWorkbook))
        let (controller, url) = try await loaded(data: data, fileExtension: "xlsx")
        let output = url.deletingLastPathComponent().appendingPathComponent("people.csv")
        try controller.write(to: output, typeName: DataFileKind.commaSeparatedType)
        #expect(try String(contentsOf: output, encoding: .utf8) == "name,age\nAnn,31\nBob,42\nCy,27\n")
    }

    @Test("A JSON Lines file opens with its keys as columns and null as NULL")
    func opensJSONLines() async throws {
        let (controller, _) = try await loaded("{\"id\":1,\"name\":null}\n{\"id\":2,\"city\":\"Hue\"}\n", fileExtension: "jsonl")
        #expect(controller.columnNames.displayNames == ["id", "name", "city"])
        #expect(controller.tableRows.rows[0].values[1] == .null)
        #expect(controller.tableRows.columnNullable["name"] == true)
        #expect(controller.isEditable)
    }

    @Test("Saving a JSON Lines file rewrites only the edited member and keeps its type")
    func jsonEditKeepsType() async throws {
        let text = "{\"id\": 1, \"name\": \"Ann\"}\n{\"id\": 2, \"name\": \"Bob\"}\n"
        let (controller, url) = try await loaded(text, fileExtension: "jsonl")
        controller.setCell(pageRow: 1, column: 0, text: "20")
        let output = url.deletingLastPathComponent().appendingPathComponent("out.jsonl")
        try controller.write(to: output, typeName: DataFileKind.jsonLinesType)
        let written = try String(contentsOf: output, encoding: .utf8)
        #expect(written == "{\"id\": 1, \"name\": \"Ann\"}\n{\"id\": 20, \"name\": \"Bob\"}\n")
    }

    @Test("NULL and a number typed into a missing cell are written as JSON null and a number")
    func jsonNullAndTypedMissingCell() async throws {
        let (controller, url) = try await loaded("{\"n\":1,\"s\":\"a\"}\n{\"s\":\"b\"}\n", fileExtension: "jsonl")
        controller.setCell(pageRow: 0, column: 1, text: nil)
        controller.setCell(pageRow: 1, column: 0, text: "7")
        let output = url.deletingLastPathComponent().appendingPathComponent("out.jsonl")
        try controller.write(to: output, typeName: DataFileKind.jsonLinesType)
        let objects = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map { line in
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary
        }
        #expect(objects[0] == ["n": 1, "s": NSNull()])
        #expect(objects[1] == ["s": "b", "n": 7])
    }

    @Test("Renaming a column renames the key in every object")
    func jsonRenameColumn() async throws {
        let (controller, url) = try await loaded("[{\"a\":1},{\"a\":2}]", fileExtension: "json")
        controller.renameColumn(controller.columnNames.ids[0], to: "b")
        let output = url.deletingLastPathComponent().appendingPathComponent("out.json")
        try controller.write(to: output, typeName: DataFileKind.jsonType)
        #expect(try String(contentsOf: output, encoding: .utf8) == "[{\"b\":1},{\"b\":2}]")
    }

    @Test("A JSON array saves as JSON Lines")
    func jsonArraySavesAsLines() async throws {
        let (controller, url) = try await loaded("[{\"a\":1,\"b\":\"x\"}]", fileExtension: "json")
        let output = url.deletingLastPathComponent().appendingPathComponent("out.jsonl")
        try controller.write(to: output, typeName: DataFileKind.jsonLinesType)
        let line = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary == ["a": 1, "b": "x"])
    }

    @Test("A malformed JSON file names the row it failed on")
    func malformedJSONNamesTheRow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataFileControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("bad.jsonl")
        try Data("{\"a\":1}\n{\"a\":}\n".utf8).write(to: url)
        let controller = DataFileController()
        controller.load(url: url, kind: try #require(DataFileKind.classify(url)))
        await controller.waitForPendingWork()
        guard case .failed(let message) = controller.loadState else {
            Issue.record("Expected the load to fail")
            return
        }
        #expect(message.hasPrefix("Row 2 is not valid JSON"))
    }

    @Test("The import snapshot of a JSON file is JSON Lines with its nulls and numbers")
    func jsonImportSnapshot() async throws {
        let (controller, _) = try await loaded("{\"id\":1,\"note\":null}\n", fileExtension: "jsonl")
        #expect(controller.importFormat == .jsonLines)
        let table = try #require(controller.table)
        let snapshot = try await DataFileController.writeImportSnapshot(
            table: table,
            columns: controller.columnNames.ids,
            names: controller.columnNames.displayNames,
            format: controller.importFormat,
            progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: snapshot.url) }
        #expect(snapshot.formatId == "json")
        let line = try String(contentsOf: snapshot.url, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary == ["id": 1, "note": NSNull()])
    }

    @Test("A typed value picks its JSON kind from the cell it replaces or the column")
    func jsonKindRules() {
        #expect(DataFileController.jsonKind(for: "5", replacing: .missing, columnKind: .integer) == .number)
        #expect(DataFileController.jsonKind(for: "five", replacing: .missing, columnKind: .integer) == .text)
        #expect(DataFileController.jsonKind(for: "true", replacing: .null, columnKind: .boolean) == .boolean)
        #expect(DataFileController.jsonKind(for: "null", replacing: .missing, columnKind: .text) == .null)
        #expect(DataFileController.jsonKind(for: "{\"a\":1}", replacing: .object, columnKind: .text) == .object)
        #expect(DataFileController.jsonKind(for: "{broken", replacing: .object, columnKind: .text) == .text)
        #expect(DataFileController.jsonKind(for: "7", replacing: .text, columnKind: .integer) == .text)
    }
}
