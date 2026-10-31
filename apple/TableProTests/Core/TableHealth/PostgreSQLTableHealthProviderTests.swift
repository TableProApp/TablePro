//
//  PostgreSQLTableHealthProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct PostgreSQLTableHealthProviderTests {
    private struct QueryFailure: LocalizedError {
        var errorDescription: String? { "permission denied for pg_stat_user_tables" }
    }

    private let provider = PostgreSQLTableHealthProvider()

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
        let result = TableHealthFixture.result(
            columns: ["schema_name", "table_name", "live_rows", "dead_rows", "last_vacuum"],
            rows: [["public", "orders", "2000", "3000", "2026-10-31 19:48:20+00"]]
        )
        let finding = try #require(provider.findings(for: .bloat, from: result).first)

        #expect(finding.kind == .bloat)
        #expect(finding.schema == "public")
        #expect(finding.table == "orders")
        #expect(finding.objectName == nil)
        #expect(finding.detail.contains("2026-10-31 19:48:20+00"))
        #expect(finding.fixSQL == #"VACUUM (ANALYZE) "public"."orders";"#)
    }

    @Test("A table never vacuumed says so")
    func neverVacuumed() throws {
        let result = TableHealthFixture.result(
            columns: ["schema_name", "table_name", "live_rows", "dead_rows", "last_vacuum"],
            rows: [["public", "orders", "2000", "3000", nil]]
        )
        let finding = try #require(provider.findings(for: .bloat, from: result).first)
        #expect(finding.detail.contains("Never vacuumed"))
    }

    @Test("An unused index previews a concurrent drop")
    func unusedIndexFinding() throws {
        let result = TableHealthFixture.result(
            columns: ["schema_name", "table_name", "index_name", "index_bytes"],
            rows: [["sales", "orders", "orders_note_idx", "8192"]]
        )
        let finding = try #require(provider.findings(for: .unusedIndex, from: result).first)

        #expect(finding.table == "orders")
        #expect(finding.objectName == "orders_note_idx")
        #expect(finding.fixSQL == #"DROP INDEX CONCURRENTLY "sales"."orders_note_idx";"#)
    }

    @Test("A table without a primary key quotes its name in the preview")
    func missingPrimaryKeyQuotesName() throws {
        let result = TableHealthFixture.result(
            columns: ["schema_name", "table_name"],
            rows: [["public", #"Odd "Name""#]]
        )
        let finding = try #require(provider.findings(for: .missingPrimaryKey, from: result).first)
        #expect(finding.fixSQL == #"ALTER TABLE "public"."Odd ""Name""" ADD PRIMARY KEY (column_name);"#)
    }

    @Test("A foreign key's column rows fold into one finding, in key order")
    func foreignKeyColumnsGroup() throws {
        let result = TableHealthFixture.result(
            columns: ["schema_name", "table_name", "constraint_name", "column_name"],
            rows: [
                ["public", "line", "line_order_fk", "order_id"],
                ["public", "line", "line_pair_fk", "y"],
                ["public", "line", "line_pair_fk", "x"],
                ["audit", "line", "line_order_fk", "order_id"]
            ]
        )
        let findings = provider.findings(for: .unindexedForeignKey, from: result)

        #expect(findings.map(\.objectName) == ["line_order_fk", "line_pair_fk", "line_order_fk"])
        #expect(findings.map(\.schema) == ["public", "public", "audit"])
        #expect(findings[1].fixSQL == #"CREATE INDEX CONCURRENTLY ON "public"."line" ("y", "x");"#)
        #expect(findings[0].fixSQL == #"CREATE INDEX CONCURRENTLY ON "public"."line" ("order_id");"#)
    }

    @Test("Findings of one kind have distinct ids, so the list can select each")
    func findingIdsAreDistinct() {
        let result = TableHealthFixture.result(
            columns: ["schema_name", "table_name", "index_name", "index_bytes"],
            rows: [["a", "t", "i1", "1"], ["a", "t", "i2", "1"], ["b", "t", "i1", "1"]]
        )
        let ids = provider.findings(for: .unusedIndex, from: result).map(\.id)
        #expect(Set(ids).count == 3)
    }

    @Test("The note names when statistics were reset, or that they never were")
    func statisticsNote() {
        let reset = TableHealthFixture.result(columns: ["stats_reset"], rows: [["2026-10-31 19:48:20+00"]])
        let never = TableHealthFixture.result(columns: ["stats_reset"], rows: [[nil]])

        #expect(provider.statisticsNote(from: [reset], now: Date())?.contains("2026-10-31 19:48:20+00") == true)
        #expect(provider.statisticsNote(from: [never], now: Date())?.contains("never been reset") == true)
        #expect(provider.statisticsNote(from: [], now: Date()) == nil)
    }

    @Test("A failing check reports its error and leaves the other checks standing")
    func failingCheckIsolated() async throws {
        let report = try await provider.fetchReport { query in
            if query == PostgreSQLTableHealthProvider.bloatQuery { throw QueryFailure() }
            if query == PostgreSQLTableHealthProvider.missingPrimaryKeyQuery {
                return TableHealthFixture.result(columns: ["schema_name", "table_name"], rows: [["public", "logs"]])
            }
            return TableHealthFixture.result(columns: [], rows: [])
        }

        #expect(report.checks.map(\.kind) == [.bloat, .unusedIndex, .missingPrimaryKey, .unindexedForeignKey])
        #expect(report.checks[0].error == "permission denied for pg_stat_user_tables")
        #expect(report.checks[2].findings.map(\.table) == ["logs"])
        #expect(report.findingCount == 1)
    }

    @Test("A cancelled refresh stops instead of reporting every check as failed")
    func cancellationPropagates() async {
        await #expect(throws: CancellationError.self) {
            _ = try await provider.fetchReport { _ in throw CancellationError() }
        }
    }

    @Test("Every query the report runs only reads")
    func queriesOnlyRead() {
        for check in provider.checks {
            let query = provider.query(for: check).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(query.uppercased().hasPrefix("SELECT"), "\(check) does not start with SELECT")
        }
    }
}
