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

    @Test("A fix two findings share runs once, under both findings' comment lines, where the first stood")
    func sharedFixRunsOnce() {
        let drop = #"DROP INDEX CONCURRENTLY "public"."orders_a_idx";"#
        let text = script([
            TableHealthFixture.finding(.unusedIndex, schema: "public", table: "orders", object: "orders_a_idx", fixSQL: drop),
            TableHealthFixture.finding(schema: "public", table: "logs",
                                       fixSQL: #"ALTER TABLE "public"."logs" ADD PRIMARY KEY (column_name);"#),
            TableHealthFixture.finding(.redundantIndex, schema: "public", table: "orders", object: "orders_a_idx",
                                       fixSQL: drop + "\n")
        ])
        let body = lines(text).dropFirst(4)
        #expect(Array(body) == [
            Substring("-- " + String(format: String(localized: "%1$@: %2$@"), TableHealthCheckKind.unusedIndex.title, "public.orders.orders_a_idx")),
            Substring("-- " + String(format: String(localized: "%1$@: %2$@"), TableHealthCheckKind.redundantIndex.title, "public.orders.orders_a_idx")),
            Substring(drop),
            "",
            Substring("-- " + String(format: String(localized: "%1$@: %2$@"), TableHealthCheckKind.missingPrimaryKey.title, "public.logs")),
            #"ALTER TABLE "public"."logs" ADD PRIMARY KEY (column_name);"#,
            ""
        ])
        #expect(text.components(separatedBy: drop).count == 2)
    }

    private func redundant(
        _ index: String,
        coveredBy cover: String,
        schema: String? = "public",
        table: String = "orders",
        fix: String? = nil
    ) -> TableHealthFinding {
        TableHealthFinding(
            kind: .redundantIndex, schema: schema, table: table, objectName: index, detail: "",
            metrics: [TableHealthMetric(id: "covering_index", label: "Covering Index", value: .text(cover))],
            fixSQL: fix ?? "DROP INDEX CONCURRENTLY \"public\".\"\(index)\";"
        )
    }

    private func unused(_ index: String, schema: String? = "public", table: String = "orders", fix: String? = nil) -> TableHealthFinding {
        TableHealthFixture.finding(
            .unusedIndex, schema: schema, table: table, object: index,
            fixSQL: fix ?? "DROP INDEX CONCURRENTLY \"public\".\"\(index)\";"
        )
    }

    private func comment(_ kind: TableHealthCheckKind, _ name: String) -> Substring {
        Substring("-- " + String(format: String(localized: "%1$@: %2$@"), kind.title, name))
    }

    @Test("A redundant index whose covering index the script drops as unused stays, with a note, so its lookups keep an index")
    func redundantIndexStaysWhenItsCoverIsDropped() {
        let text = script([
            unused("orders_customer_created_idx"),
            redundant("orders_customer_idx", coveredBy: "orders_customer_created_idx")
        ])
        #expect(Array(lines(text).dropFirst(4)) == [
            comment(.unusedIndex, "public.orders.orders_customer_created_idx"),
            #"DROP INDEX CONCURRENTLY "public"."orders_customer_created_idx";"#,
            "",
            comment(.redundantIndex, "public.orders.orders_customer_idx"),
            Substring("-- " + String(
                format: String(localized: "Not dropped: its covering index %@ is dropped in this script."), "orders_customer_created_idx"
            )),
            ""
        ])
        #expect(!text.contains(#"DROP INDEX CONCURRENTLY "public"."orders_customer_idx";"#))
    }

    @Test("A redundant index still drops when its cover stays, when the cover is another table's, or when it is unused itself")
    func redundantIndexDropsOtherwise() {
        let coverStays = script([redundant("orders_customer_idx", coveredBy: "orders_customer_created_idx")])
        #expect(coverStays.contains(#"DROP INDEX CONCURRENTLY "public"."orders_customer_idx";"#))

        let otherTable = script([
            unused("orders_customer_created_idx", table: "archive"),
            redundant("orders_customer_idx", coveredBy: "orders_customer_created_idx")
        ])
        #expect(otherTable.contains(#"DROP INDEX CONCURRENTLY "public"."orders_customer_idx";"#))

        let bothUnused = script([
            unused("orders_customer_created_idx"),
            unused("orders_customer_idx"),
            redundant("orders_customer_idx", coveredBy: "orders_customer_created_idx")
        ])
        #expect(bothUnused.components(separatedBy: #"DROP INDEX CONCURRENTLY "public"."orders_customer_idx";"#).count == 2)
        #expect(!bothUnused.contains("Not dropped"))
    }

    @Test("A cover the script keeps does not keep what it covers, so a chain drops down to the index that stays")
    func coverChainResolves() {
        let text = script([
            unused("idx_abc"),
            redundant("idx_ab", coveredBy: "idx_abc"),
            redundant("idx_a", coveredBy: "idx_ab")
        ])
        #expect(text.contains(#"DROP INDEX CONCURRENTLY "public"."idx_abc";"#))
        #expect(!text.contains(#"DROP INDEX CONCURRENTLY "public"."idx_ab";"#))
        #expect(text.contains(#"DROP INDEX CONCURRENTLY "public"."idx_a";"#))
    }

    @Test("MySQL findings, which have no schema, keep a redundant index the same way")
    func mysqlRedundantIndexStays() {
        let drop = { (index: String) in "ALTER TABLE `shop`.`orders` DROP INDEX `\(index)`;" }
        let text = script([
            unused("orders_customer_created_idx", schema: nil, fix: drop("orders_customer_created_idx")),
            redundant("orders_customer_idx", coveredBy: "orders_customer_created_idx", schema: nil, fix: drop("orders_customer_idx"))
        ])
        #expect(text.contains(drop("orders_customer_created_idx")))
        #expect(!text.contains(drop("orders_customer_idx")))
        #expect(text.contains("Not dropped"))
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
