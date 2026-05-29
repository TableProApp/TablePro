//
//  ExecutionGateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
final class StubConfirming: OperationConfirming {
    private(set) var callCount = 0
    private(set) var lastDestructive = false
    private let answer: Bool

    init(answer: Bool) {
        self.answer = answer
    }

    func confirm(sql: String, operationDescription: String, connectionId: UUID, isDestructive: Bool) async -> Bool {
        callCount += 1
        lastDestructive = isDestructive
        return answer
    }
}

final class StubAuthenticating: OperationAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCallCount = 0
    private let answer: Bool

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    init(answer: Bool) {
        self.answer = answer
    }

    func authenticate(reason: String) async -> Bool {
        lock.withLock { storedCallCount += 1 }
        return answer
    }
}

@MainActor
@Suite("ExecutionGate")
struct ExecutionGateTests {
    private func makeGate(
        level: SafeModeLevel,
        forcesWrite: Bool = false,
        confirm: StubConfirming,
        auth: StubAuthenticating
    ) -> DefaultExecutionGate {
        DefaultExecutionGate(
            confirming: confirm,
            authenticating: auth,
            safeModeLevelResolver: { _ in level },
            forcesWriteResolver: { _ in forcesWrite }
        )
    }

    private func makeRequest(
        sql: String?,
        kind: OperationKind,
        capabilities: CallerCapabilities = .interactiveUser,
        databaseType: DatabaseType = .mysql,
        caller: OperationCaller = .userInterface
    ) -> OperationRequest {
        OperationRequest(
            connectionId: UUID(),
            databaseType: databaseType,
            sql: sql,
            kind: kind,
            caller: caller,
            capabilities: capabilities,
            operationDescription: "Execute Query"
        )
    }

    // MARK: - Silent

    @Test("Silent allows reads and writes without prompting")
    func silentAllowsReadAndWrite() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let read = await gate.authorize(makeRequest(sql: "SELECT 1", kind: .readQuery))
        let write = await gate.authorize(makeRequest(sql: "INSERT INTO t VALUES (1)", kind: .writeQuery))

        #expect(read.isAuthorized)
        #expect(write.isAuthorized)
        #expect(confirm.callCount == 0)
        #expect(auth.callCount == 0)
    }

    @Test("Silent still confirms destructive operations")
    func silentConfirmsDestructive() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(sql: "DROP TABLE users", kind: .destructiveQuery))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 1)
        #expect(confirm.lastDestructive)
        #expect(auth.callCount == 0)
    }

    @Test("Silent destructive denied when user cancels")
    func silentDestructiveCancelled() async {
        let confirm = StubConfirming(answer: false)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(sql: "TRUNCATE t", kind: .destructiveQuery))

        #expect(!decision.isAuthorized)
        #expect(confirm.callCount == 1)
    }

    @Test("Unqualified DELETE is treated as destructive even when declared a write")
    func unqualifiedDeleteForcesConfirm() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(sql: "DELETE FROM users", kind: .writeQuery))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 1)
        #expect(confirm.lastDestructive)
    }

    @Test("Qualified DELETE with WHERE is an ordinary write")
    func qualifiedDeleteIsWrite() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(sql: "DELETE FROM users WHERE id = 1", kind: .writeQuery))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
    }

    @Test("worst(of:) escalates to destructive for any destructive or dangerous statement")
    func worstAcrossStatements() {
        #expect(OperationKind.worst(of: ["SELECT 1", "DROP TABLE t"], databaseType: .mysql) == .destructiveQuery)
        #expect(OperationKind.worst(of: ["SELECT 1", "DELETE FROM t"], databaseType: .mysql) == .destructiveQuery)
        #expect(OperationKind.worst(of: ["SELECT 1", "UPDATE t SET a=1"], databaseType: .mysql) == .writeQuery)
        #expect(OperationKind.worst(of: ["SELECT 1", "SELECT 2"], databaseType: .mysql) == .readQuery)
    }

    // MARK: - Read-only

    @Test("Read-only allows reads, blocks writes")
    func readOnlyBlocksWrites() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .readOnly, confirm: confirm, auth: auth)

        let read = await gate.authorize(makeRequest(sql: "SELECT 1", kind: .readQuery))
        let write = await gate.authorize(makeRequest(sql: "UPDATE t SET a=1", kind: .writeQuery))

        #expect(read.isAuthorized)
        #expect(write.deniedReason?.contains("read-only") == true)
        #expect(confirm.callCount == 0)
    }

    @Test("Read-only blocks destructive without prompting")
    func readOnlyBlocksDestructiveBeforeConfirm() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .readOnly, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(sql: "DROP TABLE t", kind: .destructiveQuery))

        #expect(!decision.isAuthorized)
        #expect(confirm.callCount == 0)
    }

    @Test("Read-only forces write for no-read-only databases")
    func readOnlyForcesWriteForNoSQL() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .readOnly, forcesWrite: true, confirm: confirm, auth: auth)

        let decision = await gate.authorize(
            makeRequest(sql: "db.users.find({})", kind: .readQuery, databaseType: .mongodb)
        )

        #expect(decision.deniedReason?.contains("read-only") == true)
    }

    // MARK: - Alert

    @Test("Alert confirms writes but not plain reads")
    func alertConfirmsWritesOnly() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .alert, confirm: confirm, auth: auth)

        let read = await gate.authorize(makeRequest(sql: "SELECT 1", kind: .readQuery))
        #expect(read.isAuthorized)
        #expect(confirm.callCount == 0)

        let write = await gate.authorize(makeRequest(sql: "INSERT INTO t VALUES (1)", kind: .writeQuery))
        #expect(write.isAuthorized)
        #expect(confirm.callCount == 1)
        #expect(auth.callCount == 0)
    }

    @Test("Alert denies write when confirmation cancelled")
    func alertWriteCancelled() async {
        let confirm = StubConfirming(answer: false)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .alert, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(sql: "DELETE FROM t WHERE id=1", kind: .writeQuery))

        #expect(decision.deniedReason?.contains("cancelled") == true)
    }

    // MARK: - Alert (Full)

    @Test("Alert full confirms reads too")
    func alertFullConfirmsReads() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .alertFull, confirm: confirm, auth: auth)

        let read = await gate.authorize(makeRequest(sql: "SELECT 1", kind: .readQuery))

        #expect(read.isAuthorized)
        #expect(confirm.callCount == 1)
        #expect(auth.callCount == 0)
    }

    // MARK: - Safe Mode

    @Test("Safe mode requires confirm then auth for writes")
    func safeModeWriteRequiresConfirmAndAuth() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .safeMode, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(sql: "UPDATE t SET a=1", kind: .writeQuery))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 1)
        #expect(auth.callCount == 1)
    }

    @Test("Safe mode does not authenticate when confirmation cancelled")
    func safeModeConfirmCancelSkipsAuth() async {
        let confirm = StubConfirming(answer: false)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .safeMode, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(sql: "UPDATE t SET a=1", kind: .writeQuery))

        #expect(!decision.isAuthorized)
        #expect(auth.callCount == 0)
    }

    @Test("Safe mode denies write when authentication fails")
    func safeModeAuthFailureDenies() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: false)
        let gate = makeGate(level: .safeMode, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(sql: "UPDATE t SET a=1", kind: .writeQuery))

        #expect(decision.deniedReason?.contains("Authentication") == true)
    }

    @Test("Safe mode allows reads without confirm or auth")
    func safeModeAllowsReads() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .safeMode, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(sql: "SELECT 1", kind: .readQuery))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
        #expect(auth.callCount == 0)
    }

    // MARK: - Safe Mode (Full)

    @Test("Safe mode full confirms and authenticates reads")
    func safeModeFullGuardsReads() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .safeModeFull, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(sql: "SELECT 1", kind: .readQuery))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 1)
        #expect(auth.callCount == 1)
    }

    // MARK: - Capability gates

    @Test("Write denied when caller lacks write capability")
    func writeDeniedWithoutCapability() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let decision = await gate.authorize(
            makeRequest(sql: "INSERT INTO t VALUES (1)", kind: .writeQuery, capabilities: [], caller: .mcpClient(label: nil))
        )

        #expect(decision.deniedReason?.contains("Write") == true)
        #expect(confirm.callCount == 0)
    }

    @Test("Destructive denied when caller lacks destructive capability")
    func destructiveDeniedWithoutCapability() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let decision = await gate.authorize(
            makeRequest(
                sql: "DROP TABLE t",
                kind: .destructiveQuery,
                capabilities: [.mayWrite],
                caller: .mcpClient(label: nil)
            )
        )

        #expect(decision.deniedReason?.contains("Destructive") == true)
    }

    @Test("Confirmation pre-cleared does not bypass the destructive capability guard")
    func confirmationPreClearedDoesNotBypassDestructiveGuard() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .alert, confirm: confirm, auth: auth)

        let decision = await gate.authorize(
            makeRequest(
                sql: "DROP TABLE t",
                kind: .destructiveQuery,
                capabilities: [.confirmationPreCleared],
                caller: .mcpClient(label: nil)
            )
        )

        #expect(decision.deniedReason?.contains("Destructive") == true)
        #expect(confirm.callCount == 0)
    }

    @Test("Multi-statement denied without capability, allowed with it")
    func multiStatementCapability() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let denied = await gate.authorize(
            makeRequest(sql: "SELECT 1; SELECT 2", kind: .readQuery, capabilities: [.mayWrite])
        )
        let allowed = await gate.authorize(
            makeRequest(sql: "SELECT 1; SELECT 2", kind: .readQuery, capabilities: [.mayRunMultiStatement])
        )

        #expect(denied.deniedReason?.contains("Multiple statements") == true)
        #expect(allowed.isAuthorized)
    }

    // MARK: - Pre-cleared and cannot-prompt

    @Test("Pre-cleared caller skips confirmation and auth")
    func preClearedSkipsPrompts() async {
        let confirm = StubConfirming(answer: false)
        let auth = StubAuthenticating(answer: false)
        let gate = makeGate(level: .safeMode, confirm: confirm, auth: auth)

        let decision = await gate.authorize(
            makeRequest(
                sql: "DROP TABLE t",
                kind: .destructiveQuery,
                capabilities: [.mayWrite, .mayRunDestructive, .preCleared],
                caller: .aiAssistant(sessionId: "s1")
            )
        )

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
        #expect(auth.callCount == 0)
    }

    @Test("Confirmation pre-cleared skips confirm but still authenticates under safe mode")
    func confirmationPreClearedSkipsConfirmKeepsAuth() async {
        let confirm = StubConfirming(answer: false)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .safeMode, confirm: confirm, auth: auth)

        let decision = await gate.authorize(
            makeRequest(
                sql: "DROP TABLE t",
                kind: .destructiveQuery,
                capabilities: [.mayWrite, .mayRunDestructive, .confirmationPreCleared],
                caller: .mcpClient(label: nil)
            )
        )

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
        #expect(auth.callCount == 1)
    }

    @Test("Confirmation pre-cleared still denies when authentication fails")
    func confirmationPreClearedAuthFailureDenies() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: false)
        let gate = makeGate(level: .safeMode, confirm: confirm, auth: auth)

        let decision = await gate.authorize(
            makeRequest(
                sql: "DROP TABLE t",
                kind: .destructiveQuery,
                capabilities: [.mayWrite, .mayRunDestructive, .confirmationPreCleared],
                caller: .mcpClient(label: nil)
            )
        )

        #expect(!decision.isAuthorized)
        #expect(confirm.callCount == 0)
    }

    @Test("Cannot-prompt caller is denied when confirmation required")
    func cannotPromptDeniesWhenConfirmationRequired() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .alert, confirm: confirm, auth: auth)

        let decision = await gate.authorize(
            makeRequest(
                sql: "INSERT INTO t VALUES (1)",
                kind: .writeQuery,
                capabilities: [.mayWrite, .cannotPrompt],
                caller: .backgroundMaintenance
            )
        )

        #expect(decision.deniedReason?.contains("Confirmation") == true)
        #expect(confirm.callCount == 0)
    }

    // MARK: - Metadata

    @Test("Metadata reads are always authorized")
    func metadataReadAlwaysAllowed() async {
        let confirm = StubConfirming(answer: false)
        let auth = StubAuthenticating(answer: false)
        let gate = makeGate(level: .safeModeFull, forcesWrite: true, confirm: confirm, auth: auth)

        let decision = await gate.authorize(
            makeRequest(sql: nil, kind: .metadataRead, databaseType: .mongodb)
        )

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
        #expect(auth.callCount == 0)
    }

    // MARK: - Backstop receipt

    @Test("Authorizing sets a task-local receipt inside the body")
    func authorizingSetsReceipt() async throws {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        #expect(AuthorizationReceiptBox.current == nil)

        let insideReceipt = try await gate.authorizing(
            makeRequest(sql: "INSERT INTO t VALUES (1)", kind: .writeQuery)
        ) {
            AuthorizationReceiptBox.current
        }

        #expect(insideReceipt != nil)
        #expect(AuthorizationReceiptBox.current == nil)
    }

    @Test("Authorizing throws when denied")
    func authorizingThrowsWhenDenied() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .readOnly, confirm: confirm, auth: auth)

        await #expect(throws: ExecutionGateError.self) {
            try await gate.authorizing(makeRequest(sql: "DELETE FROM t", kind: .writeQuery)) {}
        }
    }
}
