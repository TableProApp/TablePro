import Foundation
import TableProPluginKit
import Testing

struct PluginRowStreamTerminationTests {
    private static let header = PluginStreamHeader(columns: ["c"], columnTypeNames: ["TEXT"])

    @Test("A stream its producer finished runs no abort action, even once the consumer lets it go")
    func finishedStreamRunsNoAbortAction() async throws {
        let probe = AbortProbe()
        var stream: AsyncThrowingStream<PluginStreamElement, Error>? = PluginRowStream.make { continuation, abort in
            probe.watch(abort)
            continuation.yield(.header(Self.header))
            continuation.yield(.rows([[.text("a")]]))
            continuation.finish()
        }
        var elements = 0
        if let stream {
            for try await _ in stream { elements += 1 }
        }
        stream = nil

        #expect(elements == 2)
        #expect(probe.actions == 0)
        #expect(probe.abort?.isAborted == false)
    }

    @Test("A stream its producer finished with an error runs no abort action")
    func failedStreamRunsNoAbortAction() async {
        let probe = AbortProbe()
        var stream: AsyncThrowingStream<PluginStreamElement, Error>? = PluginRowStream.make { continuation, abort in
            probe.watch(abort)
            continuation.yield(.header(Self.header))
            continuation.finish(throwing: ProducerFailure())
        }
        await #expect(throws: ProducerFailure.self) {
            if let stream {
                for try await _ in stream {}
            }
        }
        stream = nil

        #expect(probe.actions == 0)
    }

    @Test("A consumer that lets the stream go before its end runs the abort actions")
    func droppedStreamRunsTheAbortActions() async throws {
        let probe = AbortProbe()
        var stream: AsyncThrowingStream<PluginStreamElement, Error>? = PluginRowStream.make { continuation, abort in
            probe.watch(abort)
            continuation.yield(.header(Self.header))
        }
        var iterator = stream?.makeAsyncIterator()
        _ = try await iterator?.next()
        iterator = nil
        stream = nil

        #expect(probe.actions == 1)
        #expect(probe.abort?.isAborted == true)
    }

    @Test("A consumer task cancelled while it waits runs the abort actions")
    func cancelledConsumerRunsTheAbortActions() async throws {
        let probe = AbortProbe()
        let stream = PluginRowStream.make { continuation, abort in
            probe.watch(abort)
            continuation.yield(.header(Self.header))
        }
        let reader = Task {
            for try await _ in stream {}
        }
        reader.cancel()
        _ = try? await reader.value

        #expect(probe.actions == 1)
        _ = stream
    }
}

private struct ProducerFailure: Error {}

private final class AbortProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var watched: PluginStreamAbort?
    private var count = 0

    var abort: PluginStreamAbort? {
        lock.withLock { watched }
    }

    var actions: Int {
        lock.withLock { count }
    }

    func watch(_ abort: PluginStreamAbort) {
        lock.withLock { watched = abort }
        abort.onAbort { [self] in
            lock.withLock { count += 1 }
        }
    }
}
