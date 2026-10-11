import Foundation
@testable import TableProTabular
import TableProTabularIO
import XCTest

final class TabularTableJSONSourceTests: XCTestCase {
    private func table(_ text: String) async throws -> TabularTable {
        let source = try await JSONSourceBuilder.build(bytes: Data(text.utf8), fileKind: .jsonLines)
        return TabularTable(source: source, usesFirstRowAsHeader: true)
    }

    func testKeysNameTheColumnsAndNoRowIsTakenAsAHeader() async throws {
        let table = try await table("{\"id\":1,\"name\":\"Ann\"}\n{\"id\":2,\"city\":\"Hue\"}\n")
        XCTAssertNil(table.headerRowKey)
        XCTAssertEqual(table.columns.map(\.name), ["id", "name", "city"])
        XCTAssertEqual(table.rowCount, 2)
        XCTAssertEqual(table.cells(row: 1), [TabularCell(kind: .number, text: "2"), .missing, .text("Hue")])
    }

    func testScanCarriesKindsAndInsertedCellsReadAsMissing() async throws {
        var table = try await table("{\"a\":null,\"b\":true}\n{\"a\":\"x\"}\n")
        table.insertRows([[.text("new")]], at: 2)
        var seen: [[TabularCellKind]] = []
        table.scan(columns: table.columnIDs, rows: 0..<table.rowCount) { _, cells in
            seen.append(cells.kinds)
            return true
        }
        XCTAssertEqual(seen, [[.null, .boolean], [.text, .missing], [.text, .missing]])
    }
}
