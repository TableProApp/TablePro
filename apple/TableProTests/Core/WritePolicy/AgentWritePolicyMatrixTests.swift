//
//  AgentWritePolicyMatrixTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import Testing

final class WritePolicyOutsideServer: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    var received: [String] {
        lock.withLock { calls }
    }

    func call(_ name: String) -> String {
        lock.withLock { calls.append(name) }
        return "ok"
    }
}

extension GlobalStateSuites {
    @MainActor
    struct AgentWritePolicyMatrixTests {
        private struct Observation {
            let refused: Bool
            let prompts: [WritePrompt]
            let received: [String]
            let detail: String
        }

        @MainActor
        private final class Session {
            let suite: EphemeralDefaults
            let store: MCPServerStore
            let registry: ChatToolRegistry
            let server: MCPServerConfiguration
            let outside = WritePolicyOutsideServer()
            let viewModel = AIChatViewModel()

            init() throws {
                suite = try EphemeralDefaults()
                store = MCPServerStore(defaults: suite.defaults, keychain: InMemoryKeychain())
                registry = ChatToolRegistry(serverStore: store)
                server = MCPServerConfiguration(
                    name: "Runbooks",
                    endpoint: URL(string: "https://runbooks.example/mcp") ?? URL(fileURLWithPath: "/")
                )
                for tool in ChatToolBootstrap.makeTools() {
                    registry.registerBuiltIn(tool)
                }
                let recorder = outside
                registry.register(MCPRemoteToolAdapter(
                    server: server,
                    tool: MCPRemoteTool(name: "open_ticket", description: "Open a ticket", inputSchema: .object([:]))
                ) { name, _ in
                    recorder.call(name)
                })
            }

            func toolName(for path: AgentWritePath) -> String {
                path.builtInName ?? server.toolName(for: "open_ticket")
            }
        }

        @Test("Every Agent mode tool that writes has a row in the matrix")
        func everyWritingToolHasARow() {
            let writing = ChatToolBootstrap.makeTools().filter { $0.mode != .readOnly }.map { $0.name }
            let rows = Set(AgentWritePath.builtIns.compactMap(\.builtInName))
            #expect(Set(writing) == rows)
        }

        @Test("An Agent mode write is refused, asks, or runs as the matrix says", arguments: AgentWritePath.allCases)
        func everyCell(path: AgentWritePath) async throws {
            let session = try Session()
            var mismatches: [String] = []
            for cell in AgentWriteCell.all {
                mismatches += await check(path, cell, in: session)
            }
            #expect(mismatches.isEmpty, "\(path.rawValue):\n\(mismatches.joined(separator: "\n"))")
        }

        private func check(_ path: AgentWritePath, _ cell: AgentWriteCell, in session: Session) async -> [String] {
            let expected = AgentWritePath.expected(path, cell)
            let approved = await run(path, cell, answer: .approveAll, in: session)
            var mismatches: [String] = []
            let label = "\(cell), expected \(expected)"

            guard case .runs(let prompts) = expected else {
                if !approved.refused {
                    mismatches.append("\(label): not refused (\(approved.detail))")
                }
                if !approved.received.isEmpty {
                    mismatches.append("\(label): received \(approved.received)")
                }
                return mismatches
            }

            if approved.refused {
                mismatches.append("\(label): refused (\(approved.detail))")
            }
            if approved.prompts != prompts {
                mismatches.append("\(label): asked \(approved.prompts)")
            }
            if approved.received.isEmpty {
                mismatches.append("\(label): nothing reached the database or the server")
            }

            guard let first = prompts.first else { return mismatches }
            let declined = await run(path, cell, answer: .refuseAll, in: session)
            if !declined.refused {
                mismatches.append("\(label), first prompt declined: not refused (\(declined.detail))")
            }
            if !declined.received.isEmpty {
                mismatches.append("\(label), first prompt declined: received \(declined.received)")
            }
            if declined.prompts != [first] {
                mismatches.append("\(label), first prompt declined: asked \(declined.prompts)")
            }
            return mismatches
        }

        // A turn as the chat runs one: AI policy before it starts, the card, then the tool with the card's approval.
        private func run(
            _ path: AgentWritePath,
            _ cell: AgentWriteCell,
            answer: WritePolicyPrompts.Answer,
            in session: Session
        ) async -> Observation {
            let toolName = session.toolName(for: path)
            let prompts = WritePolicyPrompts(answer)
            let rig = WritePolicyRig(
                connection: WritePolicyRig.connection(
                    type: .postgresql,
                    externalAccess: cell.externalAccess,
                    aiPolicy: cell.aiPolicy,
                    safeMode: cell.safeMode,
                    alwaysAllowedTools: cell.alwaysAllowed ? [toolName] : []
                ),
                prompts: prompts,
                live: true
            )
            defer { rig.tearDown() }
            let outsideBefore = session.outside.received.count
            var allowed = session.server
            allowed.allowedConnectionIds = [rig.connection.id]
            session.store.upsert(allowed, token: "matrix")

            func observe(refused: Bool, _ detail: String) -> Observation {
                Observation(
                    refused: refused,
                    prompts: prompts.prompts,
                    received: rig.driver.received + session.outside.received.dropFirst(outsideBefore),
                    detail: detail
                )
            }

            let viewModel = session.viewModel
            viewModel.connection = rig.connection
            var policy = viewModel.resolveConnectionPolicy(settings: AppSettingsManager.shared.ai)
            if policy == .askEachTime {
                guard prompts.ask(.connectionAccess) else { return observe(refused: true, "access declined") }
                viewModel.confirmAIAccess()
                policy = viewModel.resolveConnectionPolicy(settings: AppSettingsManager.shared.ai)
            }
            guard policy == .alwaysAllow else { return observe(refused: true, "AI policy \(String(describing: policy))") }

            var clicked = false
            switch viewModel.computeInitialApprovalState(for: toolName, registry: session.registry) {
            case .approved:
                break
            case .pending:
                guard prompts.ask(.toolCard) else { return observe(refused: true, "card rejected") }
                clicked = true
            case .denied(let reason):
                return observe(refused: true, reason)
            case .cancelled:
                return observe(refused: true, "cancelled")
            }

            let block = ToolUseBlock(id: "matrix", name: toolName, input: path.input)
            let results = await AIChatViewModel.executeToolUses(
                [block],
                scope: ChatToolScope(sessionId: UUID(), connectionId: rig.connection.id, mode: .agent),
                context: ChatToolContext(
                    connectionId: rig.connection.id,
                    bridge: MCPConnectionBridge(),
                    authPolicy: rig.authPolicy,
                    sessionId: UUID()
                ),
                explicitlyApproved: clicked ? [block.id] : [],
                registry: session.registry
            )
            let result = results.first
            return observe(refused: result?.isError ?? true, result?.content ?? "no result")
        }
    }
}
