//
//  TableLoadPerformanceRecordTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("TableLoadPerformanceRecord")
struct TableLoadPerformanceRecordTests {
    private static let stamp = TableLoadRuntimeStamp(
        appVersion: "0.68.0",
        appBuild: "1234",
        osVersion: "macOS 15.2.0"
    )

    private func summary(
        outcome: TableLoadOutcome = .completed,
        metrics: TableLoadResultMetrics? = nil,
        openTabCount: Int = 4
    ) -> TableLoadTraceSummary {
        TableLoadTraceSummary(
            origin: .sidebar,
            outcome: outcome,
            anomalies: [.staleResultDropped],
            environment: TableLoadEnvironment(
                databaseTypeId: "MySQL",
                usesSSH: true,
                openTabCount: openTabCount
            ),
            resultMetrics: metrics,
            total: .milliseconds(1_250),
            preparation: .milliseconds(30),
            driverFetch: .milliseconds(900),
            resultApply: nil,
            gridReload: .milliseconds(120),
            mainRunLoopIdle: .milliseconds(200)
        )
    }

    // MARK: - Buckets

    @Test("Row buckets split at the boundaries the history reports")
    func rowBucketBoundaries() {
        #expect(TableLoadRowBucket(rowCount: 0) == .none)
        #expect(TableLoadRowBucket(rowCount: 1) == .upTo100)
        #expect(TableLoadRowBucket(rowCount: 100) == .upTo100)
        #expect(TableLoadRowBucket(rowCount: 101) == .upTo1000)
        #expect(TableLoadRowBucket(rowCount: 1_000) == .upTo1000)
        #expect(TableLoadRowBucket(rowCount: 1_001) == .upTo10000)
        #expect(TableLoadRowBucket(rowCount: 10_000) == .upTo10000)
        #expect(TableLoadRowBucket(rowCount: 10_001) == .above10000)
    }

    @Test("Column buckets split at the boundaries the history reports")
    func columnBucketBoundaries() {
        #expect(TableLoadColumnBucket(columnCount: 0) == .none)
        #expect(TableLoadColumnBucket(columnCount: 1) == .upTo20)
        #expect(TableLoadColumnBucket(columnCount: 20) == .upTo20)
        #expect(TableLoadColumnBucket(columnCount: 21) == .upTo100)
        #expect(TableLoadColumnBucket(columnCount: 100) == .upTo100)
        #expect(TableLoadColumnBucket(columnCount: 101) == .upTo500)
        #expect(TableLoadColumnBucket(columnCount: 500) == .upTo500)
        #expect(TableLoadColumnBucket(columnCount: 501) == .above500)
    }

    @Test("Result size buckets split at the megabyte boundaries")
    func resultSizeBucketBoundaries() {
        let megabyte = 1_024 * 1_024
        #expect(TableLoadResultSizeBucket(byteCount: 0) == .underOneMegabyte)
        #expect(TableLoadResultSizeBucket(byteCount: megabyte - 1) == .underOneMegabyte)
        #expect(TableLoadResultSizeBucket(byteCount: megabyte) == .upTo10Megabytes)
        #expect(TableLoadResultSizeBucket(byteCount: 10 * megabyte - 1) == .upTo10Megabytes)
        #expect(TableLoadResultSizeBucket(byteCount: 10 * megabyte) == .upTo100Megabytes)
        #expect(TableLoadResultSizeBucket(byteCount: 100 * megabyte - 1) == .upTo100Megabytes)
        #expect(TableLoadResultSizeBucket(byteCount: 100 * megabyte) == .above100Megabytes)
    }

    @Test("Open tab buckets split at the boundaries the history reports")
    func openTabBucketBoundaries() {
        #expect(TableLoadOpenTabBucket(tabCount: 0) == .none)
        #expect(TableLoadOpenTabBucket(tabCount: 1) == .one)
        #expect(TableLoadOpenTabBucket(tabCount: 2) == .upTo5)
        #expect(TableLoadOpenTabBucket(tabCount: 5) == .upTo5)
        #expect(TableLoadOpenTabBucket(tabCount: 6) == .upTo10)
        #expect(TableLoadOpenTabBucket(tabCount: 10) == .upTo10)
        #expect(TableLoadOpenTabBucket(tabCount: 11) == .upTo30)
        #expect(TableLoadOpenTabBucket(tabCount: 30) == .upTo30)
        #expect(TableLoadOpenTabBucket(tabCount: 31) == .above30)
    }

    // MARK: - Result size estimation

    private func rows(count: Int, bytesEach: Int) -> [[PluginCellValue]] {
        (0..<count).map { _ in [.text(String(repeating: "x", count: bytesEach))] }
    }

    @Test("An empty result estimates nothing rather than dividing by no rows")
    func emptyResultEstimatesZero() {
        #expect(TableLoadResultMetrics.estimateBytes(rows: []) == 0)
        let metrics = TableLoadResultMetrics(rows: [], columnCount: 7)
        #expect(metrics.rowCount == 0)
        #expect(metrics.columnCount == 7)
        #expect(metrics.estimatedBytes == 0)
    }

    @Test("Rows with no columns weigh nothing")
    func zeroColumnRowsEstimateZero() {
        #expect(TableLoadResultMetrics.estimateBytes(rows: [[], [], []]) == 0)
    }

    @Test("A result small enough to walk is measured exactly")
    func smallResultIsMeasuredExactly() {
        let sampleLimit = TableLoadResultMetrics.sampleLimit
        #expect(TableLoadResultMetrics.estimateBytes(rows: rows(count: 1, bytesEach: 40)) == 40)
        #expect(TableLoadResultMetrics.estimateBytes(rows: rows(count: 50, bytesEach: 10)) == 500)
        #expect(
            TableLoadResultMetrics.estimateBytes(rows: rows(count: sampleLimit, bytesEach: 10))
                == sampleLimit * 10
        )
    }

    @Test("A uniform result larger than the sample estimates its exact size")
    func uniformLargeResultEstimatesExactly() {
        #expect(TableLoadResultMetrics.estimateBytes(rows: rows(count: 5_000, bytesEach: 20)) == 100_000)
    }

    @Test("A null cell weighs nothing and a blob weighs its bytes")
    func countsEveryCellKind() {
        let row: [PluginCellValue] = [.null, .text("abcd"), .bytes(Data(repeating: 0, count: 16))]
        #expect(TableLoadResultMetrics.estimateBytes(rows: [row]) == 20)
    }

    @Test("Text is weighed in UTF-8 bytes, not characters")
    func weighsTextInUTF8Bytes() {
        #expect(TableLoadResultMetrics.estimateBytes(rows: [[.text("héllo")]]) == 6)
    }

    /// Taking the head would read only the light rows and taking every nth would alias against a
    /// repeating one, so both shapes are held to the same tolerance.
    @Test("Neither an ordered result nor a repeating one biases the estimate")
    func samplingSurvivesOrderedAndRepeatingResults() {
        let ordered: [[PluginCellValue]] = (0..<1_000).map { index in
            [.text(String(repeating: "x", count: index < 500 ? 0 : 100))]
        }
        let repeating: [[PluginCellValue]] = (0..<1_000).map { index in
            [.text(String(repeating: "x", count: index.isMultiple(of: 2) ? 100 : 0))]
        }

        let trueSize = 50_000
        let tolerance = trueSize / 10
        #expect(abs(TableLoadResultMetrics.estimateBytes(rows: ordered) - trueSize) <= tolerance)
        #expect(abs(TableLoadResultMetrics.estimateBytes(rows: repeating) - trueSize) <= tolerance)
    }

    // MARK: - Record

    @Test("Durations are recorded as milliseconds and an absent phase stays absent")
    func mapsDurationsToMilliseconds() {
        let record = TableLoadPerformanceRecord(summary: summary(), stamp: Self.stamp, recordedAt: .now)

        #expect(record.totalMs == 1_250)
        #expect(record.preparationMs == 30)
        #expect(record.driverFetchMs == 900)
        #expect(record.resultApplyMs == nil)
        #expect(record.gridReloadMs == 120)
        #expect(record.mainRunLoopIdleMs == 200)
    }

    @Test("The build, the OS and the load's shape all reach the record")
    func carriesEnvironmentAndStamp() {
        let metrics = TableLoadResultMetrics(rowCount: 4_200, columnCount: 60, estimatedBytes: 3_000_000)
        let record = TableLoadPerformanceRecord(
            summary: summary(metrics: metrics),
            stamp: Self.stamp,
            recordedAt: .now
        )

        #expect(record.appVersion == "0.68.0")
        #expect(record.appBuild == "1234")
        #expect(record.osVersion == "macOS 15.2.0")
        #expect(record.origin == TableLoadOrigin.sidebar.rawValue)
        #expect(record.outcome == TableLoadOutcome.completed.rawValue)
        #expect(record.anomalies == [TableLoadAnomaly.staleResultDropped.rawValue])
        #expect(record.databaseTypeId == "MySQL")
        #expect(record.usesSSH)
        #expect(record.rowBucket == TableLoadRowBucket.upTo10000.rawValue)
        #expect(record.columnBucket == TableLoadColumnBucket.upTo100.rawValue)
        #expect(record.resultSizeBucket == TableLoadResultSizeBucket.upTo10Megabytes.rawValue)
        #expect(record.openTabBucket == TableLoadOpenTabBucket.upTo5.rawValue)
    }

    @Test("A trace that never fetched reports no result buckets rather than empty ones")
    func leavesResultBucketsAbsentWithoutAFetch() {
        let record = TableLoadPerformanceRecord(
            summary: summary(outcome: .superseded),
            stamp: Self.stamp,
            recordedAt: .now
        )

        #expect(record.rowBucket == nil)
        #expect(record.columnBucket == nil)
        #expect(record.resultSizeBucket == nil)
        #expect(record.openTabBucket == TableLoadOpenTabBucket.upTo5.rawValue)
    }

    @Test("A record round-trips through the encoding the store writes")
    func roundTripsThroughJSON() throws {
        let metrics = TableLoadResultMetrics(rowCount: 12, columnCount: 3, estimatedBytes: 900)
        let record = TableLoadPerformanceRecord(
            summary: summary(metrics: metrics),
            stamp: Self.stamp,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoder = TableLoadHistoryStore.makeEncoder(prettyPrinted: false)
        let decoder = TableLoadHistoryStore.makeDecoder()
        let decoded = try decoder.decode(TableLoadPerformanceRecord.self, from: encoder.encode(record))

        #expect(decoded == record)
    }

    /// The trace this record comes from knows a table name and the connection behind it knows a host,
    /// a port and a username. None of them may survive into a file that accumulates for a week.
    @Test("Nothing identifying the query, the table or the server survives into the record")
    func carriesNothingIdentifying() throws {
        let secrets = [
            "employee_salaries",
            "payroll",
            "SELECT * FROM employee_salaries",
            "db.internal.example.com",
            "5432",
            "admin",
            "/Users/someone/Documents/payroll.sql",
            "connection failed: password authentication failed for user"
        ]
        let metrics = TableLoadResultMetrics(rowCount: 12, columnCount: 3, estimatedBytes: 900)
        let record = TableLoadPerformanceRecord(
            summary: summary(metrics: metrics),
            stamp: Self.stamp,
            recordedAt: .now
        )

        let data = try TableLoadHistoryStore.makeEncoder(prettyPrinted: false).encode(record)
        let json = try #require(String(data: data, encoding: .utf8))

        for secret in secrets {
            #expect(json.contains(secret) == false, "record leaked \(secret)")
        }
    }
}
