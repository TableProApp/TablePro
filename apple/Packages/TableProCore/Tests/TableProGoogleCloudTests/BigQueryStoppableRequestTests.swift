import Foundation
import TableProGoogleCloud
import TableProTestSupport
import Testing

struct BigQueryStoppableRequestTests {
    private actor Received {
        private(set) var answers: [Int] = []

        func append(_ answer: Int) {
            answers.append(answer)
        }
    }

    private struct Refused: Error {}

    private func caller(
        _ request: Task<Int, any Error>,
        stop: BigQueryStopSignal,
        clock: ManualClock,
        received: Received
    ) -> Task<Int, any Error> {
        Task {
            try await BigQueryStoppableRequest.value(of: request, stop: stop, grace: .seconds(1), clock: clock) {
                await received.append($0)
            }
        }
    }

    @Test("Without Stop the caller gets the answer")
    func answerReachesTheCaller() async throws {
        let value = try await caller(Task { 7 }, stop: BigQueryStopSignal(), clock: ManualClock(), received: Received()).value
        #expect(value == 7)
    }

    @Test("Without Stop the caller gets the request's error")
    func errorReachesTheCaller() async {
        let request = Task<Int, any Error> { throw Refused() }
        let running = caller(request, stop: BigQueryStopSignal(), clock: ManualClock(), received: Received())
        await #expect(throws: Refused.self) { try await running.value }
    }

    @Test("Stop releases the caller once the answer is in, and the answer goes to the cancel")
    func stopReleasesOnTheAnswer() async throws {
        let gate = AsyncGate()
        let request = Task<Int, any Error> {
            await gate.wait()
            return 7
        }
        let stop = BigQueryStopSignal()
        let clock = ManualClock()
        let received = Received()
        let running = caller(request, stop: stop, clock: clock, received: received)
        await gate.arrived(1)

        running.cancel()
        await clock.waitUntilSleeping()
        #expect(stop.isStopped)
        await gate.open()

        await #expect(throws: CancellationError.self) { try await running.value }
        try await waitUntil { await received.answers == [7] }
    }

    @Test("Stop releases the caller after the grace period when the answer stalls, and the cancel still follows")
    func stopReleasesAfterTheGrace() async throws {
        let gate = AsyncGate()
        let request = Task<Int, any Error> {
            await gate.wait()
            return 7
        }
        let stop = BigQueryStopSignal()
        let clock = ManualClock()
        let received = Received()
        let running = caller(request, stop: stop, clock: clock, received: received)
        await gate.arrived(1)

        running.cancel()
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(1))

        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await received.answers.isEmpty)

        await gate.open()
        try await waitUntil { await received.answers == [7] }
    }
}
