//
//  PluginRowStreamDeliveryTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct PluginRowStreamDeliveryTests {
    private static func rows(_ value: Int) -> PluginStreamElement {
        .rows([[.text(String(value))]])
    }

    private static func values(of element: PluginStreamElement) -> [String] {
        guard case .rows(let rows) = element else { return [] }
        return rows.compactMap { $0.first?.asText }
    }

    @Test("A producer on its own thread waits for room and loses no batch")
    func blockingDeliveryKeepsEveryBatch() async throws {
        let total = PluginRowStream.boundedBufferBatches * 4
        let stream = PluginRowStream.makeBounded { continuation, _ in
            Thread.detachNewThread {
                for value in 0..<total {
                    guard PluginRowStream.deliverBlocking(Self.rows(value), to: continuation) else { break }
                }
                continuation.finish()
            }
        }
        var received: [String] = []
        for try await element in stream {
            received += Self.values(of: element)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(received == (0..<total).map(String.init))
    }

    @Test("A blocked producer stops once its reader is gone")
    func blockingDeliveryEndsWithTheReader() async throws {
        let ended = AsyncStream<Int>.makeStream()
        var stream: AsyncThrowingStream<PluginStreamElement, Error>? = PluginRowStream.makeBounded { continuation, _ in
            Thread.detachNewThread {
                var delivered = 0
                while PluginRowStream.deliverBlocking(Self.rows(delivered), to: continuation) { delivered += 1 }
                ended.continuation.yield(delivered)
                ended.continuation.finish()
            }
        }
        var iterator = stream?.makeAsyncIterator()
        _ = try await iterator?.next()
        iterator = nil
        stream = nil
        var delivered = Int.max
        for await count in ended.stream { delivered = count }
        #expect(delivered <= PluginRowStream.boundedBufferBatches + 1)
    }

    @Test("A blocked producer gives up when asked to stop, and the batch is not sent")
    func blockingDeliveryHonoursStop() {
        let (stream, continuation) = AsyncThrowingStream<PluginStreamElement, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        #expect(PluginRowStream.deliverBlocking(Self.rows(0), to: continuation, stops: { true }))
        #expect(!PluginRowStream.deliverBlocking(Self.rows(1), to: continuation, stops: { true }))
        _ = stream
    }

    @Test(
        "A blocked producer keeps the server alive while its reader holds a full buffer, and reads nothing ahead",
        .timeLimit(.minutes(1))
    )
    func blockingDeliveryKeepsAliveWhileFull() async throws {
        let total = PluginRowStream.boundedBufferBatches * 2
        let beats = AsyncStream<Int>.makeStream()
        let delivered = Counter()
        let stream = PluginRowStream.makeBounded { continuation, _ in
            Thread.detachNewThread {
                for value in 0..<total {
                    let sent = PluginRowStream.deliverBlocking(Self.rows(value), to: continuation, keepingAliveEvery: 0.02) {
                        beats.continuation.yield(delivered.value)
                    }
                    guard sent else { break }
                    delivered.increment()
                }
                beats.continuation.finish()
                continuation.finish()
            }
        }
        var iterator = stream.makeAsyncIterator()
        var received = Self.values(of: try #require(try await iterator.next()))
        var deliveredDuringBeats: [Int] = []
        for await count in beats.stream {
            deliveredDuringBeats.append(count)
            if deliveredDuringBeats.count == 3 { break }
        }
        while let element = try await iterator.next() {
            received += Self.values(of: element)
        }
        #expect(deliveredDuringBeats.count == 3)
        #expect(deliveredDuringBeats.allSatisfy { $0 <= PluginRowStream.boundedBufferBatches + 1 })
        #expect(received == (0..<total).map(String.init))
    }

    @Test(
        "A task producer keeps the server alive while its reader holds a full buffer, and reads nothing ahead",
        .timeLimit(.minutes(1))
    )
    func asyncDeliveryKeepsAliveWhileFull() async throws {
        let total = PluginRowStream.boundedBufferBatches * 2
        let beats = AsyncStream<Int>.makeStream()
        let delivered = Counter()
        let stream = PluginRowStream.makeBounded { continuation, _ in
            Task {
                for value in 0..<total {
                    let sent = await PluginRowStream.deliver(Self.rows(value), to: continuation, keepingAliveEvery: 0.02) {
                        beats.continuation.yield(delivered.value)
                    }
                    guard sent else { break }
                    delivered.increment()
                }
                beats.continuation.finish()
                continuation.finish()
            }
        }
        var iterator = stream.makeAsyncIterator()
        var received = Self.values(of: try #require(try await iterator.next()))
        var deliveredDuringBeats: [Int] = []
        for await count in beats.stream {
            deliveredDuringBeats.append(count)
            if deliveredDuringBeats.count == 3 { break }
        }
        while let element = try await iterator.next() {
            received += Self.values(of: element)
        }
        #expect(deliveredDuringBeats.count == 3)
        #expect(deliveredDuringBeats.allSatisfy { $0 <= PluginRowStream.boundedBufferBatches + 1 })
        #expect(received == (0..<total).map(String.init))
    }

    @Test("A keep-alive that fails ends the delivery with its error, and the batch is not sent", .timeLimit(.minutes(1)))
    func failedKeepAliveEndsTheDelivery() async throws {
        let (stream, continuation) = AsyncThrowingStream<PluginStreamElement, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        #expect(PluginRowStream.deliverBlocking(Self.rows(0), to: continuation))
        #expect(throws: KeepAliveFailure.self) {
            try PluginRowStream.deliverBlocking(Self.rows(1), to: continuation, keepingAliveEvery: 0) {
                throw KeepAliveFailure()
            }
        }
        await #expect(throws: KeepAliveFailure.self) {
            try await PluginRowStream.deliver(Self.rows(2), to: continuation, keepingAliveEvery: 0) {
                throw KeepAliveFailure()
            }
        }
        continuation.finish()
        var received: [String] = []
        for try await element in stream {
            received += Self.values(of: element)
        }
        #expect(received == ["0"])
    }

    @Test("A producer running as a task suspends for room and loses no batch")
    func asyncDeliveryKeepsEveryBatch() async throws {
        let total = PluginRowStream.boundedBufferBatches * 3
        let stream = PluginRowStream.makeBounded { continuation, _ in
            Task {
                for value in 0..<total {
                    guard await PluginRowStream.deliver(Self.rows(value), to: continuation) else { break }
                }
                continuation.finish()
            }
        }
        var received: [String] = []
        for try await element in stream {
            received += Self.values(of: element)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(received == (0..<total).map(String.init))
    }
}

private struct KeepAliveFailure: Error {}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
