import Foundation
import TableProMSSQLCore
import Testing

struct MSSQLSessionTransactionTests {
    @Test("The probe asks for the count and commit state inside an EXECUTE, which keeps the session's @@ROWCOUNT")
    func probeAsksForBoth() {
        #expect(MSSQLSessionTransaction.probe == "EXEC sp_executesql N'SELECT @@TRANCOUNT, XACT_STATE()'")
    }

    @Test("No open transaction is idle")
    func zeroCountIsIdle() {
        #expect(MSSQLSessionTransaction.state(tranCount: "0", transactionState: "0") == .idle)
    }

    @Test("Any open transaction, nested or not, is open")
    func positiveCountIsOpen() {
        #expect(MSSQLSessionTransaction.state(tranCount: "1", transactionState: "1") == .open)
        #expect(MSSQLSessionTransaction.state(tranCount: "2", transactionState: "1") == .open)
    }

    @Test("Padding around the count is read past")
    func paddedCountIsRead() {
        #expect(MSSQLSessionTransaction.state(tranCount: " 1 ", transactionState: " 1 ") == .open)
    }

    @Test("XACT_STATE -1 is a transaction that can only roll back")
    func uncommittableTransaction() {
        #expect(MSSQLSessionTransaction.state(tranCount: "1", transactionState: "-1") == .uncommittable)
        #expect(MSSQLSessionTransaction.state(tranCount: "1", transactionState: " -1 ") == .uncommittable)
    }

    @Test("An unreadable XACT_STATE still reports the count")
    func unreadableXactStateFallsBackToTheCount() {
        #expect(MSSQLSessionTransaction.state(tranCount: "1", transactionState: nil) == .open)
        #expect(MSSQLSessionTransaction.state(tranCount: "0", transactionState: nil) == .idle)
    }

    @Test("An unreadable count says nothing")
    func unreadableCountIsNil() {
        #expect(MSSQLSessionTransaction.state(tranCount: nil, transactionState: "1") == nil)
        #expect(MSSQLSessionTransaction.state(tranCount: "", transactionState: "-1") == nil)
        #expect(MSSQLSessionTransaction.state(tranCount: "n/a", transactionState: "0") == nil)
    }
}
