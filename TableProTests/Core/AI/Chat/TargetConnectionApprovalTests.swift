//
//  TargetConnectionApprovalTests.swift
//  TableProTests
//
//  Eight of the nine chat tools take `connection_id` as a model-fillable input, and
//  `list_connections` is read-only, so it is auto-approved and can enumerate every id first. The
//  approval path used to prefer the model's value over the session's, which meant a write could be
//  gated at a connection the user never opened.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("Target connection approval", .serialized)
@MainActor
struct TargetConnectionApprovalTests {
    private struct WriteTool: ChatTool {
        let name = "execute_query"
        let description = ""
        let inputSchema: JsonValue = .object(["type": .string("object")])
        let mode: ChatToolMode = .write

        func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
            ChatToolResult(content: "ok", isError: false)
        }
    }

    private struct ReadTool: ChatTool {
        let name = "list_tables"
        let description = ""
        let inputSchema: JsonValue = .object(["type": .string("object")])
        let mode: ChatToolMode = .readOnly

        func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
            ChatToolResult(content: "ok", isError: false)
        }
    }

    private struct DestructiveTool: ChatTool {
        let name = "confirm_destructive_operation"
        let description = ""
        let inputSchema: JsonValue = .object(["type": .string("object")])
        let mode: ChatToolMode = .agentOnly

        func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
            ChatToolResult(content: "ok", isError: false)
        }
    }

    private static func registry() -> ChatToolRegistry {
        let registry = ChatToolRegistry()
        registry.register(WriteTool())
        registry.register(ReadTool())
        registry.register(DestructiveTool())
        return registry
    }

    private static func store(assistantConnections: [UUID] = []) -> WorkspaceContentModeStore {
        let suiteName = "com.TablePro.tests.approvalFloor.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("UserDefaults suite \(suiteName) could not be created")
        }
        let store = WorkspaceContentModeStore(defaults: defaults)
        for id in assistantConnections {
            store.setMode(.assistant, connectionId: id)
        }
        return store
    }

    private static func viewModel(
        connection: DatabaseConnection?,
        store: WorkspaceContentModeStore
    ) -> AIChatViewModel {
        let viewModel = AIChatViewModel()
        viewModel.contentModeStore = store
        viewModel.connection = connection
        return viewModel
    }

    private static func input(connectionId: UUID?) -> JsonValue {
        guard let connectionId else { return .object([:]) }
        return .object(["connection_id": .string(connectionId.uuidString)])
    }

    private static func isPending(_ state: ToolApprovalState) -> Bool {
        if case .pending = state { return true }
        return false
    }

    private static func isApproved(_ state: ToolApprovalState) -> Bool {
        if case .approved = state { return true }
        return false
    }

    private static func deniedReason(_ state: ToolApprovalState) -> String? {
        if case .denied(let reason) = state { return reason }
        return nil
    }

    // MARK: - The floor

    @Test("A write on a Silent connection waits for a human while Assistant mode is active")
    func silentConnectionWaitsUnderTheFloor() {
        var connection = DatabaseConnection(name: "Prod", type: .mysql)
        connection.safeModeLevel = .silent
        let viewModel = Self.viewModel(
            connection: connection,
            store: Self.store(assistantConnections: [connection.id])
        )

        let state = viewModel.computeInitialApprovalState(
            for: "execute_query",
            input: Self.input(connectionId: nil),
            registry: Self.registry()
        )

        #expect(Self.isPending(state), "expected pending, got \(state)")
    }

    @Test("The same write is auto-approved once the mode is off")
    func silentConnectionIsApprovedWithoutTheFloor() {
        var connection = DatabaseConnection(name: "Prod", type: .mysql)
        connection.safeModeLevel = .silent
        let viewModel = Self.viewModel(connection: connection, store: Self.store())

        let state = viewModel.computeInitialApprovalState(
            for: "execute_query",
            input: Self.input(connectionId: nil),
            registry: Self.registry()
        )

        #expect(Self.isApproved(state), "expected approved, got \(state)")
    }

    @Test("Read-Only still blocks the write in Assistant mode; the floor is not a maximum")
    func readOnlyStillBlocks() {
        var connection = DatabaseConnection(name: "Reporting", type: .mysql)
        connection.safeModeLevel = .readOnly
        let viewModel = Self.viewModel(
            connection: connection,
            store: Self.store(assistantConnections: [connection.id])
        )

        let state = viewModel.computeInitialApprovalState(
            for: "execute_query",
            input: Self.input(connectionId: nil),
            registry: Self.registry()
        )

        #expect(Self.deniedReason(state) != nil, "expected denied, got \(state)")
    }

    /// The floor is keyed by connection, so a second connection sitting in browse mode is not
    /// dragged into Confirm Writes by the one that is in Assistant mode.
    @Test("The floor reaches only the connection whose window is in Assistant mode")
    func floorIsScopedToItsConnection() {
        var assistant = DatabaseConnection(name: "Assistant", type: .mysql)
        assistant.safeModeLevel = .silent
        var browse = DatabaseConnection(name: "Browse", type: .mysql)
        browse.safeModeLevel = .silent
        let store = Self.store(assistantConnections: [assistant.id])

        let assistantState = Self.viewModel(connection: assistant, store: store)
            .computeInitialApprovalState(
                for: "execute_query",
                input: Self.input(connectionId: nil),
                registry: Self.registry()
            )
        let browseState = Self.viewModel(connection: browse, store: store)
            .computeInitialApprovalState(
                for: "execute_query",
                input: Self.input(connectionId: nil),
                registry: Self.registry()
            )

        #expect(Self.isPending(assistantState), "assistant connection: \(assistantState)")
        #expect(Self.isApproved(browseState), "browse connection: \(browseState)")
    }

    // MARK: - Session pinning

    @Test("A write aimed at another connection is refused, and the message names this session's")
    func crossConnectionWriteIsRefused() {
        let session = DatabaseConnection(name: "Staging", type: .mysql)
        let other = DatabaseConnection(name: "Production", type: .mysql)
        let viewModel = Self.viewModel(connection: session, store: Self.store())

        let state = viewModel.computeInitialApprovalState(
            for: "execute_query",
            input: Self.input(connectionId: other.id),
            registry: Self.registry()
        )

        let reason = Self.deniedReason(state)
        #expect(reason != nil, "expected denied, got \(state)")
        #expect(reason?.contains(session.name) == true, "message should name the session's connection: \(reason ?? "nil")")
    }

    @Test("A destructive call aimed at another connection is refused too")
    func crossConnectionDestructiveIsRefused() {
        let session = DatabaseConnection(name: "Staging", type: .mysql)
        let other = DatabaseConnection(name: "Production", type: .mysql)
        let viewModel = Self.viewModel(connection: session, store: Self.store())

        let state = viewModel.computeInitialApprovalState(
            for: "confirm_destructive_operation",
            input: Self.input(connectionId: other.id),
            registry: Self.registry()
        )

        #expect(Self.deniedReason(state) != nil, "expected denied, got \(state)")
    }

    @Test("Naming this session's own connection is allowed")
    func namingTheSessionConnectionIsAllowed() {
        var connection = DatabaseConnection(name: "Prod", type: .mysql)
        connection.safeModeLevel = .alert
        let viewModel = Self.viewModel(connection: connection, store: Self.store())

        let state = viewModel.computeInitialApprovalState(
            for: "execute_query",
            input: Self.input(connectionId: connection.id),
            registry: Self.registry()
        )

        #expect(Self.isPending(state), "expected pending, got \(state)")
    }

    @Test("Session pinning also refuses when the tool would otherwise be auto-approved")
    func crossConnectionRefusalBeatsAlwaysAllow() {
        var session = DatabaseConnection(name: "Staging", type: .mysql)
        session.safeModeLevel = .silent
        session.aiAlwaysAllowedTools.insert("execute_query")
        let other = DatabaseConnection(name: "Production", type: .mysql)
        let viewModel = Self.viewModel(connection: session, store: Self.store())

        let state = viewModel.computeInitialApprovalState(
            for: "execute_query",
            input: Self.input(connectionId: other.id),
            registry: Self.registry()
        )

        #expect(Self.deniedReason(state) != nil, "expected denied, got \(state)")
    }

    // MARK: - Fail closed

    @Test("A session with no connection refuses a write instead of running it unchecked")
    func noConnectionRefusesTheWrite() {
        let viewModel = Self.viewModel(connection: nil, store: Self.store())

        let state = viewModel.computeInitialApprovalState(
            for: "execute_query",
            input: Self.input(connectionId: nil),
            registry: Self.registry()
        )

        #expect(Self.deniedReason(state) != nil, "expected denied, got \(state)")
    }

    @Test("A session with no connection refuses a destructive call too")
    func noConnectionRefusesTheDestructiveCall() {
        let viewModel = Self.viewModel(connection: nil, store: Self.store())

        let state = viewModel.computeInitialApprovalState(
            for: "confirm_destructive_operation",
            input: Self.input(connectionId: nil),
            registry: Self.registry()
        )

        #expect(Self.deniedReason(state) != nil, "expected denied, got \(state)")
    }

    /// Read-only tools carry no risk of a write, and refusing them would break the schema lookups
    /// every mode depends on, so they stay approved without a connection.
    @Test("A read-only tool is still approved with no connection")
    func readOnlyToolIsUnaffected() {
        let viewModel = Self.viewModel(connection: nil, store: Self.store())

        let state = viewModel.computeInitialApprovalState(
            for: "list_tables",
            input: Self.input(connectionId: nil),
            registry: Self.registry()
        )

        #expect(Self.isApproved(state), "expected approved, got \(state)")
    }

    // MARK: - Always Allow

    @Test("Always Allow is read from the target connection and skips the prompt")
    func alwaysAllowedToolIsApproved() {
        var connection = DatabaseConnection(name: "Prod", type: .mysql)
        connection.safeModeLevel = .alert
        connection.aiAlwaysAllowedTools.insert("execute_query")
        let viewModel = Self.viewModel(
            connection: connection,
            store: Self.store(assistantConnections: [connection.id])
        )

        let state = viewModel.computeInitialApprovalState(
            for: "execute_query",
            input: Self.input(connectionId: nil),
            registry: Self.registry()
        )

        #expect(Self.isApproved(state), "expected approved, got \(state)")
    }

    /// Always Allow must never reach a destructive call: each DROP, TRUNCATE and ALTER…DROP is
    /// confirmed on its own, floor or no floor.
    @Test("Always Allow does not cover a destructive call")
    func alwaysAllowDoesNotCoverDestructive() {
        var connection = DatabaseConnection(name: "Prod", type: .mysql)
        connection.safeModeLevel = .silent
        connection.aiAlwaysAllowedTools.insert("confirm_destructive_operation")
        let viewModel = Self.viewModel(connection: connection, store: Self.store())

        let state = viewModel.computeInitialApprovalState(
            for: "confirm_destructive_operation",
            input: Self.input(connectionId: nil),
            registry: Self.registry()
        )

        #expect(Self.isPending(state), "expected pending, got \(state)")
    }
}
