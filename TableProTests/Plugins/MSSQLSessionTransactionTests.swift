//
//  MSSQLSessionTransactionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct MSSQLSessionTransactionTests {
    @Test("A transaction count above zero is an open transaction")
    func openTransactionIsCounted() {
        #expect(MSSQLSessionTransaction.state(tranCount: "1", transactionState: "1") == .inTransaction)
        #expect(MSSQLSessionTransaction.state(tranCount: "2", transactionState: "1") == .inTransaction)
    }

    @Test("Nothing open reads as idle")
    func noTransactionIsIdle() {
        #expect(MSSQLSessionTransaction.state(tranCount: "0", transactionState: "0") == .idle)
    }

    /// `XACT_STATE()` answers -1 for a transaction that can no longer be committed, which is what a
    /// batch-aborting error leaves behind. Telling the user to commit that one discards their work.
    @Test("An uncommittable transaction is its own answer")
    func uncommittableTransactionIsAborted() {
        #expect(MSSQLSessionTransaction.state(tranCount: "1", transactionState: "-1") == .abortedTransaction)
        #expect(MSSQLSessionTransaction.state(tranCount: "0", transactionState: "-1") == .abortedTransaction)
    }

    @Test("A count that is missing or not a number says nothing")
    func unreadableCountIsUnknown() {
        #expect(MSSQLSessionTransaction.state(tranCount: nil, transactionState: "0") == .unknown)
        #expect(MSSQLSessionTransaction.state(tranCount: "", transactionState: "0") == .unknown)
        #expect(MSSQLSessionTransaction.state(tranCount: "none", transactionState: "0") == .unknown)
    }

    @Test("Padding around the numbers a driver returns is read through")
    func paddedNumbersParse() {
        #expect(MSSQLSessionTransaction.state(tranCount: " 1 ", transactionState: " 1 ") == .inTransaction)
        #expect(MSSQLSessionTransaction.state(tranCount: " 0 ", transactionState: " -1 ") == .abortedTransaction)
    }

    /// Measured on Azure SQL Edge: with `SET IMPLICIT_TRANSACTIONS ON` and nothing run since,
    /// `@@TRANCOUNT` is 0 and stays 0, so nothing is pending and a caller's own transaction commits
    /// only its own statements. The first statement after that makes it 1.
    @Test("Implicit transactions on their own are not a transaction")
    func implicitTransactionsAloneAreIdle() {
        #expect(MSSQLSessionTransaction.state(tranCount: "0", transactionState: "0") == .idle)
        #expect(MSSQLSessionTransaction.probe == "SELECT @@TRANCOUNT, XACT_STATE()")
    }
}
