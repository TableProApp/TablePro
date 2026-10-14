import Foundation
@testable import TableProTabular
import TableProTabularIO
import Testing

struct TabularTableTests {
    static func delimitedSource(_ text: String, dialect: DelimitedDialect = DelimitedDialect()) async throws -> DelimitedSource {
        try await DelimitedSourceBuilder.build(
            bytes: Data(text.utf8),
            dialect: dialect,
            byteEncoding: .utf8,
            contentStart: 0
        )
    }

    @Test func testHeaderRowNamesColumnsAndIsNotAData() async throws {
        let source = try await Self.delimitedSource("name,age\nAlice,30\nBob,41\n")
        let table = TabularTable(source: source, usesFirstRowAsHeader: true)
        #expect(table.columns.map(\.name) == ["name", "age"])
        #expect(table.rowCount == 2)
        #expect(table.cells(row: 1).map(\.text) == ["Bob", "41"])
    }

    @Test func testRaggedRowsWidenTheTable() async throws {
        let source = try await Self.delimitedSource("name,age\nAlice,30,extra\nBob,41\n")
        let table = TabularTable(source: source, usesFirstRowAsHeader: true)
        #expect(table.columnCount == 3)
        #expect(table.columns.map(\.name) == ["name", "age", ""])
        #expect(table.cells(row: 0).map(\.text) == ["Alice", "30", "extra"])
        #expect(table.cells(row: 1).map(\.text) == ["Bob", "41", ""])
        #expect(source.raggedRowCount == 1)
    }

    @Test func testEditsOverrideTheSourceAndScanSeesThem() async throws {
        let source = try await Self.delimitedSource("a,b\n1,2\n3,4\n")
        var table = TabularTable(source: source, usesFirstRowAsHeader: true)
        table.setCell(.text("9"), row: 1, column: 1)
        var seen: [[String]] = []
        table.scan(columns: table.columnIDs, rows: 0..<table.rowCount) { _, cells in
            seen.append((0..<cells.count).map { cells.string(at: $0) })
            return true
        }
        #expect(seen == [["1", "2"], ["3", "9"]])
    }

    @Test func testInsertedRowsAndColumnsScanInLogicalOrder() async throws {
        let source = try await Self.delimitedSource("a\n1\n2\n")
        var table = TabularTable(source: source, usesFirstRowAsHeader: true)
        table.insertRows([[.text("new")]], at: 1)
        let id = table.insertColumn(named: "b", at: 1)
        table.setCell(.text("x"), row: 0, column: 1)
        var seen: [[String]] = []
        table.scan(columns: [table.columns[0].id, id], rows: 0..<table.rowCount) { _, cells in
            seen.append((0..<cells.count).map { cells.string(at: $0) })
            return true
        }
        #expect(seen == [["1", "x"], ["new", ""], ["2", ""]])
    }

    @Test func testTogglingTheHeaderRowKeepsRenamedNames() async throws {
        let source = try await Self.delimitedSource("a,b\n1,2\n")
        var table = TabularTable(source: source, usesFirstRowAsHeader: true)
        table.renameColumn(table.columns[0].id, to: "renamed")
        table.setUsesFirstRowAsHeader(false)
        #expect(table.rowCount == 2)
        #expect(table.cells(row: 0).map(\.text) == ["renamed", "b"])
        table.setUsesFirstRowAsHeader(true)
        #expect(table.columns.map(\.name) == ["renamed", "b"])
        #expect(table.rowCount == 1)
    }
}
