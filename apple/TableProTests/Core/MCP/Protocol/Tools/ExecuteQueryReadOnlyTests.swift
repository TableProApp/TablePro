import Foundation
@testable import TablePro
import TableProMCP
import Testing

extension GlobalStateSuites {
    @MainActor
    struct ExecuteQueryReadOnlyTests {
        private struct Observation {
            let refusal: String?
            let succeeded: Bool
            let prompts: [WritePrompt]
            let received: [String]
        }

        private func rig() -> WritePolicyRig {
            WritePolicyRig(
                connection: WritePolicyRig.connection(
                    type: .postgresql,
                    externalAccess: .readWrite,
                    aiPolicy: .askEachTime,
                    safeMode: .silent
                ),
                prompts: WritePolicyPrompts(.approveAll),
                live: true
            )
        }

        private func services(_ rig: WritePolicyRig) -> MCPToolServices {
            MCPToolServices(
                connectionBridge: MCPConnectionBridge(),
                authPolicy: rig.authPolicy,
                settingsProvider: { MCPSettings() },
                queryHistoryManager: ToolTestQueryHistoryStore()
            )
        }

        private func arguments(_ rig: WritePolicyRig, _ sql: String, readOnly: Bool) -> JsonValue {
            var fields: [String: JsonValue] = [
                "connection_id": .string(rig.connection.id.uuidString),
                "query": .string(sql)
            ]
            if readOnly {
                fields["read_only"] = .bool(true)
            }
            return .object(fields)
        }

        private func throughHandler(_ sql: String, readOnly: Bool) async -> Observation {
            let rig = rig()
            defer { rig.tearDown() }
            let params = MCPToolTestHarness.toolCallParams(
                name: ExecuteQueryTool.name,
                arguments: arguments(rig, sql, readOnly: readOnly)
            )
            let context = MCPToolTestHarness.context(params: params)
            do {
                let result = try await ToolsCallHandler(services: services(rig)).handle(params: params, context: context)
                let isError = result.payload["isError"]?.boolValue == true
                let text = result.payload["content"]?.arrayValue?.first?["text"]?.stringValue
                return Observation(
                    refusal: isError ? text : nil,
                    succeeded: !isError,
                    prompts: rig.prompts.prompts,
                    received: rig.driver.received
                )
            } catch let error as MCPProtocolError {
                return Observation(refusal: error.message, succeeded: false, prompts: rig.prompts.prompts, received: rig.driver.received)
            } catch {
                return Observation(refusal: "\(error)", succeeded: false, prompts: rig.prompts.prompts, received: rig.driver.received)
            }
        }

        @Test("A write with read_only is refused before the approval prompt and never reaches the driver")
        func writeRefusedBeforePrompt() async {
            let observed = await throughHandler("UPDATE accounts SET balance = 0", readOnly: true)
            #expect(observed.refusal?.contains(MCPStatementGate.readOnlyRefusal) == true)
            #expect(observed.prompts.isEmpty)
            #expect(observed.received.isEmpty)
        }

        @Test("A read with read_only runs as it would without it")
        func readRuns() async {
            let observed = await throughHandler("SELECT 1", readOnly: true)
            #expect(observed.succeeded)
            #expect(observed.received.contains { $0.contains("SELECT 1") })
        }

        @Test("Without read_only the same write still runs on a Read & Write connection")
        func flagOnlyLowers() async {
            let observed = await throughHandler("UPDATE accounts SET balance = 0", readOnly: false)
            #expect(observed.succeeded)
            #expect(observed.received.contains { $0.contains("UPDATE accounts") })
        }

        @Test("The tool refuses a read_only write on its own, before Safe Mode asks anything")
        func toolRefusesWithoutTheHandler() async throws {
            let rig = rig()
            defer { rig.tearDown() }
            let result = try await ExecuteQueryTool().call(
                arguments: arguments(rig, "DELETE FROM accounts", readOnly: true),
                context: MCPToolTestHarness.context(),
                services: services(rig)
            )
            #expect(result.isError)
            #expect(MCPToolTestHarness.errorText(result) == "denied: \(MCPStatementGate.readOnlyRefusal)")
            #expect(rig.prompts.prompts.isEmpty)
            #expect(rig.driver.received.isEmpty)
        }
    }
}
