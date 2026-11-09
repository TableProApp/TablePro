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
        var position: Int?
    }

    // The columns a SELECT * on STATISTICS returns, as MySQL 8 names them.
    private static let indexColumns = [
        "TABLE_NAME", "INDEX_NAME", "SEQ_IN_INDEX", "NON_UNIQUE", "INDEX_TYPE", "COLUMN_NAME", "SUB_PART", "COLLATION",
        "IS_VISIBLE"
    ]

    // A row's position defaults to its place among the earlier rows of its index.
    private static func indexResult(_ rows: [IndexRow]) -> QueryResult {
        var seen: [String: Int] = [:]
        return TableHealthFixture.result(
            columns: indexColumns,
            rows: rows.map { row -> [String?] in
                let key = row.table + "." + row.index
                seen[key, default: 0] += 1
                let position = row.position ?? seen[key, default: 1]
                return [
                    row.table, row.index, String(position), row.nonUnique, row.type, row.column, row.subPart,
                    row.collation, row.visible
                ]
            }
        )
    }

    private func findings(_ check: TableHealthCheckKind, from results: [QueryResult]) -> [TableHealthFinding] {
        provider.findings(for: check, from: results, context: context, statistics: TableHealthStatistics()).findings
    }

    private func redundant(_ rows: [IndexRow]) -> [String: String] {
        var map: [String: String] = [:]
        for finding in findings(.redundantIndex, from: [Self.indexResult(rows)]) {
            map[finding.objectName ?? ""] = finding.detail
        }
        return map
    }

    private struct KeyRow {
        var schema = "shop"
        let table: String
        let constraint: String
        let column: String
        var referencedTable = "parent"
        var referencedColumn = "id"
        var referencesHere = false

        var isLocal: Bool { schema == "shop" }
    }

    private static let keyColumns = [
        "table_schema", "table_name", "constraint_name", "column_name",
        "referenced_table_name", "referenced_column_name", "ordinal_position", "is_local", "references_here"
    ]

    private static let tableRowsColumns = ["table_name", "estimated_rows"]

    private static func keyResult(_ keys: [KeyRow]) -> QueryResult {
        var seen: [String: Int] = [:]
        return TableHealthFixture.result(
            columns: keyColumns,
            rows: keys.map { key -> [String?] in
                let identity = key.schema + "." + key.table + "." + key.constraint
                seen[identity, default: 0] += 1
                return [
                    key.schema, key.table, key.constraint, key.column, key.referencedTable, key.referencedColumn,
                    String(seen[identity, default: 1]), key.isLocal ? "1" : "0", key.referencesHere ? "1" : "0"
                ]
            }
        )
    }

    private func unused(
        candidates: [(table: String, index: String)],
        indexes: [IndexRow],
        foreignKeys: [KeyRow] = []
    ) -> [String] {
        let results = [
            TableHealthFixture.result(
                columns: ["table_name", "index_name"],
                rows: candidates.map { candidate -> [String?] in [candidate.table, candidate.index] }
            ),
            Self.indexResult(indexes),
            Self.keyResult(foreignKeys),
            TableHealthFixture.result(columns: Self.tableRowsColumns, rows: [])
        ]
        return findings(.unusedIndex, from: results).compactMap { $0.objectName }
    }

    // One row of autoIncrementQuery. MariaDB writes display widths into column_type ("int(11)").
    private struct CounterRow {
        var table = "orders"
        var column = "id"
        var dataType = "int"
        var columnType = "int"
        var nullable = "NO"
        var comment = ""
        var extra = "auto_increment"
        let next: String
        let max: String
    }

    private static let counterColumns = [
        "table_name", "column_name", "data_type", "column_type", "is_nullable", "column_comment", "extra",
        "auto_increment", "max_value", "table_bytes"
    ]

    private func nearLimit(
        _ rows: [CounterRow],
        foreignKeys: [KeyRow] = [],
        statistics: TableHealthStatistics = TableHealthStatistics()
    ) -> (findings: [TableHealthFinding], note: String?) {
        provider.findings(
            for: .nearLimit,
            from: [
                TableHealthFixture.result(
                    columns: Self.counterColumns,
                    rows: rows.map { row -> [String?] in
                        [
                            row.table, row.column, row.dataType, row.columnType, row.nullable, row.comment, row.extra,
                            row.next, row.max, "16384"
                        ]
                    }
                ),
                Self.keyResult(foreignKeys)
            ],
            context: context,
            statistics: statistics
        )
    }

    private func nearLimitFix(_ row: CounterRow) -> String? {
        nearLimit([row]).findings.first?.fixSQL
    }

    private static let reclaimableColumns = ["table_name", "engine", "estimated_rows", "table_bytes", "free_bytes"]

    private struct ProbeDenied: LocalizedError {
        var errorDescription: String? { "Access denied; you need (at least one of) the PROCESS privilege(s) for this operation" }
    }

    // The queries a whole report asks a server that answers only its version and the PROCESS probe.
    private func report(version: String, canReadInnoDB: Bool = true) async throws -> (report: TableHealthReport, asked: [String]) {
        var asked: [String] = []
        let report = try await provider.fetchReport(context: context) { query in
            asked.append(query)
            if query == MySQLTableHealthProvider.versionQuery {
                return TableHealthFixture.result(columns: ["version"], rows: [[version]])
            }
            if query == MySQLTableHealthProvider.processPrivilegeQuery {
                guard canReadInnoDB else { throw ProbeDenied() }
                return TableHealthFixture.result(columns: ["buffer_pools"], rows: [["1"]])
            }
            return TableHealthFixture.empty()
        }
        return (report, asked)
    }

    private func statistics(
        performanceSchema: String = "1",
        instrument: String = "YES",
        consumer: String = "YES",
        countedTables: String = "3",
        version: String = "8.0.46",
        canReadInnoDB: Bool = true
    ) -> TableHealthStatistics {
        provider.statistics(
            from: [
                TableHealthFixture.result(columns: ["performance_schema"], rows: [[performanceSchema]]),
                TableHealthFixture.result(columns: ["Variable_name", "Value"], rows: [["Uptime", "3600"]]),
                TableHealthFixture.result(
                    columns: ["table_io_instrument", "global_instrumentation", "counted_tables"],
                    rows: [[instrument, consumer, countedTables]]
                ),
                TableHealthFixture.result(columns: ["version"], rows: [[version]]),
                canReadInnoDB ? TableHealthFixture.result(columns: ["buffer_pools"], rows: [["1"]]) : nil
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

    @Test("A full-text index is never redundant: two on the same columns can tokenize with different parsers")
    func fullTextIsNeverRedundant() {
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
        #expect(identical.isEmpty)
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
        let ignored = findings(
            .redundantIndex,
            from: [TableHealthFixture.result(
                columns: [
                    "TABLE_NAME", "INDEX_NAME", "SEQ_IN_INDEX", "NON_UNIQUE", "INDEX_TYPE", "COLUMN_NAME", "SUB_PART", "COLLATION",
                    "IGNORED"
                ],
                rows: [
                    ["orders", "idx_a", "1", "1", "BTREE", "a", nil, "A", "NO"],
                    ["orders", "idx_ab", "1", "1", "BTREE", "a", nil, "A", "YES"],
                    ["orders", "idx_ab", "2", "1", "BTREE", "b", nil, "A", "YES"]
                ]
            )]
        )
        #expect(invisible.isEmpty)
        #expect(ignored.isEmpty)
    }

    @Test("Rows group by exact table name, so tables whose names differ only in case cannot split an index")
    func caseDistinctTablesStayWhole() {
        let found = redundant([
            IndexRow(table: "orders", index: "idx_xy", nonUnique: "1", column: "x"),
            IndexRow(table: "Orders", index: "idx_q", nonUnique: "1", column: "q"),
            IndexRow(table: "orders", index: "idx_xy", nonUnique: "1", column: "y"),
            IndexRow(table: "orders", index: "idx_y", nonUnique: "1", column: "y")
        ])
        #expect(found.isEmpty)
    }

    @Test("Key parts compare in index order, whatever order the rows arrive in")
    func keyPartsFollowPosition() {
        let found = redundant([
            IndexRow(index: "idx_ab", nonUnique: "1", column: "b", position: 2),
            IndexRow(index: "idx_ab", nonUnique: "1", column: "a", position: 1),
            IndexRow(index: "idx_a", nonUnique: "1", column: "a")
        ])
        #expect(Array(found.keys) == ["idx_a"])
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

    @Test("A redundant index previews a drop qualified by the report's database and names its covering index")
    func redundantFixQuotes() throws {
        let finding = try #require(findings(
            .redundantIndex,
            from: [Self.indexResult([
                IndexRow(table: "odd`name", index: "idx_a", nonUnique: "1", column: "a"),
                IndexRow(table: "odd`name", index: "idx_ab", nonUnique: "1", column: "a"),
                IndexRow(table: "odd`name", index: "idx_ab", nonUnique: "1", column: "b")
            ])]
        ).first)
        #expect(finding.schema == nil)
        #expect(finding.fixSQL == "ALTER TABLE `shop`.`odd``name` DROP INDEX `idx_a`;")
        #expect(finding.metric("covering_index")?.value == .text("idx_ab"))
    }

    @Test("An unread plain index is unused; a unique, a full-text and a dropped index are not")
    func unusedSkipsUniqueFullTextAndDropped() {
        let found = unused(
            candidates: [
                ("orders", "orders_note_idx"), ("orders", "orders_code_uniq"), ("orders", "dropped_idx"), ("orders", "orders_body_ft")
            ],
            indexes: [
                IndexRow(index: "orders_body_ft", nonUnique: "1", type: "FULLTEXT", column: "body", collation: nil),
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
                KeyRow(table: "line", constraint: "line_order_fk", column: "order_id"),
                KeyRow(table: "line", constraint: "line_pair_fk", column: "x"),
                KeyRow(table: "line", constraint: "line_pair_fk", column: "y")
            ]
        )
        #expect(found == ["line_late_idx", "line_short_idx"])
    }

    @Test("A non-unique index a foreign key references, from this database or another, is not unused")
    func unusedSkipsReferencedIndex() {
        let found = unused(
            candidates: [("orders", "orders_code_idx"), ("orders", "orders_note_idx"), ("orders", "orders_misc_idx")],
            indexes: [
                IndexRow(index: "orders_code_idx", nonUnique: "1", column: "code"),
                IndexRow(index: "orders_misc_idx", nonUnique: "1", column: "misc"),
                IndexRow(index: "orders_note_idx", nonUnique: "1", column: "note")
            ],
            foreignKeys: [
                KeyRow(
                    schema: "archive", table: "audit", constraint: "audit_note_fk", column: "note",
                    referencedTable: "orders", referencedColumn: "note", referencesHere: true
                ),
                KeyRow(
                    table: "line", constraint: "line_code_fk", column: "order_code",
                    referencedTable: "orders", referencedColumn: "code", referencesHere: true
                ),
                KeyRow(table: "orders", constraint: "orders_misc_fk", column: "misc", referencedTable: "misc", referencedColumn: "id")
            ]
        )
        #expect(found == [])
    }

    @Test("A key that leaves this database protects only its referencing end here")
    func outgoingKeyProtectsOnlyItsOwnEnd() {
        let found = unused(
            candidates: [("orders", "orders_ref_idx"), ("refs", "refs_id_idx")],
            indexes: [
                IndexRow(index: "orders_ref_idx", nonUnique: "1", column: "ref_id"),
                IndexRow(table: "refs", index: "refs_id_idx", nonUnique: "1", column: "id")
            ],
            foreignKeys: [
                KeyRow(table: "orders", constraint: "orders_ref_fk", column: "ref_id", referencedTable: "refs", referencedColumn: "id")
            ]
        )
        #expect(found == ["refs_id_idx"])
    }

    @Test("An unused index and a table without a primary key preview their fixes and carry the table's rows")
    func unusedAndMissingKeyFixes() throws {
        let unusedFinding = try #require(findings(
            .unusedIndex,
            from: [
                TableHealthFixture.result(columns: ["table_name", "index_name"], rows: [["orders", "orders_note_idx"]]),
                Self.indexResult([IndexRow(index: "orders_note_idx", nonUnique: "1", column: "note")]),
                TableHealthFixture.result(columns: Self.keyColumns, rows: []),
                TableHealthFixture.result(columns: Self.tableRowsColumns, rows: [["Orders", "7"], ["orders", "4200"]])
            ]
        ).first)
        let keyFinding = try #require(findings(
            .missingPrimaryKey,
            from: [TableHealthFixture.result(
                columns: ["table_name", "estimated_rows", "table_bytes"], rows: [["logs", "900", "49152"]]
            )]
        ).first)

        #expect(unusedFinding.fixSQL == "ALTER TABLE `shop`.`orders` DROP INDEX `orders_note_idx`;")
        #expect(unusedFinding.metric("estimated_rows")?.value == .count(4200))
        #expect(unusedFinding.sizeBytes == nil)
        #expect(keyFinding.fixSQL == "ALTER TABLE `shop`.`logs` ADD PRIMARY KEY (column_name);")
        #expect(keyFinding.metric("estimated_rows")?.value == .count(900))
        #expect(keyFinding.sizeBytes == 49152)
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
        #expect(statistics().notes.contains { $0.contains(start) })
    }

    @Test("The statistics read the server version and tell MariaDB apart, also when the unused check is skipped")
    func serverVersion() {
        let mysql = statistics(version: "8.0.46")
        let mariadb = statistics(performanceSchema: "0", version: "10.6.28-MariaDB-1:10.6.28+maria~ubu2004")
        #expect(mysql.serverVersion == 80046)
        #expect(!mysql.isMariaDB)
        #expect(mariadb.serverVersion == 100_628)
        #expect(mariadb.isMariaDB)
        #expect(mariadb.skippedChecks[.unusedIndex] != nil)
        #expect(MySQLTableHealthProvider.serverVersion(from: "8.4.13-log") == 80413)
        #expect(MySQLTableHealthProvider.serverVersion(from: "5.5.5-10.11.6-MariaDB") == 101_106)
        #expect(MySQLTableHealthProvider.serverVersion(from: "11.4") == 110_400)
        #expect(MySQLTableHealthProvider.serverVersion(from: "unknown") == nil)
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
        #expect(stats.skippedChecks[.unusedIndex] == nil)
        #expect(stats.notes.isEmpty)
        #expect(stats.serverVersion == nil)
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

    @Test("Every check the provider lists has a query on every server it can meet, so none reports nothing found unread")
    func everyCheckHasAQuery() {
        var servers = [provider.statistics(from: [nil, nil, nil, nil], now: Date())]
        for version in ["5.7.44", "8.0.46", "8.4.13", "10.6.28-MariaDB", "11.4.13-MariaDB"] {
            servers.append(statistics(version: version))
            servers.append(statistics(performanceSchema: "0", version: version))
        }
        for server in servers {
            for check in provider.checks where server.skippedChecks[check] == nil {
                #expect(!provider.queries(for: check, statistics: server).isEmpty, "\(check.rawValue) has no query")
            }
        }
    }

    @Test("Every check names itself and states what it looks for")
    func everyCheckDescribed() {
        for check in provider.checks {
            #expect(provider.check(check).kind == check)
            #expect(!provider.check(check).summary.isEmpty, "\(check.rawValue) has no summary")
        }
    }

    @Test("Every query the report runs only reads, on MySQL and on MariaDB")
    func queriesOnlyRead() {
        var queries = provider.statisticsQueries
        for server in [statistics(version: "8.4.13"), statistics(version: "11.4.13-MariaDB")] {
            queries += provider.checks.flatMap { provider.queries(for: $0, statistics: server) }
        }
        for query in queries where query != MySQLTableHealthProvider.uptimeQuery {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(text.uppercased().hasPrefix("SELECT"), "\(text.prefix(40)) does not start with SELECT")
        }
        #expect(MySQLTableHealthProvider.uptimeQuery.hasPrefix("SHOW "))
    }

    @Test("A counter near its limit carries its typed values and widens the column to BIGINT with its sign kept")
    func nearLimitWidensToBigint() throws {
        let found = nearLimit([
            CounterRow(table: "ai_tiny_unsigned", dataType: "tinyint", columnType: "tinyint unsigned", next: "200", max: "255"),
            CounterRow(table: "ai_int", next: "1700000001", max: "2147483647")
        ]).findings
        let tiny = try #require(found.first { $0.table == "ai_tiny_unsigned" })
        let int = try #require(found.first { $0.table == "ai_int" })

        #expect(tiny.schema == nil)
        #expect(tiny.objectName == "id")
        #expect(tiny.sizeBytes == 16384)
        #expect(tiny.metric("auto_increment")?.value == .bigCount(200))
        #expect(tiny.metric("max_value")?.value == .bigCount(255))
        #expect(tiny.metric("used_percent")?.value == .percent(200.0 / 255.0))
        #expect(tiny.metric("column_type")?.value == .text("tinyint unsigned"))
        #expect(tiny.fixSQL == "ALTER TABLE `shop`.`ai_tiny_unsigned` MODIFY COLUMN `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;")
        #expect(int.fixSQL == "ALTER TABLE `shop`.`ai_int` MODIFY COLUMN `id` BIGINT NOT NULL AUTO_INCREMENT;")
    }

    @Test("MariaDB's display widths do not reach the new type, except the width a ZEROFILL column pads to")
    func nearLimitReadsMariaDBTypes() {
        let signed = nearLimitFix(CounterRow(columnType: "int(11)", next: "1700000001", max: "2147483647"))
        let unsigned = nearLimitFix(CounterRow(dataType: "tinyint", columnType: "tinyint(3) unsigned", next: "200", max: "255"))
        let zerofill = nearLimitFix(CounterRow(columnType: "int(5) unsigned zerofill", next: "4000000000", max: "4294967295"))
        let nullable = nearLimitFix(CounterRow(columnType: "int(11)", nullable: "YES", next: "1700000001", max: "2147483647"))

        #expect(signed == "ALTER TABLE `shop`.`orders` MODIFY COLUMN `id` BIGINT NOT NULL AUTO_INCREMENT;")
        #expect(unsigned == "ALTER TABLE `shop`.`orders` MODIFY COLUMN `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;")
        #expect(zerofill == "ALTER TABLE `shop`.`orders` MODIFY COLUMN `id` BIGINT(5) UNSIGNED ZEROFILL NOT NULL AUTO_INCREMENT;")
        #expect(nullable == "ALTER TABLE `shop`.`orders` MODIFY COLUMN `id` BIGINT NULL AUTO_INCREMENT;")
    }

    @Test("An unsigned bigint counter past Int64 keeps its exact value and has no fix; a signed one can drop its sign")
    func nearLimitAtTheWidestType() throws {
        let found = nearLimit([
            CounterRow(
                table: "events", dataType: "bigint", columnType: "bigint unsigned",
                next: "15000000000000000000", max: "18446744073709551615"
            ),
            CounterRow(table: "logs", dataType: "bigint", columnType: "bigint(20)", next: "7000000000000000000", max: "9223372036854775807")
        ]).findings
        let unsigned = try #require(found.first { $0.table == "events" })
        let signed = try #require(found.first { $0.table == "logs" })

        #expect(unsigned.metric("auto_increment")?.value == .bigCount(15_000_000_000_000_000_000))
        #expect(unsigned.metric("max_value")?.value == .bigCount(UInt64.max))
        #expect(unsigned.fixSQL == nil)
        #expect(!unsigned.detail.isEmpty)
        #expect(signed.metric("max_value")?.value == .bigCount(UInt64(Int64.max)))
        #expect(signed.fixSQL == "ALTER TABLE `shop`.`logs` MODIFY COLUMN `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;")
    }

    @Test("The fix states the whole column again: an invisible column stays invisible and a hostile comment stays one literal")
    func nearLimitRestatesTheColumn() {
        let comment = "it's a \\ path\n*/ DROP TABLE x; -- "
        let mysql = nearLimitFix(CounterRow(
            table: "odd`name", column: "se`q", dataType: "smallint", columnType: "smallint", comment: comment,
            extra: "auto_increment INVISIBLE", next: "30001", max: "32767"
        ))
        let mariadb = nearLimitFix(CounterRow(
            dataType: "smallint", columnType: "smallint(6)", comment: "row counter", extra: "auto_increment, INVISIBLE",
            next: "30001", max: "32767"
        ))
        let visible = nearLimitFix(CounterRow(dataType: "smallint", columnType: "smallint", next: "30001", max: "32767"))

        #expect(mysql == "ALTER TABLE `shop`.`odd``name` MODIFY COLUMN `se``q` BIGINT NOT NULL AUTO_INCREMENT INVISIBLE COMMENT 'it''s a \\\\ path\n*/ DROP TABLE x; -- ';")
        #expect(mariadb == "ALTER TABLE `shop`.`orders` MODIFY COLUMN `id` BIGINT NOT NULL AUTO_INCREMENT INVISIBLE COMMENT 'row counter';")
        #expect(visible == "ALTER TABLE `shop`.`orders` MODIFY COLUMN `id` BIGINT NOT NULL AUTO_INCREMENT;")
    }

    @Test("A counter a foreign key uses at either end names each key, and the fix still widens the column")
    func nearLimitNamesForeignKeys() throws {
        let found = nearLimit(
            [
                CounterRow(table: "ai_parent", next: "1800000001", max: "2147483647"),
                CounterRow(table: "ai_child", column: "seq", next: "1800000001", max: "2147483647"),
                CounterRow(table: "ai_alone", next: "1800000001", max: "2147483647")
            ],
            foreignKeys: [
                KeyRow(
                    table: "ai_child", constraint: "ai_child_fk", column: "parent_id",
                    referencedTable: "ai_parent", referencedColumn: "ID", referencesHere: true
                ),
                KeyRow(
                    schema: "archive", table: "audit", constraint: "audit_fk", column: "parent_id",
                    referencedTable: "ai_parent", referencedColumn: "id", referencesHere: true
                ),
                KeyRow(table: "ai_child", constraint: "ai_child_seq_fk", column: "seq", referencedTable: "elsewhere", referencedColumn: "id")
            ]
        ).findings
        let parent = try #require(found.first { $0.table == "ai_parent" })
        let child = try #require(found.first { $0.table == "ai_child" })
        let alone = try #require(found.first { $0.table == "ai_alone" })

        #expect(parent.detail.contains("ai_child_fk"))
        #expect(parent.detail.contains("archive.audit"))
        #expect(!parent.detail.contains("ai_child_seq_fk"))
        #expect(parent.fixSQL == "ALTER TABLE `shop`.`ai_parent` MODIFY COLUMN `id` BIGINT NOT NULL AUTO_INCREMENT;")
        #expect(child.detail.contains("ai_child_seq_fk"))
        #expect(!alone.detail.contains("_fk"))
    }

    @Test("On MySQL 8 the cached checks say information_schema may lag; MariaDB and MySQL 5.7 read live values")
    func statisticsCacheNote() {
        let reclaimable = { (server: TableHealthStatistics) in
            self.provider.findings(
                for: .reclaimableSpace,
                from: [TableHealthFixture.result(columns: Self.reclaimableColumns, rows: [])],
                context: self.context,
                statistics: server
            ).note
        }
        let mysql8 = statistics(version: "8.4.13")

        #expect(nearLimit([], statistics: mysql8).note?.contains("information_schema_stats_expiry") == true)
        #expect(reclaimable(mysql8)?.contains("information_schema_stats_expiry") == true)
        #expect(nearLimit([], statistics: statistics(version: "11.4.13-MariaDB-ubu2404")).note == nil)
        #expect(reclaimable(statistics(version: "11.4.13-MariaDB-ubu2404")) == nil)
        #expect(nearLimit([], statistics: statistics(version: "5.7.44")).note == nil)
    }

    @Test("A table with reclaimable space carries its typed values and previews OPTIMIZE TABLE")
    func reclaimableSpaceFinding() throws {
        let found = provider.findings(
            for: .reclaimableSpace,
            from: [TableHealthFixture.result(
                columns: Self.reclaimableColumns,
                rows: [
                    ["fx_parts", "InnoDB", "122895", "134905856", "148897792"],
                    ["odd`name", "MyISAM", "131072", "241770496", "119537664"]
                ]
            )],
            context: context,
            statistics: statistics(version: "8.4.13")
        ).findings
        let parts = try #require(found.first)
        let myisam = try #require(found.last)

        #expect(found.count == 2)
        #expect(parts.schema == nil)
        #expect(parts.table == "fx_parts")
        #expect(parts.objectName == nil)
        #expect(parts.sizeBytes == 134_905_856)
        #expect(parts.metric("free_bytes")?.value == .bytes(148_897_792))
        #expect(parts.metric("free_percent")?.value == .percent(148_897_792.0 / (134_905_856.0 + 148_897_792.0)))
        #expect(parts.metric("estimated_rows")?.value == .count(122_895))
        #expect(parts.metric("engine")?.value == .text("InnoDB"))
        #expect(parts.fixSQL == "OPTIMIZE TABLE `shop`.`fx_parts`;")
        #expect(myisam.fixSQL == "OPTIMIZE TABLE `shop`.`odd``name`;")
    }

    @Test("The reclaimable space check reads MySQL 8's tablespace tables on MySQL and MariaDB's own on MariaDB")
    func reclaimableQueryFollowsTheServer() async throws {
        let mysql = try await report(version: "8.4.13-log")
        let mariadb = try await report(version: "11.4.13-MariaDB-ubu2404")

        #expect(mysql.asked.contains(MySQLTableHealthProvider.reclaimableSpaceQuery))
        #expect(!mysql.asked.contains(MySQLTableHealthProvider.mariaDBReclaimableSpaceQuery))
        #expect(mariadb.asked.contains(MySQLTableHealthProvider.mariaDBReclaimableSpaceQuery))
        #expect(!mariadb.asked.contains(MySQLTableHealthProvider.reclaimableSpaceQuery))
        #expect(mysql.report.result(for: .reclaimableSpace)?.outcome == .completed)
        #expect(mariadb.report.result(for: .reclaimableSpace)?.outcome == .completed)
    }

    @Test("Without PROCESS, or before MySQL 8.0, the reclaimable space check is skipped with its reason and the rest run")
    func reclaimableSkips() async throws {
        let denied = try await report(version: "8.4.13", canReadInnoDB: false)
        let old = try await report(version: "5.7.44")

        guard case .skipped(let reason) = denied.report.result(for: .reclaimableSpace)?.outcome else {
            Issue.record("the check ran without PROCESS")
            return
        }
        #expect(reason.contains("PROCESS"))
        #expect(!denied.asked.contains(MySQLTableHealthProvider.reclaimableSpaceQuery))
        #expect(denied.report.result(for: .nearLimit)?.outcome == .completed)
        #expect(denied.report.result(for: .missingPrimaryKey)?.outcome == .completed)
        guard case .skipped(let oldReason) = old.report.result(for: .reclaimableSpace)?.outcome else {
            Issue.record("the check ran on MySQL 5.7")
            return
        }
        #expect(oldReason.contains("8.0"))
        #expect(statistics(version: "11.4.13-MariaDB", canReadInnoDB: false).skippedChecks[.reclaimableSpace] != nil)
    }
}
