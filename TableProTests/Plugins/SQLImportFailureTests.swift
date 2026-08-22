//
//  SQLImportFailureTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

private struct StubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@Suite("SQL import failure composition")
struct SQLImportFailureTests {
    private func statementFailure() -> PluginImportError {
        PluginImportError.statementFailed(
            statement: "INSERT INTO users VALUES (1)",
            line: 412,
            underlyingError: StubError(message: "Duplicate entry '1' for key 'PRIMARY'")
        )
    }

    @Test("A clean failure is passed through unchanged")
    func cleanFailureIsPassedThrough() throws {
        let result = SQLImportFailure.error(cause: statementFailure(), rollbackError: nil)
        let pluginError = try #require(result as? PluginImportError)
        guard case .statementFailed(let statement, let line, let underlying) = pluginError else {
            Issue.record("Expected statementFailed, got \(pluginError)")
            return
        }
        #expect(line == 412)
        #expect(statement == "INSERT INTO users VALUES (1)")
        #expect(underlying.localizedDescription.contains("Duplicate entry"))
    }

    /// The cause is the only carrier of the line number and the failing statement, so a rollback
    /// that also fails must not be thrown in its place.
    @Test("A failed rollback keeps the line number, the statement and the reason")
    func failedRollbackKeepsTheCause() throws {
        let result = SQLImportFailure.error(
            cause: statementFailure(),
            rollbackError: StubError(message: "no transaction is active")
        )
        let pluginError = try #require(result as? PluginImportError)
        guard case .statementFailed(let statement, let line, let underlying) = pluginError else {
            Issue.record("Expected statementFailed, got \(pluginError)")
            return
        }
        #expect(line == 412)
        #expect(statement == "INSERT INTO users VALUES (1)")
        #expect(underlying.localizedDescription.contains("Duplicate entry"))
        #expect(underlying.localizedDescription.contains("no transaction is active"))
    }

    @Test("A failed rollback on an unstructured cause keeps both messages")
    func failedRollbackOnUnstructuredCause() throws {
        let result = SQLImportFailure.error(
            cause: StubError(message: "connection lost"),
            rollbackError: StubError(message: "no transaction is active")
        )
        let description = result.localizedDescription
        #expect(description.contains("connection lost"))
        #expect(description.contains("no transaction is active"))
    }

    /// A user who stopped the import is not looking at an error, and a rollback that failed on the
    /// way out must not turn their cancellation into one.
    @Test("A cancellation survives a failed rollback")
    func cancellationSurvivesAFailedRollback() {
        let result = SQLImportFailure.error(
            cause: PluginImportCancellationError(),
            rollbackError: StubError(message: "no transaction is active")
        )
        #expect(result is PluginImportCancellationError)
    }

    @Test("A plain error becomes an import failure carrying its message")
    func plainErrorBecomesImportFailure() throws {
        let result = SQLImportFailure.error(cause: StubError(message: "disk full"), rollbackError: nil)
        let pluginError = try #require(result as? PluginImportError)
        guard case .importFailed(let message) = pluginError else {
            Issue.record("Expected importFailed, got \(pluginError)")
            return
        }
        #expect(message == "disk full")
    }
}
