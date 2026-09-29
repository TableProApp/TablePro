import Foundation
import XCTest

final class HanaOperationSlotTests: XCTestCase {
    func testACancelAfterAssignmentReturnsTheTicketToInterrupt() {
        let slot = HanaOperationSlot()
        let ticket = HanaOperationTicket(session: 7, operation: 3)

        XCTAssertTrue(slot.assign(ticket))
        XCTAssertEqual(slot.cancel(), ticket)
    }

    func testACancelBeforeAssignmentKeepsTheOperationFromBeingIssued() {
        let slot = HanaOperationSlot()

        XCTAssertNil(slot.cancel())
        XCTAssertFalse(slot.assign(HanaOperationTicket(session: 7, operation: 4)))
    }

    func testOnlyTheFirstCancelReturnsTheTicket() {
        let slot = HanaOperationSlot()
        let ticket = HanaOperationTicket(session: 7, operation: 5)

        XCTAssertTrue(slot.assign(ticket))
        XCTAssertEqual(slot.cancel(), ticket)
        XCTAssertNil(slot.cancel())
        XCTAssertTrue(slot.isCancelled)
    }

    func testInterruptingAnOpenRunsItsResponseOnce() {
        let interruption = HanaOpenInterruption()
        let responses = HanaResponseCounter()

        XCTAssertTrue(interruption.whenInterrupted { responses.record() })
        interruption.interrupt()
        interruption.interrupt()

        XCTAssertEqual(responses.count, 1)
        XCTAssertTrue(interruption.isInterrupted)
    }

    func testAnOpenAlreadyInterruptedRefusesANewResponse() {
        let interruption = HanaOpenInterruption()
        let responses = HanaResponseCounter()
        interruption.interrupt()

        XCTAssertFalse(interruption.whenInterrupted { responses.record() })

        XCTAssertEqual(responses.count, 0)
    }

    func testAResponseNoLongerWatchedIsNotRun() {
        let interruption = HanaOpenInterruption()
        let responses = HanaResponseCounter()
        XCTAssertTrue(interruption.whenInterrupted { responses.record() })

        interruption.stopWatching()
        interruption.interrupt()

        XCTAssertEqual(responses.count, 0)
        XCTAssertTrue(interruption.isInterrupted)
    }
}

private final class HanaResponseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = 0

    var count: Int { lock.withLock { recorded } }

    func record() {
        lock.withLock { recorded += 1 }
    }
}
