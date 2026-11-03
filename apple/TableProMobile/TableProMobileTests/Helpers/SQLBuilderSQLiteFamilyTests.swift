import Foundation
@testable import TableProMobile
import TableProModels
import Testing

struct SQLBuilderSQLiteFamilyTests {
    // Measured on sqlite3 3.54: `TRUNCATE TABLE "t";` is `Parse error ... near "TRUNCATE": syntax error`.
    @Test("Truncate on an engine that runs SQLite deletes every row, since SQLite has no TRUNCATE",
          arguments: [DatabaseType.sqlite, .cloudflareD1])
    func sqliteFamilyTruncatesWithDelete(type: DatabaseType) {
        #expect(SQLBuilder.truncateStatement(table: "events", schema: nil, type: type) == #"DELETE FROM "events""#)
    }

    @Test("Truncate elsewhere keeps TRUNCATE TABLE, quoted and qualified for the engine")
    func otherEnginesTruncate() {
        #expect(SQLBuilder.truncateStatement(table: "events", schema: nil, type: .mysql) == "TRUNCATE TABLE `events`")
        #expect(SQLBuilder.truncateStatement(table: "events", schema: "sales", type: .postgresql)
            == #"TRUNCATE TABLE "sales"."events""#)
    }

    @Test("A D1 search within its LIKE limit stays a LIKE")
    func shortD1SearchIsLike() {
        #expect(search("signup") == #"SELECT * FROM "events" WHERE (CAST("note" AS TEXT) LIKE '%signup%' ESCAPE '!') LIMIT 10 OFFSET 0"#)
    }

    // D1 refuses a LIKE pattern over 50 bytes, so a pasted email or URL would fail the whole page read.
    @Test("A D1 search past its LIKE limit is matched as a plain substring of every column")
    func longD1SearchUsesInstr() {
        let text = String(repeating: "a", count: 40) + "@example.com"

        #expect(search(text, columns: ["note", "email"])
            == #"SELECT * FROM "events" WHERE (instr(LOWER(CAST("note" AS TEXT)), LOWER('\#(text)')) > 0 OR "#
            + #"instr(LOWER(CAST("email" AS TEXT)), LOWER('\#(text)')) > 0) LIMIT 10 OFFSET 0"#)
    }

    @Test("A SQLite search keeps its LIKE however long, since SQLite on the device has no such limit")
    func longSQLiteSearchIsLike() {
        let text = String(repeating: "a", count: 80)

        #expect(search(text, type: .sqlite).contains(#"LIKE '%\#(text)%' ESCAPE '!'"#))
    }

    @Test("A D1 filter on a column with no type matches a number either way it was stored")
    func d1UntypedColumnMatchesEitherStorageClass() {
        let filters = [TableFilter(columnName: "v", filterOperator: .equal, value: "5")]

        #expect(SQLBuilder.buildFilteredCount(
            table: "events", schema: nil, type: .cloudflareD1, filters: filters, logicMode: .and,
            columns: [ColumnInfo(name: "v", typeName: "")]
        ) == #"SELECT COUNT(*) FROM "events" WHERE ("v" IN (5, '5') AND CAST("v" AS TEXT) = '5')"#)
    }

    private func search(_ text: String, columns: [String] = ["note"], type: DatabaseType = .cloudflareD1) -> String {
        SQLBuilder.buildSearchSelect(
            table: "events", schema: nil, type: type,
            searchText: text, searchColumns: columns.map { ColumnInfo(name: $0, typeName: "TEXT") },
            limit: 10, offset: 0
        )
    }
}
