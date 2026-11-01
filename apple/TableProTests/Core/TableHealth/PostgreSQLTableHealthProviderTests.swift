import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct PostgreSQLTableHealthProviderTests {
    private struct QueryFailure: LocalizedError {
        var errorDescription: String? { "permission denied for pg_stat_user_tables" }
    }

    private let provider = PostgreSQLTableHealthProvider()
    private let context = TableHealthFixture.postgresContext()

    private func findings(_ check: TableHealthCheckKind, columns: [String], rows: [[String?]]) -> [TableHealthFinding] {
        provider.findings(
            for: check,
            from: [TableHealthFixture.result(columns: columns, rows: rows)],
            context: context
        )
    }

    private func statistics(trackCounts: String, statsReset: String?) -> TableHealthStatistics {
        provider.statistics(
            from: [TableHealthFixture.result(columns: ["track_counts", "stats_reset"], rows: [[trackCounts, statsReset]])],
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

    @Test("A bloated table names its dead and live rows and previews a vacuum")
    func bloatFinding() throws {
        let finding = try #require(findings(
            .bloat,
            columns: ["schema_name", "table_name", "live_rows", "dead_rows", "last_vacuum"],
            rows: [["public", "orders", "2000", "3000", "2026-10-31 19:48:20+00"]]
        ).first)

        #expect(finding.schema == "public")
        #expect(finding.table == "orders")
        #expect(finding.objectName == nil)
        #expect(finding.detail.contains("2026-10-31 19:48:20+00"))
        #expect(finding.fixSQL == #"VACUUM (ANALYZE) "public"."orders";"#)
    }

    @Test("A table never vacuumed says so")
    func neverVacuumed() throws {
        let finding = try #require(findings(
            .bloat,
            columns: ["schema_name", "table_name", "live_rows", "dead_rows", "last_vacuum"],
            rows: [["public", "orders", "2000", "3000", nil]]
        ).first)
        #expect(finding.detail.contains("Never vacuumed"))
    }

    @Test("An unused index previews a concurrent drop")
    func unusedIndexFinding() throws {
        let finding = try #require(findings(
            .unusedIndex,
            columns: ["schema_name", "table_name", "index_name", "index_bytes"],
            rows: [["sales", "orders", "orders_note_idx", "8192"]]
        ).first)

        #expect(finding.table == "orders")
        #expect(finding.objectName == "orders_note_idx")
        #expect(finding.fixSQL == #"DROP INDEX CONCURRENTLY "sales"."orders_note_idx";"#)
    }

    @Test("A table without a primary key quotes its name in the preview")
    func missingPrimaryKeyQuotesName() throws {
        let finding = try #require(findings(
            .missingPrimaryKey,
            columns: ["schema_name", "table_name"],
            rows: [["public", #"Odd "Name""#]]
        ).first)
        #expect(finding.fixSQL == #"ALTER TABLE "public"."Odd ""Name""" ADD PRIMARY KEY (column_name);"#)
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

        #expect(found.map(\.objectName) == ["line_order_fk", "line_pair_fk", "line_order_fk"])
        #expect(found.map(\.schema) == ["public", "public", "audit"])
        #expect(found[0].fixSQL == #"CREATE INDEX CONCURRENTLY ON "public"."line" ("order_id");"#)
        #expect(found[1].fixSQL == #"CREATE INDEX CONCURRENTLY ON "public"."line" ("y", "x");"#)
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
        ).map(\.id)
        #expect(Set(ids).count == 3)
    }

    @Test("The note names when statistics were reset, or that they never were")
    func statisticsNote() {
        #expect(statistics(trackCounts: "on", statsReset: "2026-10-31 19:48:20+00").note?.contains("2026-10-31 19:48:20+00") == true)
        #expect(statistics(trackCounts: "on", statsReset: nil).note?.contains("never been reset") == true)
        #expect(provider.statistics(from: [nil], now: Date()) == TableHealthStatistics())
    }

    @Test("With track_counts off, the checks that read activity counters are skipped")
    func trackCountsOffSkipsCounterChecks() {
        let stats = statistics(trackCounts: "off", statsReset: nil)
        #expect(Set(stats.skippedChecks.keys) == [.bloat, .unusedIndex])
        #expect(stats.note == nil)
    }

    @Test("A skipped check runs nothing and says why")
    func skippedCheckRunsNothing() async throws {
        var asked: [String] = []
        let report = try await provider.fetchReport(context: context) { query in
            asked.append(query)
            if query == PostgreSQLTableHealthProvider.statisticsQuery {
                return TableHealthFixture.result(columns: ["track_counts", "stats_reset"], rows: [["off", nil]])
            }
            return TableHealthFixture.empty()
        }

        #expect(!asked.contains(PostgreSQLTableHealthProvider.bloatQuery))
        #expect(!asked.contains(PostgreSQLTableHealthProvider.unusedIndexQuery))
        #expect(report.checks[0].outcome == .skipped(statistics(trackCounts: "off", statsReset: nil).skippedChecks[.bloat] ?? ""))
        #expect(report.checks[2].outcome == .completed)
    }

    @Test("A failing check reports its error and leaves the other checks standing")
    func failingCheckIsolated() async throws {
        let report = try await provider.fetchReport(context: context) { query in
            if query == PostgreSQLTableHealthProvider.bloatQuery { throw QueryFailure() }
            if query == PostgreSQLTableHealthProvider.missingPrimaryKeyQuery {
                return TableHealthFixture.result(columns: ["schema_name", "table_name"], rows: [["public", "logs"]])
            }
            return TableHealthFixture.empty()
        }

        #expect(report.database == "shop")
        #expect(report.checks.map(\.kind) == [.bloat, .unusedIndex, .missingPrimaryKey, .unindexedForeignKey])
        #expect(report.checks[0].outcome == .failed("permission denied for pg_stat_user_tables"))
        #expect(report.checks[2].findings.map(\.table) == ["logs"])
        #expect(report.findingCount == 1)
    }

    @Test("A statistics query that fails leaves every check to run")
    func failedStatisticsRunsEveryCheck() async throws {
        let report = try await provider.fetchReport(context: context) { query in
            if query == PostgreSQLTableHealthProvider.statisticsQuery { throw QueryFailure() }
            return TableHealthFixture.empty()
        }
        #expect(report.checks.allSatisfy { $0.outcome == .completed })
        #expect(report.statisticsNote == nil)
    }

    @Test("A cancelled refresh stops instead of reporting every check as failed")
    func cancellationPropagates() async {
        await #expect(throws: CancellationError.self) {
            _ = try await provider.fetchReport(context: context) { _ in throw CancellationError() }
        }
    }

    @Test("Every query the report runs only reads")
    func queriesOnlyRead() {
        let queries = provider.statisticsQueries + provider.checks.flatMap { provider.queries(for: $0) }
        for query in queries {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(text.uppercased().hasPrefix("SELECT"), "\(text.prefix(40)) does not start with SELECT")
        }
    }
}
