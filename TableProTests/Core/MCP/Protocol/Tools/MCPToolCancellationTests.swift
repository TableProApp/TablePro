//
//  MCPToolCancellationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

private actor CancellationWitness {
    private(set) var reasons: [MCPCancellationReason] = []

    func record(_ reason: MCPCancellationReason) {
        reasons.append(reason)
    }

    func count() -> Int {
        reasons.count
    }
}

@Suite("Cancellation reaches the running statement")
struct MCPToolCancellationTests {
    private let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: "public")

    @Test("A cancelled request never reaches the driver")
    func cancelledRequestNeverReachesTheDriver() async throws {
        let cancellation = MCPCancellationToken()
        await cancellation.cancel()
        let context = MCPToolTestHarness.context(cancellation: cancellation)

        await #expect(throws: CancellationError.self) {
            _ = try await ToolQueryExecutor.executeAndLog(
                services: MCPToolTestHarness.services(),
                query: "SELECT 1",
                scope: scope,
                maxRows: 10,
                timeoutSeconds: 5,
                context: context,
                secrets: []
            )
        }
    }

    @Test("execute_query reports a cancelled request as a cancellation, not a query failure")
    func executeQueryReportsCancellation() async throws {
        let cancellation = MCPCancellationToken()
        await cancellation.cancel()

        do {
            _ = try await ExecuteQueryTool().call(
                arguments: .object([
                    "connection_id": .string(UUID().uuidString),
                    "query": .string("SELECT 1")
                ]),
                context: MCPToolTestHarness.context(cancellation: cancellation),
                services: MCPToolTestHarness.services()
            )
            Issue.record("Expected the cancelled request to be reported as cancelled")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.requestCancelled)
        }
    }

    @Test("A handler registered while the statement runs is invoked the moment the request is cancelled")
    func inFlightHandlersAreInvoked() async throws {
        let cancellation = MCPCancellationToken()
        let witness = CancellationWitness()

        await cancellation.onCancel { reason in
            await witness.record(reason)
        }
        #expect(await witness.count() == 0)

        await cancellation.cancel(reason: .clientDisconnected)

        #expect(await witness.count() == 1)
        #expect(await witness.reasons.first == .clientDisconnected)
        #expect(await cancellation.isCancelled)
    }

    @Test("A statement that registers late still learns it was cancelled")
    func lateRegistrationStillFires() async throws {
        let cancellation = MCPCancellationToken()
        await cancellation.cancel(reason: .deadlineExceeded)

        let witness = CancellationWitness()
        await cancellation.onCancel { reason in
            await witness.record(reason)
        }

        #expect(await witness.count() == 1)
        #expect(await witness.reasons.first == .deadlineExceeded)
    }

    @Test("Cancelling twice runs the handlers once and keeps the first reason")
    func cancellingTwiceIsIdempotent() async throws {
        let cancellation = MCPCancellationToken()
        let witness = CancellationWitness()
        await cancellation.onCancel { reason in
            await witness.record(reason)
        }

        await cancellation.cancel(reason: .clientRequested("stop"))
        await cancellation.cancel(reason: .serverShuttingDown)

        #expect(await witness.count() == 1)
        #expect(await cancellation.reason == .clientRequested("stop"))
    }

    @Test("Every cancellation reason has a stable label for the audit trail")
    func reasonsHaveStableLabels() {
        #expect(MCPCancellationReason.clientRequested(nil).label == "client_requested")
        #expect(MCPCancellationReason.clientDisconnected.label == "client_disconnected")
        #expect(MCPCancellationReason.deadlineExceeded.label == "deadline_exceeded")
        #expect(MCPCancellationReason.credentialRevoked.label == "credential_revoked")
        #expect(MCPCancellationReason.serverShuttingDown.label == "server_shutting_down")
    }

    @Test("The request context reports cancellation without waiting for a phase boundary")
    func contextReportsCancellationImmediately() async throws {
        let cancellation = MCPCancellationToken()
        let context = MCPToolTestHarness.context(cancellation: cancellation)

        try await context.throwIfCancelled()

        await cancellation.cancel()
        await #expect(throws: CancellationError.self) {
            try await context.throwIfCancelled()
        }
    }
}
