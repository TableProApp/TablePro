//
//  LibPQSessionCheckTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct LibPQSessionCheckTests {
    private static func serverError(_ sqlState: String?, _ message: String = "ERROR:  refused") -> LibPQPluginError {
        LibPQPluginError(message: message, sqlState: sqlState, detail: nil)
    }

    @Test("Inside a transaction block, open or aborted, the check sends no statement")
    func noStatementInsideATransaction() {
        #expect(!LibPQSessionCheck.sendsStatement(in: .inTransaction))
        #expect(!LibPQSessionCheck.sendsStatement(in: .inError))
    }

    @Test("Outside a transaction block, or when the state is not known, the check makes a round trip")
    func roundTripOtherwise() {
        #expect(LibPQSessionCheck.sendsStatement(in: .idle))
        #expect(LibPQSessionCheck.sendsStatement(in: .active))
        #expect(LibPQSessionCheck.sendsStatement(in: .unknown))
    }

    /// Measured on PostgreSQL 17.11: after a failed statement inside `BEGIN`, `SELECT 1` answers
    /// `25P02` on a session that is still there.
    @Test("A statement refused inside an aborted transaction is the server's answer")
    func abortedTransactionAnswers() {
        let refused = Self.serverError(
            "25P02",
            "ERROR:  current transaction is aborted, commands ignored until end of transaction block"
        )
        #expect(LibPQSessionCheck.refusalState(of: refused) == "25P02")
    }

    @Test("Any server error with a SQLSTATE is an answer", arguments: ["57014", "53200", "42501", "XX000"])
    func serverErrorsAnswer(sqlState: String) {
        #expect(LibPQSessionCheck.refusalState(of: Self.serverError(sqlState)) == sqlState)
    }

    @Test("A lost session is not an answer, even with the server's SQLSTATE on it")
    func lostSessionIsNotAnAnswer() {
        let fatal = Self.serverError("57P01", "FATAL:  terminating connection due to administrator command")
        let losses: [LibPQConnectionLoss] = [
            .afterSending,
            .beforeSending(transactionMayBeOpen: true),
            .beforeSending(transactionMayBeOpen: false)
        ]

        for loss in losses {
            let lost = LibPQConnectionLostError(loss: loss, underlying: fatal)
            #expect(LibPQSessionCheck.refusalState(of: lost) == nil, "\(loss)")
        }
    }

    @Test("libpq's own failures and a cancellation are not an answer")
    func clientFailuresAreNotAnAnswer() {
        #expect(LibPQSessionCheck.refusalState(of: LibPQPluginError.notConnected) == nil)
        #expect(LibPQSessionCheck.refusalState(of: LibPQPluginError.connectionTimedOut) == nil)
        #expect(LibPQSessionCheck.refusalState(of: Self.serverError(nil, "server closed the connection unexpectedly")) == nil)
        #expect(LibPQSessionCheck.refusalState(of: Self.serverError("")) == nil)
        #expect(LibPQSessionCheck.refusalState(of: CancellationError()) == nil)
    }
}
