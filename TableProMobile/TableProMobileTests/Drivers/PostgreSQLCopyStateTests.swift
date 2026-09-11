import CLibPQ
import Foundation
@testable import TableProMobile
import Testing

@Suite("PostgreSQL COPY state")
struct PostgreSQLCopyStateTests {
    @Test("Every libpq COPY status maps to its direction")
    func copyStatusMapping() {
        #expect(LibPQCopyState.direction(of: PGRES_COPY_IN) == .copyIn)
        #expect(LibPQCopyState.direction(of: PGRES_COPY_OUT) == .copyOut)
        #expect(LibPQCopyState.direction(of: PGRES_COPY_BOTH) == .copyBoth)
    }

    @Test("A result that is not a COPY maps to no direction")
    func nonCopyStatusMapping() {
        #expect(LibPQCopyState.direction(of: PGRES_COMMAND_OK) == nil)
        #expect(LibPQCopyState.direction(of: PGRES_TUPLES_OK) == nil)
        #expect(LibPQCopyState.direction(of: PGRES_SINGLE_TUPLE) == nil)
        #expect(LibPQCopyState.direction(of: PGRES_FATAL_ERROR) == nil)
        #expect(LibPQCopyState.direction(of: PGRES_EMPTY_QUERY) == nil)
    }

    @Test("Every direction explains itself and names the COPY form it rejects")
    func unsupportedMessages() {
        #expect(LibPQCopyDirection.copyIn.unsupportedMessage.contains("COPY FROM STDIN"))
        #expect(LibPQCopyDirection.copyIn.unsupportedMessage.contains("no rows were sent"))
        #expect(LibPQCopyDirection.copyOut.unsupportedMessage.contains("COPY TO STDOUT"))
        #expect(!LibPQCopyDirection.copyBoth.unsupportedMessage.isEmpty)
        let messages = Set([LibPQCopyDirection.copyIn, .copyOut, .copyBoth].map(\.unsupportedMessage))
        #expect(messages.count == 3)
    }

    @Test("A COPY behind an earlier statement is ended and reported, never discarded in silence")
    func copyAfterAnotherStatementIsReported() {
        let copy = LibPQCopy(direction: .copyIn, format: .textual)
        var pending: [LibPQPendingResult] = [.completed, .copy(copy)]
        var ended: [LibPQCopy] = []
        let outcome = LibPQPendingResultDrain.drain(
            nextResult: { pending.isEmpty ? nil : pending.removeFirst() },
            endCopy: { ended.append($0) }
        )
        #expect(ended == [copy])
        #expect(outcome.abandonedCopy == copy)
    }

    @Test("A COPY libpq never leaves stops the drain and marks the connection unusable")
    func stuckCopyTerminates() {
        var reads = 0
        let outcome = LibPQPendingResultDrain.drain(
            nextResult: {
                reads += 1
                return .copy(LibPQCopy(direction: .copyOut, format: .textual))
            },
            endCopy: { _ in }
        )
        #expect(outcome.stuckInCopy == LibPQCopy(direction: .copyOut, format: .textual))
        #expect(outcome.leavesConnectionUnusable)
        #expect(reads == 2)
    }
}
