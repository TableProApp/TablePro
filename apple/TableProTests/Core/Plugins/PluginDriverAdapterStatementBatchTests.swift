//
//  PluginDriverAdapterStatementBatchTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class ReportingDriver: PluginDriverStub, @unchecked Sendable {
    struct Refused: Error {}

    var answersFewer = false
    var declines = false
    var failing: Set<String> = []
    private(set) var batches: [[PluginBatchStatement]] = []
    private(set) var alone: [String] = []

    var capabilities: PluginCapabilities { [.statementBatches] }

    func execute(query: String) async throws -> PluginQueryResult {
        alone.append(query)
        if failing.contains(query) { throw Refused() }
        return .empty
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await execute(query: query)
    }

    func executeStatements(_ statements: [PluginBatchStatement]) async throws -> [PluginBatchStatementOutcome]? {
        guard !declines else { return nil }
        batches.append(statements)
        let answered = answersFewer ? statements.dropLast() : statements[...]
        return answered.map { _ in .succeeded(rowsAffected: 1, executionTime: 0) }
    }
}

struct PluginDriverAdapterStatementBatchTests {
    private func adapter(_ driver: ReportingDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: driver)
    }

    @Test("A statement the host would refuse ends the batch there, and only the ones before it are sent")
    func refusedStatementEndsTheBatch() async {
        let driver = ReportingDriver()
        let statements = [
            BatchedStatement(sql: "INSERT INTO t VALUES (1)"),
            BatchedStatement(sql: "INSERT INTO t VALUES ('a\u{0}b')"),
            BatchedStatement(sql: "INSERT INTO t VALUES (3)"),
        ]

        let outcomes = await adapter(driver).runStatements(statements)

        #expect(driver.batches.map { $0.map(\.query) } == [["INSERT INTO t VALUES (1)"]])
        #expect(outcomes.count == 2)
        #expect(outcomes.first?.succeeded == true)
        guard case .failed(let error) = outcomes.last else {
            Issue.record("The refused statement should fail")
            return
        }
        #expect((error as? DatabaseError)?.errorDescription == DatabaseError.statementContainsNulCharacter.errorDescription)
    }

    @Test("A driver that answers fewer statements than it was sent fails the first one it left out")
    func missingAnswerFails() async {
        let driver = ReportingDriver()
        driver.answersFewer = true

        let outcomes = await adapter(driver).runStatements([
            BatchedStatement(sql: "DELETE FROM t WHERE id = 1"),
            BatchedStatement(sql: "DELETE FROM t WHERE id = 2"),
        ])

        #expect(outcomes.count == 2)
        #expect(outcomes[0].succeeded)
        #expect(!outcomes[1].succeeded)
    }

    @Test("Parameters reach the driver bound, and a text without them goes as text")
    func carriesParameters() async {
        let driver = ReportingDriver()

        _ = await adapter(driver).runStatements([
            BatchedStatement(sql: "UPDATE t SET a = $1", parameters: ["x"]),
            BatchedStatement(sql: "DELETE FROM t"),
        ])

        let sent = driver.batches.first ?? []
        #expect(sent.first?.parameters == [.text("x")])
        #expect(sent.last?.parameters == nil)
    }

    @Test("A declined batch runs each statement alone and stops at the first failure")
    func declinedBatchStopsAtFailure() async {
        let driver = ReportingDriver()
        driver.declines = true
        driver.failing = ["INSERT INTO t VALUES (2)"]

        let outcomes = await adapter(driver).runStatements((1...3).map { BatchedStatement(sql: "INSERT INTO t VALUES (\($0))") })

        #expect(driver.alone == ["INSERT INTO t VALUES (1)", "INSERT INTO t VALUES (2)"])
        #expect(outcomes.count == 2)
        #expect(!outcomes[1].succeeded)
    }
}
