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
    private func loaded(_ text: String, fileExtension: String = "csv") async throws -> (DataFileController, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataFileControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("people.\(fileExtension)")
        try Data(text.utf8).write(to: url)
        let controller = DataFileController()
        controller.undoManager = UndoManager()
        let kind = try #require(DataFileKind.classify(url))
        controller.load(url: url, kind: kind)
        await controller.waitForPendingWork()
        #expect(controller.loadState == .loaded)
        return (controller, url)
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
        controller.filterState.filters = [TableFilter(columnName: "city", filterOperator: .equal, value: "london")]
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
            progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: snapshot.url) }
        #expect(snapshot.formatId == "csv")
        #expect(try String(contentsOf: snapshot.url, encoding: .utf8) == "amount,amount (2)\n2,x;y\n")
    }
}
