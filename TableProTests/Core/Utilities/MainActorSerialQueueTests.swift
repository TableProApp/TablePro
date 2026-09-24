import Foundation
@testable import TablePro
import Testing

@Suite("Main actor serial queue")
@MainActor
struct MainActorSerialQueueTests {
    @MainActor
    private final class EventLog {
        var events: [String] = []
    }

    @Test("An operation queued behind a suspended one starts only after it finishes")
    func queuedOperationWaitsForTheRunningOne() async {
        let queue = MainActorSerialQueue()
        let log = EventLog()
        let (started, signalStarted) = AsyncStream.makeStream(of: Void.self)
        let (gate, openGate) = AsyncStream.makeStream(of: Void.self)
        let (queued, signalQueued) = AsyncStream.makeStream(of: Void.self)

        let first = Task { @MainActor in
            await queue.run {
                log.events.append("first started")
                signalStarted.yield()
                for await _ in gate { break }
                log.events.append("first finished")
            }
        }
        for await _ in started { break }

        let second = Task { @MainActor in
            signalQueued.yield()
            await queue.run {
                log.events.append("second")
            }
        }
        for await _ in queued { break }

        #expect(log.events == ["first started"])

        openGate.yield()
        await first.value
        await second.value

        #expect(log.events == ["first started", "first finished", "second"])
    }

    @Test("Each operation hands back its own result")
    func operationsReturnTheirResults() async {
        let queue = MainActorSerialQueue()

        async let first = queue.run { 1 }
        async let second = queue.run { "two" }

        #expect(await first == 1)
        #expect(await second == "two")
    }
}
