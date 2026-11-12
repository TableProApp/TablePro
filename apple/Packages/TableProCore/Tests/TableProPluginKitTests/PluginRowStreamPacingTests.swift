import Foundation
import TableProPluginKit
import TableProTestSupport
import Testing

struct PluginRowStreamPacingTests {
    private static let header = PluginStreamHeader(columns: ["c"], columnTypeNames: ["TEXT"])

    private static func batch(_ index: Int, size: Int = 10) -> [PluginRow] {
        (0..<size).map { [.text("row_\(index)_\($0)")] }
    }

    @Test("A queue producer waits while the consumer has two batches unread")
    func queueProducerWaitsForTheConsumer() async throws {
        let queue = DispatchQueue(label: "test.stream.pacing.queue")
        let progress = ProducerProgress()
        var stream: AsyncThrowingStream<PluginStreamElement, Error>? = PluginRowStream.make { continuation, abort in
            queue.async {
                continuation.yield(.header(Self.header))
                for index in 0..<40 {
                    progress.entering(index)
                    abort.send(Self.batch(index), to: continuation)
                    if abort.isAborted { break }
                }
                continuation.finish()
                progress.finish()
            }
        }

        var iterator = stream?.makeAsyncIterator()
        _ = try await iterator?.next()
        _ = try await iterator?.next()
        try await progress.waitUntilEntered(2)

        iterator = nil
        stream = nil
        try await progress.waitUntilFinished()
        #expect(progress.highestEntered == 2)
    }

    @Test("A task producer suspends while the consumer has two batches unread")
    func taskProducerWaitsForTheConsumer() async throws {
        let progress = ProducerProgress()
        var stream: AsyncThrowingStream<PluginStreamElement, Error>? = PluginRowStream.make { continuation, abort in
            let task = Task {
                continuation.yield(.header(Self.header))
                for index in 0..<40 {
                    progress.entering(index)
                    await abort.send(Self.batch(index), to: continuation)
                    if abort.isAborted { break }
                }
                continuation.finish()
                progress.finish()
            }
            abort.onAbort { task.cancel() }
        }

        var iterator = stream?.makeAsyncIterator()
        _ = try await iterator?.next()
        _ = try await iterator?.next()
        try await progress.waitUntilEntered(2)

        iterator = nil
        stream = nil
        try await progress.waitUntilFinished()
        #expect(progress.highestEntered == 2)
    }

    @Test("A consumer cancelled between reads stops a waiting producer while the stream is still held")
    func cancelledConsumerStopsAWaitingProducer() async throws {
        let queue = DispatchQueue(label: "test.stream.pacing.cancel")
        let progress = ProducerProgress()
        let stream = PluginRowStream.make { continuation, abort in
            queue.async {
                continuation.yield(.header(Self.header))
                for index in 0..<40 {
                    progress.entering(index)
                    abort.send(Self.batch(index), to: continuation)
                    if abort.isAborted { break }
                }
                continuation.finish()
                progress.finish()
            }
        }

        let reader = Task {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
            _ = try await iterator.next()
            try await progress.waitUntilEntered(2)
            withUnsafeCurrentTask { $0?.cancel() }
            return try await iterator.next() == nil
        }

        #expect(try await reader.value)
        try await progress.waitUntilFinished()
        #expect(progress.highestEntered == 2)
        _ = stream
    }

    @Test("Every row arrives once and in order through a paced stream")
    func pacedStreamDeliversEveryRow() async throws {
        let queue = DispatchQueue(label: "test.stream.pacing.order")
        let stream = PluginRowStream.make { continuation, abort in
            queue.async {
                continuation.yield(.header(Self.header))
                for index in 0..<25 {
                    abort.send(Self.batch(index, size: 3), to: continuation)
                }
                continuation.yield(.rows(Self.batch(25, size: 1)))
                continuation.finish()
            }
        }

        var cells: [String] = []
        var sawHeader = false
        for try await element in stream {
            switch element {
            case .header: sawHeader = true
            case .rows(let rows): cells += rows.map { $0.first?.asText ?? "" }
            }
        }
        let expected = (0..<25).flatMap { index in (0..<3).map { "row_\(index)_\($0)" } } + ["row_25_0"]
        #expect(sawHeader)
        #expect(cells == expected)
    }

    @Test("A producer the consumer never reads reads on once its pause limit passes")
    func pauseLimitLetsTheProducerReadOn() async throws {
        let queue = DispatchQueue(label: "test.stream.pacing.pause")
        let progress = ProducerProgress()
        let stream = PluginRowStream.make { continuation, abort in
            queue.async {
                continuation.yield(.header(Self.header))
                for index in 0..<6 {
                    progress.entering(index)
                    abort.send(Self.batch(index), to: continuation, maximumPause: 0.01)
                }
                continuation.finish()
                progress.finish()
            }
        }

        try await progress.waitUntilFinished()
        #expect(progress.highestEntered == 5)
        _ = stream
    }

    @Test("A task producer reads on once its pause limit passes")
    func asyncPauseLimitLetsTheProducerReadOn() async throws {
        let progress = ProducerProgress()
        let stream = PluginRowStream.make { continuation, abort in
            Task {
                continuation.yield(.header(Self.header))
                for index in 0..<6 {
                    progress.entering(index)
                    await abort.send(Self.batch(index), to: continuation, maximumPause: 0.01)
                }
                continuation.finish()
                progress.finish()
            }
        }

        try await progress.waitUntilFinished()
        #expect(progress.highestEntered == 5)
        _ = stream
    }

    @Test("A document stream waits for its consumer and keeps each batch's documents with its rows")
    func exportStreamPacesAndKeepsDocuments() async throws {
        let queue = DispatchQueue(label: "test.stream.pacing.documents")
        let progress = ProducerProgress()
        var stream: AsyncThrowingStream<PluginExportStreamElement, Error>? = PluginRowStream.makeExport { continuation, abort in
            queue.async {
                continuation.yield(.header(Self.header))
                for index in 0..<40 {
                    progress.entering(index)
                    let rows = Self.batch(index, size: 2)
                    let documents = rows.map { row in
                        PluginExportDocument(fields: [PluginExportField(
                            name: "c", canonicalJSON: "\"\(row[0].asText ?? "")\"", typeName: "string", cellValue: row[0]
                        )])
                    }
                    abort.send(rows, documents: documents, to: continuation)
                    if abort.isAborted { break }
                }
                continuation.finish()
                progress.finish()
            }
        }

        var iterator = stream?.makeAsyncIterator()
        _ = try await iterator?.next()
        let first = try await iterator?.next()
        guard case .rows(let rows, let documents)? = first else {
            Issue.record("expected rows")
            return
        }
        #expect(rows.count == 2)
        #expect(documents?.count == 2)
        try await progress.waitUntilEntered(2)

        iterator = nil
        stream = nil
        try await progress.waitUntilFinished()
        #expect(progress.highestEntered == 2)
    }

    @Test("A batch a bounded buffer drops is not counted against the consumer", .timeLimit(.minutes(1)))
    func droppedBatchDoesNotParkTheProducer() async throws {
        let queue = DispatchQueue(label: "test.stream.pacing.dropped")
        let progress = ProducerProgress()
        let stream = PluginRowStream.make(bufferingPolicy: .bufferingOldest(1)) { continuation, abort in
            queue.async {
                for index in 0..<6 {
                    progress.entering(index)
                    abort.send(Self.batch(index), to: continuation)
                }
                continuation.finish()
                progress.finish()
            }
        }

        var batches = 0
        for try await element in stream {
            if case .rows = element { batches += 1 }
        }
        try await progress.waitUntilFinished()
        #expect(progress.highestEntered == 5)
        #expect(batches >= 1)
    }

    @Test("An abort made outside a paced stream never waits")
    func unpacedAbortNeverWaits() {
        let (stream, continuation) = AsyncThrowingStream<PluginStreamElement, Error>.makeStream()
        let abort = PluginStreamAbort()
        for index in 0..<10 {
            abort.send(Self.batch(index), to: continuation)
        }
        continuation.finish()
        _ = stream
    }
}

private final class ProducerProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = -1
    private var finished = false

    var highestEntered: Int {
        lock.withLock { entered }
    }

    func entering(_ index: Int) {
        lock.withLock { entered = max(entered, index) }
    }

    func finish() {
        lock.withLock { finished = true }
    }

    func waitUntilEntered(_ index: Int) async throws {
        try await waitUntil { self.lock.withLock { self.entered >= index } }
    }

    func waitUntilFinished() async throws {
        try await waitUntil { self.lock.withLock { self.finished } }
    }
}
