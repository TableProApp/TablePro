//
//  PluginStreamAbortTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Row stream abort reaches a producer that polls it")
struct PluginStreamAbortTests {

    @Test("Terminating the stream sets the flag, and a serial-queue producer stops early")
    func serialQueueProducerStopsEarly() async throws {
        let queue = DispatchQueue(label: "test.stream.abort.serial")
        let counter = ProducedRowCounter()
        let totalBatches = 40
        let batchSize = 500

        let consumed = await consumeFirstBatches(
            count: 2,
            from: PluginRowStream.make { continuation, abort in
                queue.async {
                    continuation.yield(.header(PluginStreamHeader(columns: ["c"], columnTypeNames: ["TEXT"])))
                    for index in 0..<totalBatches {
                        if abort.isAborted { break }
                        let batch: [PluginRow] = (0..<batchSize).map { [.text("row_\(index)_\($0)")] }
                        counter.add(batch.count)
                        continuation.yield(.rows(batch))
                        usleep(20_000)
                    }
                    continuation.finish()
                }
            }
        )

        #expect(consumed == 2 * batchSize)
        try await Task.sleep(for: .seconds(1.5))
        #expect(counter.value < totalBatches * batchSize)
    }

    @Test("A producer that never polls runs to completion, which is why the poll is the contract")
    func producerThatIgnoresTheFlagRunsOn() async throws {
        let queue = DispatchQueue(label: "test.stream.abort.ignores")
        let counter = ProducedRowCounter()
        let totalBatches = 10
        let batchSize = 100

        _ = await consumeFirstBatches(
            count: 1,
            from: PluginRowStream.make { continuation, _ in
                queue.async {
                    continuation.yield(.header(PluginStreamHeader(columns: ["c"], columnTypeNames: ["TEXT"])))
                    for index in 0..<totalBatches {
                        let batch: [PluginRow] = (0..<batchSize).map { [.text("row_\(index)_\($0)")] }
                        counter.add(batch.count)
                        continuation.yield(.rows(batch))
                    }
                    continuation.finish()
                }
            }
        )

        try await Task.sleep(for: .seconds(0.5))
        #expect(counter.value == totalBatches * batchSize)
    }

    @Test("The flag is already set when a producer scheduled after termination finally runs")
    func producerScheduledAfterTerminationSeesTheFlag() async throws {
        let queue = DispatchQueue(label: "test.stream.abort.late")
        let gate = DispatchSemaphore(value: 0)
        let observed = AbortObservation()

        do {
            let stream = PluginRowStream.make { continuation, abort in
                queue.async {
                    gate.wait()
                    observed.record(abort.isAborted)
                    continuation.finish()
                }
            }
            _ = stream.makeAsyncIterator()
        }

        gate.signal()
        try await Task.sleep(for: .seconds(0.5))
        #expect(observed.value == true)
    }

    @Test("A stream still held in scope has not terminated, however long the consumer has stopped")
    func holdingTheStreamKeepsItAlive() async throws {
        let queue = DispatchQueue(label: "test.stream.abort.held")
        let counter = ProducedRowCounter()

        let stream = PluginRowStream.make { continuation, abort in
            queue.async {
                for index in 0..<20 {
                    if abort.isAborted { break }
                    counter.add(1)
                    continuation.yield(.rows([[.text("row_\(index)")]]))
                    usleep(20_000)
                }
                continuation.finish()
            }
        }

        var seen = 0
        for try await _ in stream {
            seen += 1
            if seen >= 2 { break }
        }

        try await Task.sleep(for: .seconds(0.6))
        #expect(counter.value == 20)
        _ = stream
    }

    private func consumeFirstBatches(
        count: Int,
        from stream: AsyncThrowingStream<PluginStreamElement, Error>
    ) async -> Int {
        var rows = 0
        var batches = 0
        do {
            for try await element in stream {
                guard case .rows(let batch) = element else { continue }
                rows += batch.count
                batches += 1
                if batches >= count { break }
            }
        } catch {
            return rows
        }
        return rows
    }
}

private final class ProducedRowCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func add(_ rows: Int) {
        lock.lock()
        count += rows
        lock.unlock()
    }
}

private final class AbortObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var observed: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    func record(_ aborted: Bool) {
        lock.lock()
        observed = aborted
        lock.unlock()
    }
}
