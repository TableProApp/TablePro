//
//  TableLoadTracerSinkTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

private final class RecordingSink: TableLoadSummarySink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TableLoadPerformanceRecord] = []

    var records: [TableLoadPerformanceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ record: TableLoadPerformanceRecord) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(record)
    }
}

@MainActor
@Suite("TableLoadTracer sink")
struct TableLoadTracerSinkTests {
    private func makeTracer() -> (tracer: TableLoadTracer, sink: RecordingSink) {
        let sink = RecordingSink()
        return (TableLoadTracer(sink: sink), sink)
    }

    private var environment: TableLoadEnvironment {
        TableLoadEnvironment(databaseTypeId: "ClickHouse", usesSSH: true, openTabCount: 7)
    }

    @Test("A completed load reaches the sink once, with its environment")
    func completedLoadIsRecordedOnce() throws {
        let (tracer, sink) = makeTracer()
        let token = tracer.begin(
            tabId: UUID(),
            table: "users",
            origin: .sidebar,
            environment: environment
        )
        tracer.stage(.applyResultBegin, token: token)
        tracer.stage(.gridReloadBegin, token: token)
        tracer.stage(.gridReloadEnd, token: token)
        tracer.finish(token: token, outcome: .completed)

        #expect(sink.records.count == 1)
        let record = try #require(sink.records.first)
        #expect(record.outcome == TableLoadOutcome.completed.rawValue)
        #expect(record.origin == TableLoadOrigin.sidebar.rawValue)
        #expect(record.databaseTypeId == "ClickHouse")
        #expect(record.usesSSH)
        #expect(record.openTabBucket == TableLoadOpenTabBucket.upTo10.rawValue)
        #expect(record.gridReloadMs != nil)
    }

    @Test("A failure records a closed outcome and keeps the error type out of it")
    func failureRecordsAClosedOutcome() throws {
        let (tracer, sink) = makeTracer()
        let token = tracer.begin(tabId: UUID(), table: "users", origin: .sidebar, environment: environment)
        tracer.finish(token: token, outcome: .failed, detail: "MySQLConnectionError")

        let record = try #require(sink.records.first)
        #expect(record.outcome == TableLoadOutcome.failed.rawValue)
        #expect(record.outcome.contains("MySQLConnectionError") == false)
    }

    @Test("Navigating again on the same tab records the trace it replaced")
    func supersededLoadIsRecorded() throws {
        let (tracer, sink) = makeTracer()
        let tabId = UUID()
        _ = tracer.begin(tabId: tabId, table: "users", origin: .sidebar, environment: environment)
        let second = tracer.begin(tabId: tabId, table: "orders", origin: .sidebar, environment: environment)

        #expect(sink.records.count == 1)
        let first = try #require(sink.records.first)
        #expect(first.outcome == TableLoadOutcome.superseded.rawValue)

        tracer.finish(token: second, outcome: .completed)
        #expect(sink.records.count == 2)
    }

    @Test("A superseded trace whose late result arrives is still recorded only once")
    func supersededLoadIsNotRecordedTwice() {
        let (tracer, sink) = makeTracer()
        let tabId = UUID()
        let first = tracer.begin(tabId: tabId, table: "users", origin: .sidebar, environment: environment)
        _ = tracer.begin(tabId: tabId, table: "orders", origin: .sidebar, environment: environment)
        tracer.finish(token: first, outcome: .staleDropped)

        let outcomes = sink.records.map(\.outcome)
        #expect(outcomes == [TableLoadOutcome.superseded.rawValue])
    }

    @Test("The anomalies a trace reported ride along with it")
    func anomaliesReachTheRecord() throws {
        let (tracer, sink) = makeTracer()
        let token = tracer.begin(tabId: UUID(), table: "users", origin: .sidebar, environment: environment)
        tracer.anomaly(.blockedByInFlightExecution, token: token)
        tracer.anomaly(.connectionNotReady, token: token)
        tracer.finish(token: token, outcome: .notConnected)

        let record = try #require(sink.records.first)
        #expect(record.anomalies == [
            TableLoadAnomaly.blockedByInFlightExecution.rawValue,
            TableLoadAnomaly.connectionNotReady.rawValue
        ])
    }

    @Test("The result's shape reaches the record through the fetch that produced it")
    func resultShapeReachesTheRecord() throws {
        let (tracer, sink) = makeTracer()
        let token = tracer.begin(tabId: UUID(), table: "users", origin: .reExecute, environment: environment)
        tracer.setResultMetrics(
            TableLoadResultMetrics(rowCount: 250, columnCount: 640, estimatedBytes: 0),
            token: token
        )
        tracer.finish(token: token, outcome: .completed)

        let record = try #require(sink.records.first)
        #expect(record.rowBucket == TableLoadRowBucket.upTo1000.rawValue)
        #expect(record.columnBucket == TableLoadColumnBucket.above500.rawValue)
        #expect(record.resultSizeBucket == TableLoadResultSizeBucket.underOneMegabyte.rawValue)
    }

    @Test("A trace still open when the window overflows is recorded as evicted")
    func evictedLoadIsRecorded() {
        let (tracer, sink) = makeTracer()
        let overflow = TableLoadTraceRecorder.retainedTraceLimit + 3
        for index in 0..<overflow {
            _ = tracer.begin(
                tabId: UUID(),
                table: "t\(index)",
                origin: .programmatic,
                environment: environment
            )
        }

        #expect(sink.records.isEmpty == false)
        #expect(sink.records.allSatisfy { $0.outcome == TableLoadOutcome.evicted.rawValue })
    }

    @Test("A trace that never began records nothing")
    func unknownTokenRecordsNothing() {
        let (tracer, sink) = makeTracer()
        let stranger = TableLoadTraceToken(sequence: 999, tabId: UUID(), table: "users")
        tracer.finish(token: stranger, outcome: .completed)
        #expect(sink.records.isEmpty)
    }
}
