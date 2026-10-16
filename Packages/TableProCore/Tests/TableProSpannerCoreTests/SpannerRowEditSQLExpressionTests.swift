import TableProSpannerCore
import Testing

struct SpannerRowEditSQLExpressionTests {
    private let columns = ["id", "created_at", "name"]
    private let originalRow: [SpannerCell] = [.text("1"), .null, .text("a")]

    private func statements(
        _ change: SpannerRowChange,
        insertedRows: [Int: [SpannerCell]] = [:]
    ) -> [SpannerRenderedStatement]? {
        SpannerRowEditSQL.statements(
            schema: "",
            table: "t",
            columns: columns,
            primaryKey: ["id"],
            changes: [change],
            insertedRows: insertedRows,
            deletedRows: [],
            insertedRowIndices: Set(insertedRows.keys),
            dialect: .postgreSQL
        )
    }

    @Test("A marked insert cell is written as SQL and the other cells stay bound")
    func markedInsertCell() {
        let change = SpannerRowChange(rowIndex: 0, kind: .insert, expressionColumns: ["created_at"])
        let written = statements(change, insertedRows: [0: [.text("1"), .text("CURRENT_TIMESTAMP"), .text("a")]])
        #expect(written == [SpannerRenderedStatement(
            sql: #"INSERT INTO "t" ("id", "created_at", "name") VALUES (?, CURRENT_TIMESTAMP, ?)"#,
            parameters: [.text("1"), .text("a")]
        )])
    }

    @Test("A marked update cell is written as SQL")
    func markedUpdateCell() {
        let change = SpannerRowChange(
            rowIndex: 0,
            kind: .update,
            cellChanges: [SpannerRowChange.CellChange(column: "created_at", value: .text("CURRENT_TIMESTAMP"))],
            originalRow: originalRow,
            expressionColumns: ["created_at"]
        )
        #expect(statements(change) == [SpannerRenderedStatement(
            sql: #"UPDATE "t" SET "created_at" = CURRENT_TIMESTAMP WHERE "id" = ?"#,
            parameters: [.text("1")]
        )])
    }

    @Test("Text that spells a function is bound when its cell is not marked")
    func unmarkedTextIsBound() {
        let change = SpannerRowChange(
            rowIndex: 0,
            kind: .update,
            cellChanges: [SpannerRowChange.CellChange(column: "name", value: .text("CURRENT_TIMESTAMP"))],
            originalRow: originalRow
        )
        #expect(statements(change) == [SpannerRenderedStatement(
            sql: #"UPDATE "t" SET "name" = ? WHERE "id" = ?"#,
            parameters: [.text("CURRENT_TIMESTAMP"), .text("1")]
        )])
    }
}
