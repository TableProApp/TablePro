//
//  ConfirmDestructiveOperationScopeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import Testing

private actor DiscardingHistory: QueryHistoryRecording {
    func record(_ request: QueryHistoryRecordRequest) async -> Bool { true }
}

// The approval card names the database and schema from the call's input, and an explicit Run skips the gate's own
// dialog, so the statement has to run in exactly what the input names.
@MainActor
struct ConfirmDestructiveOperationScopeTests {
    // `reported` is what the connect captures from the driver as the database it opened; SQLite reports its file.
    private func session(database: String, type: DatabaseType = .postgresql, reported: String? = nil) -> ScriptAnsweringDriver {
        var connection = TestFixtures.makeConnection(database: database, type: type)
        connection.aiPolicy = .alwaysAllow
        let driver = ScriptAnsweringDriver(connection: connection) { _ in .empty }
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        session.openedDatabase = reported
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return driver
    }

    private func context(_ driver: ScriptAnsweringDriver, gate: any ExecutionGate) -> ChatToolContext {
        ChatToolContext(
            connectionId: driver.connection.id,
            bridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy(
                connectionResolver: { _ in nil },
                connectionIdsProvider: { [] },
                historyRecorder: DiscardingHistory(),
                executionGate: gate
            ),
            chatMode: .agent,
            sessionId: UUID(),
            approvalWasExplicit: true,
            policyLookup: { _ in .alwaysAllow }
        )
    }

    private func input(_ extra: [String: JsonValue]) -> JsonValue {
        .object([
            "query": .string("DROP TABLE orders"),
            "confirmation_phrase": .string(ConfirmDestructiveOperationChatTool.requiredPhrase)
        ].merging(extra) { first, _ in first })
    }

    @Test("A database and schema the call names are where the statement runs, not the session's current ones")
    func namedScopeIsTheRunScope() async throws {
        let driver = session(database: "prod")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let gate = RequestRecordingGate(allows: false)

        await #expect(throws: (any Error).self) {
            _ = try await ConfirmDestructiveOperationChatTool().execute(
                input: input(["database": .string("staging"), "schema": .string("archive")]),
                context: context(driver, gate: gate)
            )
        }

        let request = try #require(await gate.requests.first)
        #expect(request.scope?.database == "staging")
        #expect(request.scope?.schema == "archive")
        #expect(driver.sentStatements.isEmpty && driver.sentBatches.isEmpty)
    }

    @Test("A call that names no database runs in the session's current one")
    func unnamedScopeIsTheCurrentDatabase() async throws {
        let driver = session(database: "prod")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let gate = RequestRecordingGate(allows: false)

        await #expect(throws: (any Error).self) {
            _ = try await ConfirmDestructiveOperationChatTool().execute(
                input: input(["database": .null]),
                context: context(driver, gate: gate)
            )
        }

        let request = try #require(await gate.requests.first)
        #expect(request.scope?.database == "prod")
    }

    @Test("On a connection that cannot change database, naming another one is refused before anything is asked or run")
    func unreachableDatabaseIsRefused() async {
        let driver = session(database: "prod.sqlite", type: .sqlite, reported: "prod.sqlite")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let gate = RequestRecordingGate(allows: true)

        await #expect(throws: DatabaseAccessError.self) {
            _ = try await ConfirmDestructiveOperationChatTool().execute(
                input: input(["database": .string("staging.sqlite")]),
                context: context(driver, gate: gate)
            )
        }

        #expect(await gate.requests.isEmpty)
        #expect(driver.sentStatements.isEmpty && driver.sentBatches.isEmpty)
    }

    @Test("Naming the database a fixed connection is already on still runs there")
    func currentDatabaseOfAFixedConnectionIsTaken() async throws {
        let driver = session(database: "prod.sqlite", type: .sqlite, reported: "prod.sqlite")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let gate = RequestRecordingGate(allows: false)

        await #expect(throws: (any Error).self) {
            _ = try await ConfirmDestructiveOperationChatTool().execute(
                input: input(["database": .string("prod.sqlite")]),
                context: context(driver, gate: gate)
            )
        }

        let request = try #require(await gate.requests.first)
        #expect(request.scope?.database == "prod.sqlite")
    }

    @Test("An argument the tool does not declare is refused before anything is asked or run")
    func undeclaredArgumentIsRefused() async throws {
        let driver = session(database: "prod")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let gate = RequestRecordingGate(allows: true)

        await #expect(throws: ChatToolArgumentError.self) {
            _ = try await ConfirmDestructiveOperationChatTool().execute(
                input: input(["target_database": .string("staging")]),
                context: context(driver, gate: gate)
            )
        }

        #expect(await gate.requests.isEmpty)
        #expect(driver.sentStatements.isEmpty && driver.sentBatches.isEmpty)
    }

    @Test("The session's own connection_id is still taken, since the connection check answers it")
    func sessionConnectionIdIsAccepted() async throws {
        let driver = session(database: "prod")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let gate = RequestRecordingGate(allows: false)

        await #expect(throws: (any Error).self) {
            _ = try await ConfirmDestructiveOperationChatTool().execute(
                input: input(["connection_id": .string(driver.connection.id.uuidString)]),
                context: context(driver, gate: gate)
            )
        }

        #expect(await gate.requests.count == 1)
    }
}
