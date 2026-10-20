//
//  WritePolicyFixture.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit

enum WritePrompt: String, Sendable, CustomStringConvertible {
    // The MCP connection approval, or the assistant's Allow AI Access.
    case connectionAccess
    case toolCard
    case confirmation
    case authentication

    var description: String { rawValue }
}

enum WriteOutcome: Equatable, Sendable, CustomStringConvertible {
    case refused
    case runs(after: [WritePrompt])

    var description: String {
        switch self {
        case .refused:
            return "refused"
        case .runs(let prompts) where prompts.isEmpty:
            return "runs"
        case .runs(let prompts):
            return "runs after \(prompts.map(\.rawValue).joined(separator: ", "))"
        }
    }
}

final class WritePolicyPrompts: @unchecked Sendable {
    enum Answer {
        case approveAll
        case refuseAll
    }

    private let lock = NSLock()
    private let answer: Answer
    private var asked: [WritePrompt] = []

    init(_ answer: Answer) {
        self.answer = answer
    }

    var prompts: [WritePrompt] {
        lock.withLock { asked }
    }

    func ask(_ prompt: WritePrompt) -> Bool {
        lock.withLock {
            asked.append(prompt)
            return answer == .approveAll
        }
    }
}

struct WritePolicyPresenter: MCPApprovalPresenting {
    let prompts: WritePolicyPrompts

    func requestApproval(_ request: MCPApprovalRequest) async -> Bool {
        prompts.ask(.connectionAccess)
    }
}

struct WritePolicyConfirming: OperationConfirming {
    let prompts: WritePolicyPrompts

    @MainActor
    func confirm(_ request: OperationConfirmationRequest) async -> Bool {
        prompts.ask(.confirmation)
    }
}

struct WritePolicyAuthenticating: OperationAuthenticating {
    let prompts: WritePolicyPrompts

    func authenticate(reason: String) async -> Bool {
        prompts.ask(.authentication)
    }
}

struct WritePolicyAuditLog: ExecutionAuditLogging {
    func record(request: OperationRequest, decision: OperationDecision) async {}
    func entries() async -> [ExecutionAuditRecord] { [] }
    func verify() async -> ExecutionAuditVerification { .intact(count: 0) }
}

struct WritePolicyHistory: QueryHistoryRecording {
    func record(_ request: QueryHistoryRecordRequest) async -> Bool { true }
}

final class WritePolicyDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var received: [String] {
        lock.withLock { log }
    }

    private func record(_ entry: String) -> PluginQueryResult {
        lock.withLock { log.append(entry) }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 1, executionTime: 0)
    }

    func execute(query: String) async throws -> PluginQueryResult {
        record(query)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        record(query)
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        _ = record("CREATE DATABASE \(request.name)")
    }

    func dropDatabase(name: String) async throws {
        _ = record("DROP DATABASE \(name)")
    }

    func dropSchema(name: String) async throws {
        _ = record("DROP SCHEMA \(name)")
    }

    func switchDatabase(to database: String) async throws {}

    func supportedMaintenanceOperations() -> [String]? {
        ["VACUUM"]
    }

    func maintenanceStatements(
        operation: String,
        table: String?,
        schema: String?,
        options: [String: String]
    ) -> [String]? {
        [operation]
    }
}

@MainActor
final class WritePolicyRig {
    let connection: DatabaseConnection
    let driver = WritePolicyDriver()
    let prompts: WritePolicyPrompts
    let authPolicy: MCPAuthPolicy
    private let savedBefore: [DatabaseConnection]?

    // Not live: only the auth policy knows the connection, so a call the gates pass stops at the tool's lookup.
    init(connection: DatabaseConnection, prompts: WritePolicyPrompts, live: Bool) {
        self.connection = connection
        self.prompts = prompts

        let snapshotSource = [connection]
        authPolicy = MCPAuthPolicy(
            connectionResolver: { id in
                MCPAuthPolicy.snapshot(for: id, saved: snapshotSource, defaultPolicy: .askEachTime)
            },
            connectionIdsProvider: { Set(snapshotSource.map(\.id)) },
            approvalLedger: MCPApprovalLedger(store: MCPInMemoryApprovalStore()),
            historyRecorder: WritePolicyHistory(),
            approvalSetting: MCPFixedApprovalReader(.everyTime),
            presenter: WritePolicyPresenter(prompts: prompts),
            executionGate: DefaultExecutionGate(
                confirming: WritePolicyConfirming(prompts: prompts),
                authenticating: WritePolicyAuthenticating(prompts: prompts),
                safeModeLevelResolver: { id in
                    await MainActor.run {
                        DatabaseManager.shared.session(for: id)?.safeModeLevel ?? connection.safeModeLevel
                    }
                },
                forcesWriteResolver: { _ in false },
                auditLog: WritePolicyAuditLog()
            )
        )

        guard live else {
            savedBefore = nil
            return
        }
        let saved = ConnectionStorage.shared.loadConnections()
        savedBefore = saved
        ConnectionStorage.shared.saveConnections(saved + [connection])
        let session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        DatabaseManager.shared.injectSession(session, for: connection.id)
    }

    func tearDown() {
        guard let savedBefore else { return }
        DatabaseManager.shared.removeSession(for: connection.id)
        ConnectionStorage.shared.saveConnections(savedBefore)
    }

    static func connection(
        type: DatabaseType,
        externalAccess: ExternalAccessLevel,
        aiPolicy: AIConnectionPolicy,
        safeMode: SafeModeLevel,
        alwaysAllowedTools: Set<String> = []
    ) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Write policy matrix", database: "matrix", type: type)
        connection.externalAccess = externalAccess
        connection.aiPolicy = aiPolicy
        connection.safeModeLevel = safeMode
        connection.aiAlwaysAllowedTools = alwaysAllowedTools
        return connection
    }
}
