//
//  PluginBoundedStreamTimingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PluginBoundedStream timing")
struct PluginBoundedStreamTimingTests {
    private func stream(
        header: PluginStreamHeader,
        batches: [(delay: Duration, rows: [PluginRow])]
    ) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.header(header))
                for batch in batches {
                    try? await Task.sleep(for: batch.delay)
                    continuation.yield(.rows(batch.rows))
                }
                continuation.finish()
            }
        }
    }

    private let header = PluginStreamHeader(
        columns: ["a"],
        columnTypeNames: ["INT"],
        estimatedRowCount: nil
    )

    private let row: PluginRow = [.text("1")]

    /// The capped path is the one an editor `SELECT` without a `LIMIT` actually takes, so a
    /// breakdown that only worked on the uncapped path would never be seen.
    @Test("The first batch to arrive sets the first-row time")
    func firstBatchSetsFirstRow() async throws {
        let result = try await PluginBoundedStream.collect(
            stream(header: header, batches: [
                (.milliseconds(120), [row]),
                (.milliseconds(120), [row]),
            ]),
            rowCap: 10,
            startedAt: Date()
        )

        let firstRow = try #require(result.timing.firstRow)
        #expect(firstRow >= 0.1)
        #expect(firstRow < result.timing.total)
        #expect(result.timing.hasBreakdown)
    }

    @Test("A result with no rows reports the whole read as time to first row")
    func emptyResultHasNoTransfer() async throws {
        let result = try await PluginBoundedStream.collect(
            stream(header: header, batches: []),
            rowCap: 10,
            startedAt: Date()
        )

        let transfer = try #require(result.timing.transfer)
        #expect(transfer == 0)
    }

    /// An empty batch is not a row, so it must not stop the clock before one arrives.
    @Test("An empty batch does not set the first-row time")
    func emptyBatchDoesNotStopTheClock() async throws {
        let result = try await PluginBoundedStream.collect(
            stream(header: header, batches: [
                (.milliseconds(1), []),
                (.milliseconds(120), [row]),
            ]),
            rowCap: 10,
            startedAt: Date()
        )

        let firstRow = try #require(result.timing.firstRow)
        #expect(firstRow >= 0.1)
    }

    @Test("A server figure passed in reaches the result")
    func serverElapsedIsCarried() async throws {
        let result = try await PluginBoundedStream.collect(
            stream(header: header, batches: [(.milliseconds(1), [row])]),
            rowCap: 10,
            startedAt: Date(),
            serverElapsed: 0.042
        )

        #expect(result.timing.server == 0.042)
        #expect(result.timing.databaseTime == 0.042)
    }

    @Test("The published overload still yields a timing with no server figure")
    func legacyOverloadKeepsWorking() async throws {
        let result = try await PluginBoundedStream.collect(
            stream(header: header, batches: [(.milliseconds(1), [row])]),
            rowCap: 10,
            startedAt: Date()
        )

        #expect(result.timing.server == nil)
        #expect(result.executionTime == result.timing.total)
    }
}
