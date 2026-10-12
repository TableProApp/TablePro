//
//  ScriptingPolicyTests.swift
//  TableProTests
//
//  What a script is allowed to ask for, and what it is told when the answer is no.
//

import Foundation
@testable import TablePro
import Testing

private actor RecordingExecutionGate: ExecutionGate {
    private(set) var requests: [OperationRequest] = []
    private let decision: OperationDecision

    init(decision: OperationDecision) {
        self.decision = decision
    }

    func authorize(_ request: OperationRequest) async -> OperationDecision {
        requests.append(request)
        return decision
    }

    var lastRequest: OperationRequest? { requests.last }
}

struct ScriptingPolicyTests {
    private func authorized() -> OperationDecision {
        .authorized(
            OperationReceipt(
                connectionId: UUID(),
                kind: .writeQuery,
                effectiveWrite: true,
                grantedAt: Date(),
                token: UUID()
            )
        )
    }

    /// A script may write and may drop, but it never arrives pre-cleared: `preCleared` and
    /// `confirmationPreCleared` are what would let a caller skip the Safe Mode dialog, and no
    /// external caller gets to assert on its own that a person already agreed.
    @Test("A scripted statement reaches the execution gate as an AppleScript caller that may be asked")
    func scriptedStatementsAreNeverPreCleared() async throws {
        let gate = RecordingExecutionGate(decision: authorized())
        let connectionId = UUID()

        try await ExternalStatementGate.authorizeExecution(
            sql: "DELETE FROM users WHERE id = 1",
            connectionId: connectionId,
            databaseType: .postgresql,
            caller: .appleScript(client: "Script Editor"),
            capabilities: ScriptQueryRunner.capabilities(on: .postgresql),
            operationDescription: "Script Editor wants to run a query on \"Production\"",
            gate: gate
        )

        let request = try #require(await gate.lastRequest)
        #expect(request.caller == .appleScript(client: "Script Editor"))
        #expect(request.connectionId == connectionId)
        #expect(request.capabilities.contains(.mayWrite))
        #expect(request.capabilities.contains(.mayRunDestructive))
        #expect(!request.capabilities.contains(.preCleared))
        #expect(!request.capabilities.contains(.confirmationPreCleared))
        #expect(!request.capabilities.contains(.cannotPrompt))
    }

    /// A script runs one statement, except on SQL Server, where the script is the unit (#3078). `classify` refuses
    /// several statements everywhere else before this point; the capability is the second line.
    @Test("A script carries permission to run several statements at once only where the engine takes scripts")
    func scriptsRunSeveralStatementsOnlyWhereScriptsAreTheUnit() {
        let sqlServer = ScriptQueryRunner.capabilities(on: .mssql)
        #expect(sqlServer == [.mayWrite, .mayRunDestructive, .mayRunMultiStatement])
        for engine: DatabaseType in [.postgresql, .mysql, .sqlite, .oracle] {
            #expect(!ScriptQueryRunner.capabilities(on: engine).contains(.mayRunMultiStatement), "\(engine.rawValue)")
        }
    }

    /// The execution gate counts statements before it asks Safe Mode anything, so this holds at Silent too.
    @Test("A SQL Server script from a script clears the execution gate, and several statements elsewhere do not")
    @MainActor
    func sqlServerScriptClearsTheExecutionGate() async throws {
        let gate = DefaultExecutionGate(
            confirming: StubConfirming(answer: false),
            authenticating: StubAuthenticating(answer: false),
            safeModeLevelResolver: { _ in .silent },
            forcesWriteResolver: { _ in false }
        )

        for script in ["SELECT 1 AS a;\nSELECT 2 AS b;", "SELECT 1 AS a\nGO\nSELECT 2 AS b", "SELECT 1 AS a\nGO 3"] {
            try await ExternalStatementGate.authorizeExecution(
                sql: script,
                connectionId: UUID(),
                databaseType: .mssql,
                caller: .appleScript(client: nil),
                capabilities: ScriptQueryRunner.capabilities(on: .mssql),
                operationDescription: "a query",
                gate: gate
            )
        }

        await #expect(throws: ExternalStatementGateError.denied(
            String(localized: "Multiple statements are not permitted for this client")
        )) {
            try await ExternalStatementGate.authorizeExecution(
                sql: "SELECT 1; SELECT 2",
                connectionId: UUID(),
                databaseType: .postgresql,
                caller: .appleScript(client: nil),
                capabilities: ScriptQueryRunner.capabilities(on: .postgresql),
                operationDescription: "a query",
                gate: gate
            )
        }
    }

    @Test("A denied statement throws the gate's own reason, so the script can read it")
    func denialCarriesItsReason() async throws {
        let gate = RecordingExecutionGate(decision: .denied(reason: "Operation cancelled by user"))

        await #expect(throws: ExternalStatementGateError.denied("Operation cancelled by user")) {
            try await ExternalStatementGate.authorizeExecution(
                sql: "DELETE FROM users",
                connectionId: UUID(),
                databaseType: .postgresql,
                caller: .appleScript(client: nil),
                capabilities: [.mayWrite, .mayRunDestructive],
                operationDescription: "a query",
                gate: gate
            )
        }
    }

    // MARK: - Errors a script sees

    @Test("A refusal keeps its wording, because that wording is what tells the author what to change")
    func refusalsKeepTheirWording() {
        let refusal = ScriptingError.from(
            ExternalStatementGateError.denied("This connection is read only for external clients.")
        )
        #expect(refusal.errorDescription == "This connection is read only for external clients.")
        #expect(refusal.number == -10_000)
    }

    @Test("A malformed request is told apart from a refusal, because the fix is different")
    func malformedRequestsUseTheirOwnNumber() {
        let malformed = ScriptingError.from(
            ExternalStatementGateError.invalidArgument("Send one statement at a time.")
        )
        #expect(malformed.number == -50)
        #expect(malformed.errorDescription == "Send one statement at a time.")
    }

    @Test("A missing connection is reported as no such object, which is what a script catches on")
    func missingObjectsUseTheStandardNumber() {
        let missing = ScriptingError.from(DatabaseAccessError.notFound("No saved connection has that id."))
        #expect(missing.number == -1_728)
        #expect(missing.errorDescription == "No saved connection has that id.")
    }

    @Test("A closed connection is a failure a script can act on, not a missing object")
    func notConnectedIsAFailure() {
        let error = ScriptingError.from(DatabaseAccessError.notConnected(UUID()))
        #expect(error.number == -10_000)
        #expect(error.errorDescription == String(localized: "The connection is not open. Connect it first."))
    }

    // MARK: - Limits

    /// Deliberately independent of the MCP settings, so tuning the MCP server never changes what a
    /// script gets back.
    @Test("Row limit and timeout have their own defaults and ceilings")
    func limitsAreScriptingsOwn() {
        #expect(ScriptQueryRunner.defaultRowLimit == 500)
        #expect(ScriptQueryRunner.maximumRowLimit == 10_000)
        #expect(ScriptQueryRunner.defaultTimeoutSeconds == 30)
        #expect(ScriptQueryRunner.maximumTimeoutSeconds == 600)
    }
}
