//
//  LibPQPendingResultDrainTests.swift
//  TableProTests
//

import Foundation
import Testing

private final class SimulatedLibPQConnection {
    private var queue: [LibPQPendingResult]
    private var activeCopy: LibPQCopy?
    private let leavesCopyOnEnd: Bool
    private(set) var endedCopies: [LibPQCopy] = []
    private(set) var reads = 0

    init(results: [LibPQPendingResult], leavesCopyOnEnd: Bool = true) {
        self.queue = results
        self.leavesCopyOnEnd = leavesCopyOnEnd
    }

    func nextResult() -> LibPQPendingResult? {
        reads += 1
        if let activeCopy { return .copy(activeCopy) }
        guard !queue.isEmpty else { return nil }
        let next = queue.removeFirst()
        if case .copy(let copy) = next { activeCopy = copy }
        return next
    }

    func endCopy(_ copy: LibPQCopy) {
        endedCopies.append(copy)
        guard leavesCopyOnEnd else { return }
        activeCopy = nil
        queue.insert(.completed, at: 0)
    }

    func drain() -> LibPQDrainOutcome {
        LibPQPendingResultDrain.drain(nextResult: nextResult, endCopy: endCopy)
    }
}

private func textual(_ direction: LibPQCopyDirection) -> LibPQCopy {
    LibPQCopy(direction: direction, format: .textual)
}

@Suite("LibPQPendingResultDrain")
struct LibPQPendingResultDrainTests {
    @Test("An idle connection drains without ending anything")
    func idleConnection() {
        let connection = SimulatedLibPQConnection(results: [])
        let outcome = connection.drain()
        #expect(outcome == .idle)
        #expect(outcome.abandonedCopy == nil)
        #expect(!outcome.leavesConnectionUnusable)
        #expect(connection.endedCopies.isEmpty)
    }

    @Test("Ordinary results are read until libpq has none left")
    func ordinaryResults() {
        let connection = SimulatedLibPQConnection(results: [.completed, .completed, .completed])
        #expect(connection.drain() == .idle)
        #expect(connection.endedCopies.isEmpty)
        #expect(connection.reads == 4)
    }

    @Test(
        "A COPY that repeats its state until ended is ended once and reported",
        arguments: [LibPQCopyDirection.copyIn, .copyOut, .copyBoth]
    )
    func copyStateIsEndedAndReported(direction: LibPQCopyDirection) {
        let connection = SimulatedLibPQConnection(results: [.copy(textual(direction))])
        let outcome = connection.drain()
        #expect(connection.endedCopies == [textual(direction)])
        #expect(outcome.abandonedCopy == textual(direction))
        #expect(!outcome.leavesConnectionUnusable)
    }

    @Test("A COPY behind an earlier statement is still reported, so nothing is discarded in silence")
    func copyAfterAnotherStatementIsReported() {
        let connection = SimulatedLibPQConnection(results: [.completed, .copy(textual(.copyIn))])
        let outcome = connection.drain()
        #expect(outcome.abandonedCopy == textual(.copyIn))
        #expect(connection.endedCopies == [textual(.copyIn)])
    }

    @Test("Each COPY in a multi-statement string is ended in turn and the first is reported")
    func consecutiveCopyStatements() {
        let connection = SimulatedLibPQConnection(
            results: [.completed, .copy(textual(.copyOut)), .copy(textual(.copyIn)), .completed]
        )
        let outcome = connection.drain()
        #expect(connection.endedCopies == [textual(.copyOut), textual(.copyIn)])
        #expect(outcome.abandonedCopy == textual(.copyOut))
    }

    @Test("The COPY format travels with the direction, because binary input cannot end with CopyDone")
    func formatIsCarried() {
        let binary = LibPQCopy(direction: .copyIn, format: .binary)
        let connection = SimulatedLibPQConnection(results: [.copy(binary)])
        #expect(connection.drain().abandonedCopy == binary)
        #expect(connection.endedCopies == [binary])
    }

    @Test("A COPY libpq refuses to leave stops the drain and marks the connection unusable")
    func stuckCopyTerminates() {
        let connection = SimulatedLibPQConnection(results: [.copy(textual(.copyIn))], leavesCopyOnEnd: false)
        let outcome = connection.drain()
        #expect(outcome.stuckInCopy == textual(.copyIn))
        #expect(outcome.leavesConnectionUnusable)
        #expect(outcome.abandonedCopy == textual(.copyIn))
        #expect(connection.endedCopies == [textual(.copyIn)])
        #expect(connection.reads == 2)
    }

    @Test("Every direction explains itself in query editor terms and names the COPY form it rejects")
    func unsupportedMessages() {
        #expect(LibPQCopyDirection.copyIn.unsupportedMessage.contains("COPY FROM STDIN"))
        #expect(LibPQCopyDirection.copyIn.unsupportedMessage.contains("no rows were sent"))
        #expect(LibPQCopyDirection.copyOut.unsupportedMessage.contains("COPY TO STDOUT"))
        #expect(!LibPQCopyDirection.copyBoth.unsupportedMessage.isEmpty)
        let messages = Set([LibPQCopyDirection.copyIn, .copyOut, .copyBoth].map(\.unsupportedMessage))
        #expect(messages.count == 3)
    }
}
