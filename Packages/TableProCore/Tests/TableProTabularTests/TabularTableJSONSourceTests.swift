import Foundation
@testable import TableProTabular
import TableProTabularIO
import Testing

struct TabularTableJSONSourceTests {
    private func table(_ text: String) async throws -> TabularTable {
        let source = try await JSONSourceBuilder.build(bytes: Data(text.utf8), fileKind: .jsonLines)
        return TabularTable(source: source, usesFirstRowAsHeader: true)
    }

    @Test func testKeysNameTheColumnsAndNoRowIsTakenAsAHeader() async throws {
        let table = try await table("{\"id\":1,\"name\":\"Ann\"}\n{\"id\":2,\"city\":\"Hue\"}\n")
        #expect(table.headerRowKey == nil)
        #expect(table.columns.map(\.name) == ["id", "name", "city"])
        #expect(table.rowCount == 2)
        #expect(table.cells(row: 1) == [TabularCell(kind: .number, text: "2"), .missing, .text("Hue")])
    }

    @Test func testScanCarriesKindsAndInsertedCellsReadAsMissing() async throws {
        var table = try await table("{\"a\":null,\"b\":true}\n{\"a\":\"x\"}\n")
        table.insertRows([[.text("new")]], at: 2)
        var seen: [[TabularCellKind]] = []
        table.scan(columns: table.columnIDs, rows: 0..<table.rowCount) { _, cells in
            seen.append(cells.kinds)
            return true
        }
        #expect(seen == [[.null, .boolean], [.text, .missing], [.text, .missing]])
    }
}
