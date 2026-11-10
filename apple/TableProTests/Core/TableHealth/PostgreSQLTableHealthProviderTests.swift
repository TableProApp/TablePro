import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct PostgreSQLTableHealthProviderTests {
    private struct QueryFailure: LocalizedError {
        var errorDescription: String? { "permission denied for pg_stat_user_tables" }
    }

    private static let statisticsColumns = ["track_counts", "stats_reset", "server_version_num", "in_recovery", "standbys"]

    private let provider = PostgreSQLTableHealthProvider()
    private let context = TableHealthFixture.postgresContext()

    private func findings(
        _ check: TableHealthCheckKind,
        columns: [String],
        rows: [[String?]],
        statistics: TableHealthStatistics = TableHealthStatistics()
    ) -> [TableHealthFinding] {
        output(check, columns: columns, rows: rows, statistics: statistics).findings
    }

    private func output(
        _ check: TableHealthCheckKind,
        columns: [String],
        rows: [[String?]],
        statistics: TableHealthStatistics = TableHealthStatistics()
    ) -> (findings: [TableHealthFinding], note: String?) {
        provider.findings(
            for: check,
            from: [TableHealthFixture.result(columns: columns, rows: rows)],
            context: context,
            statistics: statistics
        )
    }

    private static func statisticsResult(
        trackCounts: String = "on",
        statsReset: String? = nil,
        version: String? = "170011",
        inRecovery: String? = "f",
        standbys: String? = "0"
    ) -> QueryResult {
        TableHealthFixture.result(columns: statisticsColumns, rows: [[trackCounts, statsReset, version, inRecovery, standbys]])
    }

    private func statistics(
        trackCounts: String = "on",
        statsReset: String? = nil,
        version: String? = "170011",
        inRecovery: String? = "f",
        standbys: String? = "0"
    ) -> TableHealthStatistics {
        provider.statistics(
            from: [Self.statisticsResult(
                trackCounts: trackCounts, statsReset: statsReset, version: version, inRecovery: inRecovery, standbys: standbys
            )],
            now: Date()
        )
    }

    @Test("The factory gives PostgreSQL, MySQL and MariaDB a provider and no other engine")
    func factoryCoversThreeEngines() {
        #expect(TableHealthProviderFactory.provider(for: .postgresql) is PostgreSQLTableHealthProvider)
        #expect(TableHealthProviderFactory.provider(for: .mysql) is MySQLTableHealthProvider)
        #expect(TableHealthProviderFactory.provider(for: .mariadb) is MySQLTableHealthProvider)
        #expect(TableHealthProviderFactory.provider(for: .sqlite) == nil)
        #expect(TableHealthProviderFactory.provider(for: .mssql) == nil)
    }

    @Test("A bloated table carries its rows, dead share, last vacuum and size as values, and previews a vacuum")
    func bloatFinding() throws {
        let vacuumed = Date(timeIntervalSince1970: 1_800_000_000)
        let finding = try #require(findings(
            .bloat,
            columns: ["schema_name", "table_name", "live_rows", "dead_rows", "last_vacuum", "table_bytes"],
            rows: [["public", "orders", "2000", "3000", "1800000000", "81920"]]
        ).first)

        #expect(finding.schema == "public")
        #expect(finding.table == "orders")
        #expect(finding.objectName == nil)
        #expect(finding.sizeBytes == 81_920)
        #expect(finding.metric("dead_rows")?.value == .count(3_000))
        #expect(finding.metric("live_rows")?.value == .count(2_000))
        #expect(finding.metric("dead_percent")?.value == .percent(0.6))
        #expect(finding.metric("last_vacuum")?.value == .date(vacuumed))
        #expect(finding.metric("table_bytes") == nil)
        #expect(finding.detail.contains(TableHealthFormatting.date(vacuumed)))
        #expect(finding.fixSQL == #"VACUUM (ANALYZE) "public"."orders";"#)
    }

    @Test("A table with no vacuum recorded says only that, since a crash also empties the record, and has no last vacuum value")
    func neverVacuumed() throws {
        let finding = try #require(findings(
            .bloat,
            columns: ["schema_name", "table_name", "live_rows", "dead_rows", "last_vacuum", "table_bytes", "stats_reset"],
            rows: [["public", "orders", "2000", "3000", nil, "81920", nil]]
        ).first)
        #expect(finding.detail == String(
            format: String(localized: "%1$@ dead rows, %2$@ live. No vacuum recorded in the server's statistics."),
            (3_000 as Int64).formatted(), (2_000 as Int64).formatted()
        ))
        #expect(!finding.detail.contains("Never"))
        #expect(finding.metric("last_vacuum") == nil)
    }

    @Test("The bloat check states the rule its query applies")
    func bloatSummaryStatesRule() {
        let summary = provider.check(.bloat).summary
        #expect(summary.contains("1,000"))
        #expect(summary.contains("20%"))
    }

    @Test("An unused index previews a concurrent drop and is sized by the index")
    func unusedIndexFinding() throws {
        let finding = try #require(findings(
            .unusedIndex,
            columns: ["schema_name", "table_name", "index_name", "index_bytes"],
            rows: [["sales", "orders", "orders_note_idx", "8192"]]
        ).first)

        #expect(finding.table == "orders")
        #expect(finding.objectName == "orders_note_idx")
        #expect(finding.sizeBytes == 8_192)
        #expect(finding.fixSQL == #"DROP INDEX CONCURRENTLY "sales"."orders_note_idx";"#)
    }

    @Test("An unused index says only that the server's statistics hold no scans, which a reset or a crash also empties")
    func unusedIndexDetailClaimsOnlyTheStatistics() throws {
        let finding = try #require(findings(
            .unusedIndex,
            columns: ["schema_name", "table_name", "index_name", "index_bytes"],
            rows: [["sales", "orders", "orders_note_idx", "8192"]]
        ).first)
        #expect(finding.detail == String(
            format: String(localized: "%1$@ has no scans in the server's statistics. It takes %2$@."),
            "orders_note_idx", ByteSizeFormatting.string(byteString: "8192")
        ))
        #expect(!finding.detail.contains("never"))
    }

    @Test("A table without a primary key quotes its name in the preview and carries its rows and size")
    func missingPrimaryKeyQuotesName() throws {
        let finding = try #require(findings(
            .missingPrimaryKey,
            columns: ["schema_name", "table_name", "estimated_rows", "table_bytes"],
            rows: [["public", #"Odd "Name""#, "1200", "65536"]]
        ).first)
        #expect(finding.fixSQL == #"ALTER TABLE "public"."Odd ""Name""" ADD PRIMARY KEY (column_name);"#)
        #expect(finding.metric("estimated_rows")?.value == .count(1_200))
        #expect(finding.sizeBytes == 65_536)
    }

    @Test("A table the server has not measured, a partitioned parent or one freshly loaded, carries no row estimate rather than 0")
    func unmeasuredTableHasNoRowEstimate() throws {
        let noKey = try #require(findings(
            .missingPrimaryKey,
            columns: ["schema_name", "table_name", "estimated_rows", "table_bytes"],
            rows: [["public", "events", nil, nil]]
        ).first)
        #expect(noKey.metric("estimated_rows") == nil)
        #expect(noKey.sizeBytes == nil)

        let foreignKey = try #require(findings(
            .unindexedForeignKey,
            columns: [
                "schema_name", "table_name", "table_kind", "constraint_name", "column_name",
                "referenced_schema", "referenced_table", "estimated_rows", "table_bytes"
            ],
            rows: [["public", "line", "r", "line_order_fk", "order_id", "sales", "orders", nil, nil]]
        ).first)
        #expect(foreignKey.metric("estimated_rows") == nil)
        #expect(foreignKey.metric("referenced_table")?.value == .text("sales.orders"))
    }

    @Test("A foreign key's column rows fold into one finding, in key order")
    func foreignKeyColumnsGroup() {
        let found = findings(
            .unindexedForeignKey,
            columns: ["schema_name", "table_name", "table_kind", "constraint_name", "column_name"],
            rows: [
                ["public", "line", "r", "line_order_fk", "order_id"],
                ["public", "line", "r", "line_pair_fk", "y"],
                ["public", "line", "r", "line_pair_fk", "x"],
                ["audit", "line", "r", "line_order_fk", "order_id"]
            ]
        )

        #expect(found.map { $0.objectName } == ["line_order_fk", "line_pair_fk", "line_order_fk"])
        #expect(found.map { $0.schema } == ["public", "public", "audit"])
        #expect(found[0].fixSQL == #"CREATE INDEX CONCURRENTLY ON "public"."line" ("order_id");"#)
        #expect(found[1].fixSQL == #"CREATE INDEX CONCURRENTLY ON "public"."line" ("y", "x");"#)
        #expect(found[1].metric("columns")?.value == .text("y, x"))
    }

    @Test("A foreign key names the table it references and carries the referencing table's rows and size")
    func foreignKeyValues() throws {
        let finding = try #require(findings(
            .unindexedForeignKey,
            columns: [
                "schema_name", "table_name", "table_kind", "constraint_name", "column_name",
                "referenced_schema", "referenced_table", "estimated_rows", "table_bytes"
            ],
            rows: [["public", "line", "r", "line_order_fk", "order_id", "sales", "orders", "5000", "40960"]]
        ).first)
        #expect(finding.metric("referenced_table")?.value == .text("sales.orders"))
        #expect(finding.metric("estimated_rows")?.value == .count(5_000))
        #expect(finding.sizeBytes == 40_960)
    }

    @Test("A partitioned table's index is not built concurrently, which PostgreSQL refuses there")
    func partitionedTableIndexIsPlain() throws {
        let finding = try #require(findings(
            .unindexedForeignKey,
            columns: ["schema_name", "table_name", "table_kind", "constraint_name", "column_name"],
            rows: [["public", "events", "p", "events_user_fk", "user_id"]]
        ).first)
        #expect(finding.fixSQL == #"CREATE INDEX ON "public"."events" ("user_id");"#)
    }

    @Test("Findings of one kind have distinct ids, so the list can select each")
    func findingIdsAreDistinct() {
        let ids = findings(
            .unusedIndex,
            columns: ["schema_name", "table_name", "index_name", "index_bytes"],
            rows: [["a", "t", "i1", "1"], ["a", "t", "i2", "1"], ["b", "t", "i1", "1"]]
        ).map { $0.id }
        #expect(Set(ids).count == 3)
    }

    @Test("A finding is the same finding when its numbers move between runs")
    func identityIgnoresNumbers() throws {
        let columns = ["schema_name", "table_name", "index_name", "index_bytes"]
        let before = try #require(findings(.unusedIndex, columns: columns, rows: [["a", "t", "i1", "8192"]]).first)
        let after = try #require(findings(.unusedIndex, columns: columns, rows: [["a", "t", "i1", "16384"]]).first)
        #expect(before == after)
        #expect(Set([before, after]).count == 1)
    }

    @Test("The note names when statistics were reset, or that they never were")
    func statisticsNote() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(statistics(statsReset: "1800000000").notes == [
            String(format: String(localized: "Index usage counts since the statistics were last reset at %@."), TableHealthFormatting.date(reset))
        ])
        #expect(statistics(statsReset: nil).notes == [String(
            localized: "Index usage counts cover only what the server's statistics hold; a reset, a crash or a failover discards them."
        )])
        #expect(provider.statistics(from: [nil], now: Date()) == TableHealthStatistics())
    }

    @Test("The statistics read the server version")
    func serverVersion() {
        #expect(statistics(version: "90624").serverVersion == 90_624)
        #expect(statistics(version: "170011").serverVersion == 170_011)
        #expect(statistics(version: nil).serverVersion == nil)
        #expect(statistics().isStandby == false)
    }

    @Test("With track_counts off, the checks that read activity counters are skipped")
    func trackCountsOffSkipsCounterChecks() {
        let stats = statistics(trackCounts: "off")
        #expect(stats.skippedChecks[.bloat] != nil)
        #expect(stats.skippedChecks[.unusedIndex] != nil)
        #expect(stats.skippedChecks[.staleStatistics] != nil)
        #expect(stats.skippedChecks[.missingPrimaryKey] == nil)
        #expect(stats.skippedChecks[.unindexedForeignKey] == nil)
        #expect(stats.skippedChecks[.transactionIdAge] == nil)
        #expect(stats.notes.isEmpty)
    }

    @Test("On a standby the counter checks are skipped with the reason, and the report says to fix on the primary")
    func standbySkipsCounterChecks() {
        let stats = statistics(inRecovery: "t")
        let reason = String(localized: "This server is a standby. Its activity counters do not reflect the primary.")
        #expect(stats.isStandby)
        #expect(stats.skippedChecks[.bloat] == reason)
        #expect(stats.skippedChecks[.unusedIndex] == reason)
        #expect(stats.skippedChecks[.staleStatistics] == reason)
        for structural in [TableHealthCheckKind.missingPrimaryKey, .unindexedForeignKey, .redundantIndex, .invalidIndex, .nearLimit, .transactionIdAge] {
            #expect(stats.skippedChecks[structural] == nil, "\(structural.rawValue) is skipped on a standby")
        }
        #expect(stats.notes == [String(localized: "This server is a read-only standby. Run the fixes on the primary.")])
    }

    @Test("A standby report runs the structural checks only and carries the standby note")
    func standbyReport() async throws {
        var asked: [String] = []
        let report = try await provider.fetchReport(context: context) { query in
            asked.append(query)
            if query == PostgreSQLTableHealthProvider.statisticsQuery {
                return Self.statisticsResult(inRecovery: "t")
            }
            if query == PostgreSQLTableHealthProvider.missingPrimaryKeyQuery {
                return TableHealthFixture.result(columns: ["schema_name", "table_name"], rows: [["public", "logs"]])
            }
            return TableHealthFixture.empty()
        }

        #expect(!asked.contains(PostgreSQLTableHealthProvider.bloatQuery))
        #expect(!asked.contains(PostgreSQLTableHealthProvider.unusedIndexQuery))
        #expect(!asked.contains(PostgreSQLTableHealthProvider.staleStatisticsQuery))
        #expect(asked.contains(PostgreSQLTableHealthProvider.unindexedForeignKeyQuery))
        #expect(asked.contains(PostgreSQLTableHealthProvider.redundantIndexQuery))
        #expect(asked.contains(PostgreSQLTableHealthProvider.invalidIndexQuery))
        #expect(asked.contains(PostgreSQLTableHealthProvider.nearLimitQuery))
        #expect(asked.contains(PostgreSQLTableHealthProvider.transactionIdAgeQuery))
        #expect(report.result(for: .staleStatistics)?.outcome == .skipped(
            String(localized: "This server is a standby. Its activity counters do not reflect the primary.")
        ))
        #expect(report.result(for: .missingPrimaryKey)?.outcome == .completed)
        #expect(report.result(for: .missingPrimaryKey)?.findings.count == 1)
        #expect(report.notes.contains(String(localized: "This server is a read-only standby. Run the fixes on the primary.")))
    }

    @Test("A skipped check runs nothing and says why")
    func skippedCheckRunsNothing() async throws {
        var asked: [String] = []
        let report = try await provider.fetchReport(context: context) { query in
            asked.append(query)
            if query == PostgreSQLTableHealthProvider.statisticsQuery {
                return Self.statisticsResult(trackCounts: "off")
            }
            return TableHealthFixture.empty()
        }

        #expect(!asked.contains(PostgreSQLTableHealthProvider.bloatQuery))
        #expect(!asked.contains(PostgreSQLTableHealthProvider.unusedIndexQuery))
        #expect(!asked.contains(PostgreSQLTableHealthProvider.staleStatisticsQuery))
        #expect(report.result(for: .bloat)?.outcome == .skipped(statistics(trackCounts: "off").skippedChecks[.bloat] ?? ""))
        #expect(report.result(for: .missingPrimaryKey)?.outcome == .completed)
    }

    @Test("A failing check reports its error and leaves the other checks standing")
    func failingCheckIsolated() async throws {
        let generated = Date(timeIntervalSince1970: 1_800_000_000)
        let report = try await provider.fetchReport(context: context, now: generated) { query in
            if query == PostgreSQLTableHealthProvider.bloatQuery { throw QueryFailure() }
            if query == PostgreSQLTableHealthProvider.missingPrimaryKeyQuery {
                return TableHealthFixture.result(columns: ["schema_name", "table_name"], rows: [["public", "logs"]])
            }
            return TableHealthFixture.empty()
        }

        #expect(report.database == "shop")
        #expect(report.generatedAt == generated)
        #expect(report.checks.map { $0.kind } == [
            .bloat, .unusedIndex, .redundantIndex, .invalidIndex, .missingPrimaryKey, .unindexedForeignKey,
            .nearLimit, .transactionIdAge, .staleStatistics
        ])
        #expect(report.checks.map { $0.check } == provider.checks.map { provider.check($0) })
        #expect(report.result(for: .bloat)?.outcome == .failed("permission denied for pg_stat_user_tables"))
        #expect(report.result(for: .missingPrimaryKey)?.findings.map { $0.table } == ["logs"])
        #expect(report.findingCount == 1)
    }

    @Test("A statistics query that fails leaves every check to run")
    func failedStatisticsRunsEveryCheck() async throws {
        let report = try await provider.fetchReport(context: context) { query in
            if query == PostgreSQLTableHealthProvider.statisticsQuery { throw QueryFailure() }
            return TableHealthFixture.empty()
        }
        #expect(report.checks.allSatisfy { $0.outcome == .completed })
        #expect(report.notes.isEmpty)
    }

    @Test("A cancelled refresh stops instead of reporting every check as failed")
    func cancellationPropagates() async {
        await #expect(throws: CancellationError.self) {
            _ = try await provider.fetchReport(context: context) { _ in throw CancellationError() }
        }
    }

    @Test("Every check the provider lists has a query on every server it can meet, so none reports nothing found unread")
    func everyCheckHasAQuery() {
        var servers = [provider.statistics(from: [nil], now: Date())]
        for version in ["90624", "100000", "120000", "170011", nil] {
            for trackCounts in ["on", "off"] {
                for inRecovery in ["t", "f"] {
                    servers.append(statistics(trackCounts: trackCounts, version: version, inRecovery: inRecovery))
                }
            }
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

    // TimescaleDB's chunk tables are not extension members, but their schema is.
    // The queries a check runs on a server too old for some of them, on a current one, and on one whose version did not read.
    private func everyServerQuery(for check: TableHealthCheckKind) -> [String] {
        let servers = [TableHealthStatistics(), statistics(version: "110000"), statistics(version: "170011")]
        var queries: [String] = []
        for server in servers {
            for query in provider.queries(for: check, statistics: server) where !queries.contains(query) {
                queries.append(query)
            }
        }
        return queries
    }

    @Test("Every check query leaves out extension members, by relation and by schema")
    func everyQueryLeavesOutExtensions() {
        for check in provider.checks {
            for query in everyServerQuery(for: check) {
                #expect(query.contains("'pg_catalog.pg_class'::pg_catalog.regclass"), "\(check.rawValue) keeps extension relations")
                #expect(query.contains("'pg_catalog.pg_namespace'::pg_catalog.regclass"), "\(check.rawValue) keeps extension schemas")
                #expect(query.contains("deptype = 'e'"), "\(check.rawValue) keeps extension members")
            }
        }
    }

    @Test("Every query the report runs only reads")
    func queriesOnlyRead() {
        let queries = provider.statisticsQueries + provider.checks.flatMap { everyServerQuery(for: $0) }
        for query in queries {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(text.uppercased().hasPrefix("SELECT"), "\(text.prefix(40)) does not start with SELECT")
        }
    }

    private static let invalidColumns = [
        "schema_name", "table_name", "index_name", "is_unique", "is_ready", "index_bytes", "index_definition"
    ]

    private func invalid(_ index: String, unique: Bool = false, ready: Bool = true, version: String?) throws -> TableHealthFinding {
        let definition = unique
            ? "CREATE UNIQUE INDEX \(index) ON public.inv USING btree (v)"
            : "CREATE INDEX \(index) ON public.inv USING btree (v, w)"
        return try #require(findings(
            .invalidIndex,
            columns: Self.invalidColumns,
            rows: [["public", "inv", index, unique ? "t" : "f", ready ? "t" : "f", "16384", definition]],
            statistics: statistics(version: version)
        ).first)
    }

    @Test("An invalid index rebuilds concurrently from PostgreSQL 12, and carries its size, definition and state")
    func invalidIndexReindexes() throws {
        let finding = try invalid("inv_vw_cancelled", version: "170011")
        #expect(finding.table == "inv")
        #expect(finding.objectName == "inv_vw_cancelled")
        #expect(finding.sizeBytes == 16_384)
        #expect(finding.fixSQL == #"REINDEX INDEX CONCURRENTLY "public"."inv_vw_cancelled";"#)
        #expect(finding.metric("index_definition")?.value == .text("CREATE INDEX inv_vw_cancelled ON public.inv USING btree (v, w)"))
        #expect(finding.metric("is_unique")?.value == .flag(false))
        #expect(finding.metric("is_ready")?.value == .flag(true))
        #expect(try invalid("inv_vw_cancelled", version: "120000").fixSQL == #"REINDEX INDEX CONCURRENTLY "public"."inv_vw_cancelled";"#)
    }

    @Test("Before PostgreSQL 12, or with no version read, an invalid index is dropped and built again concurrently")
    func invalidIndexBeforeTwelve() throws {
        let plain = try invalid("inv_vw_cancelled", version: "110000")
        #expect(plain.fixSQL == """
            DROP INDEX CONCURRENTLY "public"."inv_vw_cancelled";
            CREATE INDEX CONCURRENTLY inv_vw_cancelled ON public.inv USING btree (v, w);
            """)
        let unique = try invalid("inv_v_uniq", unique: true, version: nil)
        #expect(unique.fixSQL == """
            DROP INDEX CONCURRENTLY "public"."inv_v_uniq";
            CREATE UNIQUE INDEX CONCURRENTLY inv_v_uniq ON public.inv USING btree (v);
            """)
    }

    @Test("A copy an interrupted REINDEX CONCURRENTLY left is dropped, not rebuilt")
    func reindexLeftoverIsDropped() throws {
        for name in ["inv_v_uniq_ccnew", "inv_w_idx_ccold", "inv_w_idx_ccnew1"] {
            #expect(try invalid(name, version: "170011").fixSQL == "DROP INDEX CONCURRENTLY \"public\".\"\(name)\";")
        }
        #expect(try invalid("inv_w_idx_ccnew", version: nil).fixSQL == #"DROP INDEX CONCURRENTLY "public"."inv_w_idx_ccnew";"#)
        #expect(try invalid("inv_ccnew_backup", version: "170011").fixSQL == #"REINDEX INDEX CONCURRENTLY "public"."inv_ccnew_backup";"#)
        #expect(try invalid("inv_w_idx_ccnew", version: "110000").fixSQL?.hasPrefix("DROP INDEX CONCURRENTLY") == true)
        #expect(try invalid("inv_w_idx_ccnew", version: "110000").fixSQL?.contains("CREATE INDEX CONCURRENTLY") == true)
    }

    @Test("An invalid unique index warns that duplicate values make the rebuild fail")
    func invalidUniqueWarnsOfDuplicates() throws {
        let duplicates = String(localized: "Rebuilding a unique index fails while the table holds duplicate values.")
        #expect(try invalid("inv_v_uniq", unique: true, ready: false, version: "170011").detail.contains(duplicates))
        #expect(try !invalid("inv_vw_cancelled", version: "170011").detail.contains(duplicates))
        #expect(try invalid("inv_v_uniq", unique: true, ready: false, version: "170011").metric("is_ready")?.value == .flag(false))
    }

    private static let sequenceColumns = [
        "sequence_schema", "sequence_name", "sequence_type", "increment_by", "sequence_min", "sequence_max",
        "last_value", "lower_bound", "upper_bound", "used_fraction", "readable", "locked",
        "table_schema", "table_name", "column_name", "column_type", "column_min", "column_max", "ownership",
        "table_bytes", "referencing_columns"
    ]

    private struct SequenceRow {
        let name: String
        var type = "integer"
        var increment = "1"
        var minimum = "1"
        var maximum = "2147483647"
        var last: String? = "1700000000"
        var lower = "1"
        var upper = "2147483647"
        var used: String? = "0.79162418869475292852"
        var readable = "t"
        var locked = "f"
        var table: String?
        var column: String? = "id"
        var columnType: String? = "integer"
        var columnMin: String? = "-2147483648"
        var columnMax: String? = "2147483647"
        var ownership: String? = "owned"
        var referencing: String?

        var cells: [String?] {
            [
                "public", name, type, increment, minimum, maximum, last, lower, upper, used, readable, locked,
                table == nil ? nil : "public", table, table == nil ? nil : column, table == nil ? nil : columnType,
                table == nil ? nil : columnMin, table == nil ? nil : columnMax, table == nil ? nil : ownership,
                table == nil ? nil : "8192", referencing
            ]
        }
    }

    private func sequences(_ rows: [SequenceRow]) -> (findings: [TableHealthFinding], note: String?) {
        output(.nearLimit, columns: Self.sequenceColumns, rows: rows.map(\.cells))
    }

    private func sequenceFix(_ row: SequenceRow) throws -> String? {
        try #require(sequences([row]).findings.first).fixSQL
    }

    @Test("A serial column near its limit widens the column, then the sequence, which keeps its own type")
    func serialWidensColumnAndSequence() throws {
        let finding = try #require(sequences([
            SequenceRow(name: "seq_int_id_seq", table: "seq_int", referencing: "public.seq_int_child.seq_int_id")
        ]).findings.first)
        #expect(finding.schema == "public")
        #expect(finding.table == "seq_int")
        #expect(finding.objectName == "seq_int_id_seq")
        #expect(finding.sizeBytes == 8_192)
        #expect(finding.fixSQL == """
            ALTER TABLE "public"."seq_int" ALTER COLUMN "id" TYPE bigint;
            ALTER SEQUENCE "public"."seq_int_id_seq" AS bigint;
            """)
        #expect(finding.metric("used_percent")?.value == .percent(0.79162418869475292852))
        #expect(finding.metric("last_value")?.value == .count(1_700_000_000))
        #expect(finding.metric("upper_bound")?.value == .count(2_147_483_647))
        #expect(finding.metric("column")?.value == .text("id"))
        #expect(finding.metric("column_type")?.value == .text("integer"))
        #expect(finding.metric("referencing_columns")?.value == .text("public.seq_int_child.seq_int_id"))
        #expect(finding.detail.contains("public.seq_int_child.seq_int_id"))
        #expect(finding.detail.contains(String(
            localized: "Changing the column type rewrites the table and its indexes under an exclusive lock."
        )))
    }

    @Test("An identity column needs only the column change: its sequence follows")
    func identityWidensColumnOnly() throws {
        #expect(try sequenceFix(SequenceRow(
            name: "seq_identity_id_seq", last: "1800000000", used: "0.838", table: "seq_identity", ownership: "identity"
        )) == #"ALTER TABLE "public"."seq_identity" ALTER COLUMN "id" TYPE bigint;"#)
    }

    @Test("A bigint sequence feeding an integer column widens the column only")
    func bigintSequenceWidensColumnOnly() throws {
        #expect(try sequenceFix(SequenceRow(
            name: "seq_big_for_int", type: "bigint", maximum: "9223372036854775807", table: "seq_intcol_bigseq", ownership: "default"
        )) == #"ALTER TABLE "public"."seq_intcol_bigseq" ALTER COLUMN "id" TYPE bigint;"#)
    }

    @Test("An integer sequence feeding a bigint column changes only the sequence")
    func bigintColumnWidensSequenceOnly() throws {
        let finding = try #require(sequences([SequenceRow(
            name: "seq_int_typed", last: "2000000000", used: "0.931", table: "seq_bigcol_intseq",
            columnType: "bigint", columnMin: nil, columnMax: nil, ownership: "default"
        )]).findings.first)
        #expect(finding.fixSQL == #"ALTER SEQUENCE "public"."seq_int_typed" AS bigint;"#)
        #expect(!finding.detail.contains(String(
            localized: "Changing the column type rewrites the table and its indexes under an exclusive lock."
        )))
    }

    @Test("A sequence no column uses has no table and changes only itself")
    func standaloneSequence() throws {
        let finding = try #require(sequences([SequenceRow(
            name: "seq_standalone_small", type: "smallint", maximum: "32767", last: "30000", upper: "32767", used: "0.9155"
        )]).findings.first)
        #expect(finding.schema == "public")
        #expect(finding.table == nil)
        #expect(finding.sizeBytes == nil)
        #expect(finding.metric("column") == nil)
        #expect(finding.fixSQL == #"ALTER SEQUENCE "public"."seq_standalone_small" AS bigint;"#)
    }

    @Test("A descending sequence is measured toward its minimum")
    func descendingSequence() throws {
        let finding = try #require(sequences([SequenceRow(
            name: "seq_desc_s", increment: "-1", minimum: "-2147483648", maximum: "-1", last: "-1700000000",
            lower: "-2147483648", upper: "-1", table: "seq_desc", ownership: "default"
        )]).findings.first)
        #expect(finding.fixSQL == """
            ALTER TABLE "public"."seq_desc" ALTER COLUMN "id" TYPE bigint;
            ALTER SEQUENCE "public"."seq_desc_s" AS bigint;
            """)
        #expect(finding.detail.contains((-2_147_483_648 as Int64).formatted()))
    }

    @Test("A limit set below the sequence type's own is removed, since AS bigint keeps it")
    func explicitLimitIsRemoved() throws {
        #expect(try sequenceFix(SequenceRow(
            name: "seq_explicit", maximum: "1000", last: "900", upper: "1000", used: "0.8999"
        )) == #"ALTER SEQUENCE "public"."seq_explicit" AS bigint NO MAXVALUE;"#)
        #expect(try sequenceFix(SequenceRow(
            name: "seq_explicit_desc", increment: "-1", minimum: "-1000", maximum: "-1", last: "-900", lower: "-1000", upper: "-1"
        )) == #"ALTER SEQUENCE "public"."seq_explicit_desc" AS bigint NO MINVALUE;"#)
    }

    @Test("A bigint sequence and column have no wider type, so the finding has no fix")
    func bigintHasNoFix() throws {
        let finding = try #require(sequences([SequenceRow(
            name: "seq_huge", type: "bigint", maximum: "9223372036854775807", last: "9000000000000000000",
            upper: "9223372036854775807", used: "0.9758", table: "events", columnType: "bigint", columnMin: nil, columnMax: nil
        )]).findings.first)
        #expect(finding.fixSQL == nil)
        #expect(finding.detail.contains(String(localized: "The sequence and its column are already bigint, so no wider type exists.")))
    }

    @Test("Unreadable sequences become the check's note, never findings")
    func unreadableSequencesBecomeNote() {
        let secret = SequenceRow(name: "seq_secret", type: "smallint", last: nil, used: nil, readable: "f")
        let one = sequences([secret, SequenceRow(name: "seq_int_id_seq", table: "seq_int")])
        #expect(one.findings.map { $0.objectName } == ["seq_int_id_seq"])
        #expect(one.note == String(localized: "One sequence is not readable by this user, so its counter was not checked."))

        let two = sequences([secret, SequenceRow(name: "seq_other", last: nil, used: nil, readable: "f")])
        #expect(two.findings.isEmpty)
        #expect(two.note == String(
            format: String(localized: "%lld sequences are not readable by this user, so their counters were not checked."), 2
        ))
        #expect(sequences([SequenceRow(name: "seq_int_id_seq", table: "seq_int")]).note == nil)
    }

    @Test("The sequence check needs PostgreSQL 10, and is skipped before it without running")
    func sequencesNeedTen() async throws {
        #expect(statistics(version: "90624").skippedChecks[.nearLimit] == String(localized: "Needs PostgreSQL 10 or later."))
        #expect(statistics(version: "100000").skippedChecks[.nearLimit] == nil)
        #expect(statistics(version: nil).skippedChecks[.nearLimit] == nil)

        var asked: [String] = []
        let report = try await provider.fetchReport(context: context) { query in
            asked.append(query)
            if query == PostgreSQLTableHealthProvider.statisticsQuery {
                return Self.statisticsResult(version: "90624")
            }
            return TableHealthFixture.empty()
        }
        #expect(!asked.contains(PostgreSQLTableHealthProvider.nearLimitQuery))
        #expect(report.result(for: .nearLimit)?.outcome == .skipped(String(localized: "Needs PostgreSQL 10 or later.")))
        #expect(report.result(for: .invalidIndex)?.outcome == .completed)
    }

    @Test("The sequence check names itself after sequences")
    func sequenceCheckTitle() {
        #expect(provider.check(.nearLimit).title == String(localized: "Sequences Near Their Limit"))
        #expect(provider.check(.nearLimit).summary.contains("75%"))
    }

    @Test("A table past its freeze age previews a freeze and carries its ages as values")
    func transactionIdAgeFinding() throws {
        let finding = try #require(findings(
            .transactionIdAge,
            columns: [
                "schema_name", "table_name", "table_xid_age", "toast_xid_age", "xid_age", "freeze_max_age",
                "transactions_left", "last_vacuum", "table_bytes"
            ],
            rows: [["public", "xid_old", "200069", "200071", "200071", "100000", "2147283577", nil, "16384"]]
        ).first)
        #expect(finding.table == "xid_old")
        #expect(finding.objectName == nil)
        #expect(finding.sizeBytes == 16_384)
        #expect(finding.fixSQL == #"VACUUM (FREEZE) "public"."xid_old";"#)
        #expect(finding.metric("xid_age")?.value == .count(200_071))
        #expect(finding.metric("table_xid_age")?.value == .count(200_069))
        #expect(finding.metric("toast_xid_age")?.value == .count(200_071))
        #expect(finding.metric("freeze_max_age")?.value == .count(100_000))
        #expect(finding.metric("transactions_left")?.value == .count(2_147_283_577))
        #expect(finding.metric("last_vacuum") == nil)
        #expect(finding.detail.contains((100_000 as Int64).formatted()))
    }

    @Test("The wraparound summary states the freeze age it compares against")
    func transactionIdAgeSummary() {
        #expect(provider.check(.transactionIdAge).summary.contains("autovacuum_freeze_max_age"))
        #expect(provider.check(.transactionIdAge).summary.contains("200,000,000 by default"))
        #expect(provider.check(.staleStatistics).summary.contains("10%"))
        #expect(provider.check(.staleStatistics).summary.contains("50"))
    }

    private static let staleColumns = [
        "schema_name", "table_name", "table_kind", "live_rows", "modified_rows", "analyze_threshold", "never_analyzed",
        "last_analyze", "table_bytes"
    ]

    @Test("A table modified past the autoanalyze threshold previews an analyze and carries its counts")
    func staleStatisticsFinding() throws {
        let analyzed = Date(timeIntervalSince1970: 1_800_000_000)
        let finding = try #require(findings(
            .staleStatistics,
            columns: Self.staleColumns,
            rows: [["public", "st_stale", "r", "5000", "1000", "550", "f", "1800000000", "245760"]]
        ).first)
        #expect(finding.table == "st_stale")
        #expect(finding.sizeBytes == 245_760)
        #expect(finding.fixSQL == #"ANALYZE "public"."st_stale";"#)
        #expect(finding.metric("modified_rows")?.value == .count(1_000))
        #expect(finding.metric("live_rows")?.value == .count(5_000))
        #expect(finding.metric("analyze_threshold")?.value == .count(550))
        #expect(finding.metric("never_analyzed")?.value == .flag(false))
        #expect(finding.metric("last_analyze")?.value == .date(analyzed))
        #expect(finding.detail.contains(TableHealthFormatting.date(analyzed)))
    }

    @Test("A table never analyzed says so, and a partitioned one says only a manual analyze reaches it")
    func neverAnalyzed() throws {
        let found = findings(
            .staleStatistics,
            columns: Self.staleColumns,
            rows: [
                ["public", "st_never", "r", "5000", "5000", "50", "t", nil, "212992"],
                ["public", "st_part", "p", "0", "0", "50", "t", nil, "0"]
            ]
        )
        #expect(found.count == 2)
        #expect(found[0].detail == String(localized: "Never analyzed, so the planner has no statistics for it."))
        #expect(found[0].metric("last_analyze") == nil)
        #expect(found[0].metric("never_analyzed")?.value == .flag(true))
        #expect(found[1].detail.contains("partitioned"))
        #expect(found[1].metric("live_rows") == nil)
        #expect(found[1].metric("modified_rows") == nil)
        #expect(found[1].fixSQL == #"ANALYZE "public"."st_part";"#)
    }

    @Test("The redundant index summary says a plain index under a unique one counts, as the rule flags it")
    func redundantSummaryNamesUniqueCover() {
        #expect(provider.check(.redundantIndex).summary.contains("a plain one under a unique one"))
    }

    @Test("A bloated table with no vacuum since the statistics were reset says so, not that it was never vacuumed")
    func noVacuumSinceReset() throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let finding = try #require(findings(
            .bloat,
            columns: ["schema_name", "table_name", "live_rows", "dead_rows", "last_vacuum", "table_bytes", "stats_reset"],
            rows: [["public", "orders", "2000", "3000", nil, "81920", "1800000000"]]
        ).first)
        #expect(finding.detail.contains(TableHealthFormatting.date(reset)))
        #expect(!finding.detail.contains("Never vacuumed"))
        #expect(finding.metric("last_vacuum") == nil)
    }

    @Test("A table whose counters were emptied but still has statistics is stale by its modified rows, not never analyzed")
    func emptiedCountersAreNotNeverAnalyzed() throws {
        let finding = try #require(findings(
            .staleStatistics,
            columns: Self.staleColumns,
            rows: [["public", "st_reset", "r", "5000", "1000", "550", "f", nil, "245760"]]
        ).first)
        #expect(finding.detail == String(
            format: String(localized: "%1$@ rows modified since it was last analyzed, more than the %2$@ that start an autoanalyze."),
            (1_000 as Int64).formatted(), (550 as Int64).formatted()
        ))
        #expect(finding.metric("never_analyzed")?.value == .flag(false))
        #expect(finding.metric("last_analyze") == nil)
    }

    @Test("From PostgreSQL 12 only an index build hides its table's invalid indexes; before, or unread, any holder of its lock does")
    func invalidIndexQueryByVersion() {
        for version in ["120000", "170011"] {
            #expect(provider.queries(for: .invalidIndex, statistics: statistics(version: version))
                == [PostgreSQLTableHealthProvider.invalidIndexQuery])
        }
        #expect(provider.queries(for: .invalidIndex, statistics: statistics(version: "110000"))
            == [PostgreSQLTableHealthProvider.invalidIndexBefore12Query])
        #expect(provider.queries(for: .invalidIndex, statistics: TableHealthStatistics())
            == [PostgreSQLTableHealthProvider.invalidIndexBefore12Query])
    }

    @Test("A primary with standbys says their index scans are not counted, and a standby or a lone primary says nothing")
    func standbyScansNote() {
        let note = String(localized: "Index scans on this server's standbys are not counted here.")
        #expect(statistics(standbys: "2").notes.contains(note))
        #expect(!statistics(standbys: "0").notes.contains(note))
        #expect(!statistics(standbys: nil).notes.contains(note))
        #expect(!statistics(inRecovery: "t", standbys: "1").notes.contains(note))
    }

    @Test("A table whose statistics this user cannot read is not called never analyzed, and the detail says why")
    func unreadableStatisticsAreNotNeverAnalyzed() throws {
        let columns = Self.staleColumns + ["stats_readable"]
        let found = findings(
            .staleStatistics,
            columns: columns,
            rows: [
                ["public", "st_hidden", "r", "5000", "5000", "50", "t", nil, "212992", "f"],
                ["public", "st_never", "r", "5000", "5000", "50", "t", nil, "212992", "t"]
            ]
        )
        #expect(found.count == 2)
        #expect(found[0].detail == String(
            localized: "No analyze recorded in the server's statistics, and this user cannot read the table's statistics to confirm it."
        ))
        #expect(found[0].metric("never_analyzed") == nil)
        #expect(found[1].detail == String(localized: "Never analyzed, so the planner has no statistics for it."))
        #expect(found[1].metric("never_analyzed")?.value == .flag(true))
    }

    @Test("A sequence another session holds locked is left unread and counted in the check's note")
    func lockedSequencesBecomeNote() {
        let locked = SequenceRow(name: "seq_busy", last: nil, used: nil, locked: "t")
        let one = sequences([locked, SequenceRow(name: "seq_int_id_seq", table: "seq_int")])
        #expect(one.findings.map { $0.objectName } == ["seq_int_id_seq"])
        #expect(one.note == String(localized: "One sequence is locked by another session, so its counter was not checked."))

        let secret = SequenceRow(name: "seq_secret", type: "smallint", last: nil, used: nil, readable: "f")
        let both = sequences([locked, SequenceRow(name: "seq_busy_2", last: nil, used: nil, locked: "t"), secret])
        #expect(both.findings.isEmpty)
        #expect(both.note == [
            String(localized: "One sequence is not readable by this user, so its counter was not checked."),
            String(format: String(localized: "%lld sequences are locked by another session, so their counters were not checked."), 2)
        ].joined(separator: " "))
    }

    @Test("Before 12, an invalid index whose table was locked has no fix rather than a rebuild that blocks writes, and says to refresh")
    func lockedDefinitionHasNoFix() throws {
        let finding = try #require(findings(
            .invalidIndex,
            columns: Self.invalidColumns,
            rows: [["public", "inv", "inv_vw_cancelled", "f", "t", "16384", nil]],
            statistics: statistics(version: "110000")
        ).first)
        #expect(finding.fixSQL == nil)
        #expect(finding.detail.contains(String(
            localized: "Another session held its table locked, so its definition could not be read. Refresh once the lock is gone for a fix."
        )))
        #expect(finding.metric("index_definition") == nil)
        #expect(try invalid("inv_vw_cancelled", version: "170011").fixSQL == #"REINDEX INDEX CONCURRENTLY "public"."inv_vw_cancelled";"#)
    }
}
