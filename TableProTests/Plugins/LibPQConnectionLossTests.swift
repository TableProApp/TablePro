//
//  LibPQConnectionLossTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("libpq connection loss")
struct LibPQConnectionLossTests {
    private static let serverMessage = LibPQPluginError(
        message: "FATAL:  terminating connection due to idle-session timeout",
        sqlState: "57P05",
        detail: nil
    )

    private static func error(_ loss: LibPQConnectionLoss) -> LibPQConnectionLostError {
        LibPQConnectionLostError(loss: loss, underlying: serverMessage)
    }

    @Test("Only a known idle session counts as holding no transaction")
    func unknownCountsAsOpen() {
        #expect(!LibPQTransactionState.idle.mayHoldTransaction)
        #expect(LibPQTransactionState.unknown.mayHoldTransaction)
        #expect(LibPQTransactionState.active.mayHoldTransaction)
        #expect(LibPQTransactionState.inTransaction.mayHoldTransaction)
        #expect(LibPQTransactionState.inError.mayHoldTransaction)
    }

    @Test("A statement never sent is reported as not run, behind the server's own message")
    func notSentIsNotRun() {
        let error = Self.error(.beforeSending(transactionMayBeOpen: false))
        #expect(error.pluginErrorMessage.hasPrefix(Self.serverMessage.message))
        #expect(error.pluginErrorMessage.contains("It was not run."))
        #expect(!error.pluginErrorMessage.contains("rolled back"))
    }

    @Test("A statement never sent while a transaction may be open says the transaction was rolled back")
    func notSentInsideTransaction() {
        let error = Self.error(.beforeSending(transactionMayBeOpen: true))
        #expect(error.pluginErrorMessage.contains("It was not run, and any open transaction was rolled back."))
    }

    @Test("A statement lost after it was sent may or may not have run, whatever it was")
    func sentHasUnknownOutcome() {
        let error = Self.error(.afterSending)
        #expect(error.pluginErrorMessage.hasPrefix(Self.serverMessage.message))
        #expect(error.pluginErrorMessage.contains("may or may not have completed"))
        #expect(error.pluginErrorMessage.contains("rolled back unless this statement committed it"))
    }

    @Test("A statement libpq never sent keeps the recorded transaction state; one it sent does not need it")
    func sendStageDecidesThePhase() {
        func loss(sent: Bool, _ state: LibPQTransactionState) -> LibPQConnectionLoss {
            LibPQConnectionLoss(sent: sent, recordedState: state)
        }

        #expect(loss(sent: false, .idle) == .beforeSending(transactionMayBeOpen: false))
        #expect(loss(sent: false, .inTransaction) == .beforeSending(transactionMayBeOpen: true))
        #expect(loss(sent: false, .unknown) == .beforeSending(transactionMayBeOpen: true))
        #expect(loss(sent: true, .idle) == .afterSending)
        #expect(loss(sent: true, .inTransaction) == .afterSending)
    }

    @Test("A server message ends the session on FATAL or PANIC severity")
    func severityDecides() {
        #expect(LibPQServerMessage.endsSession(severity: "FATAL", sqlState: "57P05"))
        #expect(LibPQServerMessage.endsSession(severity: "PANIC", sqlState: "XX000"))
        #expect(!LibPQServerMessage.endsSession(severity: "NOTICE", sqlState: "42P07"))
        #expect(!LibPQServerMessage.endsSession(severity: "WARNING", sqlState: "25P01"))
        #expect(!LibPQServerMessage.endsSession(severity: "ERROR", sqlState: "08003"))
    }

    /// A server before 9.6 sends no non-localized severity, so the class is all there is to go on
    /// when choosing which message to attach. It decides nothing on its own: the caller reads the
    /// sink only once libpq reports `CONNECTION_BAD`, and clears it while the session is healthy.
    @Test("Without a severity field, only connection and operator-intervention classes are kept")
    func classFallbackForOldServers() {
        #expect(LibPQServerMessage.endsSession(severity: nil, sqlState: "57P01"))
        #expect(LibPQServerMessage.endsSession(severity: nil, sqlState: "08006"))
        #expect(!LibPQServerMessage.endsSession(severity: nil, sqlState: "42P07"))
        #expect(!LibPQServerMessage.endsSession(severity: nil, sqlState: "25P01"))
        #expect(!LibPQServerMessage.endsSession(severity: nil, sqlState: nil))
    }

    @Test("The server's message and SQLSTATE stay on the error")
    func keepsServerMessage() {
        let error = Self.error(.beforeSending(transactionMayBeOpen: false))
        #expect(error.pluginSqlState == "57P05")
        #expect(error.pluginErrorDetail == nil)
    }

    @Test("The server's own detail stays the detail")
    func keepsServerDetail() {
        let underlying = LibPQPluginError(
            message: "server closed the connection unexpectedly", sqlState: nil, detail: "hint"
        )
        let error = LibPQConnectionLostError(loss: .afterSending, underlying: underlying)
        #expect(error.pluginSqlState == nil)
        #expect(error.pluginErrorDetail == "hint")
    }
}

/// The app reads a driver error's message to tell an authentication failure from a refusal, and
/// PostgreSQL sends those as a FATAL, which is exactly the shape that now carries an explanation
/// as well. Both classifiers have to keep working through it.
@Suite("libpq connection loss and the app's error classifiers")
@MainActor
struct LibPQConnectionLossClassifierTests {
    @Test("an authentication FATAL lost with the connection is still an authentication failure")
    func authenticationFailureStillFires() {
        let underlying = LibPQPluginError(
            message: "FATAL:  password authentication failed for user \"app\"",
            sqlState: "28P01",
            detail: nil
        )
        let error = LibPQConnectionLostError(
            loss: .beforeSending(transactionMayBeOpen: false), underlying: underlying
        )

        #expect(DatabaseManager.shared.isAuthenticationFailure(error))
    }

    @Test("a read-only refusal lost with the connection is still classified, with the server's words")
    func readOnlyRefusalStillFires() {
        let underlying = LibPQPluginError(
            message: "ERROR:  cannot execute INSERT in a read-only transaction",
            sqlState: "25006",
            detail: nil
        )
        let error = LibPQConnectionLostError(loss: .afterSending, underlying: underlying)

        let diagnosis = DatabaseWriteRejectionDiagnosis.classify(error)
        #expect(diagnosis != nil)
        #expect(diagnosis?.serverMessage.contains("read-only transaction") == true)
    }
}
