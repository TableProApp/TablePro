import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct MySQLTableHealthProviderTests {
    private let provider = MySQLTableHealthProvider()
    private let context = TableHealthFixture.mysqlContext()

    private struct IndexRow {
        var table = "orders"
        let index: String
        let nonUnique: String
        var type = "BTREE"
        let column: String?
        var subPart: String?
        var collation: String? = "A"
        var visible: String?
    }

    // The columns a SELECT * on STATISTICS returns, as MySQL 8 names them.
    private static let indexColumns = [
        "TABLE_NAME", "INDEX_NAME", "NON_UNIQUE", "INDEX_TYPE", "COLUMN_NAME", "SUB_PART", "COLLATION", "IS_VISIBLE"
    ]

    private static func indexResult(_ rows: [IndexRow]) -> QueryResult {
        TableHealthFixture.result(
            columns: indexColumns,
            rows: rows.map { row -> [String?] in
                [row.table, row.index, row.nonUnique, row.type, row.column, row.subPart, row.collation, row.visible]
            }
        )
    }

    private func redundant(_ rows: [IndexRow]) -> [String: String] {
        var map: [String: String] = [:]
        for finding in provider.findings(for: .redundantIndex, from: [Self.indexResult(rows)], context: context) {
            map[finding.objectName ?? ""] = finding.detail
        }
        return map
    }

    private func unused(
        candidates: [(table: String, index: String)],
        indexes: [IndexRow],
        foreignKeys: [(table: String, constraint: String, column: String)] = []
    ) -> [String] {
        let results = [
            TableHealthFixture.result(
                columns: ["table_name", "index_name"],
                rows: candidates.map { candidate -> [String?] in [candidate.table, candidate.index] }
            ),
            Self.indexResult(indexes),
            TableHealthFixture.result(
                columns: ["table_name", "constraint_name", "column_name"],
                rows: foreignKeys.map { key -> [String?] in [key.table, key.constraint, key.column] }
            )
        ]
        return provider.findings(for: .unusedIndex, from: results, context: context).compactMap(\.objectName)
    }

    private func statistics(
        performanceSchema: String = "1",
        instrument: String = "YES",
        consumer: String = "YES",
        countedTables: String = "3"
    ) -> TableHealthStatistics {
        provider.statistics(
            from: [
                TableHealthFixture.result(columns: ["performance_schema"], rows: [[performanceSchema]]),
                TableHealthFixture.result(columns: ["Variable_name", "Value"], rows: [["Uptime", "3600"]]),
                TableHealthFixture.result(
                    columns: ["table_io_instrument", "global_instrumentation", "counted_tables"],
                    rows: [[instrument, consumer, countedTables]]
                )
            ],
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test("An index whose columns lead another index is redundant to it")
    func prefixIsRedundant() {
        let found = redundant([
            IndexRow(index: "PRIMARY", nonUnique: "0", column: "id"),
            IndexRow(index: "idx_a", nonUnique: "1", column: "a"),
            IndexRow(index: "idx_ab", nonUnique: "1", column: "a"),
            IndexRow(index: "idx_ab", nonUnique: "1", column: "b"),
            IndexRow(index: "uniq_b", nonUnique: "0", column: "b")
        ])
        #expect(Array(found.keys) == ["idx_a"])
        #expect(found["idx_a"]?.contains("idx_ab") == true)
    }

    @Test("A shorter unique index enforces more than the longer one, so it stays")
    func shorterUniqueStays() {
        let found = redundant([
            IndexRow(index: "uniq_a", nonUnique: "0", column: "a"),
            IndexRow(index: "idx_ab", nonUnique: "1", column: "a"),
            IndexRow(index: "idx_ab", nonUnique: "1", column: "b")
        ])
        #expect(found.isEmpty)
    }

    @Test("Of two equal plain indexes, the one later by name is redundant")
    func equalPlainIndexes() {
        let found = redundant([
            IndexRow(index: "idx_x", nonUnique: "1", column: "a"),
            IndexRow(index: "idx_y", nonUnique: "1", column: "a")
        ])
        #expect(Array(found.keys) == ["idx_y"])
    }

    @Test("A plain index equal to a unique one is redundant to it")
    func plainEqualToUnique() {
        let found = redundant([
            IndexRow(index: "a_plain", nonUnique: "1", column: "a"),
            IndexRow(index: "z_unique", nonUnique: "0", column: "a")
        ])
        #expect(Array(found.keys) == ["a_plain"])
    }

    @Test("A unique index equal to the primary key is redundant, and the primary key never is")
    func uniqueEqualToPrimary() {
        let found = redundant([
            IndexRow(index: "PRIMARY", nonUnique: "0", column: "id"),
            IndexRow(index: "id_unique", nonUnique: "0", column: "id")
        ])
        #expect(Array(found.keys) == ["id_unique"])
    }

    @Test("A column prefix length, an expression or another index type keeps an index apart")
    func shapesThatDoNotCompare() {
        let found = redundant([
            IndexRow(index: "idx_a10", nonUnique: "1", column: "a", subPart: "10"),
            IndexRow(index: "idx_ab", nonUnique: "1", column: "a"),
            IndexRow(index: "idx_ab", nonUnique: "1", column: "b"),
            IndexRow(index: "idx_expr", nonUnique: "1", column: nil),
            IndexRow(index: "idx_expr", nonUnique: "1", column: "b"),
            IndexRow(index: "ft_a", nonUnique: "1", type: "FULLTEXT", column: "a", collation: nil)
        ])
        #expect(found.isEmpty)
    }

    @Test("A full-text index is redundant only to an identical one, never to a longer one")
    func fullTextNeedsExactColumns() {
        let prefix = redundant([
            IndexRow(index: "ft_a", nonUnique: "1", type: "FULLTEXT", column: "a", collation: nil),
            IndexRow(index: "ft_ab", nonUnique: "1", type: "FULLTEXT", column: "a", collation: nil),
            IndexRow(index: "ft_ab", nonUnique: "1", type: "FULLTEXT", column: "b", collation: nil)
        ])
        let identical = redundant([
            IndexRow(index: "ft_a", nonUnique: "1", type: "FULLTEXT", column: "a", collation: nil),
            IndexRow(index: "ft_a2", nonUnique: "1", type: "FULLTEXT", column: "a", collation: nil)
        ])
        #expect(prefix.isEmpty)
        #expect(Array(identical.keys) == ["ft_a2"])
    }

    @Test("A key part sorted the other way keeps an index apart")
    func sortDirectionMatters() {
        let found = redundant([
            IndexRow(index: "idx_ab_desc", nonUnique: "1", column: "a"),
            IndexRow(index: "idx_ab_desc", nonUnique: "1", column: "b", collation: "D"),
            IndexRow(index: "idx_ab", nonUnique: "1", column: "a"),
            IndexRow(index: "idx_ab", nonUnique: "1", column: "b")
        ])
        #expect(found.isEmpty)
    }

    @Test("An index is never redundant to an invisible or ignored one, which serves no query")
    func invisibleIndexCoversNothing() {
        let invisible = redundant([
            IndexRow(index: "idx_a", nonUnique: "1", column: "a"),
            IndexRow(index: "idx_ab", nonUnique: "1", column: "a", visible: "NO"),
            IndexRow(index: "idx_ab", nonUnique: "1", column: "b", visible: "NO")
        ])
        let ignored = provider.findings(
            for: .redundantIndex,
            from: [TableHealthFixture.result(
                columns: ["TABLE_NAME", "INDEX_NAME", "NON_UNIQUE", "INDEX_TYPE", "COLUMN_NAME", "SUB_PART", "COLLATION", "IGNORED"],
                rows: [
                    ["orders", "idx_a", "1", "BTREE", "a", nil, "A", "NO"],
                    ["orders", "idx_ab", "1", "BTREE", "a", nil, "A", "YES"],
                    ["orders", "idx_ab", "1", "BTREE", "b", nil, "A", "YES"]
                ]
            )],
            context: context
        )
        #expect(invisible.isEmpty)
        #expect(ignored.isEmpty)
    }

    @Test("Indexes compare only within their own table")
    func tablesStayApart() {
        let found = redundant([
            IndexRow(table: "a", index: "idx_x", nonUnique: "1", column: "c"),
            IndexRow(table: "b", index: "idx_xy", nonUnique: "1", column: "c"),
            IndexRow(table: "b", index: "idx_xy", nonUnique: "1", column: "d")
        ])
        #expect(found.isEmpty)
    }

    @Test("A redundant index previews a drop qualified by the report's database")
    func redundantFixQuotes() throws {
        let finding = try #require(provider.findings(
            for: .redundantIndex,
            from: [Self.indexResult([
                IndexRow(table: "odd`name", index: "idx_a", nonUnique: "1", column: "a"),
                IndexRow(table: "odd`name", index: "idx_ab", nonUnique: "1", column: "a"),
                IndexRow(table: "odd`name", index: "idx_ab", nonUnique: "1", column: "b")
            ])],
            context: context
        ).first)
        #expect(finding.schema == nil)
        #expect(finding.fixSQL == "ALTER TABLE `shop`.`odd``name` DROP INDEX `idx_a`;")
    }

    @Test("An unread plain index is unused; a unique index and one gone from the catalog are not")
    func unusedSkipsUniqueAndDropped() {
        let found = unused(
            candidates: [("orders", "orders_note_idx"), ("orders", "orders_code_uniq"), ("orders", "dropped_idx")],
            indexes: [
                IndexRow(index: "orders_code_uniq", nonUnique: "0", column: "code"),
                IndexRow(index: "orders_note_idx", nonUnique: "1", column: "note")
            ]
        )
        #expect(found == ["orders_note_idx"])
    }

    @Test("An index that leads with a foreign key's columns is not unused: InnoDB checks the key through it uncounted")
    func unusedSkipsForeignKeyIndex() {
        let found = unused(
            candidates: [("line", "line_order_idx"), ("line", "line_pair_idx"), ("line", "line_late_idx"), ("line", "line_short_idx")],
            indexes: [
                IndexRow(table: "line", index: "line_late_idx", nonUnique: "1", column: "note"),
                IndexRow(table: "line", index: "line_late_idx", nonUnique: "1", column: "order_id"),
                IndexRow(table: "line", index: "line_order_idx", nonUnique: "1", column: "ORDER_ID"),
                IndexRow(table: "line", index: "line_order_idx", nonUnique: "1", column: "note"),
                IndexRow(table: "line", index: "line_pair_idx", nonUnique: "1", column: "x"),
                IndexRow(table: "line", index: "line_pair_idx", nonUnique: "1", column: "y"),
                IndexRow(table: "line", index: "line_short_idx", nonUnique: "1", column: "x", subPart: "4"),
                IndexRow(table: "line", index: "line_short_idx", nonUnique: "1", column: "y")
            ],
            foreignKeys: [
                ("line", "line_order_fk", "order_id"),
                ("line", "line_pair_fk", "x"),
                ("line", "line_pair_fk", "y")
            ]
        )
        #expect(found == ["line_late_idx", "line_short_idx"])
    }

    @Test("An unused index and a table without a primary key preview their fixes")
    func unusedAndMissingKeyFixes() throws {
        let unusedFinding = try #require(provider.findings(
            for: .unusedIndex,
            from: [
                TableHealthFixture.result(columns: ["table_name", "index_name"], rows: [["orders", "orders_note_idx"]]),
                Self.indexResult([IndexRow(index: "orders_note_idx", nonUnique: "1", column: "note")]),
                TableHealthFixture.result(columns: ["table_name", "constraint_name", "column_name"], rows: [])
            ],
            context: context
        ).first)
        let keyFinding = try #require(provider.findings(
            for: .missingPrimaryKey,
            from: [TableHealthFixture.result(columns: ["table_name"], rows: [["logs"]])],
            context: context
        ).first)

        #expect(unusedFinding.fixSQL == "ALTER TABLE `shop`.`orders` DROP INDEX `orders_note_idx`;")
        #expect(keyFinding.fixSQL == "ALTER TABLE `shop`.`logs` ADD PRIMARY KEY (column_name);")
    }

    @Test("Each setting that stops index reads being counted skips the unused index check")
    func uncountedReadsSkipUnused() {
        #expect(statistics(performanceSchema: "0").skippedChecks[.unusedIndex]?.contains("Performance Schema is off") == true)
        #expect(statistics(instrument: "NO").skippedChecks[.unusedIndex]?.contains("wait/io/table/sql/handler") == true)
        #expect(statistics(consumer: "NO").skippedChecks[.unusedIndex]?.contains("global_instrumentation") == true)
        #expect(statistics(countedTables: "0").skippedChecks[.unusedIndex] != nil)
        #expect(statistics().skippedChecks.isEmpty)
    }

    @Test("While reads are counted, the note names the server start")
    func serverStartNote() {
        let start = Date(timeIntervalSince1970: 1_800_000_000 - 3600).formatted(date: .abbreviated, time: .shortened)
        #expect(statistics().note?.contains(start) == true)
    }

    @Test("Without access to the counting settings the unused check still runs and reports for itself")
    func unreadableCountingRunsCheck() {
        let stats = provider.statistics(
            from: [
                TableHealthFixture.result(columns: ["performance_schema"], rows: [["1"]]),
                nil,
                nil
            ],
            now: Date()
        )
        #expect(stats.skippedChecks.isEmpty)
        #expect(stats.note == nil)
    }

    @Test("The index catalog is read once for the two checks that use it")
    func indexCatalogReadOnce() async throws {
        var asked: [String] = []
        _ = try await provider.fetchReport(context: context) { query in
            asked.append(query)
            return TableHealthFixture.empty()
        }
        #expect(asked.filter { $0 == MySQLTableHealthProvider.indexQuery }.count == 1)
    }

    @Test("Every query the report runs only reads")
    func queriesOnlyRead() {
        let queries = provider.statisticsQueries + provider.checks.flatMap { provider.queries(for: $0) }
        for query in queries where query != MySQLTableHealthProvider.uptimeQuery {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(text.uppercased().hasPrefix("SELECT"), "\(text.prefix(40)) does not start with SELECT")
        }
        #expect(MySQLTableHealthProvider.uptimeQuery.hasPrefix("SHOW "))
    }
}
