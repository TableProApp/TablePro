import Foundation
@testable import TableProTabular
import TableProTabularIO
import XCTest

final class TabularTableTests: XCTestCase {
    static func delimitedSource(_ text: String, dialect: DelimitedDialect = DelimitedDialect()) async throws -> DelimitedSource {
        try await DelimitedSourceBuilder.build(
            bytes: Data(text.utf8),
            dialect: dialect,
            byteEncoding: .utf8,
            contentStart: 0
        )
    }

    func testHeaderRowNamesColumnsAndIsNotAData() async throws {
        let source = try await Self.delimitedSource("name,age\nAlice,30\nBob,41\n")
        let table = TabularTable(source: source, usesFirstRowAsHeader: true)
        XCTAssertEqual(table.columns.map(\.name), ["name", "age"])
        XCTAssertEqual(table.rowCount, 2)
        XCTAssertEqual(table.cells(row: 1).map(\.text), ["Bob", "41"])
    }

    func testRaggedRowsWidenTheTable() async throws {
        let source = try await Self.delimitedSource("name,age\nAlice,30,extra\nBob,41\n")
        let table = TabularTable(source: source, usesFirstRowAsHeader: true)
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.columns.map(\.name), ["name", "age", ""])
        XCTAssertEqual(table.cells(row: 0).map(\.text), ["Alice", "30", "extra"])
        XCTAssertEqual(table.cells(row: 1).map(\.text), ["Bob", "41", ""])
        XCTAssertEqual(source.raggedRowCount, 1)
    }

    func testEditsOverrideTheSourceAndScanSeesThem() async throws {
        let source = try await Self.delimitedSource("a,b\n1,2\n3,4\n")
        var table = TabularTable(source: source, usesFirstRowAsHeader: true)
        table.setCell(.text("9"), row: 1, column: 1)
        var seen: [[String]] = []
        table.scan(columns: table.columnIDs, rows: 0..<table.rowCount) { _, cells in
            seen.append((0..<cells.count).map { cells.string(at: $0) })
            return true
        }
        XCTAssertEqual(seen, [["1", "2"], ["3", "9"]])
    }

    func testInsertedRowsAndColumnsScanInLogicalOrder() async throws {
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
        XCTAssertEqual(seen, [["1", "x"], ["new", ""], ["2", ""]])
    }

    func testTogglingTheHeaderRowKeepsRenamedNames() async throws {
        let source = try await Self.delimitedSource("a,b\n1,2\n")
        var table = TabularTable(source: source, usesFirstRowAsHeader: true)
        table.renameColumn(table.columns[0].id, to: "renamed")
        table.setUsesFirstRowAsHeader(false)
        XCTAssertEqual(table.rowCount, 2)
        XCTAssertEqual(table.cells(row: 0).map(\.text), ["renamed", "b"])
        table.setUsesFirstRowAsHeader(true)
        XCTAssertEqual(table.columns.map(\.name), ["renamed", "b"])
        XCTAssertEqual(table.rowCount, 1)
    }
}
