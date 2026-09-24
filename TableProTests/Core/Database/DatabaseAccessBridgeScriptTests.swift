//
//  DatabaseAccessBridgeScriptTests.swift
//  TableProTests
//
//  MCP, the assistant and AppleScript send SQL Server text through the same bridge. Before it learned batches the
//  bridge sent a script through the one-result call, so everything after the first result set was dropped (#3078).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL Server scripts sent from outside the app", .serialized)
@MainActor
struct DatabaseAccessBridgeScriptTests {
    private static let reporterScript = """
        DECLARE @sn NVARCHAR(50) = '2404GQV000066A00105';

        SELECT *
        FROM serialnew
        WHERE [S/N] = @sn;

        SELECT *
        FROM [v_wms_joined]
        WHERE [S/N] = @sn;

        SELECT *
        FROM drm_report_n
        WHERE [Serial number] = @sn;

        SELECT *
        FROM serial_existed
        WHERE sn_code = @sn;
        """

    nonisolated private static func fourResultSets(_ query: String) -> QueryBatchResult {
        ScriptAnsweringDriver.batch([
            ScriptAnsweringDriver.resultSet(columns: ["S/N", "model"], rows: [["2404GQV000066A00105", "X1"]]),
            ScriptAnsweringDriver.resultSet(columns: ["S/N", "warehouse"], rows: [["2404GQV000066A00105", "W2"]]),
            ScriptAnsweringDriver.resultSet(columns: ["Serial number"], rows: []),
            ScriptAnsweringDriver.resultSet(columns: ["sn_code", "seen_at"], rows: [["a", "b"], ["c", "d"]])
        ])
    }

    private func install(_ driver: ScriptAnsweringDriver) -> DatabaseScope {
        var session = ConnectionSession(connection: driver.connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: driver.connection.id)
        return DatabaseScope(connectionId: driver.connection.id, database: driver.connection.database, schema: nil)
    }

    private func makeDriver(
        sendsBatchesWhole: Bool = true,
        transactionState: PluginSessionTransactionState = .idle,
        answer: @escaping @Sendable (String) -> QueryBatchResult = { _ in .empty }
    ) -> ScriptAnsweringDriver {
        ScriptAnsweringDriver(
            connection: TestFixtures.makeConnection(database: "warehouse", type: .mssql),
            sendsBatchesWhole: sendsBatchesWhole,
            transactionState: transactionState,
            answer: answer
        )
    }

    private func run(
        _ text: String,
        on driver: ScriptAnsweringDriver,
        maxRows: Int = 500
    ) async throws -> DatabaseAccessBridge.ScriptOutcome {
        let scope = install(driver)
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        return try await DatabaseAccessBridge().runScript(
            scope: scope,
            query: text,
            maxRows: maxRows,
            timeoutSeconds: 30,
            cancellation: nil
        )
    }

    @Test("The #3078 script reaches the server as one batch and every result set comes back")
    func reporterScriptReturnsEveryResultSet() async throws {
        let driver = makeDriver(answer: Self.fourResultSets)

        let outcome = try await run(Self.reporterScript, on: driver, maxRows: 7)

        let sent = try #require(driver.sentBatches.first)
        #expect(driver.sentBatches.count == 1)
        #expect(sent.sql.hasPrefix("DECLARE @sn"))
        #expect(sent.sql.hasSuffix("WHERE sn_code = @sn"))
        #expect(sent.rowCap == 7)
        #expect(driver.sentStatements.isEmpty)
        #expect(outcome.resultSets.map(\.columns) == [
            ["S/N", "model"], ["S/N", "warehouse"], ["Serial number"], ["sn_code", "seen_at"]
        ])
        #expect(outcome.primary.columns == ["S/N", "model"])
        #expect(outcome.rowsReturned == 4)
    }

    @Test("A procedure call returns every result set it produced")
    func procedureCallReturnsEveryResultSet() async throws {
        let driver = makeDriver(answer: Self.fourResultSets)

        let outcome = try await run("EXEC sp_help 'dbo.orders'", on: driver)

        #expect(driver.sentBatches.map(\.sql) == ["EXEC sp_help 'dbo.orders'"])
        #expect(outcome.resultSets.count == 4)
    }

    @Test("GO lines cut a script into batches, run a batch as often as they ask, and never reach the server")
    func goLinesCutTheScript() async throws {
        let driver = makeDriver { query in
            ScriptAnsweringDriver.batch([ScriptAnsweringDriver.resultSet(columns: [query], rows: [["1"]])])
        }

        let outcome = try await run("SELECT 1 AS a\nGO\nSELECT 2 AS b\nGO 3", on: driver)

        #expect(driver.sentBatches.map(\.sql) == ["SELECT 1 AS a", "SELECT 2 AS b", "SELECT 2 AS b", "SELECT 2 AS b"])
        #expect(outcome.resultSets.count == 4)
    }

    @Test("A lone query keeps the path that bounds its fetch, and a GO line before it is not sent")
    func loneQueryKeepsTheBoundedPath() async throws {
        let driver = makeDriver(answer: Self.fourResultSets)

        let outcome = try await run("GO\nSELECT * FROM orders", on: driver)

        #expect(driver.sentBatches.isEmpty)
        #expect(driver.sentStatements == ["SELECT * FROM orders"])
        #expect(outcome.resultSets.count == 1)
    }

    @Test("Rows the script changed and a transaction it left open are reported on the first result")
    func scriptTotalsAndNoticesAreReported() async throws {
        let notice = try #require(PluginSessionTransactionState.inTransaction.openTransactionNotice)
        let driver = makeDriver(transactionState: .inTransaction) { _ in
            ScriptAnsweringDriver.batch(
                [ScriptAnsweringDriver.resultSet(columns: ["id"], rows: [["1"]], isTruncated: true)],
                rowsAffected: 3
            )
        }

        let outcome = try await run("BEGIN TRAN\nUPDATE orders SET paid = 1\nSELECT id FROM orders", on: driver)

        #expect(outcome.primary.rowsAffected == 3)
        #expect(outcome.primary.isTruncated)
        #expect(outcome.primary.statusMessage == notice)
    }

    @Test("A batch that raises an error fails the call, names the batch and line, and stops the script")
    func batchErrorFailsTheCall() async throws {
        let driver = makeDriver { query in
            guard query.contains("missing") else {
                return ScriptAnsweringDriver.batch([ScriptAnsweringDriver.resultSet(columns: ["n"], rows: [["1"]])])
            }
            return ScriptAnsweringDriver.batch(
                [],
                errors: [
                    PluginBatchError(
                        message: "Invalid object name 'missing'.",
                        code: 208,
                        line: 1,
                        procedure: nil,
                        precedingResultSetCount: 0
                    )
                ]
            )
        }

        let error = await #expect(throws: DatabaseError.self) {
            try await run("SELECT 1\nGO\nSELECT * FROM missing\nGO\nSELECT 3", on: driver)
        }

        let message = try #require(error?.errorDescription)
        #expect(message.contains("Batch 2/3 failed: Line 3: Invalid object name 'missing'."))
        #expect(message.contains(String(localized: "The batch before it stays applied.")))
        #expect(driver.sentBatches.map(\.sql) == ["SELECT 1", "SELECT * FROM missing"])
    }

    @Test("Result sets past the ceiling one batch keeps are counted and reported")
    func resultSetsPastTheCeilingAreReported() async throws {
        let driver = makeDriver { _ in
            ScriptAnsweringDriver.batch([ScriptAnsweringDriver.resultSet(columns: ["n"], rows: [["1"]])])
        }

        let outcome = try await run("SELECT 1 AS n\nGO 102", on: driver)

        #expect(driver.sentBatches.count == 102)
        #expect(outcome.resultSets.count == QueryBatchResult.keptResultSetLimit)
        #expect(outcome.primary.statusMessage == BatchRunNotice.text(discardedResultSetCount: 2, sessionState: .idle))
    }

    @Test("A driver that cannot send a batch whole refuses a script rather than run part of it")
    func scriptWithoutBatchDriverIsRefused() async throws {
        let driver = makeDriver(sendsBatchesWhole: false)

        let error = await #expect(throws: DatabaseAccessError.self) {
            try await run("SELECT 1; SELECT 2", on: driver)
        }

        guard case .invalidArgument? = error else {
            Issue.record("Expected an invalid argument, got \(String(describing: error))")
            return
        }
        #expect(driver.sentStatements.isEmpty)
    }

    @Test("GO with a count is refused by a driver that cannot send a batch whole")
    func repeatedBatchWithoutBatchDriverIsRefused() async throws {
        let driver = makeDriver(sendsBatchesWhole: false)

        let error = await #expect(throws: DatabaseAccessError.self) {
            try await run("SELECT 1\nGO 2", on: driver)
        }

        guard case .invalidArgument? = error else {
            Issue.record("Expected an invalid argument, got \(String(describing: error))")
            return
        }
        #expect(driver.sentStatements.isEmpty)
    }
}
