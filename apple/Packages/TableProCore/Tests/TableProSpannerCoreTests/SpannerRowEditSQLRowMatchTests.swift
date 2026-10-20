import TableProSpannerCore
import Testing

struct SpannerRowEditSQLRowMatchTests {
    private let columns = ["tenant", "id", "name"]
    private let originalRow: [SpannerCell] = [.text("acme"), .text("7"), .text("a")]

    private func statements(
        _ changes: [SpannerRowChange],
        columns: [String]? = nil,
        primaryKey: [String] = ["tenant", "id"],
        deletedRows: Set<Int> = []
    ) -> [SpannerRenderedStatement]? {
        SpannerRowEditSQL.statements(
            schema: "",
            table: "t",
            columns: columns ?? self.columns,
            primaryKey: primaryKey,
            changes: changes,
            insertedRows: [:],
            deletedRows: deletedRows,
            insertedRowIndices: [],
            dialect: .postgreSQL
        )
    }

    private func rename(row: [SpannerCell]? = nil) -> SpannerRowChange {
        SpannerRowChange(
            rowIndex: 0,
            kind: .update,
            cellChanges: [SpannerRowChange.CellChange(column: "name", value: .text("b"))],
            originalRow: row ?? originalRow
        )
    }

    private func deletion(row: [SpannerCell]? = nil) -> SpannerRowChange {
        SpannerRowChange(rowIndex: 1, kind: .delete, originalRow: row ?? originalRow)
    }

    @Test("An update and a delete name the row by every key column")
    func writesNameTheRowByItsKey() {
        #expect(statements([rename(), deletion()], deletedRows: [1]) == [
            SpannerRenderedStatement(
                sql: #"UPDATE "t" SET "name" = ? WHERE "tenant" = ? AND "id" = ?"#,
                parameters: [.text("b"), .text("acme"), .text("7")]
            ),
            SpannerRenderedStatement(
                sql: #"DELETE FROM "t" WHERE "tenant" = ? AND "id" = ?"#,
                parameters: [.text("acme"), .text("7")]
            ),
        ])
    }

    @Test("A table with no key writes nothing rather than a statement that could reach other rows")
    func keylessTableIsRefused() {
        #expect(statements([rename()], primaryKey: []) == nil)
        #expect(statements([deletion()], primaryKey: [], deletedRows: [1]) == nil)
    }

    @Test("A result that leaves out a key column writes nothing")
    func missingKeyColumnIsRefused() {
        let partial = ["id", "name"]
        let row: [SpannerCell] = [.text("7"), .text("a")]
        #expect(statements([rename(row: row)], columns: partial) == nil)
        #expect(statements([deletion(row: row)], columns: partial, deletedRows: [1]) == nil)
    }

    @Test("A change with no row read back writes nothing")
    func changeWithoutOriginalRowIsRefused() {
        let change = SpannerRowChange(
            rowIndex: 0,
            kind: .update,
            cellChanges: [SpannerRowChange.CellChange(column: "name", value: .text("b"))]
        )
        #expect(statements([change]) == nil)
    }
}
