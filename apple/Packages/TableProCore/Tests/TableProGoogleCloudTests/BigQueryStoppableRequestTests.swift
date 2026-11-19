import Foundation
import TableProGoogleCloud
import TableProTestSupport
import Testing

struct BigQueryStoppableRequestTests {
    private struct Refused: Error {}

    private actor Record {
        private(set) var launches = 0
        private(set) var handedOver: [Int] = []
        private(set) var requestEnded = false
        private(set) var requestCancelled = false
        private var stopCheck: (@Sendable () -> Bool)?

        func launched(_ isStopped: @escaping @Sendable () -> Bool) {
            launches += 1
            stopCheck = isStopped
        }

        func ended(cancelled: Bool) {
            requestEnded = true
            requestCancelled = cancelled
        }

        func handOver(_ answer: Int) {
            handedOver.append(answer)
        }

        func isStopped() -> Bool? {
            stopCheck?()
        }
    }

    private struct Fixture {
        let gate = AsyncGate()
        let clock = ManualClock()
        let record = Record()

        // The request answers `outcome` once the gate opens; the gate does not watch cancellation, the answer does.
        func caller(answering outcome: Result<Int, Refused>, after startGate: AsyncGate? = nil) -> Task<Int, any Error> {
            Task { [gate, clock, record] in
                await startGate?.wait()
                return try await BigQueryStoppableRequest.value(
                    grace: .seconds(1),
                    limit: .seconds(10),
                    clock: clock
                ) { isStopped in
                    await record.launched(isStopped)
                    await gate.wait()
                    let cancelled = Task.isCancelled
                    await record.ended(cancelled: cancelled)
                    if cancelled { throw CancellationError() }
                    return try outcome.get()
                } afterStop: { answer in
                    await record.handOver(answer)
                }
            }
        }

        func waitForSleepers(_ count: Int) async throws {
            try await waitUntil { clock.pendingSleeperCount == count }
        }
    }

    @Test("Start runs the request once and its answer reaches the caller")
    func startThenAnswer() async throws {
        let fixture = Fixture()
        let running = fixture.caller(answering: .success(7))
        await fixture.gate.arrived(1)
        #expect(await fixture.record.launches == 1)
        #expect(await fixture.record.isStopped() == false)

        await fixture.gate.open()

        #expect(try await running.value == 7)
        #expect(await fixture.record.handedOver.isEmpty)
        #expect(fixture.clock.pendingSleeperCount == 0)
    }

    @Test("A caller cancelled before the request starts runs nothing")
    func cancelledBeforeStart() async throws {
        let fixture = Fixture()
        let startGate = AsyncGate()
        let running = fixture.caller(answering: .success(7), after: startGate)
        running.cancel()
        await startGate.open()

        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await fixture.record.launches == 0)
        #expect(fixture.clock.pendingSleeperCount == 0)
    }

    @Test("A failure before Stop reaches the caller")
    func failureBeforeStop() async {
        let fixture = Fixture()
        let running = fixture.caller(answering: .failure(Refused()))
        await fixture.gate.open()

        await #expect(throws: Refused.self) { try await running.value }
        #expect(await fixture.record.handedOver.isEmpty)
    }

    @Test("Stop marks the running request stopped and arms one timer")
    func stopWhileRunning() async throws {
        let fixture = Fixture()
        let running = fixture.caller(answering: .success(7))
        await fixture.gate.arrived(1)

        running.cancel()
        try await fixture.waitForSleepers(1)

        #expect(await fixture.record.isStopped() == true)
        await fixture.gate.open()
        await #expect(throws: CancellationError.self) { try await running.value }
    }

    @Test("An answer while the caller is held releases it as cancelled and goes to afterStop")
    func answerWhileHeld() async throws {
        let fixture = Fixture()
        let running = fixture.caller(answering: .success(7))
        await fixture.gate.arrived(1)
        running.cancel()
        try await fixture.waitForSleepers(1)

        await fixture.gate.open()

        await #expect(throws: CancellationError.self) { try await running.value }
        try await waitUntil { await fixture.record.handedOver == [7] }
        try await fixture.waitForSleepers(0)
        #expect(await fixture.record.requestCancelled == false)
    }

    @Test("A failure while the caller is held releases it as cancelled and hands nothing over")
    func failureWhileHeld() async throws {
        let fixture = Fixture()
        let running = fixture.caller(answering: .failure(Refused()))
        await fixture.gate.arrived(1)
        running.cancel()
        try await fixture.waitForSleepers(1)

        await fixture.gate.open()

        await #expect(throws: CancellationError.self) { try await running.value }
        try await fixture.waitForSleepers(0)
        #expect(await fixture.record.handedOver.isEmpty)
    }

    @Test("The grace releases a caller whose answer stalls, and the request keeps running")
    func graceReleasesTheCaller() async throws {
        let fixture = Fixture()
        let running = fixture.caller(answering: .success(7))
        await fixture.gate.arrived(1)
        running.cancel()
        try await fixture.waitForSleepers(1)

        fixture.clock.advance(by: .seconds(1))

        await #expect(throws: CancellationError.self) { try await running.value }
        try await fixture.waitForSleepers(1)
        #expect(await fixture.record.requestEnded == false)
        await fixture.gate.open()
        try await waitUntil { await fixture.record.requestEnded }
        #expect(await fixture.record.requestCancelled == false)
    }

    @Test("A late answer goes to afterStop and ends the timer")
    func lateAnswer() async throws {
        let fixture = Fixture()
        let running = fixture.caller(answering: .success(7))
        await fixture.gate.arrived(1)
        running.cancel()
        try await fixture.waitForSleepers(1)
        fixture.clock.advance(by: .seconds(1))
        await #expect(throws: CancellationError.self) { try await running.value }
        try await fixture.waitForSleepers(1)

        await fixture.gate.open()

        try await waitUntil { await fixture.record.handedOver == [7] }
        try await fixture.waitForSleepers(0)
        #expect(await fixture.record.requestCancelled == false)
    }

    @Test("A late failure hands nothing over and ends the timer")
    func lateFailure() async throws {
        let fixture = Fixture()
        let running = fixture.caller(answering: .failure(Refused()))
        await fixture.gate.arrived(1)
        running.cancel()
        try await fixture.waitForSleepers(1)
        fixture.clock.advance(by: .seconds(1))
        await #expect(throws: CancellationError.self) { try await running.value }
        try await fixture.waitForSleepers(1)

        await fixture.gate.open()

        try await waitUntil { await fixture.record.requestEnded }
        try await fixture.waitForSleepers(0)
        #expect(await fixture.record.handedOver.isEmpty)
    }

    @Test("The limit cancels a stopped request still unanswered")
    func limitCancelsTheRequest() async throws {
        let clock = ManualClock()
        let wire = ManualClock()
        let record = Record()
        let running = Task {
            try await BigQueryStoppableRequest.value(grace: .seconds(1), limit: .seconds(10), clock: clock) { isStopped in
                await record.launched(isStopped)
                do {
                    try await wire.sleep(for: .seconds(3_600))
                } catch {
                    await record.ended(cancelled: true)
                    throw error
                }
                return 7
            } afterStop: { answer in
                await record.handOver(answer)
            }
        }
        await wire.waitUntilSleeping()
        running.cancel()
        try await waitUntil { clock.pendingSleeperCount == 1 }
        clock.advance(by: .seconds(1))
        await #expect(throws: CancellationError.self) { try await running.value }
        try await waitUntil { clock.pendingSleeperCount == 1 }
        #expect(await record.requestEnded == false)

        clock.advance(by: .seconds(9))

        try await waitUntil { await record.requestCancelled }
        try await waitUntil { clock.pendingSleeperCount == 0 }
        #expect(await record.handedOver.isEmpty)
    }
}
