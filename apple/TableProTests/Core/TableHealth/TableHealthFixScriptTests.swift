import Foundation
@testable import TablePro
import Testing

struct TableHealthFixScriptTests {
    private static let generated = Date(timeIntervalSince1970: 1_800_000_000)

    private func script(database: String = "shop", _ findings: [TableHealthFinding]) -> String {
        TableHealthFixScript.script(
            database: database, generatedAt: Self.generated, databaseType: .postgresql, findings: findings
        )
    }

    private func lines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
    }

    @Test("The script names the database and date, says to run each statement alone, then gives each fix under its finding")
    func scriptShape() {
        let text = script([
            TableHealthFixture.finding(.unusedIndex, schema: "public", table: "orders", object: "orders_note_idx",
                                       fixSQL: #"DROP INDEX CONCURRENTLY "public"."orders_note_idx";"#),
            TableHealthFixture.finding(schema: "public", table: "logs",
                                       fixSQL: #"ALTER TABLE "public"."logs" ADD PRIMARY KEY (column_name);"#)
        ])
        let expected = [
            "-- " + String(format: String(localized: "Database: %1$@ (%2$@)"), "shop", DatabaseType.postgresql.displayName),
            "-- " + String(format: String(localized: "Generated: %@"), "2027-01-15T08:00:00Z"),
            "-- " + String(localized: "Run each statement on its own; some cannot run inside a transaction."),
            "",
            "-- " + String(format: String(localized: "%1$@: %2$@"), TableHealthCheckKind.unusedIndex.title, "public.orders.orders_note_idx"),
            #"DROP INDEX CONCURRENTLY "public"."orders_note_idx";"#,
            "",
            "-- " + String(format: String(localized: "%1$@: %2$@"), TableHealthCheckKind.missingPrimaryKey.title, "public.logs"),
            #"ALTER TABLE "public"."logs" ADD PRIMARY KEY (column_name);"#,
            ""
        ].joined(separator: "\n")
        #expect(text == expected)
    }

    @Test("A finding without a fix is left out")
    func findingWithoutFixSkipped() {
        let text = script([
            TableHealthFixture.finding(table: "kept", fixSQL: "SELECT 1;"),
            TableHealthFixture.finding(table: "nofix", fixSQL: nil),
            TableHealthFixture.finding(table: "blank", fixSQL: "  \n")
        ])
        #expect(text.contains("public.kept"))
        #expect(!text.contains("nofix"))
        #expect(!text.contains("blank"))
    }

    @Test(
        "A hostile name stays on its one comment line and cannot open or close a block comment",
        arguments: [
            "evil\nDROP TABLE users;",
            "evil\rDROP TABLE users;",
            "evil\r\nDROP TABLE users;",
            "evil\u{2028}DROP TABLE users;",
            "evil\u{2029}DROP TABLE users;",
            "evil\u{0085}DROP TABLE users;",
            "evil\u{000B}DROP\u{000C}TABLE\tusers;",
            "evil */ DROP TABLE users; /*",
            "evil /*!50000 DROP TABLE users */",
            "evil*/*/"
        ]
    )
    func hostileNamesStayInTheComment(name: String) throws {
        let text = script(database: name, [
            TableHealthFixture.finding(.unusedIndex, schema: name, table: name, object: name, fixSQL: "SELECT 1;")
        ])
        let all = lines(text)
        try #require(all.count == 7)
        #expect(all.filter { !$0.isEmpty }.allSatisfy { $0.hasPrefix("-- ") || $0 == "SELECT 1;" })
        #expect(all[4].hasPrefix("-- "))
        #expect(all[5] == "SELECT 1;")
        #expect(!text.contains("/*"))
        #expect(!text.contains("*/"))
        #expect(!text.contains("\t"))
    }

    @Test("Flattening turns every line break and tab into a space and keeps the rest")
    func singleLine() {
        #expect(TableHealthFixScript.singleLine("a\nb\r\nc\u{2028}d\te") == "a b c d e")
        #expect(TableHealthFixScript.singleLine("表 é") == "表 é")
    }
}
