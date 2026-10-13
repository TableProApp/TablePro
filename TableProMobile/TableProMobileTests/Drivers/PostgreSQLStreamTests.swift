import CLibPQ
import Foundation
@testable import TableProMobile
import Testing

@Suite("PostgreSQL stream end")
struct PostgreSQLStreamTests {
    private func drain(
        _ results: [PostgreSQLPendingResult],
        afterCancel: Bool = false
    ) -> (end: PostgreSQLStreamEnd, ended: [LibPQCopy], unread: Int) {
        var pending = results
        var ended: [LibPQCopy] = []
        let drained = PostgreSQLStreamDrain.drain(
            nextResult: { pending.isEmpty ? nil : pending.removeFirst() },
            endCopy: { ended.append($0) },
            afterCancel: afterCancel
        )
        return (drained.end, ended, pending.count)
    }

    @Test("A failed statement and an unreadable reply count as failures; rows and completions do not")
    func failureStatuses() {
        #expect(PostgreSQLStreamDrain.isFailure(PGRES_FATAL_ERROR))
        #expect(PostgreSQLStreamDrain.isFailure(PGRES_BAD_RESPONSE))
        #expect(!PostgreSQLStreamDrain.isFailure(PGRES_SINGLE_TUPLE))
        #expect(!PostgreSQLStreamDrain.isFailure(PGRES_TUPLES_OK))
        #expect(!PostgreSQLStreamDrain.isFailure(PGRES_COMMAND_OK))
        #expect(!PostgreSQLStreamDrain.isFailure(PGRES_EMPTY_QUERY))
    }

    @Test("A statement that fails behind a completed result ends the stream with that failure")
    func failureBehindCompletedResult() {
        let message = "ERROR:  duplicate key value violates unique constraint \"s_pkey\"\n"
        let drained = drain([.completed, .failed(message)])
        #expect(drained.end == .failed(message))
        #expect(drained.unread == 0)
    }

    @Test("The first failure is the one reported, and every result is still read")
    func firstFailureWins() {
        let drained = drain([.failed("ERROR:  division by zero\n"), .failed("ERROR:  later\n"), .completed])
        #expect(drained.end == .failed("ERROR:  division by zero\n"))
        #expect(drained.unread == 0)
    }

    @Test("A failure after the driver's own cancel ends the stream as cancelled")
    func failureAfterCancelIsTheCancel() {
        let drained = drain(
            [.completed, .failed("ERROR:  canceling statement due to user request\n")],
            afterCancel: true
        )
        #expect(drained.end == .cancelled)
    }

    @Test("A COPY is reported over the error that ending it provokes")
    func copyWinsOverItsOwnError() {
        let copy = LibPQCopy(direction: .copyIn, format: .binary)
        let drained = drain([.copy(copy), .failed("ERROR:  COPY from stdin failed: no COPY data was sent\n")])
        #expect(drained.ended == [copy])
        #expect(drained.end == .abandonedCopy(.copyIn))
    }

    @Test("Rows and completions alone end the stream cleanly")
    func cleanDrainCompletes() {
        let drained = drain([.completed, .completed], afterCancel: true)
        #expect(drained.end == .completed)
        #expect(drained.unread == 0)
    }

    @Test("Whether the cancel happened is asked only once every result is read")
    func cancelIsReadAfterTheResults() {
        var pending: [PostgreSQLPendingResult] = [.completed, .failed("ERROR:  canceling statement due to user request\n")]
        var cancelled = false
        let drained = PostgreSQLStreamDrain.drain(
            nextResult: {
                guard !pending.isEmpty else { return nil }
                cancelled = true
                return pending.removeFirst()
            },
            endCopy: { _ in },
            afterCancel: cancelled
        )
        #expect(drained.end == .cancelled)
    }

    @Test("A failed end carries the server's message, and a cancelled end is a cancellation")
    func endErrors() {
        let failure = PostgreSQLStreamEnd.failed("ERROR:  division by zero\n").error as? PostgreSQLError
        #expect(failure?.errorDescription?.contains("division by zero") == true)
        #expect(PostgreSQLStreamEnd.cancelled.error is CancellationError)
        #expect(PostgreSQLStreamEnd.completed.error == nil)
        let copy = PostgreSQLStreamEnd.abandonedCopy(.copyOut).error as? PostgreSQLError
        #expect(copy?.errorDescription == LibPQCopyDirection.copyOut.unsupportedMessage)
    }
}

@Suite("PostgreSQL query cancels")
struct PostgreSQLQueryCancelsTests {
    @Test("A cancel for the query in flight marks it and goes out once")
    func cancelInFlightQuery() {
        var cancels = PostgreSQLQueryCancels()
        let query = cancels.reserve()
        cancels.sent(query)
        let firstCancelSent = cancels.cancel(query)
        #expect(firstCancelSent)
        let secondCancelSent = cancels.cancel(query)
        #expect(!secondCancelSent)
        #expect(cancels.isCancelled(query))
    }

    @Test("A cancel for a query that is not in flight yet sends nothing and marks nothing")
    func cancelBeforeSendIsDropped() {
        var cancels = PostgreSQLQueryCancels()
        let query = cancels.reserve()
        let cancelSent = cancels.cancel(query)
        #expect(!cancelSent)
        cancels.sent(query)
        #expect(!cancels.isCancelled(query))
    }

    @Test("A cancel aimed at a finished query never marks the next one")
    func lateCancelDoesNotReachTheNextQuery() {
        var cancels = PostgreSQLQueryCancels()
        let first = cancels.reserve()
        cancels.sent(first)
        cancels.finished(first)
        let second = cancels.reserve()
        cancels.sent(second)
        let lateCancelSent = cancels.cancel(first)
        #expect(!lateCancelSent)
        #expect(!cancels.isCancelled(second))
        #expect(cancels.inFlight == second)
    }

    @Test("Stop cancels whatever query is in flight, and nothing when none is")
    func stopTargetsTheQueryInFlight() {
        var cancels = PostgreSQLQueryCancels()
        let idleStopSent = cancels.cancelInFlight()
        #expect(!idleStopSent)
        let browse = cancels.reserve()
        let editor = cancels.reserve()
        cancels.sent(editor)
        let stopSent = cancels.cancelInFlight()
        #expect(stopSent)
        #expect(cancels.isCancelled(editor))
        #expect(!cancels.isCancelled(browse))
    }

    @Test("The end of another query leaves the one in flight in place")
    func finishingAnotherQueryKeepsTheInFlightOne() {
        var cancels = PostgreSQLQueryCancels()
        let stale = cancels.reserve()
        let current = cancels.reserve()
        cancels.sent(current)
        cancels.finished(stale)
        #expect(cancels.inFlight == current)
    }

    @Test("Closing the connection leaves nothing in flight to cancel")
    func detachClearsTheQueryInFlight() {
        var cancels = PostgreSQLQueryCancels()
        let query = cancels.reserve()
        cancels.sent(query)
        cancels.detach()
        #expect(cancels.inFlight == nil)
        let cancelSent = cancels.cancel(query)
        #expect(!cancelSent)
    }
}
