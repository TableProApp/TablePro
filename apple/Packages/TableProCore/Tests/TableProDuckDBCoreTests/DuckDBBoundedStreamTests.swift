import Foundation
import TableProDuckDBCore
import Testing

@Test func aSlowConsumerReceivesEveryBatchThroughASmallBuffer() async throws {
    let (stream, continuation) = AsyncThrowingStream<Int, Error>.makeStream(bufferingPolicy: .bufferingOldest(2))
    Thread.detachNewThread {
        for value in 0..<500 {
            guard DuckDBBoundedStream.deliver(value, to: continuation, pause: { _ = usleep(100) }) else { break }
        }
        continuation.finish()
    }

    var received: [Int] = []
    for try await value in stream {
        received.append(value)
    }
    #expect(received == Array(0..<500))
}

@Test func theProducerWaitsWhileTheBufferIsFull() {
    let (stream, continuation) = AsyncThrowingStream<Int, Error>.makeStream(bufferingPolicy: .bufferingOldest(2))
    #expect(DuckDBBoundedStream.deliver(1, to: continuation))
    #expect(DuckDBBoundedStream.deliver(2, to: continuation))

    var pauses = 0
    let delivered = DuckDBBoundedStream.deliver(3, to: continuation) {
        pauses += 1
        if pauses == 3 { continuation.finish() }
    }
    #expect(!delivered)
    #expect(pauses == 3)
    _ = stream
}

@Test func theProducerStopsWhenTheStreamIsGone() {
    var stream: AsyncThrowingStream<Int, Error>?
    var held: AsyncThrowingStream<Int, Error>.Continuation?
    stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1)) { held = $0 }
    let continuation = held
    #expect(continuation.map { DuckDBBoundedStream.deliver(1, to: $0) } == true)
    stream = nil
    #expect(continuation.map { DuckDBBoundedStream.deliver(2, to: $0, pause: {}) } == false)
}
