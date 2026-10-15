import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct PluginStreamAbortTests {
    @Test("Terminating the stream sets the flag, and a serial-queue producer stops early")
    func serialQueueProducerStopsEarly() async throws {
        let queue = DispatchQueue(label: "test.stream.abort.serial")
        // Released by signals rather than created with a count: a semaphore freed below its
        // starting value traps.
        let step = DispatchSemaphore(value: 0)
        step.signal()
        step.signal()
        let counter = ProducedRowCounter()
        let totalBatches = 40
        let batchSize = 500

        let consumed = await consumeFirstBatches(
            count: 2,
            from: PluginRowStream.make { continuation, abort in
                queue.async {
                    continuation.yield(.header(PluginStreamHeader(columns: ["c"], columnTypeNames: ["TEXT"])))
                    for index in 0..<totalBatches {
                        step.wait()
                        if abort.isAborted { break }
                        let batch: [PluginRow] = (0..<batchSize).map { [.text("row_\(index)_\($0)")] }
                        counter.add(batch.count)
                        continuation.yield(.rows(batch))
                    }
                    continuation.finish()
                }
            }
        )

        #expect(consumed == 2 * batchSize)
        for _ in 2..<totalBatches { step.signal() }
        await Self.drain(queue)
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

        await Self.drain(queue)
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
        await Self.drain(queue)
        #expect(observed.value == true)
    }

    @Test(
        "A stream still held in scope has not terminated, however long the consumer has stopped",
        .timeLimit(.minutes(1))
    )
    func holdingTheStreamKeepsItAlive() async throws {
        let queue = DispatchQueue(label: "test.stream.abort.held")
        // Released by signals rather than created with a count: a semaphore freed below its
        // starting value traps.
        let step = DispatchSemaphore(value: 0)
        step.signal()
        step.signal()
        let counter = ProducedRowCounter()
        let producerFinished = ProducerCompletion()

        let stream = PluginRowStream.make { continuation, abort in
            queue.async {
                for index in 0..<20 {
                    step.wait()
                    if abort.isAborted { break }
                    counter.add(1)
                    continuation.yield(.rows([[.text("row_\(index)")]]))
                }
                continuation.finish()
                producerFinished.signal()
            }
        }

        var seen = 0
        for try await _ in stream {
            seen += 1
            if seen >= 2 { break }
        }

        // The producer goes on only once the consumer has stopped, so an abort would end it early.
        for _ in 2..<20 { step.signal() }
        await producerFinished.wait()
        #expect(counter.value == 20)
        _ = stream
    }

    /// A serial queue runs blocks in order, so one queued now runs after the producer has returned.
    private static func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
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

/// One shot, and safe to await after the fact: a producer that finished before the consumer asked
/// resumes the waiter immediately rather than leaving it there.
private final class ProducerCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFinished = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        hasFinished = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasFinished {
                lock.unlock()
                continuation.resume()
                return
            }
            waiter = continuation
            lock.unlock()
        }
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
