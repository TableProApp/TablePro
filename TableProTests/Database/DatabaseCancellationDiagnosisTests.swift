//
//  DatabaseCancellationDiagnosisTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct FakeDriverError: PluginDriverError {
    let pluginErrorMessage: String
    let pluginErrorCode: Int?
    let pluginSqlState: String?
}

private struct PlainError: Error, LocalizedError {
    var errorDescription: String? { "Something else went wrong" }
}

@Suite("DatabaseCancellationDiagnosis")
struct DatabaseCancellationDiagnosisTests {
    @Test("A Swift cancellation is recognised")
    func recognisesSwiftCancellationError() {
        #expect(DatabaseCancellationDiagnosis.isCancellation(CancellationError()))
    }

    @Test("A Cocoa user cancellation is recognised, matching presentError:")
    func recognisesCocoaUserCancelled() {
        #expect(DatabaseCancellationDiagnosis.isCancellation(CocoaError(.userCancelled)))
        #expect(DatabaseCancellationDiagnosis.isCancellation(
            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        ))
    }

    @Test("A query timeout is not a cancellation, even though PostgreSQL reports 57014 for both")
    func doesNotSwallowAQueryTimeout() {
        let timeout = FakeDriverError(
            pluginErrorMessage: "canceling statement due to statement timeout",
            pluginErrorCode: nil,
            pluginSqlState: "57014"
        )

        #expect(DatabaseCancellationDiagnosis.isCancellation(timeout) == false)
    }

    @Test("An interrupted MySQL query is not swallowed on its error code alone")
    func doesNotSwallowMySQLInterrupted() {
        let interrupted = FakeDriverError(
            pluginErrorMessage: "Query execution was interrupted",
            pluginErrorCode: 1_317,
            pluginSqlState: "70100"
        )

        #expect(DatabaseCancellationDiagnosis.isCancellation(interrupted) == false)
    }

    @Test("An unrelated error is not a cancellation")
    func ignoresAPlainError() {
        #expect(DatabaseCancellationDiagnosis.isCancellation(PlainError()) == false)
    }
}
