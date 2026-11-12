//
//  ExecutionGateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class StubConfirming: OperationConfirming, @unchecked Sendable {
    private(set) var callCount = 0
    private(set) var lastDestructive = false
    private(set) var lastRequest: OperationConfirmationRequest?
    private let answer: Bool

    init(answer: Bool) {
        self.answer = answer
    }

    func confirm(_ request: OperationConfirmationRequest) async -> Bool {
        callCount += 1
        lastDestructive = request.isDestructive
        lastRequest = request
        return answer
    }
}

final class StubAuthenticating: OperationAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCallCount = 0
    private var storedReason: String?
    private let answer: Bool

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    var lastReason: String? {
        lock.withLock { storedReason }
    }

    init(answer: Bool) {
        self.answer = answer
    }

    func authenticate(reason: String) async -> Bool {
        lock.withLock {
            storedCallCount += 1
            storedReason = reason
        }
        return answer
    }
}

@MainActor
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

    /// A row-scoped DELETE is an ordinary write, so Silent mode sends it straight through. Replaying
    /// one from query history is a single click, which is why that caller asks for the confirmation
    /// its safe-mode level would not give it.
    @Test("A caller that confirms its writes is prompted even in Silent mode")
    func confirmsWritesPromptsUnderSilent() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(
            sql: "DELETE FROM users WHERE id = 5",
            kind: .writeQuery,
            capabilities: CallerCapabilities.interactiveUser.union(.confirmsWrites)
        ))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 1)
        #expect(!confirm.lastDestructive)
        #expect(auth.callCount == 0)
    }

    @Test("A caller that confirms its writes still runs reads without prompting")
    func confirmsWritesLeavesReadsAlone() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(
            sql: "SELECT * FROM users",
            kind: .readQuery,
            capabilities: CallerCapabilities.interactiveUser.union(.confirmsWrites)
        ))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
    }

    /// `effectiveWrite` is true for every statement on a driver that cannot be opened read-only,
    /// so gating the extra prompt on it would ask before every Redis `GET`.
    @Test("A caller that confirms its writes still runs reads on a driver with no read-only mode")
    func confirmsWritesLeavesReadsAloneWhenTheDriverForcesWrite() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, forcesWrite: true, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(
            sql: "SELECT * FROM users",
            kind: .readQuery,
            capabilities: CallerCapabilities.interactiveUser.union(.confirmsWrites)
        ))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
    }

    @Test("A confirmed write that the user cancels is denied")
    func confirmsWritesCancelled() async {
        let confirm = StubConfirming(answer: false)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(
            sql: "UPDATE users SET name = 'x' WHERE id = 5",
            kind: .writeQuery,
            capabilities: CallerCapabilities.interactiveUser.union(.confirmsWrites)
        ))

        #expect(!decision.isAuthorized)
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

    @Test("Silent still confirms a destructive statement that an invisible character precedes")
    func silentConfirmsDestructiveBehindInvisibleCharacter() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(sql: "\u{FEFF}DROP TABLE t", kind: .readQuery))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 1)
        #expect(confirm.lastDestructive)
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

    @Test("A Cancel at the confirmation is told apart from a refusal")
    func cancelCarriesItsCause() async {
        let gate = makeGate(level: .silent, confirm: StubConfirming(answer: false), auth: StubAuthenticating(answer: true))

        let decision = await gate.authorize(makeRequest(sql: "TRUNCATE t", kind: .destructiveQuery))

        guard case .denied(_, let cause) = decision else {
            Issue.record("A Cancel must deny")
            return
        }
        #expect(cause == .cancelledByUser)
        guard case .cancelledByUser = decision.denialError else {
            Issue.record("A Cancel must throw as a Cancel, got \(String(describing: decision.denialError))")
            return
        }
    }

    @Test("Read-Only and a declined Touch ID are refusals, not a Cancel")
    func refusalsCarryThePolicyCause() async {
        let readOnly = await makeGate(
            level: .readOnly, confirm: StubConfirming(answer: true), auth: StubAuthenticating(answer: true)
        ).authorize(makeRequest(sql: "DELETE FROM t WHERE id = 1", kind: .writeQuery))
        let declined = await makeGate(
            level: .safeMode, confirm: StubConfirming(answer: true), auth: StubAuthenticating(answer: false)
        ).authorize(makeRequest(sql: "DELETE FROM t WHERE id = 1", kind: .writeQuery))

        for decision in [readOnly, declined] {
            guard case .denied(_, let cause) = decision else {
                Issue.record("Expected a denial")
                continue
            }
            #expect(cause == .policy)
            guard case .denied = decision.denialError else {
                Issue.record("A refusal must throw as a refusal, got \(String(describing: decision.denialError))")
                continue
            }
        }
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

    @Test("Read-only runs a read that an invisible character precedes")
    func readOnlyAllowsReadBehindInvisibleCharacter() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .readOnly, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(sql: "\u{0008}SELECT 1", kind: .readQuery))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
    }

    /// SQL Server rejected a text holding a `GO` line outright, so nothing after one ever ran. A script is now cut at
    /// its `GO` lines and each batch runs, so the gate has to see the statement behind one.
    @Test("Read-only denies a DROP that a GO line puts in a batch of its own")
    func readOnlyDeniesDropBehindGoLine() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .readOnly, confirm: confirm, auth: auth)
        let script = "SELECT 1\nGO\nDROP TABLE t"

        let declared = await gate.authorize(makeRequest(
            sql: script,
            kind: OperationKind.worst(
                of: QueryClassifier.statements(of: script, grammar: DatabaseType.mssql.lexicalGrammar),
                databaseType: .mssql
            ),
            databaseType: .mssql
        ))
        let understated = await gate.authorize(makeRequest(sql: script, kind: .readQuery, databaseType: .mssql))

        #expect(!declared.isAuthorized)
        #expect(!understated.isAuthorized)
        #expect(confirm.callCount == 0)
    }

    /// T-SQL needs no `;` between statements, and Azure SQL Edge 15.0 ran the second statement of each text whole.
    @Test("Read-only denies a statement SQL Server runs without a terminator", arguments: [
        "SELECT 1\nDROP TABLE t",
        "SELECT 1 DELETE FROM t",
        "PRINT 'x' UPDATE t SET c = 1",
        "SELECT 1DELETE FROM t",
        "SELECT 1 EXEC('DELETE FROM t')",
        "SELECT 1\nUPDATE [t] SET c = 1",
        "PRINT 1\nSELECT [a], [b] INTO x FROM t",
    ])
    func readOnlyDeniesUnterminatedStatement(sql: String) async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .readOnly, confirm: confirm, auth: auth)
        let statements = QueryClassifier.statements(of: sql, grammar: DatabaseType.mssql.lexicalGrammar)

        let declared = await gate.authorize(makeRequest(
            sql: sql,
            kind: OperationKind.worst(of: statements, databaseType: .mssql),
            databaseType: .mssql
        ))
        let understated = await gate.authorize(makeRequest(sql: sql, kind: .readQuery, databaseType: .mssql))

        #expect(declared.deniedReason?.contains("read-only") == true)
        #expect(understated.deniedReason?.contains("read-only") == true)
        #expect(confirm.callCount == 0)
    }

    @Test("Read-only runs a SQL Server read that only names a statement keyword", arguments: [
        "SELECT deleted_at, last_update FROM t WHERE id IN (SELECT id FROM s)",
        "SELECT 1\nSELECT 2",
        "SELECT CASE WHEN a = 1 THEN 'x' ELSE 'y' END FROM t OPTION (MERGE JOIN)",
    ])
    func readOnlyRunsUnterminatedRead(sql: String) async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .readOnly, confirm: confirm, auth: auth)

        let decision = await gate.authorize(makeRequest(sql: sql, kind: .readQuery, databaseType: .mssql))

        #expect(decision.isAuthorized)
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
            makeRequest(sql: "SELECT 1", kind: .readQuery, databaseType: DatabaseType(rawValue: "FutureStore"))
        )

        #expect(decision.deniedReason?.contains("read-only") == true)
    }

    // MARK: - Engines without a read-only mode

    @Test("Only an engine the classifier cannot prove reads on is forced to write")
    func forcedWriteFallsBackToTheDeclaration() {
        for databaseType in [DatabaseType.mongodb, .redis, .etcd, .sapHana] {
            #expect(!ExecutionGateProvider.forcesWrite(databaseType, supportsReadOnlyMode: false))
        }
        let unknown = DatabaseType(rawValue: "FutureStore")
        #expect(ExecutionGateProvider.forcesWrite(unknown, supportsReadOnlyMode: false))
        #expect(!ExecutionGateProvider.forcesWrite(unknown, supportsReadOnlyMode: true))
    }

    @Test("Read-only runs a MongoDB read and blocks a MongoDB write")
    func readOnlyRunsMongoReads() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let forcesWrite = ExecutionGateProvider.forcesWrite(.mongodb, supportsReadOnlyMode: false)
        let gate = makeGate(level: .readOnly, forcesWrite: forcesWrite, confirm: confirm, auth: auth)

        let read = await gate.authorize(makeRequest(
            sql: #"db.c.find({}, {"_id": 1}).limit(1)"#,
            kind: .readQuery,
            databaseType: .mongodb
        ))
        let write = await gate.authorize(
            makeRequest(sql: "db.c.insertOne({a: 1})", kind: .writeQuery, databaseType: .mongodb)
        )

        #expect(read.isAuthorized)
        #expect(write.deniedReason?.contains("read-only") == true)
    }

    /// A run of several statements reaches the gate as one text.
    @Test("Alert confirms a MongoDB write but not a run of reads")
    func alertConfirmsOnlyMongoWrites() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let forcesWrite = ExecutionGateProvider.forcesWrite(.mongodb, supportsReadOnlyMode: false)
        let gate = makeGate(level: .alert, forcesWrite: forcesWrite, confirm: confirm, auth: auth)

        let reads = await gate.authorize(makeRequest(
            sql: "db.orders.find({status: \"open\"})\ndb.orders.aggregate([{$group: {_id: \"$region\"}}])",
            kind: .readQuery,
            databaseType: .mongodb
        ))
        #expect(reads.isAuthorized)
        #expect(confirm.callCount == 0)

        let write = await gate.authorize(makeRequest(
            sql: "db.orders.find({})\ndb.orders.updateOne({_id: 1}, {$set: {a: 1}})",
            kind: .writeQuery,
            databaseType: .mongodb
        ))
        #expect(write.isAuthorized)
        #expect(confirm.callCount == 1)
    }

    @Test("Read-only runs reads on Redis, etcd and SAP HANA")
    func readOnlyRunsReadsOnEnginesWithoutReadOnlyMode() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let reads: [(DatabaseType, String)] = [(.redis, "GET session:1"), (.etcd, "get config/app"), (.sapHana, "SELECT * FROM DUMMY")]
        for (databaseType, sql) in reads {
            let forcesWrite = ExecutionGateProvider.forcesWrite(databaseType, supportsReadOnlyMode: false)
            let gate = makeGate(level: .readOnly, forcesWrite: forcesWrite, confirm: confirm, auth: auth)
            let decision = await gate.authorize(makeRequest(sql: sql, kind: .readQuery, databaseType: databaseType))
            #expect(decision.isAuthorized, "\(databaseType.rawValue): \(sql)")
        }
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

    /// macOS shows the reason as "<app> is trying to <reason>.", so a capitalised imperative read
    /// "TablePro is trying to Authenticate to execute database operations."
    @Test("The Touch ID reason completes the sentence macOS puts it in")
    func authenticationReasonCompletesTheSystemSentence() async throws {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .safeMode, confirm: confirm, auth: auth)

        _ = await gate.authorize(makeRequest(sql: "UPDATE t SET a=1", kind: .writeQuery))

        let reason = try #require(auth.lastReason)
        #expect(reason == DefaultExecutionGate.authenticationReason)
        #expect(reason.first?.isUppercase != true, "\(reason) starts with a capital")
        #expect(!reason.hasSuffix(".") && !reason.hasSuffix("\u{3002}"), "\(reason) closes the sentence")
    }

    /// Every shipped language supplies its own closing mark after the reason ("đang cố gắng %@.",
    /// "正在尝试%@。"), so a translation that capitalises or closes it reads wrong in the same way.
    @Test("Every translation of the Touch ID reason continues the system sentence")
    func authenticationReasonTranslationsContinueTheSentence() throws {
        let units = try StringCatalog.loadAll()
            .flatMap(\.translatedUnits)
            .filter { $0.key == "execute database operations" }

        #expect(units.count >= 5, "Expected the reason in every shipped language, found \(units.count)")
        for unit in units {
            #expect(unit.value.first?.isUppercase != true, "\(unit.description) starts with a capital")
            #expect(!unit.value.hasSuffix(".") && !unit.value.hasSuffix("\u{3002}"), "\(unit.description) closes the sentence")
        }
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

    @Test("A DROP written after a read without a terminator is destructive for a caller that may only write")
    func unterminatedDropNeedsTheDestructiveCapability() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let decision = await gate.authorize(
            makeRequest(
                sql: "SELECT 1 DROP TABLE t",
                kind: .readQuery,
                capabilities: [.mayWrite],
                databaseType: .mssql,
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

    @Test("A trailing comment after the semicolon is not denied as multi-statement")
    func trailingCommentNotDeniedAsMultiStatement() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let decision = await gate.authorize(
            makeRequest(sql: "SELECT 1; -- note", kind: .readQuery, capabilities: [.mayWrite])
        )

        #expect(decision.isAuthorized)
    }

    @Test("An invisible character after the semicolon is not denied as multi-statement")
    func trailingInvisibleCharacterNotDeniedAsMultiStatement() async {
        let confirm = StubConfirming(answer: true)
        let auth = StubAuthenticating(answer: true)
        let gate = makeGate(level: .silent, confirm: confirm, auth: auth)

        let decision = await gate.authorize(
            makeRequest(sql: "SELECT 1;\n\u{FEFF}\u{0008}", kind: .readQuery, capabilities: [.mayWrite])
        )

        #expect(decision.isAuthorized)
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

    // MARK: - Read-Only function calls on a driver without the engine's read-only mode

    private func makeReadOnlyGate(
        level: SafeModeLevel = .readOnly,
        policy: ReadOnlyFunctionPolicy,
        confirm: StubConfirming
    ) -> DefaultExecutionGate {
        DefaultExecutionGate(
            confirming: confirm,
            authenticating: StubAuthenticating(answer: true),
            safeModeLevelResolver: { _ in level },
            forcesWriteResolver: { _ in false },
            readOnlyFunctionPolicyResolver: { _, _ in policy }
        )
    }

    private static let writableFunctions = ReadOnlyFunctionPolicy(functionsCanWrite: true, levelIsHeld: false)

    @Test("Read-Only asks before a read that calls a function the engine could let write")
    func readOnlyAsksBeforeAFunctionCall() async {
        let confirm = StubConfirming(answer: true)
        let gate = makeReadOnlyGate(policy: Self.writableFunctions, confirm: confirm)

        let decision = await gate.authorize(makeRequest(sql: "SELECT purge_orders()", kind: .readQuery))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 1)
        #expect(confirm.lastRequest?.sql == "SELECT purge_orders()")
        #expect(confirm.lastDestructive == false)
    }

    @Test("A Cancel at that question is a Cancel, and nothing runs")
    func readOnlyFunctionCallCancelled() async {
        let confirm = StubConfirming(answer: false)
        let gate = makeReadOnlyGate(policy: Self.writableFunctions, confirm: confirm)

        let decision = await gate.authorize(makeRequest(sql: "SELECT purge_orders()", kind: .readQuery))

        guard case .denied(_, let cause) = decision else {
            Issue.record("A Cancel must deny")
            return
        }
        #expect(cause == .cancelledByUser)
    }

    @Test("A managed policy or an engine floor holding Read-Only refuses the call without asking")
    func heldReadOnlyRefusesAFunctionCall() async {
        let confirm = StubConfirming(answer: true)
        let gate = makeReadOnlyGate(
            policy: ReadOnlyFunctionPolicy(functionsCanWrite: true, levelIsHeld: true),
            confirm: confirm
        )

        let decision = await gate.authorize(makeRequest(sql: "SELECT purge_orders()", kind: .readQuery))

        guard case .denied(let reason, let cause) = decision else {
            Issue.record("A held Read-Only must refuse")
            return
        }
        #expect(reason.contains("Read-Only"))
        #expect(cause == .policy)
        #expect(confirm.callCount == 0)
    }

    @Test("A caller that cannot prompt is denied the call")
    func readOnlyFunctionCallDeniedWithoutPrompt() async {
        let confirm = StubConfirming(answer: true)
        let gate = makeReadOnlyGate(policy: Self.writableFunctions, confirm: confirm)

        let decision = await gate.authorize(
            makeRequest(sql: "SELECT purge_orders()", kind: .readQuery, capabilities: [.cannotPrompt])
        )

        #expect(decision.deniedReason?.contains("Confirmation") == true)
        #expect(confirm.callCount == 0)
    }

    @Test(
        "Read-Only runs built-ins, keywords before a parenthesis and a plain EXPLAIN without asking",
        arguments: [
            "SELECT COUNT(*), MAX(total), LOWER(name) FROM orders WHERE id IN (1, 2) AND EXISTS (SELECT 1)",
            "SELECT ROW_NUMBER() OVER (PARTITION BY region ORDER BY total) FROM orders",
            "SELECT 'purge_orders()' FROM orders -- purge_orders()",
            "EXPLAIN SELECT purge_orders()",
        ]
    )
    func readOnlyRunsBuiltins(sql: String) async {
        let confirm = StubConfirming(answer: false)
        let gate = makeReadOnlyGate(policy: Self.writableFunctions, confirm: confirm)

        let decision = await gate.authorize(makeRequest(sql: sql, kind: .readQuery))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
    }

    @Test(
        "A qualified name, a quoted name and a call in a later statement are asked about",
        arguments: [
            "SELECT app.count(id) FROM orders",
            "SELECT `purge_orders`() FROM orders",
            "SELECT 1;\nSELECT purge_orders()",
        ]
    )
    func readOnlyAsksAboutAnyOtherCall(sql: String) async {
        let confirm = StubConfirming(answer: false)
        let gate = makeReadOnlyGate(policy: Self.writableFunctions, confirm: confirm)

        let decision = await gate.authorize(
            makeRequest(sql: sql, kind: .readQuery, capabilities: CallerCapabilities.interactiveUser)
        )

        #expect(!decision.isAuthorized)
        #expect(confirm.callCount == 1)
    }

    @Test(
        "A user function named like a keyword another engine leaves unreserved is asked about",
        arguments: [
            "SELECT filter(x) FROM orders",
            "SELECT `within`(1) FROM orders",
            "SELECT keep(1), sets(2) FROM orders",
            "SELECT pivot(total) FROM orders",
            "SELECT array(1) FROM orders",
            "SELECT id FROM orders WHERE total = offset(1)",
            "SELECT join(id) FROM orders",
            "SELECT id FROM orders WHERE status IN (purge_orders())",
            "SELECT 10 DIV pivot(1)",
            "SELECT 10 MOD pivot(1)",
            "SELECT paid XOR offset(1) FROM orders",
            "SELECT id FROM orders WHERE /* don't */ offset(1) = 1",
        ]
    )
    func keywordNamedFunctionIsAsked(sql: String) async {
        let confirm = StubConfirming(answer: false)
        let gate = makeReadOnlyGate(policy: Self.writableFunctions, confirm: confirm)

        let decision = await gate.authorize(makeRequest(sql: sql, kind: .readQuery))

        #expect(!decision.isAuthorized)
        #expect(confirm.callCount == 1)
    }

    @Test(
        "A keyword in the syntax that uses it before a parenthesis runs without asking",
        arguments: [
            "SELECT MAX(sal) KEEP (DENSE_RANK FIRST ORDER BY hired) FROM emp",
            "SELECT LISTAGG(name, ',') WITHIN GROUP (ORDER BY name) FROM emp",
            "SELECT * FROM sales PIVOT (SUM(amount) FOR quarter IN ('Q1', 'Q2'))",
            "SELECT region, SUM(total) FROM orders GROUP BY ROLLUP (region)",
            "SELECT region, SUM(total) FROM orders GROUP BY GROUPING SETS ((region), ())",
            "SELECT * FROM orders PARTITION (p1)",
            "SELECT * FROM orders WHERE total = ANY (SELECT total FROM refunds)",
            "SELECT * FROM orders o JOIN (SELECT id FROM refunds) r ON o.id = r.id",
            "SELECT CASE WHEN (total > 0) THEN 1 ELSE 0 END FROM orders",
        ]
    )
    func keywordSyntaxRuns(sql: String) async {
        let confirm = StubConfirming(answer: false)
        let gate = makeReadOnlyGate(policy: Self.writableFunctions, confirm: confirm)

        let decision = await gate.authorize(makeRequest(sql: sql, kind: .readQuery, databaseType: .oracle))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
    }

    @Test(
        "A word operator before a parenthesis runs without asking",
        arguments: [
            "SELECT 10 DIV (2), paid XOR (refunded) FROM orders",
            "SELECT id FROM orders WHERE name REGEXP ('^a') OR name RLIKE ('b$')",
            "SELECT id FROM orders WHERE note LIKE 'a!%' ESCAPE ('!')",
        ]
    )
    func wordOperatorsRun(sql: String) async {
        let confirm = StubConfirming(answer: false)
        let gate = makeReadOnlyGate(policy: Self.writableFunctions, confirm: confirm)

        let decision = await gate.authorize(makeRequest(sql: sql, kind: .readQuery, databaseType: .mysql))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
    }

    @Test(
        "The fallback engines' everyday built-ins run without asking",
        arguments: [
            (DatabaseType.oracle, "SELECT DECODE(status, 1, 'open', 'closed'), NVL2(a, b, c), INSTR(name, 'x') FROM orders"),
            (.oracle, "SELECT ADD_MONTHS(created, 1), MONTHS_BETWEEN(a, b), TO_TIMESTAMP(t), SYS_GUID() FROM orders"),
            (.oracle, "SELECT * FROM orders WHERE REGEXP_LIKE(name, '^a') AND TRUNC(created) = LAST_DAY(created)"),
            (.dameng, "SELECT INITCAP(name), LPAD(code, 5, '0'), CHR(65) FROM orders"),
            (.mysql, "SELECT DATE_FORMAT(created_at, '%Y-%m') AS m, COUNT(*) FROM orders GROUP BY m"),
            (.mysql, "SELECT IF(paid, 1, 0), GROUP_CONCAT(name), JSON_EXTRACT(doc, '$.a') FROM orders USE INDEX (idx)"),
            (.mariadb, "SELECT * FROM orders WHERE MATCH (title) AGAINST ('x') AND DATEDIFF(NOW(), created) < 7"),
            (.oceanbase, "SELECT DATE_ADD(created, INTERVAL (1) DAY), UUID(), MD5(name) FROM orders"),
        ]
    )
    func everydayBuiltinsRun(type: DatabaseType, sql: String) async {
        let confirm = StubConfirming(answer: false)
        let gate = makeReadOnlyGate(policy: Self.writableFunctions, confirm: confirm)

        let decision = await gate.authorize(makeRequest(sql: sql, kind: .readQuery, databaseType: type))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
    }

    // GET_LOCK is refused as a write before the question; the others are asked about, and the test answers Cancel.
    @Test(
        "A built-in that locks, sleeps or waits never runs on its own",
        arguments: ["SELECT GET_LOCK('a', 10)", "SELECT SLEEP(5)", "SELECT BENCHMARK(1000, MD5('a'))"]
    )
    func lockingOrSleepingBuiltinDoesNotRun(sql: String) async {
        let confirm = StubConfirming(answer: false)
        let gate = makeReadOnlyGate(policy: Self.writableFunctions, confirm: confirm)

        let decision = await gate.authorize(makeRequest(sql: sql, kind: .readQuery))

        #expect(!decision.isAuthorized)
    }

    @Test("The built-in lists hold nothing that writes, locks, sleeps or reaches a file")
    func builtinListsHoldOnlyReads() {
        let forbidden: Set<String> = [
            "GET_LOCK", "RELEASE_LOCK", "IS_FREE_LOCK", "SLEEP", "PG_SLEEP", "BENCHMARK", "LOAD_FILE", "NEXTVAL",
            "SETVAL", "LAST_INSERT_ID", "SET_CONFIG", "MASTER_POS_WAIT", "SOURCE_POS_WAIT", "TXID_CURRENT",
        ]
        for type in [DatabaseType.oracle, .dameng, .mysql, .mariadb, .oceanbase, .postgresql, .sqlite] {
            let builtins = ReadOnlyFunctionCalls.builtins(for: type)
            #expect(builtins.isDisjoint(with: forbidden))
            #expect(!builtins.contains { $0.hasPrefix("DBMS_") || $0.hasPrefix("UTL_") || $0.hasPrefix("PG_") })
        }
    }

    @Test("A driver that runs the statement in the engine's read-only mode is not asked about")
    func enforcingDriverRunsTheCall() async {
        let confirm = StubConfirming(answer: false)
        let gate = makeReadOnlyGate(policy: ReadOnlyFunctionPolicy(), confirm: confirm)

        let decision = await gate.authorize(makeRequest(sql: "SELECT purge_orders()", kind: .readQuery))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
    }

    @Test("Only Read-Only asks: Silent runs the same call", arguments: [SafeModeLevel.silent, .alert])
    func otherLevelsDoNotAsk(level: SafeModeLevel) async {
        let confirm = StubConfirming(answer: false)
        let gate = makeReadOnlyGate(level: level, policy: Self.writableFunctions, confirm: confirm)

        let decision = await gate.authorize(makeRequest(sql: "SELECT purge_orders()", kind: .readQuery))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
    }

    @Test("A metadata read is never asked about")
    func metadataReadSkipsTheFunctionCheck() async {
        let confirm = StubConfirming(answer: false)
        let gate = makeReadOnlyGate(policy: Self.writableFunctions, confirm: confirm)

        let decision = await gate.authorize(makeRequest(sql: "SELECT pg_get_viewdef(1)", kind: .metadataRead))

        #expect(decision.isAuthorized)
        #expect(confirm.callCount == 0)
    }
}

// Which engines let a function a query calls write, and what the live driver adds to that.
@MainActor
struct ReadOnlyFunctionPolicyTests {
    @Test(
        "Oracle, Dameng, MySQL, MariaDB, OceanBase and the PostgreSQL family count as engines whose functions can write",
        arguments: [DatabaseType.oracle, .dameng, .mysql, .mariadb, .oceanbase, .postgresql, .kingbasees]
    )
    func enginesWhoseFunctionsWrite(type: DatabaseType) {
        #expect(PluginMetadataRegistry.queryFunctionsCanWrite.contains(type))
    }

    @Test(
        "Engines that refuse a write from a function in a query, or have no such function, do not",
        arguments: [
            DatabaseType.mssql, .snowflake, .bigQuery, .trino, .redshift, .clickhouse, .sqlite, .libsql, .duckdb,
            .cassandra, .mongodb, .redis, .tidb, .starrocks, .databend,
        ]
    )
    func enginesWhoseFunctionsDoNotWrite(type: DatabaseType) {
        #expect(!PluginMetadataRegistry.queryFunctionsCanWrite.contains(type))
    }

    @Test("A live MySQL driver without the mode needs the question, and one with it does not")
    func liveDriverDecides() {
        let connection = DatabaseConnection(name: "Shop", database: "shop", type: .mysql, safeModeLevel: .readOnly)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        install(connection, capabilities: [.readOnlyStatements])
        let older = ExecutionGateProvider.readOnlyFunctionPolicy(connectionId: connection.id, databaseType: .mysql)
        install(connection, capabilities: [.readOnlyStatements, .enforcesReadOnlyMode])
        let enforcing = ExecutionGateProvider.readOnlyFunctionPolicy(connectionId: connection.id, databaseType: .mysql)

        #expect(older.functionsCanWrite)
        #expect(!older.levelIsHeld)
        #expect(!enforcing.functionsCanWrite)
        #expect(ExecutionGateProvider.runsAtReadOnly(connection.id))
    }

    private func install(_ connection: DatabaseConnection, capabilities: PluginCapabilities) {
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: CapabilityOnlyDriver(capabilities))
        )
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
    }
}

private final class CapabilityOnlyDriver: PluginDriverStub, @unchecked Sendable {
    private let declared: PluginCapabilities

    init(_ capabilities: PluginCapabilities) {
        declared = capabilities
    }

    var capabilities: PluginCapabilities { declared }
}

// The editor's request for a text the gate must tier by what the server runs, behind each executable comment form.
@MainActor
struct ExecutionGateExecutableCommentTests {
    nonisolated static let hiddenDrops: [(String, DatabaseType)] = QueryClassifierExecutableCommentTests.hiddenDrops.flatMap { sql in
        QueryClassifierExecutableCommentTests.engines.map { (sql, $0) }
    }

    private func authorize(_ sql: String, on databaseType: DatabaseType, at level: SafeModeLevel) async
        -> (decision: OperationDecision, confirm: StubConfirming)
    {
        let confirm = StubConfirming(answer: true)
        let gate = DefaultExecutionGate(
            confirming: confirm,
            authenticating: StubAuthenticating(answer: true),
            safeModeLevelResolver: { _ in level },
            forcesWriteResolver: { _ in false }
        )
        let request = OperationRequest(
            connectionId: UUID(),
            databaseType: databaseType,
            sql: sql,
            kind: OperationKind.worst(of: [sql], databaseType: databaseType),
            caller: .userInterface,
            capabilities: .interactiveUser,
            operationDescription: "Execute Query"
        )
        return (await gate.authorize(request), confirm)
    }

    @Test(
        "A DROP behind an executable comment is refused in Read-Only and asked about as destructive elsewhere",
        arguments: hiddenDrops, SafeModeLevel.allCases
    )
    func hiddenDropAtEveryLevel(text: (String, DatabaseType), level: SafeModeLevel) async {
        let (decision, confirm) = await authorize(text.0, on: text.1, at: level)
        if level == .readOnly {
            #expect(!decision.isAuthorized)
            #expect(confirm.callCount == 0)
        } else {
            #expect(decision.isAuthorized)
            #expect(confirm.callCount == 1)
            #expect(confirm.lastDestructive)
        }
    }

    @Test(
        "A write behind a comment a server reads as plain is refused in Read-Only",
        arguments: [
            "WITH c AS (SELECT 1) /*m! ' */ DELETE FROM orders -- '",
            "SELECT * FROM orders /*m! ' */ INTO OUTFILE '/tmp/x' -- '",
            "SELECT * FROM orders /*!99999 ' */ INTO OUTFILE '/tmp/x' -- '",
        ]
    )
    func hiddenWriteIsRefusedInReadOnly(sql: String) async {
        let (decision, _) = await authorize(sql, on: .mysql, at: .readOnly)
        #expect(!decision.isAuthorized)
    }
}
