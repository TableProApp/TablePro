//
//  CompareTimeoutLiftOrderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct CompareTimeoutLiftOrderTests {
    // One queue runs the connection's statements in turn, as a libpq session's does, so a lift sent while a bounded
    // stream waits at a full buffer would wait behind it, and the walk that would drain the buffer never starts.
    @Test(
        "A comparison lifts the query timeout before its streams start their statements",
        .timeLimit(.minutes(1))
    )
    func timeoutIsLiftedBeforeTheStreamsStart() async throws {
        let connectionQueue = DispatchQueue(label: "test.compare.connection")
        let driver = MockDatabaseDriver()
        driver.applyQueryTimeoutGate = {
            await withCheckedContinuation { continuation in
                connectionQueue.async { continuation.resume() }
            }
        }
        let batches = PluginRowStream.boundedBufferBatches * 3

        let rowsRead = try await CompareRowService.readingBothSides(liftingTimeoutOn: [driver]) {
            PluginRowStream.makeBounded { continuation, _ in
                connectionQueue.async {
                    continuation.yield(.header(PluginStreamHeader(columns: ["id"], columnTypeNames: ["integer"])))
                    for index in 0..<batches {
                        guard PluginRowStream.deliverBlocking(.rows([[.text(String(index))]]), to: continuation) else {
                            break
                        }
                    }
                    continuation.finish()
                }
            }
        } _: { stream in
            var count = 0
            for try await element in stream {
                if case .rows(let rows) = element { count += rows.count }
            }
            return count
        }

        #expect(rowsRead == batches)
        #expect(driver.applyQueryTimeoutValues.first == 0)
    }
}
