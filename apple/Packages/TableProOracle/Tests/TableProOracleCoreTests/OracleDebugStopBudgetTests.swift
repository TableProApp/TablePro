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

    // The kill can wait one supervisor poll on the gate; that and the cleanup still leave time to see the end.
    @Test func testTheSupervisorPollFitsInsideTheBudget() {
        let poll = Duration.seconds(OracleDBMSDebugStatements.supervisorTimeoutSeconds)
        #expect(poll + OracleDebugStopBudget.cleanup < OracleDebugStopBudget.total)
        #expect(OracleDebugStopBudget.total <= .seconds(3))
    }
}
