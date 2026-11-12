//
//  MultiStatementReplanTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

@MainActor
struct MultiStatementReplanTests {
    private static let script = "SET sql_mode = 'NO_BACKSLASH_ESCAPES';\n"
        + "INSERT INTO t VALUES ('C:\\');\n"
        + "INSERT INTO t VALUES ('two');"

    private static let noEscapes = SQLLexicalResolver.readings(for: .mysql, session: PluginSessionLexicalState(
        determined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes], enabled: []
    )).execution

    @Test("The rest of a run is cut again the way the session reads it once a statement changed that")
    func restIsCutWithTheSessionsGrammar() throws {
        let planned = SQLStatementScanner.executableStatements(in: Self.script, grammar: TestGrammar.mysql)
        let plannedCount = planned.count
        #expect(plannedCount == 2)
        let first = try #require(planned.first)
        let last = try #require(planned.last)

        let rest = QueryExecutionCoordinator.remainingStatements(
            in: Self.script, after: first, through: NSMaxRange(last.range), grammar: Self.noEscapes
        )
        let restSQL = rest.map { $0.sql }
        let restText = rest.map { (Self.script as NSString).substring(with: $0.range) }

        #expect(restSQL == ["INSERT INTO t VALUES ('C:\\')", "INSERT INTO t VALUES ('two')"])
        #expect(restText == restSQL)
        #expect(QueryExecutionCoordinator.scriptHolds(planned, in: Self.script))
        #expect(!QueryExecutionCoordinator.scriptHolds(planned, in: "SELECT 1"))
    }

    @Test("A replan starts past a COPY's rows and keeps the DELIMITER in force")
    func replanStartsPastTheSegment() throws {
        let postgres = "COPY t FROM stdin;\nDROP TABLE users; COMMIT;\n\\.\nSELECT 1;"
        let copy = try #require(SQLStatementScanner.executableStatements(in: postgres, grammar: TestGrammar.postgres).first)
        let afterCopy = QueryExecutionCoordinator.remainingStatements(
            in: postgres, after: copy, through: (postgres as NSString).length, grammar: TestGrammar.postgres
        )
        #expect(afterCopy.map { $0.sql } == ["SELECT 1"])

        let mysql = "DELIMITER //\nSET sql_mode = 'NO_BACKSLASH_ESCAPES'//\nSELECT 'a\\'//"
        let set = try #require(SQLStatementScanner.executableStatements(in: mysql, grammar: TestGrammar.mysql).first)
        let afterSet = QueryExecutionCoordinator.remainingStatements(
            in: mysql, after: set, through: (mysql as NSString).length, grammar: Self.noEscapes
        )
        #expect(afterSet.map { $0.sql } == ["SELECT 'a\\'"])
    }

    @Test("A run sends the replanned rest in place of what it planned")
    func runSendsTheReplannedRest() async {
        let driver = ScriptAnsweringDriver(connection: TestFixtures.makeConnection(type: .mysql), sendsBatchesWhole: false)
        let replannedRest = ["INSERT INTO t VALUES ('C:\\')", "INSERT INTO t VALUES ('two')"]

        let outcome = await BatchStatementRun.run(
            ["SET sql_mode = 'NO_BACKSLASH_ESCAPES'", "INSERT INTO t VALUES ('C:\\');\nINSERT INTO t VALUES ('two')"],
            plan: .autocommit,
            mode: .readWrite,
            driver: driver,
            connectionId: UUID(),
            gate: BatchClaimGate(isCurrent: { true }, enterCommitPhase: { true }, leaveCommitPhase: {}),
            failureSQL: { $0 },
            isCommitPoint: { _ in false },
            replanned: { ran in ran == 1 ? replannedRest : nil }
        ) { statement in
            try await driver.execute(query: statement)
        }

        guard case .completed(let results) = outcome else {
            Issue.record("expected a completed run, got \(outcome)")
            return
        }
        #expect(results.count == 3)
        #expect(driver.sentStatements == ["SET sql_mode = 'NO_BACKSLASH_ESCAPES'"] + replannedRest)
    }
}
