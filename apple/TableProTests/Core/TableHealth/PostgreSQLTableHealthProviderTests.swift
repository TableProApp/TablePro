import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct PostgreSQLTableHealthProviderTests {
    private struct QueryFailure: LocalizedError {
        var errorDescription: String? { "permission denied for pg_stat_user_tables" }
    }

    private static let statisticsColumns = ["track_counts", "stats_reset", "server_version_num", "in_recovery"]

    private let provider = PostgreSQLTableHealthProvider()
    private let context = TableHealthFixture.postgresContext()

    private func findings(_ check: TableHealthCheckKind, columns: [String], rows: [[String?]]) -> [TableHealthFinding] {
        provider.findings(
            for: check,
            from: [TableHealthFixture.result(columns: columns, rows: rows)],
            context: context,
            statistics: TableHealthStatistics()
        ).findings
    }

    private static func statisticsResult(
        trackCounts: String = "on",
        statsReset: String? = nil,
        version: String? = "170011",
        inRecovery: String? = "f"
    ) -> QueryResult {
        TableHealthFixture.result(columns: statisticsColumns, rows: [[trackCounts, statsReset, version, inRecovery]])
    }

    private func statistics(
        trackCounts: String = "on",
        statsReset: String? = nil,
        version: String? = "170011",
        inRecovery: String? = "f"
    ) -> TableHealthStatistics {
        provider.statistics(
            from: [Self.statisticsResult(trackCounts: trackCounts, statsReset: statsReset, version: version, inRecovery: inRecovery)],
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
        #expect(finding.sizeBytes == 81920)
        #expect(finding.metric("dead_rows")?.value == .count(3000))
        #expect(finding.metric("live_rows")?.value == .count(2000))
        #expect(finding.metric("dead_percent")?.value == .percent(0.6))
        #expect(finding.metric("last_vacuum")?.value == .date(vacuumed))
        #expect(finding.metric("table_bytes") == nil)
        #expect(finding.detail.contains(TableHealthFormatting.date(vacuumed)))
        #expect(finding.fixSQL == #"VACUUM (ANALYZE) "public"."orders";"#)
    }

    @Test("A table never vacuumed says so and has no last vacuum value")
    func neverVacuumed() throws {
        let finding = try #require(findings(
            .bloat,
            columns: ["schema_name", "table_name", "live_rows", "dead_rows", "last_vacuum", "table_bytes"],
            rows: [["public", "orders", "2000", "3000", nil, "81920"]]
        ).first)
        #expect(finding.detail.contains("Never vacuumed"))
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
        #expect(finding.sizeBytes == 8192)
        #expect(finding.fixSQL == #"DROP INDEX CONCURRENTLY "sales"."orders_note_idx";"#)
    }

    @Test("A table without a primary key quotes its name in the preview and carries its rows and size")
    func missingPrimaryKeyQuotesName() throws {
        let finding = try #require(findings(
            .missingPrimaryKey,
            columns: ["schema_name", "table_name", "estimated_rows", "table_bytes"],
            rows: [["public", #"Odd "Name""#, "1200", "65536"]]
        ).first)
        #expect(finding.fixSQL == #"ALTER TABLE "public"."Odd ""Name""" ADD PRIMARY KEY (column_name);"#)
        #expect(finding.metric("estimated_rows")?.value == .count(1200))
        #expect(finding.sizeBytes == 65536)
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
        #expect(finding.metric("estimated_rows")?.value == .count(5000))
        #expect(finding.sizeBytes == 40960)
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
        #expect(statistics(statsReset: nil).notes.first?.contains("never been reset") == true)
        #expect(provider.statistics(from: [nil], now: Date()) == TableHealthStatistics())
    }

    @Test("The statistics read the server version")
    func serverVersion() {
        #expect(statistics(version: "90624").serverVersion == 90624)
        #expect(statistics(version: "170011").serverVersion == 170_011)
        #expect(statistics(version: nil).serverVersion == nil)
        #expect(statistics().isStandby == false)
    }

    @Test("With track_counts off, the checks that read activity counters are skipped")
    func trackCountsOffSkipsCounterChecks() {
        let stats = statistics(trackCounts: "off")
        #expect(stats.skippedChecks[.bloat] != nil)
        #expect(stats.skippedChecks[.unusedIndex] != nil)
        #expect(stats.skippedChecks[.missingPrimaryKey] == nil)
        #expect(stats.skippedChecks[.unindexedForeignKey] == nil)
        #expect(stats.notes.isEmpty)
    }

    @Test("On a standby the counter checks are skipped with the reason, and the report says to fix on the primary")
    func standbySkipsCounterChecks() {
        let stats = statistics(inRecovery: "t")
        let reason = String(localized: "This server is a standby. Its activity counters do not reflect the primary.")
        #expect(stats.isStandby)
        #expect(stats.skippedChecks[.bloat] == reason)
        #expect(stats.skippedChecks[.unusedIndex] == reason)
        #expect(stats.skippedChecks[.missingPrimaryKey] == nil)
        #expect(stats.skippedChecks[.unindexedForeignKey] == nil)
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
        #expect(asked.contains(PostgreSQLTableHealthProvider.unindexedForeignKeyQuery))
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
        #expect(report.checks[0].outcome == .skipped(statistics(trackCounts: "off").skippedChecks[.bloat] ?? ""))
        #expect(report.checks[2].outcome == .completed)
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
        #expect(report.checks.map { $0.kind } == [.bloat, .unusedIndex, .missingPrimaryKey, .unindexedForeignKey])
        #expect(report.checks.map { $0.check } == provider.checks.map { provider.check($0) })
        #expect(report.checks[0].outcome == .failed("permission denied for pg_stat_user_tables"))
        #expect(report.checks[2].findings.map { $0.table } == ["logs"])
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
    @Test("Every check query leaves out extension members, by relation and by schema")
    func everyQueryLeavesOutExtensions() {
        for check in provider.checks {
            for query in provider.queries(for: check, statistics: TableHealthStatistics()) {
                #expect(query.contains("'pg_catalog.pg_class'::pg_catalog.regclass"), "\(check.rawValue) keeps extension relations")
                #expect(query.contains("'pg_catalog.pg_namespace'::pg_catalog.regclass"), "\(check.rawValue) keeps extension schemas")
                #expect(query.contains("deptype = 'e'"), "\(check.rawValue) keeps extension members")
            }
        }
    }

    @Test("Every query the report runs only reads")
    func queriesOnlyRead() {
        let queries = provider.statisticsQueries
            + provider.checks.flatMap { provider.queries(for: $0, statistics: TableHealthStatistics()) }
        for query in queries {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(text.uppercased().hasPrefix("SELECT"), "\(text.prefix(40)) does not start with SELECT")
        }
    }
}
