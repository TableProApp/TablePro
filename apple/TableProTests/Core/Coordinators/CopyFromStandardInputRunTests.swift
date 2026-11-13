//
//  CopyFromStandardInputRunTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

@MainActor
struct CopyFromStandardInputRunTests {
    private static let script = "CREATE TABLE t (a int, b text);\n"
        + "COPY t (a, b) FROM stdin;\n1\tone\n2\té\n\\.\n"
        + "ANALYZE t;"

    private let connection = TestFixtures.makeConnection(type: .postgresql)

    private func run(_ script: String, on driver: CopyInRecordingDriver) async throws -> QueryTab {
        let fixture = CoordinatorFixture(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = connection.database
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tab = fixture.addTab(QueryTab(title: "Query", query: script, tabType: .query))
        let statements = SQLStatementScanner.executableStatements(
            in: script, grammar: fixture.coordinator.lexicalGrammar
        )
        fixture.coordinator.queryExecutionCoordinator.executeMultipleStatements(statements)
        let handle = try #require(fixture.coordinator.queryTasks.task(for: tab.id))
        await handle.value
        return try #require(fixture.tabManager.tabs.first { $0.id == tab.id })
    }

    @Test("A run sends a COPY's rows through copy-in with its header, byte for byte, and never the \\. line")
    func copyGoesThroughCopyIn() async throws {
        let driver = CopyInRecordingDriver(connection: connection, copiesIn: true)

        let tab = try await run(Self.script, on: driver)

        #expect(driver.sentCopies == [
            CopyInRecordingDriver.Copy(statement: "COPY t (a, b) FROM stdin", data: Data("1\tone\n2\té\n".utf8)),
        ])
        #expect(driver.sentStatements == ["CREATE TABLE t (a int, b text)", "ANALYZE t"])
        #expect(!tab.display.resultSets.isEmpty)
        #expect(tab.display.resultSets.allSatisfy { $0.errorMessage == nil })
    }

    @Test("A driver without copy-in refuses the COPY before anything is sent for it, and the run fails there")
    func driverWithoutCopyInRefuses() async throws {
        let driver = CopyInRecordingDriver(connection: connection, copiesIn: false)

        let tab = try await run(Self.script, on: driver)

        #expect(driver.sentCopies.isEmpty)
        #expect(driver.sentStatements == ["CREATE TABLE t (a int, b text)"])
        let failed = try #require(tab.display.resultSets.last)
        #expect(failed.failedQuery == "COPY t (a, b) FROM stdin")
        let refusal = try #require(PluginDriverUnsupportedOperation.copyFromStandardInput.errorDescription)
        #expect(failed.errorMessage?.contains(refusal) == true)
    }

    @Test("A COPY with no rows still goes through copy-in, as a copy of none")
    func copyWithoutRows() async throws {
        let driver = CopyInRecordingDriver(connection: connection, copiesIn: true)

        _ = try await run("COPY t FROM stdin;", on: driver)

        #expect(driver.sentCopies == [CopyInRecordingDriver.Copy(statement: "COPY t FROM stdin", data: Data())])
        #expect(driver.sentStatements.isEmpty)
    }

    @Test("A COPY that ends a run cut again after a SET keeps its rows")
    func replannedCopyKeepsItsRows() async throws {
        let standard = PluginSessionLexicalState(determined: [.backslashEscapesInSingleQuotes], enabled: [])
        let escapes = PluginSessionLexicalState(
            determined: [.backslashEscapesInSingleQuotes], enabled: [.backslashEscapesInSingleQuotes]
        )
        #expect(SQLLexicalResolver.readings(for: .postgresql, session: standard).execution
            != SQLLexicalResolver.readings(for: .postgresql, session: escapes).execution)
        let driver = CopyInRecordingDriver(
            connection: connection, copiesIn: true, lexicalState: standard, lexicalStateAfterFirstStatement: escapes
        )

        _ = try await run("SET standard_conforming_strings = off;\nCOPY t FROM stdin;\n1\tC:\\\\dir\n\\.", on: driver)

        #expect(driver.sentStatements == ["SET standard_conforming_strings = off"])
        #expect(driver.sentCopies == [
            CopyInRecordingDriver.Copy(statement: "COPY t FROM stdin", data: Data("1\tC:\\\\dir\n".utf8)),
        ])
    }
}
