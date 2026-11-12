//
//  DatabaseAccessBridgeAnswerBudgetTests.swift
//  TableProTests
//
//  MCP and the assistant read rows through DatabaseAccessBridge, which held them to a row count and never to a size.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct DatabaseAccessBridgeAnswerBudgetTests {
    private func approved(
        _ sql: String,
        scope: DatabaseScope,
        databaseType: DatabaseType,
        maxRows: Int = 500
    ) async throws -> ApprovedOperation {
        let statement = try await DatabaseAccessBridge().plannedStatement(scope: scope, query: sql, maxRows: maxRows)
        return try await ApprovedOperationFixture.approve([statement], scope: scope, databaseType: databaseType)
    }

    @Test("A read of 10,000 rows of 2 KB answers at most 4 MiB, marked truncated")
    func largeReadIsHeldToTheBudget() async throws {
        let driver = AnsweringPluginDriver { _ in
            AnsweringPluginDriver.textRows(column: "body", count: 10_000, bytes: 2_048)
        }
        let scope = AnsweringPluginDriver.install(driver, connection: TestFixtures.makeConnection(database: "shop", type: .postgresql))
        defer { DatabaseManager.shared.removeSession(for: scope.connectionId) }
        let operation = try await approved("SELECT body FROM documents", scope: scope, databaseType: .postgresql, maxRows: 10_000)

        let outcome = try await DatabaseAccessBridge().runStatement(
            operation, maxRows: 10_000, timeoutSeconds: 30, cancellation: nil, budget: .mcpAnswer
        )

        let budget = try #require(outcome.budget)
        #expect(!outcome.result.rows.isEmpty)
        #expect(outcome.result.rows.count * 2_048 <= ExternalAnswerBudget.answerBytes)
        #expect(outcome.result.rows.count < 10_000)
        #expect(outcome.result.isTruncated)
        #expect(budget.sizeLimited)
        #expect(budget.spentBytes <= ExternalAnswerBudget.answerBytes)
    }

    @Test("Without a budget, as AppleScript and Shortcuts run, every row comes back")
    func noBudgetKeepsEveryRow() async throws {
        let driver = AnsweringPluginDriver { _ in
            AnsweringPluginDriver.textRows(column: "body", count: 3_000, bytes: 2_048)
        }
        let scope = AnsweringPluginDriver.install(driver, connection: TestFixtures.makeConnection(database: "shop", type: .postgresql))
        defer { DatabaseManager.shared.removeSession(for: scope.connectionId) }
        let operation = try await approved("SELECT body FROM documents", scope: scope, databaseType: .postgresql, maxRows: 3_000)

        let outcome = try await DatabaseAccessBridge().runStatement(
            operation, maxRows: 3_000, timeoutSeconds: 30, cancellation: nil
        )

        #expect(outcome.result.rows.count == 3_000)
        #expect(outcome.budget == nil)
        #expect(driver.sent.last?.context.resultByteLimit == nil)
    }

    @Test("A read reaches the driver with the answer's byte limit, and a write reaches it with none")
    func onlyReadsCarryTheByteLimit() async throws {
        let driver = AnsweringPluginDriver()
        let scope = AnsweringPluginDriver.install(driver, connection: TestFixtures.makeConnection(database: "shop", type: .postgresql))
        defer { DatabaseManager.shared.removeSession(for: scope.connectionId) }
        let bridge = DatabaseAccessBridge()

        _ = try await bridge.runStatement(
            try await approved("SELECT 1", scope: scope, databaseType: .postgresql),
            maxRows: 500, timeoutSeconds: 30, cancellation: nil, budget: .assistantAnswer
        )
        _ = try await bridge.runStatement(
            try await approved("UPDATE orders SET paid = true WHERE id = 1", scope: scope, databaseType: .postgresql),
            maxRows: 500, timeoutSeconds: 30, cancellation: nil, budget: .assistantAnswer
        )

        #expect(driver.sent.map { $0.context.resultByteLimit } == [ExternalAnswerBudget.assistantAnswerBytes, nil])
        #expect(driver.sent.map { $0.context.readOnly } == [true, false])
    }

    @Test("A read the driver stopped at its byte limit says the size limit left rows out")
    func driverStopIsReported() async throws {
        let driver = AnsweringPluginDriver { _ in
            AnsweringPluginDriver.textRows(column: "body", count: 10, bytes: 10, isTruncated: true)
        }
        let scope = AnsweringPluginDriver.install(driver, connection: TestFixtures.makeConnection(database: "shop", type: .postgresql))
        defer { DatabaseManager.shared.removeSession(for: scope.connectionId) }

        let outcome = try await DatabaseAccessBridge().runStatement(
            try await approved("SELECT body FROM documents", scope: scope, databaseType: .postgresql),
            maxRows: 500, timeoutSeconds: 30, cancellation: nil, budget: .mcpAnswer
        )

        #expect(outcome.result.rows.count == 10)
        #expect(outcome.result.isTruncated)
        #expect(outcome.budget?.sizeLimited == true)
        #expect(outcome.budget?.notes.count == 1)
    }

    // If the cut ran first, the last four characters shown would be the end of the cut mark.
    @Test("A partial mask reads the whole value before any cut")
    func maskRunsBeforeTheCut() async throws {
        var connection = TestFixtures.makeConnection(database: "shop", type: .mysql)
        connection.maskingRules = [MaskingRule(pattern: "*.card", style: .lastFour)]
        let long = String(repeating: "1", count: 200_000) + "WXYZ"
        let driver = ScriptAnsweringDriver(connection: connection, statementAnswer: { _ in
            var result = ScriptAnsweringDriver.resultSet(columns: ["card"], rows: [[long]])
            result.columnOrigins = [PluginColumnOrigin(schema: "shop", table: "payments", column: "card")]
            return result
        })
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)

        let outcome = try await DatabaseAccessBridge().runStatement(
            try await approved("SELECT card FROM payments", scope: scope, databaseType: .mysql),
            maxRows: 500, timeoutSeconds: 30, cancellation: nil, budget: .mcpAnswer
        )

        let cell = try #require(outcome.result.rows.first?.first?.asText)
        #expect(cell.hasSuffix("WXYZ"))
        #expect(!cell.contains("TablePro cut"))
        #expect(outcome.budget?.valuesCut == false)
    }
}

@Suite("SQL Server scripts held to one answer budget", .serialized)
@MainActor
struct DatabaseAccessBridgeScriptBudgetTests {
    private func run(
        _ text: String,
        on driver: ScriptAnsweringDriver,
        budget: ExternalAnswerBudget?
    ) async throws -> DatabaseAccessBridge.ScriptOutcome {
        var session = ConnectionSession(connection: driver.connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: driver.connection.id)
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let scope = DatabaseScope(connectionId: driver.connection.id, database: driver.connection.database, schema: nil)
        let bridge = DatabaseAccessBridge()
        let planned = try await bridge.plannedScript(scope: scope, query: text, maxRows: 500)
        let operation = try await ApprovedOperationFixture.approve(
            [planned.statement], scope: scope, databaseType: .mssql, unit: planned.unit
        )
        return try await bridge.runScript(operation, maxRows: 500, timeoutSeconds: 30, cancellation: nil, budget: budget)
    }

    nonisolated private static func rows(_ column: String, count: Int, bytes: Int) -> QueryResult {
        ScriptAnsweringDriver.resultSet(
            columns: [column],
            rows: Array(repeating: [String(repeating: "x", count: bytes)], count: count)
        )
    }

    private func makeDriver(answer: @escaping @Sendable (String) -> QueryBatchResult) -> ScriptAnsweringDriver {
        ScriptAnsweringDriver(
            connection: TestFixtures.makeConnection(database: "warehouse", type: .mssql),
            answer: answer
        )
    }

    nonisolated private static let threeBatches = "SELECT 1 AS a\nGO\nSELECT 2 AS b\nGO\nSELECT 3 AS c"

    nonisolated private static func firstBatchFillsTheBudget(_ batch: String) -> QueryBatchResult {
        batch.contains("AS a")
            ? ScriptAnsweringDriver.batch([rows("a", count: 50, bytes: 1_000)])
            : ScriptAnsweringDriver.batch([rows("b", count: 5, bytes: 10)])
    }

    @Test("Once the budget is spent, later batches still run, reading one row and keeping none")
    func laterBatchesRunWithoutRows() async throws {
        let driver = makeDriver(answer: Self.firstBatchFillsTheBudget)

        let outcome = try await run(Self.threeBatches, on: driver, budget: ExternalAnswerBudget(bytes: 10_000))

        #expect(driver.sentBatches.map { $0.rowCap } == [500, 1, 1])
        #expect(outcome.resultSets.count == 3)
        let first = try #require(outcome.resultSets.first)
        #expect(!first.rows.isEmpty && first.rows.count < 50)
        #expect(first.isTruncated)
        #expect(outcome.resultSets.dropFirst().allSatisfy { $0.rows.isEmpty && $0.isTruncated })
        #expect(outcome.primary.rows.count == first.rows.count)
        #expect(outcome.primary.isTruncated)
        #expect(outcome.budget?.sizeLimited == true)
    }

    @Test("Without a budget, as AppleScript and Shortcuts run, every batch keeps its rows")
    func noBudgetKeepsEveryBatch() async throws {
        let driver = makeDriver(answer: Self.firstBatchFillsTheBudget)

        let outcome = try await run(Self.threeBatches, on: driver, budget: nil)

        #expect(driver.sentBatches.map { $0.rowCap } == [500, 500, 500])
        #expect(outcome.resultSets.map { $0.rows.count } == [50, 5, 5])
        #expect(outcome.budget == nil)
    }

    @Test("Each batch's answer is cut to the budget before the next batch runs, so rows past it are not held")
    func answersAreHeldToTheBudgetBatchByBatch() async throws {
        let driver = makeDriver(answer: Self.firstBatchFillsTheBudget)
        let batches = QueryBatchPlanner.batches(
            in: Self.threeBatches,
            model: QueryStatementModel.forDatabaseType(.mssql),
            grammar: DatabaseType.mssql.lexicalGrammar
        )

        let answered = try await ScriptBatchRun.run(
            batches, startLines: [1, 3, 5], rowCap: 500, driver: driver, progress: ScriptBatchProgress(),
            budget: ExternalAnswerBudget(bytes: 10_000)
        )

        let heldRows = answered.answers.map { answer in answer.resultSets.map { set in set.rows.count } }
        #expect(heldRows == [[9], [0], [0]])
        #expect(driver.sentBatches.map { $0.rowCap } == [500, 1, 1])
        #expect(answered.budget?.sizeLimited == true)
        #expect((answered.budget?.spentBytes ?? .max) <= 10_000)
    }

    // If a value were cut before the mask, the last four characters shown would be the end of the cut mark.
    @Test("A script's partial mask reads the whole value before any cut")
    func scriptMaskRunsBeforeTheCut() async throws {
        var connection = TestFixtures.makeConnection(database: "warehouse", type: .mssql)
        connection.maskingRules = [MaskingRule(pattern: "*.card", style: .lastFour)]
        let long = String(repeating: "1", count: 200_000) + "WXYZ"
        let driver = ScriptAnsweringDriver(connection: connection, answer: { _ in
            var set = ScriptAnsweringDriver.resultSet(columns: ["card"], rows: [[long]])
            set.columnOrigins = [PluginColumnOrigin(schema: "dbo", table: "payments", column: "card")]
            return ScriptAnsweringDriver.batch([set])
        })

        let outcome = try await run("SELECT card FROM payments\nGO\nSELECT 2 AS b", on: driver, budget: .mcpAnswer)

        let cell = try #require(outcome.resultSets.first?.rows.first?.first?.asText)
        #expect(cell.hasSuffix("WXYZ"))
        #expect(!cell.contains("TablePro cut"))
    }

    @Test("With more than one result set the first costs twice, since the answer writes it twice")
    func firstSetCostsTwice() async throws {
        let twoSets = makeDriver { _ in
            ScriptAnsweringDriver.batch([Self.rows("a", count: 6, bytes: 1_000), Self.rows("b", count: 1, bytes: 1)])
        }
        let oneSet = makeDriver { _ in ScriptAnsweringDriver.batch([Self.rows("a", count: 6, bytes: 1_000)]) }

        let both = try await run("EXEC report", on: twoSets, budget: ExternalAnswerBudget(bytes: 10_000))
        let single = try await run("EXEC report", on: oneSet, budget: ExternalAnswerBudget(bytes: 10_000))

        #expect(both.resultSets.first?.rows.count == 4)
        #expect(single.resultSets.first?.rows.count == 6)
    }
}
