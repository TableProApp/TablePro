//
//  SQLiteDashboardProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct SQLiteDashboardProviderTests {
    private struct UnexpectedStatement: Error {
        let sql: String
    }

    private func cacheSizeMetric(cacheSize: String, pageSize: String = "4096") async throws -> DashboardMetric {
        let answers = [
            "PRAGMA page_count": "10",
            "PRAGMA page_size": pageSize,
            "PRAGMA journal_mode": "wal",
            "PRAGMA cache_size": cacheSize
        ]
        let metrics = try await SQLiteDashboardProvider().fetchMetrics { sql in
            guard let answer = answers[sql] else { throw UnexpectedStatement(sql: sql) }
            return QueryResult(
                columns: ["value"],
                columnTypes: [],
                rows: [[PluginCellValue.text(answer)]],
                rowsAffected: 0,
                executionTime: 0,
                error: nil
            )
        }
        return try #require(metrics.first { $0.id == "cache_size" })
    }

    @Test("A negative cache_size is a budget in KiB, shown as a size")
    func negativeCacheSizeIsKibibytes() async throws {
        let metric = try await cacheSizeMetric(cacheSize: "-2000")
        #expect(metric.value == ByteSizeFormatting.string(bytes: 2_048_000))
        #expect(metric.unit.isEmpty)
    }

    @Test("A positive cache_size is a page count, shown as a size at the database's page size")
    func positiveCacheSizeIsPages() async throws {
        let metric = try await cacheSizeMetric(cacheSize: "500", pageSize: "8192")
        #expect(metric.value == ByteSizeFormatting.string(bytes: 500 * 8_192))
        #expect(metric.unit.isEmpty)
    }
}
