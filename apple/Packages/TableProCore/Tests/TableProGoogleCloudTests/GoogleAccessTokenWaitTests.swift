import Foundation
import TableProGoogleCloud
import TableProTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct GoogleAccessTokenWaitTests {
    private struct Refused: Error {}

    private actor GatedTokens: GoogleAccessTokenProviding {
        private let gate: AsyncGate
        private let outcome: Result<String, Refused>
        private(set) var asked = 0
        private(set) var answered = false

        init(gate: AsyncGate, outcome: Result<String, Refused>) {
            self.gate = gate
            self.outcome = outcome
        }

        // Waits like a shared refresh does: cancelling the caller does not end it.
        func accessToken() async throws -> String {
            asked += 1
            await gate.wait()
            answered = true
            return try outcome.get()
        }

        func invalidateCachedToken() async {}
    }

    @Test("The caller gets the token")
    func tokenReachesTheCaller() async throws {
        let gate = AsyncGate()
        let tokens = GatedTokens(gate: gate, outcome: .success("token"))
        await gate.open()

        #expect(try await GoogleAccessTokenWait.token(from: tokens) == "token")
        #expect(await tokens.asked == 1)
    }

    @Test("A failed fetch reaches the caller")
    func failureReachesTheCaller() async {
        let gate = AsyncGate()
        let tokens = GatedTokens(gate: gate, outcome: .failure(Refused()))
        await gate.open()

        await #expect(throws: Refused.self) { _ = try await GoogleAccessTokenWait.token(from: tokens) }
    }

    @Test("A caller cancelled before the wait asks for nothing")
    func cancelledBeforeStart() async {
        let gate = AsyncGate()
        let tokens = GatedTokens(gate: gate, outcome: .success("token"))
        let startGate = AsyncGate()
        let waiting = Task {
            await startGate.wait()
            return try await GoogleAccessTokenWait.token(from: tokens)
        }
        waiting.cancel()
        await startGate.open()

        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        #expect(await tokens.asked == 0)
    }

    @Test("A cancelled caller stops waiting while the fetch runs on")
    func cancelledWhileWaiting() async throws {
        let gate = AsyncGate()
        let tokens = GatedTokens(gate: gate, outcome: .success("token"))
        let waiting = Task { try await GoogleAccessTokenWait.token(from: tokens) }
        await gate.arrived(1)

        waiting.cancel()

        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        #expect(await tokens.answered == false)
        await gate.open()
        try await waitUntil { await tokens.answered }
    }
}
