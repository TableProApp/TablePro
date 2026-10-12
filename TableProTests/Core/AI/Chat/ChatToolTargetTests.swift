//
//  ChatToolTargetTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ChatToolTargetTests {
    private static let sessionConnection = UUID()
    private static let otherConnection = UUID()

    private func makeContext(
        connectionId: UUID? = ChatToolTargetTests.sessionConnection,
        approvalWasExplicit: Bool = false
    ) -> ChatToolContext {
        ChatToolContext(
            connectionId: connectionId,
            bridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy(),
            approvalWasExplicit: approvalWasExplicit
        )
    }

    @Test("A call that names no connection acts on the session's own")
    func defaultsToTheSessionConnection() throws {
        let resolved = try ChatToolTarget.resolve(context: makeContext(), input: .object([:]))
        #expect(resolved == Self.sessionConnection)
    }

    @Test("A call that names the session's own connection is allowed")
    func acceptsTheSessionConnection() throws {
        let input = JsonValue.object(["connection_id": .string(Self.sessionConnection.uuidString)])
        let resolved = try ChatToolTarget.resolve(context: makeContext(), input: input)
        #expect(resolved == Self.sessionConnection)
    }

    /// The defect this exists for: approval was computed from the window's connection while the
    /// statement ran against whatever `connection_id` the model supplied, so a connection sitting
    /// at Silent could authorize a write to a different one and skip its Safe Mode.
    @Test("A call that names a different connection is refused, never redirected")
    func refusesAnotherConnection() {
        let input = JsonValue.object(["connection_id": .string(Self.otherConnection.uuidString)])
        #expect(throws: ChatToolTargetError.outsideSession) {
            try ChatToolTarget.resolve(context: makeContext(), input: input)
        }
    }

    @Test("A conversation with no connection attached has nothing to act on")
    func refusesWithNoSessionConnection() {
        let input = JsonValue.object(["connection_id": .string(Self.otherConnection.uuidString)])
        #expect(throws: ChatToolTargetError.noConnection) {
            try ChatToolTarget.resolve(context: makeContext(connectionId: nil), input: input)
        }
    }

    @Test("A malformed connection_id does not smuggle past the check")
    func refusesUnparseableConnectionId() throws {
        let input = JsonValue.object(["connection_id": .string("not-a-uuid")])
        let resolved = try ChatToolTarget.resolve(context: makeContext(), input: input)
        #expect(resolved == Self.sessionConnection)
    }

    @Test("Only an explicit answer pre-clears the execution gate's confirmation")
    func confirmationIsPreClearedOnlyByAClick() {
        #expect(makeContext(approvalWasExplicit: true).writeCapabilities.contains(.confirmationPreCleared))
        #expect(!makeContext(approvalWasExplicit: false).writeCapabilities.contains(.confirmationPreCleared))
    }

    @Test("Carrying an approval outcome leaves the rest of the context alone")
    func carryingKeepsTheSessionConnection() {
        let carried = makeContext().carrying(approvalWasExplicit: true)
        #expect(carried.connectionId == Self.sessionConnection)
        #expect(carried.approvalWasExplicit)
    }

    /// The connection form states the separation: AI Policy governs the in-app assistant, External
    /// Clients governs Raycast, Cursor, Claude Desktop and AppleScript. Authorizing the assistant
    /// through the external gate would have refused every in-app write by default, because
    /// `externalAccess` is `.readOnly` on a new connection.
    @Test("The assistant is not gated by the External Clients level")
    func doesNotConsultExternalAccess() {
        let connection = TestFixtures.makeConnection(type: .mysql)
        #expect(connection.externalAccess == .readOnly)
        #expect(connection.aiPolicy == nil)
    }

    /// A parameter the session can only ever ignore or refuse should not be advertised to the model.
    @Test("No in-app tool publishes a connection_id parameter")
    func noToolPublishesConnectionId() {
        let registry = ChatToolRegistry()
        for tool in ChatToolBootstrap.makeTools() {
            registry.register(tool)
        }
        for tool in registry.allTools {
            guard case .object(let schema) = tool.inputSchema,
                  case .object(let properties)? = schema["properties"] else { continue }
            #expect(properties["connection_id"] == nil, "\(tool.name) still publishes connection_id")
        }
    }
}
