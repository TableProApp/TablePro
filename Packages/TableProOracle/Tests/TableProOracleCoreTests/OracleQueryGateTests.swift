@testable import TableProOracleCore
import XCTest

/// The gate is what gives a task the right to close the channel, so a probe that cannot take a
/// turn must be told so rather than being allowed to act (#3053).
final class OracleQueryGateTests: XCTestCase {
    func testATurnIsRefusedWhileTheChannelIsHeld() async {
        let gate = QueryGate()
        await gate.acquire()

        guard case .busy = await gate.takeTurnIfFree() else {
            return XCTFail("A held gate must not hand out a second turn")
        }

        await gate.release()
        let afterRelease = await gate.takeTurnIfFree()
        XCTAssertEqual(afterRelease, .acquired)
    }

    func testAQueuedStatementKeepsTheChannelBusy() async {
        let gate = QueryGate()
        await gate.acquire()

        let queued = Task { await gate.acquire() }
        try? await Task.sleep(for: .milliseconds(50))

        guard case .busy = await gate.takeTurnIfFree() else {
            return XCTFail("A gate with a waiter must not hand out a turn")
        }

        await gate.release()
        await queued.value

        guard case .busy = await gate.takeTurnIfFree() else {
            return XCTFail("The waiter now holds the gate")
        }
        await gate.release()
    }

    /// Compared against the first holder's own age rather than a wall-clock bound: time only moves
    /// forward, so without the reset the second reading could never be the smaller one, whatever a
    /// loaded CI worker does to the scheduling in between.
    func testAHandoverRestartsTheHoldingClock() async {
        let gate = QueryGate()
        await gate.acquire()
        let queued = Task { await gate.acquire() }
        try? await Task.sleep(for: .milliseconds(120))

        guard case .busy(let beforeHandover) = await gate.takeTurnIfFree() else {
            return XCTFail("The first holder still holds the gate")
        }

        await gate.release()
        await queued.value

        guard case .busy(let afterHandover) = await gate.takeTurnIfFree() else {
            return XCTFail("The waiter now holds the gate")
        }
        XCTAssertGreaterThan(beforeHandover, .zero)
        XCTAssertLessThan(afterHandover, beforeHandover)
        await gate.release()
    }
}
