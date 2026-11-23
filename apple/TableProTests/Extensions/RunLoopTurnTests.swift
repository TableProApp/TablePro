//
//  RunLoopTurnTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
private final class TurnLog {
    var entries: [String] = []
}

@MainActor
struct RunLoopTurnTests {
    private func nextTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform { continuation.resume() }
        }
    }

    @Test("The body runs once, after work queued in the same turn")
    func bodyRunsOnceAtTheEndOfTheTurn() async throws {
        let log = TurnLog()
        RunLoopTurn.onEnd { log.entries.append("end") }
        RunLoop.main.perform { MainActor.assumeIsolated { log.entries.append("work") } }

        try await waitUntil { log.entries.contains("end") }
        await nextTurn()
        await nextTurn()

        #expect(log.entries == ["work", "end"])
    }
}
