import Foundation
import TableProGoogleCloud
import TableProTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct BigQueryStoppableRequestTests {
    private struct Refused: Error {}

    private actor Record {
        private(set) var launches = 0
        private(set) var handedOver: [Int] = []
        private(set) var requestEnded = false
        private(set) var requestCancelled = false
        private var signals: BigQueryRequestSignals?

        func launched(_ signals: BigQueryRequestSignals) {
            launches += 1
            self.signals = signals
        }

        func ended(cancelled: Bool) {
            requestEnded = true
            requestCancelled = cancelled
        }

        func handOver(_ answer: Int) {
            handedOver.append(answer)
        }

        func isStopped() -> Bool? {
            signals?.isStopped()
        }

        func beginAttempt() -> Bool? {
            signals?.beginAttempt()
        }

        func bodySent() {
            signals?.bodySent()
        }
    }

    private struct Fixture {
        let gate = AsyncGate()
        let clock = ManualClock()
        let record = Record()

        // The request starts an attempt, reports its body sent when `sendsBody`, then answers `outcome` once the gate
        // opens. The gate does not watch cancellation; the answer does.
        func caller(
            answering outcome: Result<Int, Refused>,
            sendsBody: Bool = true,
            after startGate: AsyncGate? = nil
        ) -> Task<Int, any Error> {
            Task { [gate, clock, record] in
                await startGate?.wait()
                return try await BigQueryStoppableRequest.value(
                    grace: .seconds(1),
                    limit: .seconds(10),
                    clock: clock
                ) { signals in
                    await record.launched(signals)
                    guard signals.beginAttempt() else { throw CancellationError() }
                    if sendsBody { signals.bodySent() }
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

    // A request whose wait ends only when its task is cancelled, as a stalled transfer or token fetch does.
    private func stalledCaller(
        clock: ManualClock,
        record: Record,
        sendsBody: Bool
    ) -> Task<Int, any Error> {
        Task {
            try await BigQueryStoppableRequest.value(grace: .seconds(1), limit: .seconds(10), clock: clock) { signals in
                guard signals.beginAttempt() else { throw CancellationError() }
                if sendsBody { signals.bodySent() }
                await record.launched(signals)
                do {
                    try await Task.sleep(for: .seconds(3_600))
                } catch {
                    await record.ended(cancelled: true)
                    throw error
                }
                return 7
            } afterStop: { answer in
                await record.handOver(answer)
            }
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

    @Test("Stop before the body is sent cancels the request at once, as main did")
    func stopBeforeTheBodyIsSent() async throws {
        let clock = ManualClock()
        let record = Record()
        let running = stalledCaller(clock: clock, record: record, sendsBody: false)
        try await waitUntil { await record.launches == 1 }

        running.cancel()

        await #expect(throws: CancellationError.self) { try await running.value }
        try await waitUntil { await record.requestCancelled }
        try await waitUntil { clock.pendingSleeperCount == 0 }
        #expect(await record.handedOver.isEmpty)
    }

    @Test("A new attempt after a sent one is not sent until it says so, so Stop cancels it at once")
    func newAttemptStartsUnsent() async throws {
        let clock = ManualClock()
        let record = Record()
        let running = stalledCaller(clock: clock, record: record, sendsBody: true)
        try await waitUntil { await record.launches == 1 }
        #expect(await record.beginAttempt() == true)

        running.cancel()

        await #expect(throws: CancellationError.self) { try await running.value }
        try await waitUntil { await record.requestCancelled }
    }

    @Test("Stop after the body is sent holds the request, arms one timer and refuses a new attempt")
    func stopAfterTheBodyIsSent() async throws {
        let fixture = Fixture()
        let running = fixture.caller(answering: .success(7))
        await fixture.gate.arrived(1)

        running.cancel()
        try await fixture.waitForSleepers(1)

        #expect(await fixture.record.isStopped() == true)
        #expect(await fixture.record.beginAttempt() == false)
        #expect(await fixture.record.requestEnded == false)
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

    @Test("The limit cancels a sent request still unanswered")
    func limitCancelsTheRequest() async throws {
        let clock = ManualClock()
        let record = Record()
        let running = stalledCaller(clock: clock, record: record, sendsBody: true)
        try await waitUntil { await record.launches == 1 }
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

    @Test("A timer that resumes late still cancels at the limit counted from Stop")
    func lateTimerKeepsTheLimit() async throws {
        let clock = ManualClock()
        let record = Record()
        let running = stalledCaller(clock: clock, record: record, sendsBody: true)
        try await waitUntil { await record.launches == 1 }
        running.cancel()
        try await waitUntil { clock.pendingSleeperCount == 1 }

        clock.advance(by: .seconds(10))

        await #expect(throws: CancellationError.self) { try await running.value }
        try await waitUntil { await record.requestCancelled }
        try await waitUntil { clock.pendingSleeperCount == 0 }
    }
}
