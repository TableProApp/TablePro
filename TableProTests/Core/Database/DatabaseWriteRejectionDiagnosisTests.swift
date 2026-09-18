//
//  DatabaseWriteRejectionDiagnosisTests.swift
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

@Suite("DatabaseWriteRejectionDiagnosis")
struct DatabaseWriteRejectionDiagnosisTests {
    @Test("MySQL 1792 in a read-only transaction is recognised by its portable SQLSTATE")
    func recognisesMySQLReadOnlyTransaction() {
        let error = FakeDriverError(
            pluginErrorMessage: "Cannot execute statement in a READ ONLY transaction.",
            pluginErrorCode: 1_792,
            pluginSqlState: "25006"
        )

        #expect(DatabaseWriteRejectionDiagnosis.classify(error) != nil)
    }

    @Test("PostgreSQL uses the same SQLSTATE and is recognised without a native code")
    func recognisesPostgresReadOnlyTransaction() {
        let error = FakeDriverError(
            pluginErrorMessage: "cannot execute UPDATE in a read-only transaction",
            pluginErrorCode: nil,
            pluginSqlState: "25006"
        )

        #expect(DatabaseWriteRejectionDiagnosis.classify(error) != nil)
    }

    @Test("Server-level read-only codes report HY000 and are matched on the native code")
    func recognisesServerLevelReadOnlyCodes() {
        for code in [1_290, 1_836, 1_874] {
            let error = FakeDriverError(
                pluginErrorMessage: "The MySQL server is running with the --read-only option",
                pluginErrorCode: code,
                pluginSqlState: "HY000"
            )

            #expect(DatabaseWriteRejectionDiagnosis.classify(error) != nil)
        }
    }

    @Test("An unrelated driver error is not diagnosed as read-only")
    func ignoresUnrelatedDriverError() {
        let error = FakeDriverError(
            pluginErrorMessage: "You have an error in your SQL syntax",
            pluginErrorCode: 1_064,
            pluginSqlState: "42000"
        )

        #expect(DatabaseWriteRejectionDiagnosis.classify(error) == nil)
    }

    @Test("An error that is not a driver error is not diagnosed")
    func ignoresNonDriverError() {
        #expect(DatabaseWriteRejectionDiagnosis.classify(PlainError()) == nil)
    }

    @Test("The recovery suggestion blames the server and clears TablePro's Safe Mode")
    func recoverySuggestionNamesTheServer() throws {
        let error = FakeDriverError(
            pluginErrorMessage: "Cannot execute statement in a READ ONLY transaction.",
            pluginErrorCode: 1_792,
            pluginSqlState: "25006"
        )

        let diagnosis = try #require(DatabaseWriteRejectionDiagnosis.classify(error))
        let suggestion = try #require(diagnosis.recoverySuggestion)

        #expect(suggestion.contains("Safe Mode"))
        #expect(suggestion.contains("Cannot execute statement in a READ ONLY transaction."))
        #expect(diagnosis.errorDescription?.isEmpty == false)
    }

    @Test("Formatting a read-only rejection replaces the raw driver string")
    func formattedReplacesRawDriverString() {
        let error = FakeDriverError(
            pluginErrorMessage: "Cannot execute statement in a READ ONLY transaction.",
            pluginErrorCode: 1_792,
            pluginSqlState: "25006"
        )

        let formatted = DatabaseWriteRejectionDiagnosis.formatted(error)

        #expect(formatted.contains("Safe Mode"))
        #expect(!formatted.hasPrefix("[1792]"))
    }

    @Test("Formatting any other error falls back to its own description")
    func formattedFallsBackForOtherErrors() {
        #expect(DatabaseWriteRejectionDiagnosis.formatted(PlainError()) == "Something else went wrong")
    }
}
