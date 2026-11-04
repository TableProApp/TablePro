//
//  DisconnectToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

struct DisconnectToolTests {
    private let tool = DisconnectTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Closing a session is a write, so the tool needs the write scope")
    func metadata() {
        #expect(DisconnectTool.name == "disconnect")
        #expect(DisconnectTool.requiredScopes == [.toolsWrite])
        #expect(DisconnectTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) == ["connection_id"])
        #expect(DisconnectTool.outputSchema != nil)
    }

    @Test("Missing connection_id is a protocol error")
    func missingConnectionId() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([:]))
        }
    }

    @Test("A malformed connection id is a tool error")
    func malformedConnectionId() async throws {
        let result = try await call(.object(["connection_id": .string("not-a-uuid")]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("Disconnecting a session that is not open says so")
    func disconnectingAClosedSession() async throws {
        let result = try await call(.object(["connection_id": .string(UUID().uuidString)]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("not_connected:") == true)
    }

    @Test("Disconnecting while TablePro has work on the connection is refused and the session stays")
    @MainActor
    func runningWorkRefusesDisconnect() async throws {
        let connection = TestFixtures.makeConnection(name: "Busy", type: .mysql)
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: IdleDriver())
        )
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let work = RunningWorkRegistry.shared.begin(
            .dataImport,
            subject: "private-file.csv",
            connectionName: connection.name,
            connectionIds: [connection.id]
        ) {}
        defer { RunningWorkRegistry.shared.end(work) }

        let result = try await call(.object(["connection_id": .string(connection.id.uuidString)]))

        #expect(result.isError)
        let text = try #require(MCPToolTestHarness.errorText(result))
        #expect(text.hasPrefix("denied:"))
        #expect(text.contains("an import, export, backup, restore or copy"))
        #expect(!text.contains("private-file.csv"))
        #expect(DatabaseManager.shared.activeSessions[connection.id] != nil)
    }

    @Test("Once the work ends the same call disconnects")
    @MainActor
    func disconnectsOnceTheWorkEnds() async throws {
        let connection = TestFixtures.makeConnection(name: "Idle again", type: .mysql)
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: IdleDriver())
        )
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let work = RunningWorkRegistry.shared.begin(
            .backup, subject: "", connectionName: connection.name, connectionIds: [connection.id]
        ) {}
        let arguments: JsonValue = .object(["connection_id": .string(connection.id.uuidString)])

        #expect(try await call(arguments).isError)
        RunningWorkRegistry.shared.end(work)
        let result = try await call(arguments)

        #expect(!result.isError)
        #expect(DatabaseManager.shared.activeSessions[connection.id] == nil)
    }

    @Test("Work that starts while the transaction probe runs is seen, and the disconnect is refused")
    @MainActor
    func workStartingDuringTheProbeRefuses() async throws {
        let connection = TestFixtures.makeConnection(name: "Starts work", type: .mysql)
        let driver = WorkStartingDriver(connectionId: connection.id)
        try await withLiveSession(connection, driver: driver) {
            let result = try await call(.object(["connection_id": .string(connection.id.uuidString)]))

            #expect(result.isError)
            #expect(MCPToolTestHarness.errorText(result)?.contains("an import, export, backup, restore or copy") == true)
            #expect(DatabaseManager.shared.activeSessions[connection.id] != nil)
        }
        RunningWorkRegistry.shared.end(driver.startedWork)
    }

    @Test("A transaction another lane opened while the probe ran is seen, and the disconnect is refused")
    @MainActor
    func transactionOpenedDuringTheProbeRefuses() async throws {
        let connection = TestFixtures.makeConnection(name: "Opens a transaction", type: .mysql)
        let driver = TransactionOpeningDriver(connectionId: connection.id)
        try await withLiveSession(connection, driver: driver) {
            let result = try await call(.object(["connection_id": .string(connection.id.uuidString)]))

            #expect(result.isError)
            #expect(MCPToolTestHarness.errorText(result)?.contains("an open transaction") == true)
            #expect(DatabaseManager.shared.activeSessions[connection.id] != nil)
        }
    }

    @Test("A turn recorded while the probe ran makes an idle answer unknown")
    @MainActor
    func turnDuringTheProbeIsUnknown() {
        let manager = DatabaseManager.shared
        let connectionId = UUID()
        let before = manager.sessionTransactions.turnRevision(for: connectionId)

        #expect(manager.settledTransactionSafety(.noTransaction, for: connectionId, turnRevisionBefore: before) == .noTransaction)
        #expect(manager.settledTransactionSafety(.noTransaction, for: connectionId, turnRevisionBefore: before - 1) == .unknown)
        #expect(manager.settledTransactionSafety(.holding, for: connectionId, turnRevisionBefore: before) == .holding)
    }

    @Test("A transactional engine that cannot report its state is refused, naming nothing")
    @MainActor
    func unknownTransactionStateRefuses() async throws {
        let connection = TestFixtures.makeConnection(name: "Cannot tell", type: .mysql)
        try await withLiveSession(connection, driver: UnknownStateDriver()) {
            let result = try await call(.object(["connection_id": .string(connection.id.uuidString)]))

            #expect(result.isError)
            let text = try #require(MCPToolTestHarness.errorText(result))
            #expect(text.hasPrefix("denied:"))
            #expect(text.contains("cannot tell whether this connection holds an open transaction"))
            #expect(!text.contains("Cannot tell"))
            #expect(DatabaseManager.shared.activeSessions[connection.id] != nil)
        }
    }

    @Test("An engine without transactions disconnects without a probe answer")
    @MainActor
    func engineWithoutTransactionsDisconnects() async throws {
        let connection = TestFixtures.makeConnection(name: "No transactions", type: .mysql)
        try await withLiveSession(connection, driver: TransactionlessDriver()) {
            let result = try await call(.object(["connection_id": .string(connection.id.uuidString)]))

            #expect(!result.isError)
            #expect(DatabaseManager.shared.activeSessions[connection.id] == nil)
        }
    }

    @Test("An open transaction is named as a loss, never the database")
    @MainActor
    func openTransactionRefuses() {
        let message = ExternalDisconnectRefusal.message(work: [], transactions: .holding, hasUnsavedWork: false)
        #expect(message?.contains("an open transaction") == true)
        #expect(ExternalDisconnectRefusal.message(work: [], transactions: .noTransaction, hasUnsavedWork: false) == nil)
    }

    @MainActor
    private func withLiveSession(
        _ connection: DatabaseConnection,
        driver: any PluginDatabaseDriver,
        _ body: @MainActor () async throws -> Void
    ) async throws {
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await body()
    }

    @Test("Each loss is named by its kind, in one fixed order")
    @MainActor
    func refusalNamesKinds() {
        #expect(ExternalDisconnectRefusal.message(for: []) == nil)
        #expect(
            ExternalDisconnectRefusal.message(for: [.transaction])
                == "This connection has an open transaction in TablePro, which disconnecting would stop or discard. "
                + "Finish it first, or disconnect in TablePro, which asks the user."
        )
        let several = ExternalDisconnectRefusal.message(for: [.unsavedChanges, .query]) ?? ""
        let query = several.range(of: "a running query")
        let unsaved = several.range(of: "unsaved changes")
        #expect(query != nil && unsaved != nil)
        if let query, let unsaved { #expect(query.lowerBound < unsaved.lowerBound) }
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "force": .bool(true)
            ]))
        }
    }
}

private final class IdleDriver: PluginDriverStub, @unchecked Sendable {
    func sessionTransactionState() async -> PluginSessionTransactionState { .idle }
}

private final class UnknownStateDriver: PluginDriverStub, @unchecked Sendable {
    func sessionTransactionState() async -> PluginSessionTransactionState { .unknown }
}

private final class TransactionlessDriver: PluginDriverStub, @unchecked Sendable {
    var supportsTransactions: Bool { false }
}

// Another lane's turn finishes with a transaction open while the disconnect still waits on this probe.
private final class TransactionOpeningDriver: PluginDriverStub, @unchecked Sendable {
    private let connectionId: UUID

    init(connectionId: UUID) {
        self.connectionId = connectionId
    }

    func sessionTransactionState() async -> PluginSessionTransactionState {
        let connectionId = connectionId
        await MainActor.run {
            let manager = DatabaseManager.shared
            guard let driver = manager.activeSessions[connectionId]?.driver else { return }
            manager.sessionTransactions.record(
                .inTransaction,
                on: driver,
                for: SessionTransactionTracker.Key(connectionId: connectionId, lane: nil)
            )
        }
        return .idle
    }
}

// Starts an import on the connection while the disconnect is still asking about transactions.
private final class WorkStartingDriver: PluginDriverStub, @unchecked Sendable {
    private let connectionId: UUID
    private let lock = NSLock()
    private var work: UUID?

    init(connectionId: UUID) {
        self.connectionId = connectionId
    }

    var startedWork: UUID? { lock.withLock { work } }

    func sessionTransactionState() async -> PluginSessionTransactionState {
        let connectionId = connectionId
        let id = await MainActor.run {
            RunningWorkRegistry.shared.begin(
                .dataImport, subject: "late.csv", connectionName: "", connectionIds: [connectionId]
            ) {}
        }
        lock.withLock { work = id }
        return .idle
    }
}
