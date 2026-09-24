import Foundation
@testable import TableProTabular
import TableProTabularIO
import XCTest

final class TabularTableJSONOutputTests: XCTestCase {
    private func source(_ text: String, kind: JSONTableFileKind = .jsonLines) async throws -> JSONSource {
        try await JSONSourceBuilder.build(bytes: Data(text.utf8), fileKind: kind)
    }

    private func typedLiteral(_ cell: TabularCell, _ column: TabularColumnID) throws -> String {
        try JSONValueTyping.literal(for: cell.text, originalKind: cell.kind)
    }

    private func written(_ table: TabularTable, source: JSONSource) throws -> String {
        let rows = table.jsonOutputRows(sourceKeys: source.keys, literal: typedLiteral)
        let writer = JSONTableWriter(source: source, keyChanges: table.jsonKeyChanges(sourceKeys: source.keys))
        let bytes = try writer.encoded(rows: rows)
        XCTAssertNil(rows.status.failure)
        return String(decoding: bytes, as: UTF8.self)
    }

    func testAnUntouchedTableWritesTheSourceBackByteForByte() async throws {
        let text = "{\"id\": 1, \"name\":\"Ann\"}\n{ \"id\":2 ,\"tags\":[1, 2]}\n"
        let source = try await source(text)
        let table = TabularTable(source: source, usesFirstRowAsHeader: false)
        XCTAssertEqual(try written(table, source: source), text)
    }

    func testAnEditedCellRewritesOnlyThatMemberAndKeepsItsType() async throws {
        let text = "{\"id\":1,\"name\":\"Ann\"}\n{\"id\":2,\"name\":\"Bob\"}\n"
        let source = try await source(text)
        var table = TabularTable(source: source, usesFirstRowAsHeader: false)
        table.setCells([(key: 1, columnID: table.columns[0].id, cell: TabularCell(kind: .number, text: "20"))])
        XCTAssertEqual(try written(table, source: source), "{\"id\":1,\"name\":\"Ann\"}\n{\"id\":20,\"name\":\"Bob\"}\n")
    }

    func testRenamedAndDeletedColumnsChangeEveryObject() async throws {
        let text = "{\"id\":1,\"name\":\"Ann\",\"x\":0}\n{\"id\":2,\"x\":1}\n"
        let source = try await source(text)
        var table = TabularTable(source: source, usesFirstRowAsHeader: false)
        table.renameColumn(table.columns[0].id, to: "key")
        table.deleteColumns([table.columns[2].id])
        XCTAssertEqual(try written(table, source: source), "{\"key\":1,\"name\":\"Ann\"}\n{\"key\":2}\n")
    }

    func testAnAddedColumnAppearsOnlyWhereItHasAValue() async throws {
        let source = try await source("{\"id\":1}\n{\"id\":2}\n")
        var table = TabularTable(source: source, usesFirstRowAsHeader: false)
        let added = table.insertColumn(named: "note", at: 1)
        table.setCells([(key: 1, columnID: added, cell: .text("hi"))])
        let output = try written(table, source: source)
        let objects = output.split(separator: "\n").map { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: AnyHashable]
        }
        XCTAssertEqual(objects[0], ["id": 1])
        XCTAssertEqual(objects[1], ["id": 2, "note": "hi"])
    }

    func testAnInsertedRowIsWrittenAsANewObject() async throws {
        let source = try await source("{\"id\":1,\"name\":\"Ann\"}\n")
        var table = TabularTable(source: source, usesFirstRowAsHeader: false)
        _ = table.insertRows([[TabularCell(kind: .number, text: "2"), .missing]], at: 1)
        let output = try written(table, source: source)
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "{\"id\":1,\"name\":\"Ann\"}")
        let inserted = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: AnyHashable])
        XCTAssertEqual(inserted, ["id": 2])
    }

    func testAnInvalidObjectEditStopsTheWriteAndSaysWhere() async throws {
        let source = try await source("{\"meta\":{\"a\":1}}\n{\"meta\":{}}\n")
        var table = TabularTable(source: source, usesFirstRowAsHeader: false)
        let column = table.columns[0].id
        table.setCells([(key: 1, columnID: column, cell: TabularCell(kind: .object, text: "{broken"))])
        let rows = table.jsonOutputRows(sourceKeys: source.keys, literal: typedLiteral)
        _ = try JSONTableWriter(source: source).encoded(rows: rows)
        XCTAssertEqual(rows.status.failure?.key, 1)
        XCTAssertEqual(rows.status.failure?.column, column)
    }

    func testRowsWithoutASourceAreAllNewObjects() async throws {
        let delimited = try await TabularTableTests.delimitedSource("a,b\n1,x\n")
        let table = TabularTable(source: delimited, usesFirstRowAsHeader: true)
        let rows = table.jsonOutputRows(sourceKeys: nil) { cell, _ in JSONText.stringLiteral(cell.text) }
        let output = String(decoding: try JSONTableWriter(shape: .array).encoded(rows: rows), as: UTF8.self)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: String]])
        XCTAssertEqual(parsed, [["a": "1", "b": "x"]])
    }

    func testReplaceAllKeepsAJSONNumberANumber() async throws {
        let source = try await source("{\"id\":1,\"name\":\"a1\"}\n")
        let table = TabularTable(source: source, usesFirstRowAsHeader: false)
        let query = TabularFindQuery(
            text: "1",
            matchesCase: false,
            matchesWholeWords: false,
            isRegularExpression: false,
            columns: table.columnIDs
        )
        let result = try await TabularFinder.replaceAll(query, with: "10", keys: table.rowOrder.keys, in: table)
        var updated = table
        for (id, values) in result.values {
            updated.replaceValues(of: id, with: values)
        }
        XCTAssertEqual(try written(updated, source: source), "{\"id\":10,\"name\":\"a10\"}\n")
    }
}
