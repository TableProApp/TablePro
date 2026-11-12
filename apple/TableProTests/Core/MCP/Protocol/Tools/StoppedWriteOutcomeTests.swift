//
//  StoppedWriteOutcomeTests.swift
//  TableProTests
//
//  A write already in the driver runs to its end when the caller stops waiting. The caller used to hear a plain
//  CancellationError, history kept no row, and the write committed anyway.
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import TableProTestSupport
import Testing

private struct StoppedTool: MCPToolImplementation {
    static let name = "stopped_test_tool"
    static let description = "A tool whose write was stopped in the driver."
    static let requiredScopes: Set<MCPScope> = [.toolsRead]
    static let inputSchema = MCPToolSchema.empty

    let cancelsItsTask: Bool

    func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        if cancelsItsTask {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        throw DatabaseAccessBridge.stoppedWhileRunning
    }
}

@MainActor
struct StoppedWriteOutcomeTests {
    private static let write = "UPDATE orders SET n = n + 1 WHERE id = 1"

    private func makeServices(history: RecordingQueryHistory) -> MCPToolServices {
        MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy(
                connectionResolver: { _ in nil },
                connectionIdsProvider: { [] },
                historyRecorder: history,
                executionGate: AlwaysAllowGate()
            )
        )
    }

    @Test("A write stopped in the driver is recorded in history as failed, with the outcome unknown")
    func stoppedWriteIsRecorded() async throws {
        let gate = AsyncGate()
        let driver = AnsweringPluginDriver(hold: gate)
        let scope = AnsweringPluginDriver.install(driver, connection: TestFixtures.makeConnection(database: "shop", type: .postgresql))
        defer { DatabaseManager.shared.removeSession(for: scope.connectionId) }
        let history = RecordingQueryHistory()
        let services = makeServices(history: history)
        let operation = try await ApprovedOperationFixture.approve(
            [OperationStatement(sql: Self.write)], scope: scope, databaseType: .postgresql
        )

        let caller = Task {
            try await ToolQueryExecutor.executeAndLog(
                services: services,
                operation: operation,
                maxRows: 500,
                timeoutSeconds: 30,
                principal: MCPToolTestHarness.principal()
            )
        }
        await gate.arrived(1)
        caller.cancel()
        let error = await #expect(throws: DatabaseAccessError.self) { _ = try await caller.value }

        guard case .stoppedWhileRunning? = error else {
            Issue.record("expected the outcome to be unknown, got \(String(describing: error))")
            return
        }
        let rows = history.requests
        #expect(rows.count == 1)
        #expect(rows.first?.query == Self.write)
        #expect(rows.first?.wasSuccessful == false)
        #expect(rows.first?.errorMessage == MCPErrorRedactor.message(for: DatabaseAccessBridge.stoppedWhileRunning))
        #expect(driver.finishedCount == 0)

        await gate.open()
        try await waitUntil { driver.finishedCount == 1 }
    }

    @Test("A cancelled MCP request whose write was in the driver keeps -33002 and says the outcome is unknown")
    func cancelledRequestKeepsItsCode() async throws {
        do {
            _ = try await Task {
                try await StoppedTool(cancelsItsTask: true).call(
                    arguments: .object([:]),
                    context: MCPToolTestHarness.context(),
                    services: MCPToolTestHarness.services()
                )
            }.value
            Issue.record("Expected a cancellation protocol error")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.requestCancelled)
            #expect(error.data == .object(["outcome": .string("unknown")]))
        }
    }

    @Test("Outside a cancelled request the stopped write is a timeout result that says it may have been applied")
    func uncancelledStopIsATimeoutResult() async throws {
        let result = try await StoppedTool(cancelsItsTask: false).call(
            arguments: .object([:]),
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )

        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result) == "timeout: \(DatabaseAccessBridge.stoppedWhileRunning.message)")
    }

    @Test("An analyzed write explain_query runs is recorded in history, and a plan of a read is not")
    func analyzedWriteIsRecorded() async throws {
        let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
        let driver = ScriptAnsweringDriver(connection: connection, statementAnswer: { _ in
            ScriptAnsweringDriver.resultSet(columns: ["QUERY PLAN"], rows: [["Update on orders"]])
        })
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)
        let variants = [
            ExplainVariant(id: "plan", label: "Plan", sqlPrefix: "EXPLAIN"),
            ExplainVariant(id: "analyze", label: "Analyze", sqlPrefix: "EXPLAIN ANALYZE")
        ]
        let analyzedWrite = try MCPConnectionBridge.explainRequest(
            for: Self.write, databaseType: .postgresql, variants: variants, variantId: nil, analyze: true
        )
        let plannedRead = try MCPConnectionBridge.explainRequest(
            for: "SELECT 1", databaseType: .postgresql, variants: variants, variantId: nil, analyze: false
        )
        let history = RecordingQueryHistory()
        let services = makeServices(history: history)

        for (request, kind) in [(analyzedWrite, OperationKind.writeQuery), (plannedRead, .readQuery)] {
            let operation = try await ApprovedOperationFixture.approve(
                [OperationStatement(sql: request.statement)], scope: scope, databaseType: .postgresql, kind: kind
            )
            _ = try await ToolQueryExecutor.explainAndLog(
                services: services,
                operation: operation,
                request: request,
                timeoutSeconds: 30,
                context: MCPToolTestHarness.context(),
                secrets: []
            )
        }

        #expect(driver.sentStatements == [analyzedWrite.statement, plannedRead.statement])
        #expect(history.requests.map { $0.query } == [analyzedWrite.statement])
        #expect(history.requests.first?.wasSuccessful == true)
    }
}

// A request that reaches a write needs a saved connection open to external writes.
extension GlobalStateSuites {
    @MainActor
    struct StoppedWriteRequestTests {
        @Test("execute_query cancelled during a write in the driver answers -33002, and history keeps the write")
        func executeQueryCancelledInTheDriver() async throws {
            let gate = AsyncGate()
            let driver = AnsweringPluginDriver(hold: gate)
            var connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
            connection.externalAccess = .readWrite
            let savedBefore = ConnectionStorage.shared.loadConnections()
            ConnectionStorage.shared.saveConnections(savedBefore + [connection])
            let scope = AnsweringPluginDriver.install(driver, connection: connection)
            defer {
                DatabaseManager.shared.removeSession(for: scope.connectionId)
                ConnectionStorage.shared.saveConnections(savedBefore)
            }
            let history = RecordingQueryHistory()
            let services = MCPToolServices(
                connectionBridge: MCPConnectionBridge(),
                authPolicy: MCPAuthPolicy(
                    connectionResolver: { _ in nil },
                    connectionIdsProvider: { [] },
                    historyRecorder: history,
                    executionGate: AlwaysAllowGate()
                )
            )

            let caller = Task {
                try await ExecuteQueryTool().call(
                    arguments: .object([
                        "connection_id": .string(connection.id.uuidString),
                        "query": .string("UPDATE orders SET n = n + 1 WHERE id = 1")
                    ]),
                    context: MCPToolTestHarness.context(),
                    services: services
                )
            }
            await gate.arrived(1)
            caller.cancel()
            do {
                _ = try await caller.value
                Issue.record("Expected the cancelled request to end as a cancellation")
            } catch let error as MCPProtocolError {
                #expect(error.code == JsonRpcErrorCode.requestCancelled)
                #expect(error.data == .object(["outcome": .string("unknown")]))
            }
            #expect(history.requests.map { $0.wasSuccessful } == [false])

            await gate.open()
            try await waitUntil { driver.finishedCount == 1 }
        }
    }
}
