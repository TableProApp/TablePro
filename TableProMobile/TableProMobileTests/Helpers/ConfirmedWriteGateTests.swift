import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("Confirmed write gate")
struct ConfirmedWriteGateTests {
    private let statement = "INSERT INTO t (a) VALUES (1)"

    @Test("Safe mode off runs the write at once and keeps nothing pending")
    func offRunsAtOnce() {
        var gate = ConfirmedWriteGate()

        #expect(gate.submit(statement, under: .off) == .run(statement))
        #expect(gate.pendingStatement == nil)
    }

    @Test("Read-only blocks the write and keeps nothing pending")
    func readOnlyBlocks() {
        var gate = ConfirmedWriteGate()

        #expect(gate.submit(statement, under: .readOnly) == .blocked)
        #expect(gate.pendingStatement == nil)
    }

    @Test("Confirm Writes holds the write until it is confirmed, and hands it over once")
    func confirmWritesWaitsForConfirmation() {
        var gate = ConfirmedWriteGate()

        #expect(gate.submit(statement, under: .confirmWrites) == .awaitConfirmation)
        #expect(gate.confirm(under: .confirmWrites) == statement)
        #expect(gate.confirm(under: .confirmWrites) == nil)
    }

    @Test("A write confirmed after safe mode turned read-only does not run")
    func readOnlyAfterConfirmationBlocks() {
        var gate = ConfirmedWriteGate()
        #expect(gate.submit(statement, under: .confirmWrites) == .awaitConfirmation)

        #expect(gate.confirm(under: .readOnly) == nil)
        #expect(gate.pendingStatement == nil)
    }

    @Test("A cancelled confirmation leaves nothing to run")
    func cancelDropsThePendingWrite() {
        var gate = ConfirmedWriteGate()
        #expect(gate.submit(statement, under: .confirmWrites) == .awaitConfirmation)

        gate.cancel()

        #expect(gate.confirm(under: .off) == nil)
    }
}
