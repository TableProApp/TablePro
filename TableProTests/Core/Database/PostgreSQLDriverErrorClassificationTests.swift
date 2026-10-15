//
//  PostgreSQLDriverErrorClassificationTests.swift
//  TableProTests
//
//  The app reads a driver error's message and SQLSTATE to tell an authentication failure from a
//  read-only refusal. These are the errors the PostgreSQL plugin raises, spelled the way
//  PostgreSQLDriverTests pins them: a FATAL behind a lost connection, a decoded server error, and a
//  PGlite login refusal passed through unchanged.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct PostgreSQLDriverError: PluginDriverError {
    let pluginErrorMessage: String
    let pluginSqlState: String?
}

@MainActor
struct PostgreSQLDriverErrorClassificationTests {
    @Test("an authentication FATAL lost with the connection is still an authentication failure")
    func authenticationFailureStillFires() {
        let error = PostgreSQLDriverError(
            pluginErrorMessage: """
                FATAL:  password authentication failed for user "app" The connection to the server was closed \
                before the statement was sent. It was not run.
                """,
            pluginSqlState: "28P01"
        )

        #expect(DatabaseManager.shared.isAuthenticationFailure(error))
    }

    @Test("a read-only refusal lost with the connection is still classified, with the server's words")
    func readOnlyRefusalStillFires() {
        let error = PostgreSQLDriverError(
            pluginErrorMessage: """
                ERROR:  cannot execute INSERT in a read-only transaction Lost the connection to the server while \
                the statement was running. It may or may not have completed. If a transaction was open, it was \
                rolled back unless this statement committed it.
                """,
            pluginSqlState: "25006"
        )

        let diagnosis = DatabaseWriteRejectionDiagnosis.classify(error)
        #expect(diagnosis != nil)
        #expect(diagnosis?.serverMessage.contains("read-only transaction") == true)
    }

    @Test("A decoded read-only transaction error is diagnosed as server-enforced read-only")
    func readOnlyTransactionIsDiagnosed() {
        let error = PostgreSQLDriverError(
            pluginErrorMessage: "ERROR: cannot execute INSERT in a read-only transaction",
            pluginSqlState: "25006"
        )
        #expect(DatabaseWriteRejectionDiagnosis.classify(error) != nil)
    }

    @Test("A refused login through PGlite still reads as an authentication failure")
    func refusedLoginStillPromptsForCredentials() {
        let error = PostgreSQLDriverError(
            pluginErrorMessage: """
                connection to server at "127.0.0.1", port 5432 failed: FATAL:  password authentication failed \
                for user "app"
                """,
            pluginSqlState: nil
        )
        #expect(DatabaseManager.shared.isAuthenticationFailure(error))
    }
}
