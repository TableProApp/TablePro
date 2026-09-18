//
//  MySQLStatementDeadlineRunnerTests.swift
//  TableProTests
//

import Foundation
import Testing

private struct StubFailure: Error, Equatable {
    let code: UInt32
    var message = "stub"
    var outlasted = false
}

private final class RunnerHarness: @unchecked Sendable {
    let watch = MySQLStatementWatch()
    var scheduledDuration: Duration?
    var cancelledSchedule = false
    var interrupts = 0
    var flushes = 0
    var orphanKills = 0
    var firesImmediately = false

    func runner(
        deadline: MySQLStatementDeadline?,
        flavor: MySQLServerFlavor = .mysql,
        socketTimeoutSeconds: UInt32 = 31,
        elapsed: Duration = .seconds(1)
    ) -> MySQLStatementDeadlineRunner {
        var reads = 0
        let start = ContinuousClock.now
        return MySQLStatementDeadlineRunner(
            deadline: deadline,
            flavor: flavor,
            socketTimeoutSeconds: socketTimeoutSeconds,
            watch: watch,
            now: {
                reads += 1
                return reads == 1 ? start : start.advanced(by: elapsed)
            },
            schedule: { duration, action in
                self.scheduledDuration = duration
                if self.firesImmediately { action() }
                return { self.cancelledSchedule = true }
            },
            expire: { token in
                self.watch.expire(token) {
                    self.interrupts += 1
                    return true
                }
            },
            flushInterrupt: { self.flushes += 1 },
            killOrphan: { self.orphanKills += 1 },
            failureDetail: { error in
                guard let failure = error as? StubFailure else { return nil }
                return MySQLStatementFailure(code: failure.code, message: failure.message)
            },
            deadlineExceeded: { StubFailure(code: 1_317, message: "stopped after \($0)s") },
            markOutlasted: { error in
                guard var failure = error as? StubFailure else { return error }
                failure.outlasted = true
                return failure
            }
        )
    }
}

@Suite("MySQL statement deadline runner")
struct MySQLStatementDeadlineRunnerTests {
    private let deadline = MySQLStatementDeadline(seconds: 5, scope: .selectStatements)

    @Test("A statement that finishes first cancels the schedule and is never interrupted")
    func fastBodyCancelsSchedule() throws {
        let harness = RunnerHarness()
        let value = try harness.runner(deadline: deadline).run("SELECT 1") { 42 }
        #expect(value == 42)
        #expect(harness.scheduledDuration == .seconds(5))
        #expect(harness.cancelledSchedule)
        #expect(harness.interrupts == 0)
        #expect(harness.flushes == 0)
    }

    @Test("A statement past the deadline is interrupted once and reported as the timeout")
    func slowBodyBecomesTimeout() {
        let harness = RunnerHarness()
        harness.firesImmediately = true
        #expect(throws: StubFailure(code: 1_317, message: "stopped after 5s")) {
            try harness.runner(deadline: deadline).run("SELECT SLEEP(9)") {
                throw StubFailure(code: 1_317, message: "Query execution was interrupted")
            }
        }
        #expect(harness.interrupts == 1)
        #expect(harness.flushes == 0)
    }

    /// The kill connection takes up to 1900ms to open, so the statement can finish while it is
    /// being built. The flag then waits for the next statement: measured on MySQL 5.5.62, the one
    /// after an idle kill failed with 1317 and an `INSERT ... SELECT` inserted nothing.
    @Test("A kill that landed too late is consumed before the queue is released")
    func killWithoutInterruptionIsFlushed() throws {
        let harness = RunnerHarness()
        harness.firesImmediately = true
        let value = try harness.runner(deadline: deadline).run("SELECT 1") { 7 }
        #expect(value == 7)
        #expect(harness.interrupts == 1)
        #expect(harness.flushes == 1)
    }

    @Test("A kill that landed on a statement the server refused for another reason is flushed too")
    func killWithUnrelatedFailureIsFlushed() {
        let harness = RunnerHarness()
        harness.firesImmediately = true
        #expect(throws: StubFailure(code: 1_146, message: "Table 't' doesn't exist")) {
            try harness.runner(deadline: deadline).run("SELECT 1") {
                throw StubFailure(code: 1_146, message: "Table 't' doesn't exist")
            }
        }
        #expect(harness.flushes == 1)
    }

    @Test("A lost connection past the socket timeout is flagged and the orphan is killed")
    func socketTimeoutKillsTheOrphan() {
        let harness = RunnerHarness()
        #expect(throws: StubFailure(code: 2_013, message: "Lost connection", outlasted: true)) {
            try harness.runner(deadline: nil, elapsed: .seconds(31)).run("SHOW TABLES") {
                throw StubFailure(code: 2_013, message: "Lost connection")
            }
        }
        #expect(harness.orphanKills == 1)
    }

    @Test("A lost connection before the socket timeout is left replayable")
    func earlyConnectionLossIsNotFlagged() {
        let harness = RunnerHarness()
        #expect(throws: StubFailure(code: 2_013, message: "Lost connection")) {
            try harness.runner(deadline: nil, elapsed: .seconds(2)).run("SHOW TABLES") {
                throw StubFailure(code: 2_013, message: "Lost connection")
            }
        }
        #expect(harness.orphanKills == 0)
    }

    @Test("A statement outside the deadline's scope schedules nothing")
    func outOfScopeStatementIsNotWatched() throws {
        let harness = RunnerHarness()
        let value = try harness.runner(deadline: deadline).run("SHOW TABLES") { 1 }
        #expect(value == 1)
        #expect(harness.scheduledDuration == nil)
        #expect(harness.interrupts == 0)
    }
}
