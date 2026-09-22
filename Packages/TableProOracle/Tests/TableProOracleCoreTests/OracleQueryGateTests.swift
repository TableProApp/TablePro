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

    func testAHandoverRestartsTheHoldingClock() async {
        let gate = QueryGate()
        await gate.acquire()
        let queued = Task { await gate.acquire() }
        try? await Task.sleep(for: .milliseconds(120))

        await gate.release()
        await queued.value

        guard case .busy(let held) = await gate.takeTurnIfFree() else {
            return XCTFail("The waiter now holds the gate")
        }
        XCTAssertLessThan(held, .milliseconds(100))
        await gate.release()
    }
}
