import Foundation
@testable import TableProOracleCore
import Testing

/// The gate is what gives a task the right to close the channel, so a probe that cannot take a
/// turn must be told so rather than being allowed to act (#3053).
struct OracleQueryGateTests {
    @Test func testATurnIsRefusedWhileTheChannelIsHeld() async {
        let gate = QueryGate()
        await gate.acquire()

        guard case .busy = await gate.takeTurnIfFree() else {
            Issue.record("A held gate must not hand out a second turn")
            return
        }

        await gate.release()
        let afterRelease = await gate.takeTurnIfFree()
        #expect(afterRelease == .acquired)
    }

    @Test func testAQueuedStatementKeepsTheChannelBusy() async {
        let gate = QueryGate()
        await gate.acquire()

        let queued = Task { await gate.acquire() }
        try? await Task.sleep(for: .milliseconds(50))

        guard case .busy = await gate.takeTurnIfFree() else {
            Issue.record("A gate with a waiter must not hand out a turn")
            return
        }

        await gate.release()
        await queued.value

        guard case .busy = await gate.takeTurnIfFree() else {
            Issue.record("The waiter now holds the gate")
            return
        }
        await gate.release()
    }

    /// Compared against the first holder's own age rather than a wall-clock bound: time only moves
    /// forward, so without the reset the second reading could never be the smaller one, whatever a
    /// loaded CI worker does to the scheduling in between.
    @Test func testAHandoverRestartsTheHoldingClock() async {
        let gate = QueryGate()
        await gate.acquire()
        let queued = Task { await gate.acquire() }
        try? await Task.sleep(for: .milliseconds(120))

        guard case .busy(let beforeHandover) = await gate.takeTurnIfFree() else {
            Issue.record("The first holder still holds the gate")
            return
        }

        await gate.release()
        await queued.value

        guard case .busy(let afterHandover) = await gate.takeTurnIfFree() else {
            Issue.record("The waiter now holds the gate")
            return
        }
        #expect(beforeHandover > .zero)
        #expect(afterHandover < beforeHandover)
        await gate.release()
    }
}
