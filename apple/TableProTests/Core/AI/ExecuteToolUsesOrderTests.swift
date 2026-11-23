//
//  ExecuteToolUsesOrderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProTestSupport
import Testing

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] { lock.withLock { recorded } }

    func record(_ event: String) {
        lock.withLock { recorded.append(event) }
    }
}

private struct RecordingTool: ChatTool {
    let name: String
    let mode: ChatToolMode
    let log: CallLog
    var gate: AsyncGate?
    let description = ""
    let inputSchema: JsonValue = .object(["type": .string("object")])

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        log.record("\(name) started")
        if let gate { await gate.wait() }
        log.record("\(name) finished")
        return ChatToolResult(content: name)
    }
}

@MainActor
struct ExecuteToolUsesOrderTests {
    private func context() -> ChatToolContext {
        ChatToolContext(connectionId: nil, bridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy(), chatMode: .agent)
    }

    private func scope() -> ChatToolScope {
        ChatToolScope(sessionId: UUID(), connectionId: nil, mode: .agent)
    }

    @Test("A round with a write runs its calls one at a time, in the order proposed")
    func writeRoundRunsInOrder() async {
        let log = CallLog()
        let gate = AsyncGate()
        let registry = ChatToolRegistry()
        registry.register(RecordingTool(name: "create_table", mode: .write, log: log, gate: gate))
        registry.register(RecordingTool(name: "insert_rows", mode: .write, log: log))
        let blocks = [
            ToolUseBlock(id: "u1", name: "create_table", input: .object([:])),
            ToolUseBlock(id: "u2", name: "insert_rows", input: .object([:]))
        ]
        let context = context()
        let scope = scope()

        let run = Task {
            await AIChatViewModel.executeToolUses(blocks, scope: scope, context: context, registry: registry)
        }
        await gate.arrived(1)
        await gate.open()
        let results = await run.value

        #expect(log.events == ["create_table started", "create_table finished", "insert_rows started", "insert_rows finished"])
        #expect(results.map(\.toolUseId) == ["u1", "u2"])
    }

    @Test("A round of reads still runs its calls at once")
    func readRoundRunsConcurrently() async {
        let log = CallLog()
        let gate = AsyncGate()
        let registry = ChatToolRegistry()
        registry.register(RecordingTool(name: "describe_orders", mode: .readOnly, log: log, gate: gate))
        registry.register(RecordingTool(name: "describe_items", mode: .readOnly, log: log, gate: gate))
        let blocks = [
            ToolUseBlock(id: "u1", name: "describe_orders", input: .object([:])),
            ToolUseBlock(id: "u2", name: "describe_items", input: .object([:]))
        ]
        let context = context()
        let scope = scope()

        let run = Task {
            await AIChatViewModel.executeToolUses(blocks, scope: scope, context: context, registry: registry)
        }
        let bothHeld: Void? = await BoundedCall.result { await gate.arrived(2) }
        await gate.open()
        let results = await run.value

        #expect(bothHeld != nil)
        #expect(results.map(\.toolUseId) == ["u1", "u2"])
    }

    @Test("Only a built-in read runs beside other calls; a write or an unknown name does not")
    func onlyReadsRunConcurrently() {
        let log = CallLog()
        let registry = ChatToolRegistry()
        registry.register(RecordingTool(name: "reader", mode: .readOnly, log: log))
        registry.register(RecordingTool(name: "writer", mode: .write, log: log))
        registry.register(RecordingTool(name: "destroyer", mode: .agentOnly, log: log))

        #expect(registry.onlyReads(toolName: "reader"))
        #expect(!registry.onlyReads(toolName: "writer"))
        #expect(!registry.onlyReads(toolName: "destroyer"))
        #expect(!registry.onlyReads(toolName: "ghost"))
    }
}
