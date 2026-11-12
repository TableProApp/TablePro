import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LazyCellKeyTests {
    private static let notes = LazyContext(table: "notes", primaryKeyColumns: ["tenant", "id"])

    @Test("A row's key is read from the columns the result carries, in the table's key order")
    func keyFromResultColumns() throws {
        let key = try #require(LazyCellKey(Self.notes, columnNames: ["id", "body", "tenant"]))
        let values = ["7", "long text", "acme"]
        let primaryKey = key.primaryKey { values[$0] }
        let ref = try #require(key.ref(column: "body", primaryKey: primaryKey))

        #expect(ref.table == "notes")
        #expect(ref.column == "body")
        #expect(ref.primaryKey == [
            PrimaryKeyComponent(column: "tenant", value: "acme"),
            PrimaryKeyComponent(column: "id", value: "7"),
        ])
    }

    @Test("A result without every key column, or a read without a key, offers no ref")
    func noKeyNoRef() {
        #expect(LazyCellKey(Self.notes, columnNames: ["id", "body"]) == nil)
        #expect(LazyCellKey(nil, columnNames: ["id", "body"]) == nil)
        #expect(LazyCellKey(LazyContext(table: "notes", primaryKeyColumns: []), columnNames: ["id"]) == nil)
    }

    @Test("A NULL or binary key value names no row")
    func unreadableKeyNamesNoRow() throws {
        let key = try #require(LazyCellKey(Self.notes, columnNames: ["tenant", "id", "body"]))
        let primaryKey = key.primaryKey { $0 == 0 ? "acme" : nil }

        #expect(primaryKey == nil)
        #expect(key.ref(column: "body", primaryKey: primaryKey) == nil)
    }

    @Test("A DuckDB value cut for display carries the key it is read back by")
    func duckDBCutValueCarriesRef() async throws {
        let cells = try await Self.duckDBBody(selecting: "SELECT id, body FROM notes")
        let ref = try #require(cells.last?.fullValueRef)

        #expect(ref.table == "notes")
        #expect(ref.column == "body")
        #expect(ref.primaryKey == [PrimaryKeyComponent(column: "id", value: "7")])
    }

    @Test("A DuckDB result without the key column offers nothing to load")
    func duckDBWithoutKeyOffersNoRef() async throws {
        let cells = try await Self.duckDBBody(selecting: "SELECT body FROM notes")
        guard case .truncatedText(_, let totalBytes, let ref)? = cells.last else {
            Issue.record("expected the body cut for display, got \(cells)")
            return
        }
        #expect(totalBytes == 5_000)
        #expect(ref == nil)
    }

    private static func duckDBBody(selecting query: String) async throws -> [Cell] {
        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        _ = try await driver.execute(query: "CREATE TABLE notes (id INTEGER PRIMARY KEY, body VARCHAR)")
        _ = try await driver.execute(query: "INSERT INTO notes VALUES (7, repeat('x', 5000))")
        let options = StreamOptions(
            textTruncationBytes: 4_096,
            maxRows: 10,
            lazyContext: LazyContext(table: "notes", primaryKeyColumns: ["id"])
        )
        var cells: [Cell] = []
        for try await element in driver.executeStreaming(query: query, options: options) {
            if case .row(let row) = element { cells = row.cells }
        }
        try await driver.disconnect()
        return cells
    }
}
