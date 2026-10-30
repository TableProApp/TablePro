import Foundation
import os
@testable import TableProOracleCore
import Testing

// A clock that moves only when a step says it took time.
private final class StepClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let current = OSAllocatedUnfairLock(initialState: Instant(offset: .zero))

    var now: Instant { current.withLock { $0 } }
    var minimumResolution: Duration { .zero }

    func advance(by duration: Duration) {
        current.withLock { $0 = $0.advanced(by: duration) }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        current.withLock { $0 = max($0, deadline) }
    }
}

// The host closes the transport 5 s after asking for Stop, so a DBMS_DEBUG kill must be sent at once and everything
// after it fit in 3 s.
struct OracleDebugStopBudgetTests {
    @Test func testTheKillGoesFirstAndTheRestWaitsForTheEnd() async {
        let clock = StepClock()
        let order = OSAllocatedUnfairLock(initialState: [String]())
        let ended = await OracleDebugStopBudget.endRunningTarget(clock: clock) {
            order.withLock { $0.append("kill at \(clock.now.offset)") }
            clock.advance(by: .milliseconds(300))
            return .marked
        } waitForEnd: { remaining in
            order.withLock { $0.append("wait \(remaining)") }
            return true
        }
        #expect(ended)
        #expect(order.withLock { $0 } == ["kill at 0.0 seconds", "wait 2.2 seconds"])
    }

    // Without ALTER SYSTEM the routine may still reach its end or a breakpoint, but only inside the budget.
    @Test func testARefusedKillWaitsOnlyForWhatIsLeft() async {
        let clock = StepClock()
        let waited = OSAllocatedUnfairLock<Duration?>(initialState: nil)
        let ended = await OracleDebugStopBudget.endRunningTarget(clock: clock) {
            clock.advance(by: .milliseconds(100))
            return .refused
        } waitForEnd: { remaining in
            waited.withLock { $0 = remaining }
            clock.advance(by: remaining)
            return false
        }
        #expect(!ended)
        #expect(waited.withLock { $0 } == .milliseconds(2_400))
        #expect(clock.now.offset <= OracleDebugStopBudget.total)
    }

    @Test func testAKillThatUsedTheBudgetDoesNotWait() async {
        let clock = StepClock()
        let waited = OSAllocatedUnfairLock(initialState: false)
        let ended = await OracleDebugStopBudget.endRunningTarget(clock: clock) {
            clock.advance(by: .seconds(3))
            return .marked
        } waitForEnd: { _ in
            waited.withLock { $0 = true }
            return true
        }
        #expect(!ended)
        #expect(!waited.withLock { $0 })
    }

    // ORA-00028 is how a killed target's call fails (measured); a transport the connection lost, or never had, says
    // nothing about the server session.
    @Test func testOnlyTheServersAnswerProvesTheCallEnded() {
        let answered: [Result<[String?], Error>] = [
            .success([]),
            .failure(OracleCoreError.queryFailed("ORA-00028: your session has been killed")),
            .failure(OracleDebugError.server(code: 6_543, message: "ORA-06543"))
        ]
        let unanswered: [Result<[String?], Error>] = [
            .failure(OracleCoreError.connectionClosed),
            .failure(OracleCoreError.notConnected),
            .failure(OracleCoreError.protocolError),
            .failure(OracleCoreError.queryFailed(String(format: OracleCoreError.driverErrorFormat, "uncleanShutdown"))),
            .failure(OracleCoreError.queryFailed("IOError: Connection reset by peer (errno: 54)")),
            .failure(CancellationError())
        ]
        #expect(answered.map { OracleDebugSupport.endedOnServer($0) } == [true, true, true])
        #expect(unanswered.map { OracleDebugSupport.endedOnServer($0) } == Array(repeating: false, count: 6))
    }

    // The kill can wait one supervisor poll on the gate; that and the cleanup still leave time to see the end.
    @Test func testTheSupervisorPollFitsInsideTheBudget() {
        let poll = Duration.seconds(OracleDBMSDebugStatements.supervisorTimeoutSeconds)
        #expect(poll + OracleDebugStopBudget.cleanup < OracleDebugStopBudget.total)
        #expect(OracleDebugStopBudget.total <= .seconds(3))
    }
}
